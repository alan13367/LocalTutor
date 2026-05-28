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
    @Published var sources: [StudySource] = []
    @Published var selectedResource: StudyResourceKind = .summary
    @Published var composerText: String = ""
    @Published var turns: [StudyTurn] = []
    @Published var globalError: String?
    @AppStorage("selectedProfileID") private var storedProfileID: String = ""

    private let runner: LocalModelRunner
    private var runTask: Task<Void, Never>?

    init(runner: LocalModelRunner = LocalModelRunner()) {
        self.runner = runner
    }

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
        sources.first(where: \.isImage)?.url
    }

    var isRunning: Bool {
        if case .streaming = turns.last?.assistant.status { return true }
        return false
    }

    var canSend: Bool {
        guard !isRunning else { return false }
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
        guard !isRunning else { return }
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
        guard !isRunning else { return }
        var user = turn.user
        user = StudyTurnUser(
            focus: user.focus,
            resourceKind: user.resourceKind,
            sources: sources.isEmpty ? user.sources : sources,
            isRefinement: user.isRefinement
        )
        startTurn(user: user)
    }

    func clearTranscript() {
        guard !isRunning else { return }
        turns.removeAll()
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if let idx = turns.indices.last {
            turns[idx].assistant.statusMessage = "Cancelling"
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
        let history = Array(turns.dropLast())
        let imageURL = user.sources.first(where: \.isImage)?.url ?? selectedImageURL

        runTask = Task { [weak self] in
            guard let self else { return }
            let extracted = await SourceExtractor.extract(user.sources)
            await MainActor.run {
                self.updateStatusIfStreaming(turnID: turnID, message: "Starting \(profile.name)")
            }

            let prompt = self.makePrompt(for: user, history: history, extracted: extracted)

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

    private func updateStatusIfStreaming(turnID: UUID, message: String) {
        guard let idx = turns.firstIndex(where: { $0.id == turnID }),
              turns[idx].assistant.status == .streaming else { return }
        turns[idx].assistant.statusMessage = message
    }

    private func handle(_ event: LocalModelRunnerEvent, turnID: UUID, kind: StudyResourceKind) {
        guard let idx = turns.firstIndex(where: { $0.id == turnID }) else { return }
        switch event {
        case .stage(let message):
            turns[idx].assistant.statusMessage = message
            if Self.stageEndsDownload(message) {
                turns[idx].assistant.isDownloading = false
                turns[idx].assistant.downloadProgress = nil
            }
        case .downloadProgress(let update):
            turns[idx].assistant.isDownloading = true
            turns[idx].assistant.downloadProgress = update.fraction
            turns[idx].assistant.statusMessage = update.message
        case .outputChunk(let chunk):
            turns[idx].assistant.markdown += chunk
            if kind.isInteractive {
                turns[idx].assistant.statusMessage = Self.interactiveProgressMessage(for: kind, raw: turns[idx].assistant.markdown)
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
        guard let idx = turns.firstIndex(where: { $0.id == turnID }) else { return }
        if turns[idx].assistant.markdown.isEmpty {
            turns[idx].assistant.markdown = record.output
        }
        turns[idx].assistant.finishedAt = Date()
        turns[idx].assistant.isDownloading = false
        turns[idx].assistant.downloadProgress = nil

        let kind = turns[idx].user.resourceKind
        if kind.isInteractive {
            turns[idx].assistant.payload = StudyArtifactParser.parse(turns[idx].assistant.markdown, kind: kind)
        }

        switch record.status {
        case .success:
            turns[idx].assistant.status = .done
            turns[idx].assistant.statusMessage = kind.isInteractive
                ? (turns[idx].assistant.payload == nil ? "Could not parse response" : "Ready")
                : "Ready"
        case .cancelled:
            turns[idx].assistant.status = .cancelled
            turns[idx].assistant.statusMessage = "Cancelled"
        case .failed:
            turns[idx].assistant.status = .failed(record.errorMessage ?? "The local model run failed.")
            turns[idx].assistant.statusMessage = "Failed"
        case .skipped:
            turns[idx].assistant.status = .failed(record.errorMessage ?? "Skipped.")
            turns[idx].assistant.statusMessage = "Skipped"
        }
    }

    private func fail(turnID: UUID, message: String) {
        guard let idx = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[idx].assistant.status = .failed(message)
        turns[idx].assistant.statusMessage = "Failed"
        turns[idx].assistant.finishedAt = Date()
        turns[idx].assistant.isDownloading = false
        turns[idx].assistant.downloadProgress = nil
    }

    private static func stageEndsDownload(_ message: String) -> Bool {
        message.hasPrefix("Loaded")
            || message.hasPrefix("Using loaded")
            || message == "Preparing prompt"
            || message == "Generating"
    }

    private func makePrompt(for user: StudyTurnUser, history: [StudyTurn], extracted: [ExtractedSource]) -> String {
        let trimmed = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmed.isEmpty ? "Help me study the attached sources." : trimmed
        let sourceList = user.sources.isEmpty
            ? "No files were attached."
            : user.sources.map { "- \($0.displayName) (\($0.kind.label))" }.joined(separator: "\n")

        var transcript = ""
        if !history.isEmpty {
            let recent = history.suffix(4)
            transcript = "\nPrevious turns (most recent last):\n" + recent.map { turn in
                let assistantText = turn.assistant.markdown.isEmpty ? "(no output)" : turn.assistant.markdown
                return """
                Student: \(turn.user.displayPrompt)
                Tutor: \(assistantText)
                """
            }.joined(separator: "\n---\n") + "\n"
        }

        let sourceContents = Self.renderSourceContents(extracted, hasImage: user.sources.contains(where: \.isImage))

        let formatBlock: String
        if let schema = user.resourceKind.jsonSchemaInstruction {
            formatBlock = """
            Output format (STRICT):
            \(schema)
            """
        } else {
            formatBlock = "Format the answer for studying with short markdown headings, concrete bullets, and **bold** for key terms. No filler."
        }

        return """
        You are LocalTutor, a private local study tutor running on the student's Mac.

        Resource to create:
        \(user.resourceKind.promptInstruction)
        \(transcript)
        Student goal:
        \(goal)

        Source files:
        \(sourceList)

        \(sourceContents)

        Base your answer strictly on the provided source contents and any attached image. If the sources do not cover something, say so briefly rather than guessing. Never ask the student to upload or paste a file that already appears above — it has already been provided.

        \(formatBlock)
        """
    }

    private static func renderSourceContents(_ extracted: [ExtractedSource], hasImage: Bool) -> String {
        if extracted.isEmpty {
            return hasImage
                ? "Source contents:\nAn image is attached as a separate input — analyze it directly."
                : "Source contents:\nNo text could be extracted from the attached files."
        }

        var budget = SourceExtractor.totalCharacterBudget
        var sections: [String] = []
        var truncatedAny = false

        for item in extracted {
            if let reason = item.failureReason, !item.hasContent {
                sections.append("""
                === \(item.source.displayName) ===
                (Could not read: \(reason))
                """)
                continue
            }

            let allowed = min(item.text.count, budget)
            let snippet = allowed > 0 ? String(item.text.prefix(allowed)) : ""
            budget -= allowed

            var section = """
            === \(item.source.displayName) ===
            \(snippet)
            """
            if allowed < item.text.count {
                section += "\n…[truncated — only the first portion fits the context window]"
                truncatedAny = true
            }
            sections.append(section)
            if budget <= 0 { break }
        }

        let truncationNote = truncatedAny
            ? "\nNote: Some excerpts above are truncated to fit the local model's context window. Base your answer on what is present and say 'the excerpt does not cover this' for anything that isn't.\n"
            : ""

        return """
        Source contents (verbatim excerpts the student attached):
        \(sections.joined(separator: "\n\n"))
        \(truncationNote)
        """
    }
}
