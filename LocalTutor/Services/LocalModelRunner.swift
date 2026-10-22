//
//  LocalModelRunner.swift
//  LocalTutor
//
//

import CoreImage
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

enum LocalModelRunnerEvent: Sendable {
    case stage(String)
    case downloadProgress(DownloadProgressUpdate)
    case prefillProgress(Double)
    case reasoningChunk(String)
    case outputChunk(String)
}

enum LocalModelRunnerStage {
    static let preparingPrompt = "Preparing prompt"
    static let readingSources = "Reading sources"
    static let generating = "Generating"
    static let waitingForModel = "Waiting for the model"

    static func checkingModelCache() -> String {
        "Checking model cache"
    }

    static func loading(_ profile: ModelProfile) -> String {
        "Loading \(profile.name)"
    }

    static func loaded(_ profile: ModelProfile) -> String {
        "Loaded \(profile.name)"
    }

    static func usingLoaded(_ profile: ModelProfile) -> String {
        "Using loaded \(profile.name)"
    }

    static func endsDownloadPhase(_ message: String) -> Bool {
        message.hasPrefix("Loaded")
            || message.hasPrefix("Using loaded")
            || message == preparingPrompt
            || message == readingSources
            || message == generating
    }
}

enum LocalModelRunnerError: LocalizedError {
    case busy
    case imageRequired
    case unsupportedProfile(String)
    case structuredOutputFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "A model run is already in progress."
        case .imageRequired:
            "Select an image for this vision run."
        case .unsupportedProfile(let id):
            "Unsupported profile: \(id)."
        case .structuredOutputFailed(let message):
            "The model could not produce structured output: \(message)"
        }
    }
}

