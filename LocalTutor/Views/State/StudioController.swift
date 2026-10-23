//
//  StudioController.swift
//  LocalTutor
//

import Foundation
import Observation

@MainActor
@Observable
final class StudioController {
    private(set) var live: [UUID: LiveGeneration] = [:]

    @ObservationIgnored private let store: NotebookStore
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    init(store: NotebookStore, models: ModelManager) {
        self.store = store
        self.models = models
    }

    var isGenerating: Bool { !tasks.isEmpty }

    func liveGeneration(for itemID: UUID) -> LiveGeneration? {
        live[itemID]
    }

    func isRunning(_ itemID: UUID) -> Bool {
        tasks[itemID] != nil
    }

    @discardableResult
    func generate(_ kind: StudyResourceKind, focus: String = "", in notebookID: UUID) -> UUID? {
        guard kind != .ask else { return nil }
        if let running = store.notebook(notebookID)?.runningStudioItem(of: kind) {
            return running.id
        }
        guard let profile = models.selectedProfile, let policy = models.runtimePolicy else {
            onError("Choose a model before creating study materials.")
            return nil
        }
        guard let notebook = store.notebook(notebookID) else { return nil }
        let sources = notebook.enabledSources.filter { policy.supportsVision || !$0.isImage }
        guard !sources.isEmpty else {
            onError("Add or enable at least one source to create a \(kind.title.lowercased()).")
            return nil
        }

        let trimmedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = StudioItem(
            kind: kind,
            title: trimmedFocus.isEmpty ? kind.title : "\(kind.title): \(trimmedFocus)",
            focus: trimmedFocus,
            statusMessage: "Queued",
            sourceIDs: sources.map(\.id)
        )
        store.update(notebookID) { $0.studioItems.insert(item, at: 0) }
        let liveGeneration = LiveGeneration(statusMessage: "Queued")
        live[item.id] = liveGeneration

        let inference = models.inferenceService
        let user = StudyTurnUser(focus: trimmedFocus, resourceKind: kind, sources: sources, isRefinement: false)
        tasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.models.ensureLoaded(profile)
                let content = try await SourceContextPlanner.content(
                    for: user,
                    history: [],
                    profile: profile,
                    runtimePolicy: policy,
                    generateIntermediate: { content, maxTokens, temperature in
                        let request = InferenceRequest(
                            profile: profile,
                            runtimePolicy: policy,
                            promptContent: content,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                        let record = try await inference.run(request: request) { event in
                            if case .reasoningChunk(let chunk) = event {
                                await liveGeneration.appendReasoning(chunk)
                            }
                        }
                        switch record.status {
                        case .success:
                            return record.output
                        case .cancelled:
                            throw CancellationError()
                        case .failed, .skipped:
                            throw SourceContextPlannerError.intermediateFailed(
                                record.errorMessage ?? "The local model could not summarize a source section."
                            )
                        }
                    },
                    status: { [weak liveGeneration] message in
                        await MainActor.run { liveGeneration?.statusMessage = message }
                    }
                )
                liveGeneration.citations = content.citations

                let request = Self.request(for: kind, profile: profile, policy: policy, content: content)
                let handler: @Sendable (LocalModelRunnerEvent) async -> Void = { [weak self] event in
                    await self?.handle(event, kind: kind, live: liveGeneration, profile: profile)
                }
                let record: BenchmarkRecord
                if let schema = kind.jsonSchema {
                    record = try await inference.generateStructured(request: request, jsonSchema: schema, events: handler)
                } else {
                    record = try await inference.run(request: request, events: handler)
                }
                self.finish(itemID: item.id, notebookID: notebookID, kind: kind, record: record, citations: content.citations)
            } catch is CancellationError {
                self.finish(itemID: item.id, notebookID: notebookID, status: .cancelled, message: "Cancelled")
            } catch {
                self.finish(itemID: item.id, notebookID: notebookID, status: .failed(error.localizedDescription), message: "Failed")
            }
        }
        return item.id
    }

    func cancel(_ itemID: UUID) {
        live[itemID]?.statusMessage = "Cancelling"
        tasks[itemID]?.cancel()
    }

    func cancelAll() {
        for id in tasks.keys {
            cancel(id)
        }
    }

    func delete(_ itemID: UUID, in notebookID: UUID) {
        cancel(itemID)
        store.deleteStudioItem(itemID, in: notebookID)
    }

    nonisolated static let thinkingTokens = 4_096

    nonisolated static func request(
        for kind: StudyResourceKind,
        profile: ModelProfile,
        policy: ModelRuntimePolicy,
        content: StudyPromptContent
    ) -> InferenceRequest {
        let thinking = kind.jsonSchema == nil && !ModelCatalog.disablesThinking(profile)
        var content = content
        if thinking {
            content.systemInstruction = StudyPromptBuilder.thinkingSystemInstruction
        }
        return InferenceRequest(
            profile: profile,
            runtimePolicy: policy,
            promptContent: content,
            maxTokens: maxTokens(for: kind, policy: policy) + (thinking ? thinkingTokens : 0),
            temperature: kind.isInteractive ? 0.2 : nil,
            thinking: thinking
        )
    }

    nonisolated static func maxTokens(for kind: StudyResourceKind, policy: ModelRuntimePolicy) -> Int {
        let ceiling = policy.outputReserve(for: kind)
        switch kind {
        case .studyGuide, .briefing, .audioOverview:
            return max(ceiling, min(3_072, policy.contextTokens / 3))
        case .mindMap:
            return min(ceiling, 900)
        case .flashcards, .quiz:
            return min(max(ceiling, 1_536), 2_048)
        default:
            return ceiling
        }
    }

    // MARK: - Streaming

    private func handle(_ event: LocalModelRunnerEvent, kind: StudyResourceKind, live: LiveGeneration, profile: ModelProfile) {
        models.handleLoadEvent(event, profile: profile)
        switch event {
        case .stage(let message):
            if message == LocalModelRunnerStage.generating {
                live.statusMessage = kind.isInteractive ? "Composing \(kind.title.lowercased())" : "Writing"
                live.prefillFraction = nil
            } else if message != LocalModelRunnerStage.preparingPrompt {
                live.statusMessage = message
            }
        case .prefillProgress(let fraction):
            live.prefillFraction = fraction < 1 ? fraction : nil
        case .reasoningChunk(let chunk):
            live.appendReasoning(chunk)
        case .outputChunk(let chunk):
            live.appendText(chunk)
            if kind.isInteractive {
                live.statusMessage = Self.structuredProgress(kind: kind, raw: live.receivedText)
            }
        case .downloadProgress(let update):
            live.statusMessage = update.message
        }
    }

    nonisolated static func structuredProgress(kind: StudyResourceKind, raw: String) -> String {
        let marker: String
        let noun: String
        switch kind {
        case .quiz: (marker, noun) = ("\"prompt\"", "question")
        case .flashcards: (marker, noun) = ("\"front\"", "card")
        case .audioOverview: (marker, noun) = ("\"speaker\"", "line")
        case .mindMap: (marker, noun) = ("\"title\"", "node")
        default: return "Generating"
        }
        let count = raw.components(separatedBy: marker).count - 1
        return count <= 0 ? "Composing \(kind.title.lowercased())" : "Writing \(noun) \(count)"
    }

    private func finish(
        itemID: UUID,
        notebookID: UUID,
        kind: StudyResourceKind,
        record: BenchmarkRecord,
        citations: [SourceCitation]
    ) {
        let liveGeneration = live[itemID]
        liveGeneration?.drain()
        let markdown = liveGeneration?.markdown.isEmpty == false ? (liveGeneration?.markdown ?? "") : record.output
        let reasoning = liveGeneration?.reasoning ?? ""
        let payload = kind.isInteractive ? StudyArtifactParser.parse(markdown, kind: kind) : nil

        store.updateStudioItem(itemID, in: notebookID) { item in
            item.markdown = markdown
            item.reasoning = reasoning
            item.payload = payload
            item.citations = citations
            item.finishedAt = Date()
            if let title = Self.title(for: payload), item.focus.isEmpty {
                item.title = title
            }
            switch record.status {
            case .success:
                if kind.isInteractive && payload == nil {
                    item.status = .failed("The model's response couldn't be turned into a \(kind.title.lowercased()). Try again or pick a larger model.")
                    item.statusMessage = "Couldn't parse response"
                } else {
                    item.status = .done
                    item.statusMessage = payload?.itemCountDescription ?? ChatController.performanceSummary(record)
                }
            case .cancelled:
                item.status = .cancelled
                item.statusMessage = "Cancelled"
            case .failed, .skipped:
                item.status = .failed(record.errorMessage ?? "The local model run failed.")
                item.statusMessage = "Failed"
            }
        }
        live[itemID] = nil
        tasks[itemID] = nil
    }

    private func finish(itemID: UUID, notebookID: UUID, status: StudyTurnStatus, message: String) {
        let liveGeneration = live[itemID]
        liveGeneration?.drain()
        let existing = store.notebook(notebookID)?.studioItems.first { $0.id == itemID }
        if status == .cancelled, (liveGeneration?.markdown ?? existing?.markdown ?? "").isEmpty {
            store.deleteStudioItem(itemID, in: notebookID)
            live[itemID] = nil
            tasks[itemID] = nil
            return
        }
        store.updateStudioItem(itemID, in: notebookID) { item in
            item.markdown = liveGeneration?.markdown ?? item.markdown
            item.reasoning = liveGeneration?.reasoning ?? item.reasoning
            item.status = status
            item.statusMessage = message
            item.finishedAt = Date()
        }
        live[itemID] = nil
        tasks[itemID] = nil
    }

    nonisolated static func title(for payload: StudyArtifactPayload?) -> String? {
        let raw: String?
        switch payload {
        case .quiz(let quiz): raw = quiz.title
        case .flashcards(let deck): raw = deck.title
        case .mindMap(let root): raw = root.title
        case .audioScript(let script): raw = script.title
        case nil: raw = nil
        }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return String(raw.prefix(80))
    }
}
