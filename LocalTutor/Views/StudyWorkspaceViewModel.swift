//
//  StudyWorkspaceViewModel.swift
//  LocalTutor
//
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudyWorkspaceViewModel: ObservableObject {
    // Persisted study-session history. Each session owns its own sources + turns.
    @Published private(set) var sessions: [StudySession] = []
    @Published var currentSessionID: UUID = UUID()

    // Ephemeral, not persisted with the session.
    @Published var composerText: String = ""
    @Published var globalError: String?

    /// The session that owns the in-flight generation, if any.
    @Published private(set) var runningSessionID: UUID?

    @AppStorage(AppStorageKeys.selectedProfileID) private var storedProfileID: String = ""

    private let runner: LocalModelRunner
    private let store = SessionStore()
    private var runTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var hasLoaded = false

    // Streaming coalescing: buffer tokens and flush to the UI on a frame cadence
    // instead of mutating published state on every single token.
    private var pendingChunks: String = ""
    private var flushScheduled = false

    init(runner: LocalModelRunner = LocalModelRunner()) {
        self.runner = runner
        bootstrap()
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

    var activeProfile: InferenceProfile {
        if let profile = InferenceProfile.profile(withID: storedProfileID),
           MemoryPreflight.evaluate(profile: profile).canRun {
            return profile
        }
        return InferenceProfile.recommendedDefault
    }

    func setActiveProfile(_ profile: InferenceProfile) {
        storedProfileID = profile.id
        Task { await runner.unload() }
        objectWillChange.send()
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
        return hasText || !sources.isEmpty
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
            await runner.unload()
        }
    }

    // MARK: - Streaming

    private func startTurn(user: StudyTurnUser) {
        let profile = activeProfile
        let preflight = MemoryPreflight.evaluate(profile: profile)
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
        let imageURL = user.sources.first(where: \.isImage)?.accessibleURL ?? selectedImageURL

        pendingChunks = ""
        flushScheduled = false
        runningSessionID = sessionID

        runTask = Task { [weak self] in
            guard let self else { return }
            let extracted = await SourceExtractor.extract(user.sources)
            await MainActor.run {
                self.updateStatusIfStreaming(turnID: turnID, message: "Starting \(profile.name)")
            }

            let prompt = StudyPromptBuilder.prompt(for: user, history: history, extracted: extracted)

            let maxTokens: Int? = user.resourceKind.isInteractive ? 2048 : nil
            let temperature: Float? = user.resourceKind.isInteractive ? 0.1 : nil

            do {
                let record = try await self.runner.run(
                    profile: profile,
                    prompt: prompt,
                    imageURL: imageURL,
                    maxTokens: maxTokens,
                    temperature: temperature
                ) { [weak self] event in
                    await self?.handle(event, turnID: turnID, kind: user.resourceKind)
                }
                await MainActor.run {
                    self.finish(record: record, turnID: turnID)
                }
            } catch {
                await MainActor.run {
                    self.fail(turnID: turnID, message: error.localizedDescription)
                }
            }
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