actor GenerationGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOccupied: Bool { isBusy }
    var queuedCount: Int { waiters.count }

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor LocalModelRunner: InferenceService {
    private struct ConversationState {
        var conversationID: UUID
        var profileID: String
        var instructionsHash: Int
        var session: ChatSession
        var recordedTurns: Int
        var estimatedTokens: Int
    }

    private struct SpeculativeConversation {
        var conversationID: UUID
        var profileID: String
        var cache: UncheckedSendableBox<[KVCache]>
        var tokens: [Int]
    }

    private let modelDownloadService: ManagedModelDownloadService
    private let gate = GenerationGate()
    private var activeContainer: ModelContainer?
    private var activeProfileID: String?
    private var activeDrafter: UncheckedSendableBox<any MTPDrafterModel>?
    private var drafterUnavailableProfileIDs: Set<String> = []
    private(set) var lastDrafterError: String?
    private var didRegisterDrafterTypes = false
    private var speculativeDecodingEnabled = UserDefaults.standard.object(forKey: AppStorageKeys.useSpeculativeDecoding) as? Bool ?? true
    private var conversation: ConversationState?
    private var speculativeConversation: SpeculativeConversation?

    init(modelDownloadService: ManagedModelDownloadService = .shared) {
        self.modelDownloadService = modelDownloadService
    }

    var isGenerating: Bool {
        get async { await gate.isOccupied }
    }

    // MARK: - Single-shot generation

    func run(
        profile: ModelProfile,
        prompt: String,
        imageURL: URL?,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        let promptContent = try StudyPromptBuilder.modelLabContent(
            prompt: prompt,
            imageURL: imageURL
        )
        let request = InferenceRequest(
            profile: profile,
            runtimePolicy: ModelRuntimePolicyProvider.policy(for: profile),
            promptContent: promptContent,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return try await run(request: request, events: events)
    }

    func run(
        request: InferenceRequest,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        try await admitted(events: events) {
            try await self.measured(
                profile: request.profile,
                runtimePolicy: request.runtimePolicy,
                promptText: request.promptContent.benchmarkText,
                promptContent: request.promptContent,
                events: events
            ) { container, collector in
                await events(.stage(LocalModelRunnerStage.preparingPrompt))
                let input = try await container.prepare(
                    input: Self.makeUserInput(
                        promptContent: request.promptContent,
                        profile: request.profile,
                        runtimePolicy: request.runtimePolicy
                    )
                )
                try Task.checkCancellation()
                await events(.stage(LocalModelRunnerStage.readingSources))
                var parameters = request.runtimePolicy.generationDefaults.generateParameters(
                    maxTokensOverride: request.maxTokens,
                    temperatureOverride: request.temperature
                )
                parameters.prefill.progress = Self.prefillReporter(events)
                let stream: AsyncStream<Generation>
                if self.speculativeDecodingEnabled, let drafter = self.activeDrafter {
                    parameters.kvBits = nil
                    let speculativeParameters = parameters
                    let boxedInput = UncheckedSendableBox(input)
                    stream = try await container.perform { context in
                        try MLXLMCommon.generate(
                            input: boxedInput.value,
                            parameters: speculativeParameters,
                            context: context,
                            mtpDrafter: drafter.value
                        )
                    }
                } else {
                    stream = try await container.generate(input: input, parameters: parameters)
                }
                for await generation in stream {
                    try Task.checkCancellation()
                    await collector.consume(generation, events: events)
                }
            }
        }
    }

    // MARK: - Conversational generation

    func chat(
        request: ChatInferenceRequest,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        try await admitted(events: events) {
            try await self.measured(
                profile: request.profile,
                runtimePolicy: request.runtimePolicy,
                promptText: request.instructions + "\n\n" + request.message,
                promptContent: nil,
                events: events
            ) { container, collector in
                if self.speculativeDecodingEnabled, let drafter = self.activeDrafter {
                    try await self.speculativeChat(
                        request: request,
                        container: container,
                        drafter: drafter,
                        collector: collector,
                        events: events
                    )
                    return
                }
                let (session, isNewSession) = self.conversationSession(for: request, container: container)
                var parameters = request.runtimePolicy.generationDefaults.generateParameters(
                    maxTokensOverride: request.maxTokens,
                    temperatureOverride: request.temperature
                )
                parameters.prefill.progress = Self.prefillReporter(events)
                session.generateParameters = parameters

                let images = request.runtimePolicy.supportsVision && isNewSession
                    ? request.images.map { UserInput.Image.ciImage($0.image) }
                    : []
                await events(.stage(LocalModelRunnerStage.readingSources))
                let stream = session.streamDetails(to: [.user(request.message, images: images)])
                do {
                    for try await generation in stream {
                        try Task.checkCancellation()
                        await collector.consume(generation, events: events)
                    }
                } catch {
                    self.conversation = nil
                    throw error
                }
                let output = await collector.visibleOutput
                self.recordConversationTurn(request: request, answer: output, sentImages: images.count)
            }
        }
    }

    #if DEBUG
    func conversationDiagnostics() async -> String {
        guard let live = conversation?.session else { return "no live conversation" }
        nonisolated(unsafe) let session = live
        return (try? await session.cacheStatus()).map { String(describing: $0) } ?? "status unavailable"
    }
    #endif

    func setSpeculativeDecoding(_ enabled: Bool) async {
        speculativeDecodingEnabled = enabled
        speculativeConversation = nil
        conversation = nil
        if !enabled {
            activeDrafter = nil
        }
    }

    func releaseConversations() async {
        conversation = nil
        speculativeConversation = nil
        Memory.clearCache()
    }

    private func speculativeChat(
        request: ChatInferenceRequest,
        container: ModelContainer,
        drafter: UncheckedSendableBox<any MTPDrafterModel>,
        collector: GenerationCollector,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {
        let limit = request.runtimePolicy.contextTokens - request.runtimePolicy.outputReserve(for: .ask)
        let incomingTokens = PromptTokenEstimator.estimate(request.message)
            + request.images.count * ModelRuntimePolicy.estimatedImageTokens
        let history = Self.trimmedHistory(
            request.history,
            instructions: request.instructions,
            incomingTokens: incomingTokens,
            limit: limit
        )
        let previous = speculativeConversation.flatMap {
            $0.conversationID == request.conversationID && $0.profileID == request.profile.id ? $0 : nil
        }
        speculativeConversation = nil

        let sendsImages = previous == nil && request.runtimePolicy.supportsVision && !request.images.isEmpty
        var chat: [Chat.Message] = [.system(request.instructions)]
        for message in history {
            chat.append(.user(message.question))
            chat.append(.assistant(message.answer))
        }
        chat.append(.user(request.message, images: sendsImages ? request.images.map { .ciImage($0.image) } : []))

        await events(.stage(LocalModelRunnerStage.preparingPrompt))
        let prepared = try await container.prepare(
            input: UserInput(
                chat: chat,
                processing: UserInput.Processing(resize: request.runtimePolicy.generationDefaults.imageResize),
                additionalContext: Self.chatTemplateContext(for: request.profile)
            )
        )
        let promptTokens = prepared.text.tokens.reshaped(-1).asArray(Int.self)

        var reusedCache: UncheckedSendableBox<[KVCache]>?
        var reusedCount = 0
        if let previous,
           prepared.image == nil,
           promptTokens.count > previous.tokens.count,
           promptTokens.starts(with: previous.tokens),
           previous.cache.value.first?.offset == previous.tokens.count {
            reusedCache = previous.cache
            reusedCount = previous.tokens.count
        }
        let input = reusedCache == nil
            ? UncheckedSendableBox(prepared)
            : UncheckedSendableBox(LMInput(text: LMInput.Text(
                tokens: MLXArray(Array(promptTokens[reusedCount...])).expandedDimensions(axis: 0)
            )))
        await collector.recordReusedPromptTokens(reusedCount)

        var parameters = request.runtimePolicy.generationDefaults.generateParameters(
            maxTokensOverride: request.maxTokens,
            temperatureOverride: request.temperature
        )
        parameters.kvBits = nil
        parameters.prefill.progress = Self.prefillReporter(events)
        let generationParameters = parameters
        let existingCache = reusedCache

        await events(.stage(LocalModelRunnerStage.readingSources))
        let (stream, cache) = try await container.perform { context in
            let cache = try existingCache?.value ?? context.model.newCache(parameters: generationParameters)
            let stream = try MLXLMCommon.generateTokens(
                input: input.value,
                cache: cache,
                parameters: generationParameters,
                context: context,
                mtpDrafter: drafter.value
            )
            return (stream, UncheckedSendableBox(cache))
        }

        var detokenizer = NaiveStreamingDetokenizer(tokenizer: await container.tokenizer)
        var generated: [Int] = []
        for await item in stream {
            try Task.checkCancellation()
            switch item {
            case .token(let token):
                generated.append(token)
                detokenizer.append(token: token)
                if let text = detokenizer.next() {
                    await collector.consume(.chunk(text), events: events)
                }
            case .info(let info):
                await collector.consume(.info(info), events: events)
            }
        }

        let committed = (cache.value.first?.offset ?? 0) - promptTokens.count
        guard committed >= 0, committed <= generated.count, !generated.isEmpty else { return }
        speculativeConversation = SpeculativeConversation(
            conversationID: request.conversationID,
            profileID: request.profile.id,
            cache: cache,
            tokens: promptTokens + generated.prefix(committed)
        )
    }

    private func conversationSession(for request: ChatInferenceRequest, container: ModelContainer) -> (ChatSession, Bool) {
        let instructionsHash = request.instructions.hashValue
        let incomingTokens = PromptTokenEstimator.estimate(request.message)
            + request.images.count * ModelRuntimePolicy.estimatedImageTokens
        let limit = request.runtimePolicy.contextTokens
            - request.runtimePolicy.outputReserve(for: .ask)

        if let state = conversation,
           state.conversationID == request.conversationID,
           state.profileID == request.profile.id,
           state.instructionsHash == instructionsHash,
           state.recordedTurns == request.history.count,
           state.estimatedTokens + PromptTokenEstimator.estimate(request.message) <= limit {
            return (state.session, false)
        }

        let history = Self.trimmedHistory(
            request.history,
            instructions: request.instructions,
            incomingTokens: incomingTokens,
            limit: limit
        )
        let session = ChatSession(
            container,
            instructions: request.instructions,
            history: history.flatMap { [Chat.Message.user($0.question), .assistant($0.answer)] },
            generateParameters: request.runtimePolicy.generationDefaults.generateParameters(),
            processing: UserInput.Processing(resize: request.runtimePolicy.generationDefaults.imageResize),
            additionalContext: Self.chatTemplateContext(for: request.profile)
        )
        let estimated = PromptTokenEstimator.estimate(request.instructions)
            + history.reduce(0) { $0 + PromptTokenEstimator.estimate($1.question + $1.answer) }
        conversation = ConversationState(
            conversationID: request.conversationID,
            profileID: request.profile.id,
            instructionsHash: instructionsHash,
            session: session,
            recordedTurns: request.history.count,
            estimatedTokens: estimated
        )
        return (session, true)
    }

    private func recordConversationTurn(request: ChatInferenceRequest, answer: String, sentImages: Int) {
        guard var state = conversation, state.conversationID == request.conversationID else { return }
        guard !answer.isEmpty else {
            conversation = nil
            return
        }
        state.recordedTurns = request.history.count + 1
        state.estimatedTokens += PromptTokenEstimator.estimate(request.message + answer)
            + sentImages * ModelRuntimePolicy.estimatedImageTokens
        conversation = state
    }

    nonisolated static func trimmedHistory(
        _ history: [ChatHistoryMessage],
        instructions: String,
        incomingTokens: Int,
        limit: Int
    ) -> [ChatHistoryMessage] {
        var budget = limit - PromptTokenEstimator.estimate(instructions) - incomingTokens
        var kept: [ChatHistoryMessage] = []
        for message in history.reversed() {
            let cost = PromptTokenEstimator.estimate(message.question + message.answer)
            guard cost <= budget else { break }
            budget -= cost
            kept.insert(message, at: 0)
        }
        return kept
    }

    // MARK: - Structured generation

    func generateStructured(
        request: InferenceRequest,
        jsonSchema: String,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        try await admitted(events: events) {
            try await self.measured(
                profile: request.profile,
                runtimePolicy: request.runtimePolicy,
                promptText: request.promptContent.benchmarkText,
                promptContent: request.promptContent,
                events: events
            ) { container, collector in
                await events(.stage(LocalModelRunnerStage.preparingPrompt))
                let promptContent = request.promptContent
                let profile = request.profile
                let runtimePolicy = request.runtimePolicy
                let maxTokens = request.maxTokens ?? request.runtimePolicy.generationDefaults.maxTokens
                let kvBits = request.runtimePolicy.generationDefaults.kvBits
                let prefillStep = request.runtimePolicy.generationDefaults.prefillStepSize
                let progress = Self.prefillReporter(events)
                let (deltas, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task {
                    for await delta in deltas {
                        await collector.consumeStructured(delta, events: events)
                    }
                }
                await events(.stage(LocalModelRunnerStage.readingSources))
                let started = Date()
                do {
                    let generated = try await container.perform { context in
                        let userInput = Self.makeUserInput(
                            promptContent: promptContent,
                            profile: profile,
                            runtimePolicy: runtimePolicy
                        )
                        let input = try await context.processor.prepare(input: userInput)
                        let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                        let grammarTokenizer = try GrammarTokenizer(
                            vocab: vocab.vocab,
                            vocabType: vocab.vocabType,
                            eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0)
                        )
                        let constraint = try GrammarConstraint(
                            tokenizer: grammarTokenizer,
                            jsonSchema: jsonSchema,
                            fastForward: true,
                            hostTokenizer: context.tokenizer
                        )
                        var prefill = PrefillParameters(stepSize: prefillStep)
                        prefill.progress = progress
                        return try GuidedGenerationLoop.run(
                            input: input,
                            context: context,
                            constraint: constraint,
                            maxTokens: maxTokens,
                            vocabSize: grammarTokenizer.vocabSize,
                            kvBits: kvBits,
                            prefill: prefill
                        ) { delta in
                            continuation.yield(delta)
                            return !Task.isCancelled
                        }
                    }
                    continuation.finish()
                    await forwarder.value
                    await collector.recordStructuredCompletion(
                        generatedTokens: generated,
                        seconds: Date().timeIntervalSince(started)
                    )
                } catch {
                    continuation.finish()
                    await forwarder.value
                    if error is CancellationError { throw error }
                    throw LocalModelRunnerError.structuredOutputFailed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Lifecycle

    func unload() async {
        conversation = nil
        speculativeConversation = nil
        activeDrafter = nil
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()
    }

    func preload(
        profile: ModelProfile,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        try await preload(profile: profile, runtimePolicy: runtimePolicy, events: events)
    }

    func preload(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        Memory.cacheLimit = runtimePolicy.cacheLimitBytes
        _ = try await loadContainerIfNeeded(profile: profile, events: events)
    }

    func clearCache() async throws {
        guard !(await gate.isOccupied) else {
            throw LocalModelRunnerError.busy
        }
        conversation = nil
        activeDrafter = nil
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()
        try AppDirectories.clearHuggingFaceCache()
        try AppDirectories.clearManagedModels()
    }

    // MARK: - Shared plumbing

    private func admitted<T: Sendable>(
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void,
        _ body: () async throws -> T
    ) async throws -> T {
        if await gate.isOccupied {
            await events(.stage(LocalModelRunnerStage.waitingForModel))
        }
        await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        return try await body()
    }

    private func measured(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        promptText: String,
        promptContent: StudyPromptContent?,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void,
        body: (ModelContainer, GenerationCollector) async throws -> Void
    ) async throws -> BenchmarkRecord {
        let startedAt = Date()
        let collector = GenerationCollector(startedAt: startedAt)
        var status: BenchmarkStatus = .success
        var errorMessage: String?
        var downloadSeconds = 0.0
        var loadSeconds = 0.0
        var mlxMemoryBefore: MLXMemorySnapshotRecord?

        let sampler = MemorySampler()
        await sampler.start()

        do {
            Memory.cacheLimit = runtimePolicy.cacheLimitBytes
            Memory.peakMemory = 0
            mlxMemoryBefore = MLXMemorySnapshotRecord(snapshot: Memory.snapshot())

            try Task.checkCancellation()
            let loadStart = Date()
            let loadResult = try await loadContainerIfNeeded(profile: profile, events: events)
            downloadSeconds = loadResult.downloadSeconds
            loadSeconds = max(0, Date().timeIntervalSince(loadStart) - downloadSeconds)

            try Task.checkCancellation()
            try await body(loadResult.container, collector)
            await collector.finish(events: events)
        } catch is CancellationError {
            await collector.finish(events: events)
            status = .cancelled
            errorMessage = "Run cancelled."
        } catch {
            await collector.finish(events: events)
            status = .failed
            errorMessage = error.localizedDescription
        }

        let peakFootprint = await sampler.stopAndReturnPeak()
        let mlxMemoryAfter = MLXMemorySnapshotRecord(snapshot: Memory.snapshot())
        let output = await collector.visibleOutput
        let firstTokenSeconds = await collector.firstTokenSeconds
        let metrics = await collector.tokenMetrics
        if status == .success {
            PrefillSpeedStore.record(metrics, for: profile.id)
        }

        return BenchmarkRecord(
            schemaVersion: BenchmarkRecord.schemaVersion,
            id: UUID(),
            startedAt: startedAt,
            endedAt: Date(),
            appVersion: AppInfo.version,
            device: .current,
            profileID: profile.id,
            profileName: profile.name,
            modelID: profile.modelIdentifier,
            kind: profile.kind.rawValue,
            tier: profile.tier.rawValue,
            prompt: promptText,
            imageFilename: promptContent?.imageFilenames.first,
            imageFilenames: promptContent?.imageFilenames ?? [],
            includedImageCount: promptContent?.includedImageCount ?? 0,
            omittedImageCount: promptContent?.omittedImageCount ?? 0,
            timing: BenchmarkTiming(
                downloadSeconds: downloadSeconds,
                loadSeconds: loadSeconds,
                firstTokenSeconds: firstTokenSeconds,
                wallSeconds: Date().timeIntervalSince(startedAt)
            ),
            tokenMetrics: metrics,
            mlxMemoryBefore: mlxMemoryBefore,
            mlxMemoryAfter: mlxMemoryAfter,
            processPeakPhysicalFootprintBytes: peakFootprint,
            status: status,
            errorMessage: errorMessage,
            output: output
        )
    }

    private func loadContainerIfNeeded(
        profile: ModelProfile,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> LoadedContainer {
        if activeProfileID == profile.id, let activeContainer {
            await loadDrafterIfNeeded(for: profile, events: events)
            await events(.stage(LocalModelRunnerStage.usingLoaded(profile)))
            return LoadedContainer(container: activeContainer, downloadSeconds: 0)
        }

        conversation = nil
        speculativeConversation = nil
        activeDrafter = nil
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()

        await events(.stage(LocalModelRunnerStage.checkingModelCache()))
        let tokenizerLoader = TransformersTokenizerLoader()

        let progressHandler: @Sendable (DownloadProgressUpdate) -> Void = { update in
            Task {
                await events(.downloadProgress(update))
            }
        }
        let downloadResult = try await modelDownloadService.ensureDownloaded(
            profile: profile,
            progressHandler: progressHandler
        )

        await events(.stage(LocalModelRunnerStage.loading(profile)))
        let container: ModelContainer
        switch profile.configuration {
        case .llm(let configuration):
            var localConfiguration = configuration
            localConfiguration.id = .directory(downloadResult.directory)
            container = try await LLMModelFactory.shared.loadContainer(
                from: LocalDirectoryOnlyDownloader(),
                using: tokenizerLoader,
                configuration: localConfiguration
            )

        case .vlm(let configuration):
            var localConfiguration = configuration
            localConfiguration.id = .directory(downloadResult.directory)
            container = try await VLMModelFactory.shared.loadContainer(
                from: LocalDirectoryOnlyDownloader(),
                using: tokenizerLoader,
                configuration: localConfiguration
            )
            await container.update { context in
                context.processor = TextMaskNormalizingProcessor(base: context.processor)
            }
        case .embedder:
            throw LocalModelRunnerError.unsupportedProfile(profile.id)
        }

        activeContainer = container
        activeProfileID = profile.id
        await loadDrafterIfNeeded(for: profile, events: events)
        await events(.stage(LocalModelRunnerStage.loaded(profile)))
        return LoadedContainer(container: container, downloadSeconds: downloadResult.downloadSeconds)
    }

    private func loadDrafterIfNeeded(
        for profile: ModelProfile,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async {
        guard speculativeDecodingEnabled,
              activeDrafter == nil,
              !drafterUnavailableProfileIDs.contains(profile.id),
              let drafterProfile = profile.drafterProfile else { return }
        do {
            if !didRegisterDrafterTypes {
                await Gemma4AssistantRegistration.register()
                await Qwen35VLMMTPRegistration.register()
                didRegisterDrafterTypes = true
            }
            let download = try await modelDownloadService.ensureDownloaded(profile: drafterProfile) { update in
                Task { await events(.downloadProgress(update)) }
            }
            let drafter = try await MTPDrafterModelFactory.shared.loadContainer(
                from: download.directory,
                using: TransformersTokenizerLoader()
            )
            activeDrafter = await drafter.perform { UncheckedSendableBox($0.model) }
        } catch is CancellationError {
            return
        } catch {
            drafterUnavailableProfileIDs.insert(profile.id)
            lastDrafterError = String(describing: error)
        }
    }

    nonisolated private static func prefillReporter(
        _ events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) -> @Sendable (Int, Int) -> Void {
        { processed, total in
            guard total > 0 else { return }
            let fraction = min(1, Double(processed) / Double(total))
            Task { await events(.prefillProgress(fraction)) }
        }
    }

    nonisolated static func chatTemplateContext(for profile: ModelProfile) -> [String: any Sendable]? {
        ModelCatalog.disablesThinking(profile) ? ["enable_thinking": false] : nil
    }

    nonisolated static func makeUserInput(
        promptContent: StudyPromptContent,
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy
    ) -> UserInput {
        var chat: [Chat.Message] = []
        if !promptContent.systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.append(.system(promptContent.systemInstruction))
        }

        var text: [String] = []
        var images: [UserInput.Image] = []
        if !promptContent.openingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text.append(promptContent.openingText)
        }
        for block in promptContent.sourceBlocks {
            switch block {
            case .text(let value):
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text.append(value)
                }
            case .image(let image):
                if runtimePolicy.supportsVision {
                    text.append("[Figure \(images.count + 1): \(image.displayCaption)]")
                    images.append(.ciImage(image.image))
                }
            }
        }
        if !promptContent.warnings.isEmpty {
            text.append("Source warnings:\n" + promptContent.warnings.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !promptContent.closingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text.append(promptContent.closingText)
        }
        chat.append(.user(text.joined(separator: "\n\n"), images: images))

        return UserInput(
            chat: chat,
            processing: UserInput.Processing(resize: runtimePolicy.generationDefaults.imageResize),
            additionalContext: chatTemplateContext(for: profile)
        )
    }
}

actor GenerationCollector {
    private let startedAt: Date
    private var outputFilter = ReasoningOutputFilter()
    private(set) var visibleOutput = ""
    private(set) var firstTokenSeconds: Double?
    private(set) var completionInfo: GenerateCompletionInfo?
    private var structuredTokens: Int?
    private var structuredSeconds: Double?
    private var reusedPromptTokens: Int?

    func recordReusedPromptTokens(_ count: Int) {
        reusedPromptTokens = count
    }

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func consume(_ generation: Generation, events: @Sendable (LocalModelRunnerEvent) async -> Void) async {
        switch generation {
        case .chunk(let chunk):
            if firstTokenSeconds == nil {
                firstTokenSeconds = Date().timeIntervalSince(startedAt)
                await events(.stage(LocalModelRunnerStage.generating))
            }
            let filtered = outputFilter.append(chunk)
            if !filtered.reasoning.isEmpty {
                await events(.reasoningChunk(filtered.reasoning))
            }
            if !filtered.visible.isEmpty {
                visibleOutput += filtered.visible
                await events(.outputChunk(filtered.visible))
            }
        case .info(let info):
            completionInfo = info
        case .toolCall, .rejectedToolCall:
            break
        }
    }

    func consumeStructured(_ delta: String, events: @Sendable (LocalModelRunnerEvent) async -> Void) async {
        if firstTokenSeconds == nil {
            firstTokenSeconds = Date().timeIntervalSince(startedAt)
            await events(.stage(LocalModelRunnerStage.generating))
        }
        visibleOutput += delta
        await events(.outputChunk(delta))
    }

    func recordStructuredCompletion(generatedTokens: Int, seconds: Double) {
        structuredTokens = generatedTokens
        structuredSeconds = seconds
    }

    func finish(events: @Sendable (LocalModelRunnerEvent) async -> Void) async {
        let trailing = outputFilter.finish()
        if !trailing.reasoning.isEmpty {
            await events(.reasoningChunk(trailing.reasoning))
        }
        if !trailing.visible.isEmpty {
            visibleOutput += trailing.visible
            await events(.outputChunk(trailing.visible))
        }
    }

    var tokenMetrics: BenchmarkTokenMetrics {
        if let info = completionInfo {
            return BenchmarkTokenMetrics(
                promptTokens: info.promptTokenCount,
                generatedTokens: info.generationTokenCount,
                promptTimeSeconds: info.promptTime,
                generationTimeSeconds: info.generateTime,
                tokensPerSecond: info.tokensPerSecond,
                stopReason: String(describing: info.stopReason),
                cachedPromptTokens: max(info.cachedPromptTokenCount, reusedPromptTokens ?? 0),
                proposedDraftTokens: info.proposedDraftTokens,
                acceptedDraftTokens: info.acceptedDraftTokens,
                speculativePassthroughReason: info.passthroughReason
            )
        }
        if let structuredTokens, let structuredSeconds, structuredSeconds > 0 {
            return BenchmarkTokenMetrics(
                promptTokens: nil,
                generatedTokens: structuredTokens,
                promptTimeSeconds: nil,
                generationTimeSeconds: structuredSeconds,
                tokensPerSecond: Double(structuredTokens) / structuredSeconds,
                stopReason: "stop"
            )
        }
        return BenchmarkTokenMetrics(
            promptTokens: nil,
            generatedTokens: nil,
            promptTimeSeconds: nil,
            generationTimeSeconds: nil,
            tokensPerSecond: nil,
            stopReason: nil
        )
    }
}

struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

struct TextMaskNormalizingProcessor: UserInputProcessor {
    let base: any UserInputProcessor

    @concurrent
    func prepare(input: UserInput) async throws -> LMInput {
        let prepared = try await base.prepare(input: input)
        guard prepared.image == nil,
              prepared.video == nil,
              prepared.audio == nil,
              let mask = prepared.text.mask,
              mask.min().item(Int.self) == 1 else {
            return prepared
        }
        return LMInput(text: LMInput.Text(tokens: prepared.text.tokens))
    }
}

struct LocalDirectoryOnlyDownloader: Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw ManagedModelDownloadError.invalidRepositoryID(id)
    }
}

private struct LoadedContainer: Sendable {
    var container: ModelContainer
    var downloadSeconds: Double
}
