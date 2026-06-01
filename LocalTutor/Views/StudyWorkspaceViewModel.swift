//
//  StudyWorkspaceViewModel.swift
//  LocalTutor
//
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ModelDownloadPhase: Equatable {
    case checking
    case downloading
    case loading
    case ready
    case failed
}

struct ModelDownloadStatus: Equatable {
    var profileID: String
    var profileName: String
    var message: String
    var fraction: Double?
    var phase: ModelDownloadPhase
}

@MainActor
final class StudyWorkspaceViewModel: ObservableObject {
    // Persisted study-session history. Each session owns its own sources + turns.
    @Published private(set) var sessions: [StudySession] = []
    @Published var currentSessionID: UUID = UUID()

    // Ephemeral, not persisted with the session.
    @Published var composerText: String = ""
    @Published var globalError: String?
    @Published var modelDownloadStatus: ModelDownloadStatus?

    /// The session that owns the in-flight generation, if any.
    @Published private(set) var runningSessionID: UUID?

    @AppStorage(AppStorageKeys.selectedProfileID) private var storedProfileID: String = ""

    private let inferenceService: any InferenceService
    private let store = SessionStore()
    private var runTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var modelPreloadTask: Task<Void, Error>?
    private var modelPreloadProfileID: String?
    private var modelDownloadDismissTask: Task<Void, Never>?
    private var hasLoaded = false

    // Streaming coalescing: buffer tokens and flush to the UI on a frame cadence
    // instead of mutating published state on every single token.
    private var pendingChunks: String = ""
    private var flushScheduled = false

    init(inferenceService: any InferenceService = LocalModelRunner()) {
        self.inferenceService = inferenceService
        bootstrap()
    }

    convenience init(runner: LocalModelRunner) {
        self.init(inferenceService: runner)
    }

    private func bootstrap() {
        var loaded = SessionStore.loadSync()
        if loaded.isEmpty {
            loaded = [StudySession()]
        } else {
            loaded.sort { $0.updatedAt > $1.updatedAt }
        }
        sessions = loaded
        currentSessionID = loaded[0].id
        hasLoaded = true
    }

    // MARK: - Current session access

    private var currentIndex: Int? {
        sessions.firstIndex(where: { $0.id == currentSessionID })
    }

    var currentSession: StudySession {
        get {
            if let index = currentIndex {
                return sessions[index]
            }
            return sessions.first ?? StudySession()
        }
        set {
            guard let index = currentIndex else { return }
            sessions[index] = newValue
        }
    }

    var sources: [StudySource] {
        get { currentSession.sources }
        set {
            currentSession.sources = newValue
            touchCurrent()
        }
    }

    var turns: [StudyTurn] {
        get { currentSession.turns }
        set {
            currentSession.turns = newValue
            touchCurrent()
        }
    }

    var selectedResource: StudyResourceKind {
        get { currentSession.selectedResource }
        set {
            currentSession.selectedResource = newValue
            touchCurrent()
        }
    }

    // MARK: - Session management

    func newSession() {
        guard runningSessionID == nil else { return }
        composerText = ""
        // Reuse an existing empty session instead of stacking up blank ones.
        if let empty = sessions.first(where: { $0.isEmpty }) {
            currentSessionID = empty.id
        } else {
            let session = StudySession()
            sessions.insert(session, at: 0)
            currentSessionID = session.id
        }
        scheduleSave()
    }

    func selectSession(_ id: UUID) {
        guard id != currentSessionID, sessions.contains(where: { $0.id == id }) else { return }
        composerText = ""
        globalError = nil
        currentSessionID = id
    }

