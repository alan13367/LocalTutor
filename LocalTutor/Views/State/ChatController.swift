//
//  ChatController.swift
//  LocalTutor
//

import Foundation
import Observation

struct ChatTarget: Equatable, Hashable {
    var notebookID: UUID
    var chatID: UUID
    var turnID: UUID
}

@MainActor
@Observable
final class ChatController {
    var composerText = ""
    private(set) var running: ChatTarget?
    private(set) var live: LiveGeneration?

    @ObservationIgnored private let store: NotebookStore
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(store: NotebookStore, models: ModelManager) {
        self.store = store
        self.models = models
    }

    var isGenerating: Bool { running != nil }

    func isRunning(chatID: UUID) -> Bool {
        running?.chatID == chatID
    }

    func liveGeneration(for turnID: UUID) -> LiveGeneration? {
        running?.turnID == turnID ? live : nil
    }

    func canSend(in notebook: Notebook?) -> Bool {
        guard notebook != nil, models.selectedProfile != nil, running == nil else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    func send(in notebookID: UUID) {
        guard canSend(in: store.notebook(notebookID)) else { return }
        let question = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        composerText = ""
        ask(question, in: notebookID, isRefinement: false)
    }

    var willAnswerWithSystemModel: Bool {
        !models.isSelectedModelDownloaded && SystemModelHelper.canRun
    }

    func ask(_ question: String, in notebookID: UUID, isRefinement: Bool = false) {
        guard running == nil else { return }
        guard let profile = models.selectedProfile, let modelPolicy = models.runtimePolicy else {
            onError("Choose a model before asking a question.")
            return
        }
        let useSystemModel = willAnswerWithSystemModel
        let policy = useSystemModel ? SystemModelHelper.chatPolicy() : modelPolicy
        if useSystemModel, !models.isPaused {
            models.startPreload(for: profile)
        }
        let preflight = MemoryPreflight.evaluate(policy: policy)
        guard preflight.canRun else {
            onError(preflight.message)
            return
        }
        guard let notebook = store.notebook(notebookID),
              let chatID = store.selectedChatID(in: notebookID) else { return }
        store.selectedChatIDs[notebookID] = chatID

        let sources = notebook.enabledSources.filter { policy.supportsVision || !$0.isImage }
        let history = notebook.chats.first { $0.id == chatID }?.turns.filter { $0.assistant.status == .done } ?? []
        var turn = StudyTurn(user: StudyTurnUser(
            focus: question,
            resourceKind: .ask,
            sources: sources,
            isRefinement: isRefinement
        ))
        turn.assistant.statusMessage = sources.isEmpty ? "Starting \(policy.profileName)" : "Reading sources"
        turn.assistant.profileName = policy.profileName
        store.updateChat(chatID, in: notebookID) { $0.turns.append(turn) }

        let target = ChatTarget(notebookID: notebookID, chatID: chatID, turnID: turn.id)
        let liveGeneration = LiveGeneration(statusMessage: turn.assistant.statusMessage)
        running = target
        live = liveGeneration

        let inference = models.inferenceService
        let notebookTitle = notebook.title
        runTask = Task { [weak self] in
            guard let self else { return }
            await SourceIndexCoordinator.shared.setTutorGenerationActive(true)
            defer {
                Task { await SourceIndexCoordinator.shared.setTutorGenerationActive(false) }
            }
            do {
                if !useSystemModel {
                    try await self.models.ensureLoaded(profile)
                }
                let plan = try await ChatContextPlanner.plan(
                    question: question,
                    history: history,
                    isRefinement: isRefinement,
                    sources: sources,
                    notebookTitle: notebookTitle,
                    runtimePolicy: policy
                ) { [weak liveGeneration] message in
                    await MainActor.run { liveGeneration?.statusMessage = message }
                }
                liveGeneration.citations = plan.citations
                let historyMessages = history.map {
                    ChatHistoryMessage(
                        question: $0.user.focus,
                        answer: ReasoningOutputFilter.sanitize($0.assistant.markdown)
                    )
                }

                if useSystemModel {
                    liveGeneration.statusMessage = "Answering with Apple Intelligence while \(profile.name) downloads"
                    let answer = try await SystemModelHelper.streamAnswer(
                        instructions: plan.instructions,
                        history: historyMessages,
                        message: plan.message
                    ) { text in
                        liveGeneration.replaceText(text)
                        liveGeneration.statusMessage = "Writing answer"
                    }
                    try Task.checkCancellation()
                    self.finishSystemAnswer(target: target, answer: answer, citations: plan.citations, question: question)
                    return
                }

                let request = ChatInferenceRequest(
                    profile: profile,
                    runtimePolicy: policy,
                    conversationID: chatID,
                    instructions: plan.instructions,
                    history: historyMessages,
                    message: plan.message,
                    images: plan.images
                )
                let record = try await inference.chat(request: request) { [weak self] event in
                    await self?.handle(event, live: liveGeneration, profile: profile)
                }
                self.finish(target: target, record: record, citations: plan.citations, question: question)
            } catch is CancellationError {
                self.finish(target: target, status: .cancelled, message: "Cancelled")
            } catch {
                self.finish(target: target, status: .failed(error.localizedDescription), message: "Failed")
            }
        }
    }

    func refine(_ suggestion: RefinementSuggestion, in notebookID: UUID) {
        ask(suggestion.instruction, in: notebookID, isRefinement: true)
    }

    func regenerate(_ turn: StudyTurn, in notebookID: UUID) {
        guard running == nil, let chatID = store.selectedChatID(in: notebookID) else { return }
        store.updateChat(chatID, in: notebookID) { chat in
            guard let index = chat.turns.firstIndex(where: { $0.id == turn.id }) else { return }
            chat.turns.removeSubrange(index...)
        }
        Task { await models.inferenceService.releaseConversations() }
        ask(turn.user.focus, in: notebookID, isRefinement: turn.user.isRefinement)
    }

    func cancel() {
        guard running != nil else { return }
        live?.statusMessage = "Cancelling"
        runTask?.cancel()
    }

    // MARK: - Streaming

    private func handle(_ event: LocalModelRunnerEvent, live: LiveGeneration, profile: ModelProfile) {
        models.handleLoadEvent(event, profile: profile)
        switch event {
        case .stage(let message):
            if message == LocalModelRunnerStage.generating {
                live.statusMessage = "Writing answer"
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
        case .downloadProgress(let update):
            live.statusMessage = update.message
        }
    }

    private func finish(target: ChatTarget, record: BenchmarkRecord, citations: [SourceCitation], question: String) {
        live?.drain()
        let markdown = live?.markdown.isEmpty == false ? (live?.markdown ?? "") : record.output
        let reasoning = live?.reasoning ?? ""
        store.updateTurn(target.turnID, chatID: target.chatID, notebookID: target.notebookID) { turn in
            turn.assistant.markdown = markdown
            turn.assistant.reasoning = reasoning
            turn.assistant.citations = citations
            turn.assistant.finishedAt = Date()
            switch record.status {
            case .success:
                turn.assistant.status = .done
                turn.assistant.statusMessage = Self.performanceSummary(record)
            case .cancelled:
                turn.assistant.status = .cancelled
                turn.assistant.statusMessage = "Cancelled"
            case .failed, .skipped:
                turn.assistant.status = .failed(record.errorMessage ?? "The local model run failed.")
                turn.assistant.statusMessage = "Failed"
            }
        }
        clearRunning()
        if record.status == .success {
            generateTitleIfNeeded(target: target, question: question, answer: markdown)
        }
    }

    private func finishSystemAnswer(target: ChatTarget, answer: String, citations: [SourceCitation], question: String) {
        store.updateTurn(target.turnID, chatID: target.chatID, notebookID: target.notebookID) { turn in
            turn.assistant.markdown = answer
            turn.assistant.citations = citations
            turn.assistant.finishedAt = Date()
            turn.assistant.status = answer.isEmpty ? .failed("Apple Intelligence returned an empty answer.") : .done
            turn.assistant.statusMessage = answer.isEmpty ? "Failed" : "On-device system model"
        }
        clearRunning()
        if !answer.isEmpty {
            generateTitleIfNeeded(target: target, question: question, answer: answer)
        }
    }

    private func finish(target: ChatTarget, status: StudyTurnStatus, message: String) {
        live?.drain()
        let markdown = live?.markdown ?? ""
        let reasoning = live?.reasoning ?? ""
        store.updateTurn(target.turnID, chatID: target.chatID, notebookID: target.notebookID) { turn in
            turn.assistant.markdown = markdown
            turn.assistant.reasoning = reasoning
            turn.assistant.status = status
            turn.assistant.statusMessage = message
            turn.assistant.finishedAt = Date()
        }
        clearRunning()
    }

    private func clearRunning() {
        running = nil
        live = nil
        runTask = nil
    }

    nonisolated static func performanceSummary(_ record: BenchmarkRecord) -> String {
        var parts: [String] = []
        if let tps = record.tokenMetrics.tokensPerSecond, tps > 0 {
            parts.append(String(format: "%.0f tok/s", tps))
        }
        if let first = record.timing.firstTokenSeconds {
            parts.append(String(format: "first token %.1fs", first))
        }
        if let cached = record.tokenMetrics.cachedPromptTokens, cached > 0 {
            parts.append("\(cached.formatted()) tokens reused")
        }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " · ")
    }

    private func generateTitleIfNeeded(target: ChatTarget, question: String, answer: String) {
        guard let chat = store.notebook(target.notebookID)?.chats.first(where: { $0.id == target.chatID }),
              !chat.titleIsCustom,
              chat.title == "New chat",
              chat.turns.count == 1 else { return }
        let fallback = String(question.prefix(48))
        guard SystemModelHelper.canRun else {
            store.renameChat(target.chatID, in: target.notebookID, to: fallback, isCustom: false)
            return
        }
        Task { [weak self] in
            let title = (try? await SystemModelHelper.chatTitle(question: question, answer: answer)) ?? fallback
            self?.store.renameChat(target.chatID, in: target.notebookID, to: title.isEmpty ? fallback : title, isCustom: false)
        }
    }
}