    func deleteSession(_ id: UUID) {
        guard runningSessionID != id else { return }
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            sessions = [StudySession()]
        }
        if !sessions.contains(where: { $0.id == currentSessionID }) {
            currentSessionID = sessions[0].id
        }
        scheduleSave()
    }

    func renameSession(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = trimmed
        sessions[index].titleIsCustom = true
        sessions[index].updatedAt = Date()
        scheduleSave()
    }

    // MARK: - Profiles

    var activeProfile: ModelProfile {
        if let profile = ModelProfile.profile(withID: storedProfileID),
           MemoryPreflight.evaluate(profile: profile).canRun {
            return profile
        }
        return ModelProfile.recommendedDefault
    }

    func setActiveProfile(_ profile: ModelProfile) {
        storedProfileID = profile.id
        startModelPreload(for: profile)
        objectWillChange.send()
    }

    func dismissModelDownloadStatus() {
        modelDownloadDismissTask?.cancel()
        modelDownloadDismissTask = nil
        modelDownloadStatus = nil
    }

    private func startModelPreload(for profile: ModelProfile) {
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        guard MemoryPreflight.evaluate(policy: runtimePolicy).canRun else {
            return
        }
        if modelPreloadProfileID == profile.id, modelPreloadTask != nil {
            return
        }

        modelPreloadTask?.cancel()
        modelDownloadDismissTask?.cancel()
        modelDownloadDismissTask = nil
        modelPreloadProfileID = profile.id
        modelDownloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "Preparing \(profile.name)",
            fraction: nil,
            phase: .checking
        )

        let inferenceService = inferenceService
        modelPreloadTask = Task { [weak self] in
            do {
                try await inferenceService.preload(profile: profile, runtimePolicy: runtimePolicy) { [weak self] event in
                    await self?.handleModelLoad(event, profile: profile)
                }
                await MainActor.run {
                    self?.completeModelPreload(for: profile)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearModelPreloadIfCurrent(profile)
                }
                throw CancellationError()
            } catch {
                await MainActor.run {
                    self?.failModelPreload(for: profile, error: error)
                }
                throw error
            }
        }
    }

    private func waitForModelPreloadIfNeeded(profile: ModelProfile, turnID: UUID) async throws {
        guard modelPreloadProfileID == profile.id, let task = modelPreloadTask else {
            return
        }
        updateStatusIfStreaming(turnID: turnID, message: "Waiting for \(profile.name)")
        try Task.checkCancellation()
        try await task.value
        try Task.checkCancellation()
    }

    private func handleModelLoad(_ event: LocalModelRunnerEvent, profile: ModelProfile) {
        switch event {
        case .stage(let message):
            if message == LocalModelRunnerStage.checkingModelCache() {
                updateModelDownloadStatus(for: profile, message: message, fraction: nil, phase: .checking)
            } else if message.hasPrefix("Loading") {
                updateModelDownloadStatus(for: profile, message: message, fraction: nil, phase: .loading)
            } else if LocalModelRunnerStage.endsDownloadPhase(message) {
                guard modelDownloadStatus?.profileID == profile.id || modelPreloadProfileID == profile.id else {
                    return
                }
                markModelReady(for: profile)
            }

        case .downloadProgress(let update):
            updateModelDownloadStatus(
                for: profile,
                message: update.message,
                fraction: update.fraction,
                phase: .downloading
            )

        case .outputChunk:
            break
        }
    }

    private func updateModelDownloadStatus(
        for profile: ModelProfile,
        message: String,
        fraction: Double?,
        phase: ModelDownloadPhase
    ) {
        modelDownloadDismissTask?.cancel()
        modelDownloadDismissTask = nil
        modelDownloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: message,
            fraction: fraction,
            phase: phase
        )
    }

    private func completeModelPreload(for profile: ModelProfile) {
        markModelReady(for: profile)
        clearModelPreloadIfCurrent(profile)
    }

    private func markModelReady(for profile: ModelProfile) {
        guard modelDownloadStatus?.profileID == profile.id || modelPreloadProfileID == profile.id else {
            return
        }
        modelDownloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "\(profile.name) is ready",
            fraction: 1,
            phase: .ready
        )
        scheduleModelDownloadDismiss()
    }

    private func failModelPreload(for profile: ModelProfile, error: Error) {
        clearModelPreloadIfCurrent(profile)
        modelDownloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: error.localizedDescription,
            fraction: nil,
            phase: .failed
        )
    }

    private func clearModelPreloadIfCurrent(_ profile: ModelProfile) {
        guard modelPreloadProfileID == profile.id else { return }
        modelPreloadProfileID = nil
        modelPreloadTask = nil
    }

    private func scheduleModelDownloadDismiss() {
        modelDownloadDismissTask?.cancel()
        modelDownloadDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.modelDownloadStatus?.phase == .ready else { return }
                self?.modelDownloadStatus = nil
                self?.modelDownloadDismissTask = nil
            }
        }
    }

    var preflight: MemoryPreflightResult {
        MemoryPreflight.evaluate(profile: activeProfile)
    }

    var selectedImageURL: URL? {
        sources.first(where: \.isImage)?.accessibleURL
    }

    // MARK: - Run state

    /// True when the *current* session is the one actively generating.
    var isRunning: Bool {
        runningSessionID == currentSessionID && runningSessionID != nil
    }

    /// True when any session is generating (the runner is single-flight).
    var isGenerating: Bool {
        runningSessionID != nil
    }

    var canSend: Bool {
        guard runningSessionID == nil else { return false }
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selectedResource.allowsEmptyFocus {
            return hasText || !sources.isEmpty
        }
        return hasText
    }

    var shouldShowFirstTurnSourcePreview: Bool {
        !sources.isEmpty && turns.isEmpty
    }

    var sourceSummary: String {
        if sources.isEmpty {
            return "No sources"
        }
        let sourceCount = sources.count
        let imageCount = sources.filter(\.isImage).count
        if imageCount > 0 {
            return "\(sourceCount) source\(sourceCount == 1 ? "" : "s"), \(imageCount) image\(imageCount == 1 ? "" : "s")"
        }
        return "\(sourceCount) source\(sourceCount == 1 ? "" : "s")"
    }

    var refinementSuggestions: [RefinementSuggestion] {
        guard let lastKind = turns.last?.user.resourceKind, turns.last?.assistant.status == .done else {
            return []
        }
        return RefinementSuggestion.suggestions(for: lastKind)
    }

    // MARK: - Source management

    func importURLs(_ urls: [URL]) {
        let existingURLs = Set(sources.map(\.url))
        let newSources = urls
            .filter { !existingURLs.contains($0) }
            .map(StudySource.init(url:))

        guard !newSources.isEmpty else { return }
        sources.append(contentsOf: newSources)
        globalError = nil
    }

    func importFromDropProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                if let error {
                    Task { @MainActor in
                        self?.globalError = error.localizedDescription
                    }
                    return
                }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else { return }
                Task { @MainActor in
                    self?.importURLs([url])
                }
            }
        }
        return true
    }

    func removeSource(_ source: StudySource) {
        sources.removeAll { $0.id == source.id }
    }

    func clearSources() {
        sources.removeAll()
        globalError = nil
    }

    // MARK: - Turn lifecycle

    func send() {
        guard canSend else { return }
        let user = StudyTurnUser(
            focus: composerText,
            resourceKind: selectedResource,
            sources: sources,
            isRefinement: false
        )
        composerText = ""
        startTurn(user: user)
    }

    func applyExample(_ example: StudyExamplePrompt) {
        composerText = example.focus
        selectedResource = example.kind
    }

    func refine(with suggestion: RefinementSuggestion) {
        guard runningSessionID == nil else { return }
        let kind = suggestion.newKind ?? turns.last?.user.resourceKind ?? selectedResource
        if let newKind = suggestion.newKind {
            selectedResource = newKind
        }
        let user = StudyTurnUser(
            focus: suggestion.instruction,
            resourceKind: kind,
            sources: sources,
            isRefinement: true
        )
        startTurn(user: user)
    }

    func regenerate(turn: StudyTurn) {
        guard runningSessionID == nil else { return }
        let user = StudyTurnUser(
            focus: turn.user.focus,
            resourceKind: turn.user.resourceKind,
            sources: sources.isEmpty ? turn.user.sources : sources,
            isRefinement: turn.user.isRefinement
        )
        startTurn(user: user)
    }

    func cancel() {
        guard runningSessionID != nil else { return }
        runTask?.cancel()
        if let runningSessionID,
           let sIdx = sessions.firstIndex(where: { $0.id == runningSessionID }),
           let last = sessions[sIdx].turns.indices.last {
            sessions[sIdx].turns[last].assistant.statusMessage = "Cancelling"
        }
    }

    func unloadModel() {
        Task {
            await inferenceService.unload()
        }
    }

    // MARK: - Streaming

    private func startTurn(user: StudyTurnUser) {
        let profile = activeProfile
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        let preflight = MemoryPreflight.evaluate(policy: runtimePolicy)
        guard preflight.canRun else {
            globalError = preflight.message
            return
        }

        var turn = StudyTurn(user: user)
        turn.assistant.statusMessage = user.sources.contains(where: { !$0.isImage }) ? "Reading sources" : "Starting \(profile.name)"
        turns.append(turn)
        let turnID = turn.id
        let sessionID = currentSessionID
        let history = Array(turns.dropLast())

        pendingChunks = ""
        flushScheduled = false
        runningSessionID = sessionID

        runTask = Task { [weak self] in
            guard let self else { return }
            let maxTokens: Int? = user.resourceKind.isInteractive ? 2048 : nil
            let temperature: Float? = user.resourceKind.isInteractive ? 0.1 : nil

            do {
                try await self.waitForModelPreloadIfNeeded(profile: profile, turnID: turnID)
                let promptContent = try await SourceContextPlanner.content(
                    for: user,
                    history: history,
                    profile: profile,
                    runtimePolicy: runtimePolicy,
                    generateIntermediate: { [weak self] content, maxTokens, temperature in
                        guard let self else { throw CancellationError() }
                        let request = InferenceRequest(
                            profile: profile,
                            runtimePolicy: runtimePolicy,
                            promptContent: content,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                        let record = try await self.inferenceService.run(request: request) { [weak self] event in
                            await self?.handleIntermediate(event, turnID: turnID)
                            await self?.handleModelLoad(event, profile: profile)
                        }
                        switch record.status {
                        case .success:
                            return record.output
                        case .cancelled:
                            throw CancellationError()
                        case .failed, .skipped:
                            throw SourceContextPlannerError.intermediateFailed(
                                record.errorMessage ?? "The local model could not summarize an intermediate source section."
                            )
                        }
                    },
                    status: { [weak self] message in
                        await MainActor.run {
                            self?.updateStatusIfStreaming(turnID: turnID, message: message)
                        }
                    }
                )
                await MainActor.run {
                    let figureText = promptContent.includedImageCount == 0
                        ? "Starting \(profile.name)"
                        : "Includes \(promptContent.includedImageCount) figure\(promptContent.includedImageCount == 1 ? "" : "s")"
                    self.updateStatusIfStreaming(turnID: turnID, message: figureText)
                }

                let request = InferenceRequest(
                    profile: profile,
                    runtimePolicy: runtimePolicy,
                    promptContent: promptContent,
                    maxTokens: maxTokens,
                    temperature: temperature
                )
                let record = try await self.inferenceService.run(request: request) { [weak self] event in
                    await self?.handle(event, turnID: turnID, kind: user.resourceKind)
                    await self?.handleModelLoad(event, profile: profile)
                }
                await MainActor.run {
                    self.finish(record: record, turnID: turnID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.cancel(turnID: turnID)
                }
            } catch {
                await MainActor.run {
                    self.fail(turnID: turnID, message: error.localizedDescription)
                }
            }
        }
    }

    private func handleIntermediate(_ event: LocalModelRunnerEvent, turnID: UUID) {
        switch event {
        case .stage:
            return
        case .downloadProgress(let update):
            updateTurn(turnID) { turn in
                turn.assistant.isDownloading = true
                turn.assistant.downloadProgress = update.fraction
                turn.assistant.statusMessage = update.message
            }
        case .outputChunk:
            break
        }
    }

    /// Mutates a turn in whichever session owns it (so background runs keep
    /// updating their origin session even if the user switches away).
    private func updateTurn(_ turnID: UUID, _ body: (inout StudyTurn) -> Void) {
        // No scheduleSave here: this runs up to ~25x/sec while streaming. Persistence
        // is handled at terminal points (finish/fail) and on structural changes.
        for sIdx in sessions.indices {
            if let tIdx = sessions[sIdx].turns.firstIndex(where: { $0.id == turnID }) {
                body(&sessions[sIdx].turns[tIdx])
                sessions[sIdx].updatedAt = Date()
                return
            }
        }
    }

    private func updateStatusIfStreaming(turnID: UUID, message: String) {
        updateTurn(turnID) { turn in
            guard turn.assistant.status == .streaming else { return }
            turn.assistant.statusMessage = message
        }
    }

    private func handle(_ event: LocalModelRunnerEvent, turnID: UUID, kind: StudyResourceKind) {
        switch event {
        case .stage(let message):
            updateTurn(turnID) { turn in
                turn.assistant.statusMessage = message
                if LocalModelRunnerStage.endsDownloadPhase(message) {
                    turn.assistant.isDownloading = false
                    turn.assistant.downloadProgress = nil
                }
            }
        case .downloadProgress(let update):
            updateTurn(turnID) { turn in
                turn.assistant.isDownloading = true
                turn.assistant.downloadProgress = update.fraction
                turn.assistant.statusMessage = update.message
            }
        case .outputChunk(let chunk):
            pendingChunks += chunk
            scheduleFlush(turnID: turnID, kind: kind)
        }
    }

    private func scheduleFlush(turnID: UUID, kind: StudyResourceKind) {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000) // ~25 fps
            self?.flushPending(turnID: turnID, kind: kind)
        }
    }

    private func flushPending(turnID: UUID, kind: StudyResourceKind) {
        flushScheduled = false
        guard !pendingChunks.isEmpty else { return }
        let chunk = pendingChunks
        pendingChunks = ""
        updateTurn(turnID) { turn in
            turn.assistant.markdown += chunk
            if kind.isInteractive {
                turn.assistant.statusMessage = Self.interactiveProgressMessage(for: kind, raw: turn.assistant.markdown)
            }
        }
    }

    private static func interactiveProgressMessage(for kind: StudyResourceKind, raw: String) -> String {
        let openBraces = raw.filter { $0 == "{" }.count
        let itemCount = max(0, openBraces - 1)
        switch kind {
        case .quiz:
            return itemCount == 0 ? "Composing quiz…" : "Writing question \(itemCount)…"
        case .flashcards:
            return itemCount == 0 ? "Composing flashcards…" : "Writing card \(itemCount)…"
        default:
            return "Generating"
        }
    }

    private func finish(record: BenchmarkRecord, turnID: UUID) {
        // Drain any buffered tokens before settling the turn.
        let pending = pendingChunks
        pendingChunks = ""
        flushScheduled = false
        runningSessionID = nil

        updateTurn(turnID) { turn in
            if !pending.isEmpty {
                turn.assistant.markdown += pending
            }
            if turn.assistant.markdown.isEmpty {
                turn.assistant.markdown = record.output
            }
            turn.assistant.finishedAt = Date()
            turn.assistant.isDownloading = false
            turn.assistant.downloadProgress = nil

            let kind = turn.user.resourceKind
            if kind.isInteractive {
                turn.assistant.payload = StudyArtifactParser.parse(turn.assistant.markdown, kind: kind)
            }

            switch record.status {
            case .success:
                turn.assistant.status = .done
                turn.assistant.statusMessage = kind.isInteractive
                    ? (turn.assistant.payload == nil ? "Could not parse response" : "Ready")
                    : "Ready"
            case .cancelled:
                turn.assistant.status = .cancelled
                turn.assistant.statusMessage = "Cancelled"
            case .failed:
                turn.assistant.status = .failed(record.errorMessage ?? "The local model run failed.")
                turn.assistant.statusMessage = "Failed"
            case .skipped:
                turn.assistant.status = .failed(record.errorMessage ?? "Skipped.")
                turn.assistant.statusMessage = "Skipped"
            }
        }
        scheduleSave()
    }

    private func fail(turnID: UUID, message: String) {
        pendingChunks = ""
        flushScheduled = false
        runningSessionID = nil
        updateTurn(turnID) { turn in
            turn.assistant.status = .failed(message)
            turn.assistant.statusMessage = "Failed"
            turn.assistant.finishedAt = Date()
            turn.assistant.isDownloading = false
            turn.assistant.downloadProgress = nil
        }
        scheduleSave()
    }

    private func cancel(turnID: UUID) {
        pendingChunks = ""
        flushScheduled = false
        runningSessionID = nil
        updateTurn(turnID) { turn in
            turn.assistant.status = .cancelled
            turn.assistant.statusMessage = "Cancelled"
            turn.assistant.finishedAt = Date()
            turn.assistant.isDownloading = false
            turn.assistant.downloadProgress = nil
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func touchCurrent() {
        guard hasLoaded, let index = currentIndex else { return }
        sessions[index].updatedAt = Date()
        if !sessions[index].titleIsCustom, sessions[index].title == "New session" {
            let derived = sessions[index].derivedTitle
            if derived != "New session" {
                sessions[index].title = derived
            }
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        let snapshot = sessions
        saveTask = Task { [store] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
    }
}
