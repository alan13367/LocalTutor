//
//  LocalModelRunner.swift
//  LocalTutor
//
//

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

enum LocalModelRunnerEvent: Sendable {
    case stage(String)
    case downloadProgress(DownloadProgressUpdate)
    case reasoningChunk(String)
    case outputChunk(String)
}

enum LocalModelRunnerStage {
    static let preparingPrompt = "Preparing prompt"
    static let generating = "Generating"

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
            || message == generating
    }
}

enum LocalModelRunnerError: LocalizedError {
    case busy
    case imageRequired
    case unsupportedProfile(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            "A model run is already in progress."
        case .imageRequired:
            "Select an image for this vision run."
        case .unsupportedProfile(let id):
            "Unsupported profile: \(id)."
        }
    }
}

actor LocalModelRunner: InferenceService {
    private let modelDownloadService: ManagedModelDownloadService
    private var activeContainer: ModelContainer?
    private var activeProfileID: String?
    private var isRunning = false

    init(modelDownloadService: ManagedModelDownloadService = .shared) {
        self.modelDownloadService = modelDownloadService
    }

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
        return try await run(
            profile: profile,
            promptContent: promptContent,
            maxTokens: maxTokens,
            temperature: temperature,
            events: events
        )
    }

    func run(
        profile: ModelProfile,
        promptContent: StudyPromptContent,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        let request = InferenceRequest(
            profile: profile,
            runtimePolicy: runtimePolicy,
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
        let profile = request.profile
        let runtimePolicy = request.runtimePolicy
        guard !isRunning else {
            throw LocalModelRunnerError.busy
        }

        isRunning = true
        defer { isRunning = false }

        let startedAt = Date()
        let wallStart = Date()
        var output = ""
        var firstTokenSeconds: Double?
        var completionInfo: GenerateCompletionInfo?
        var status: BenchmarkStatus = .success
        var errorMessage: String?
        var downloadSeconds = 0.0
        var loadSeconds = 0.0
        var outputFilter = ReasoningOutputFilter()
        var peakFootprint: UInt64?
        var mlxMemoryBefore: MLXMemorySnapshotRecord?
        var mlxMemoryAfter: MLXMemorySnapshotRecord?

        let sampler = MemorySampler()
        await sampler.start()

        do {
            Memory.cacheLimit = runtimePolicy.cacheLimitBytes
            Memory.clearCache()
            Memory.peakMemory = 0
            mlxMemoryBefore = MLXMemorySnapshotRecord(snapshot: Memory.snapshot())

            try Task.checkCancellation()
            let loadStart = Date()
            let loadResult = try await loadContainerIfNeeded(profile: profile, events: events)
            let container = loadResult.container
            downloadSeconds = loadResult.downloadSeconds
            loadSeconds = max(0, Date().timeIntervalSince(loadStart) - downloadSeconds)
            Memory.clearCache()

            try Task.checkCancellation()
            await events(.stage(LocalModelRunnerStage.preparingPrompt))
            let preparedInput = try await Self.prepareInput(
                container: container,
                promptContent: request.promptContent,
                runtimePolicy: runtimePolicy
            )
            Memory.clearCache()

            try Task.checkCancellation()
            await events(.stage(LocalModelRunnerStage.generating))
            let parameters = runtimePolicy.generationDefaults.generateParameters(
                maxTokensOverride: request.maxTokens,
                temperatureOverride: request.temperature
            )
            let stream = try await container.generate(
                input: preparedInput,
                parameters: parameters
            )

            for await generation in stream {
                try Task.checkCancellation()

                switch generation {
                case .chunk(let chunk):
                    if firstTokenSeconds == nil {
                        firstTokenSeconds = Date().timeIntervalSince(wallStart)
                    }
                    let filteredChunk = outputFilter.append(chunk)
                    if !filteredChunk.reasoning.isEmpty {
                        await events(.reasoningChunk(filteredChunk.reasoning))
                    }
                    if !filteredChunk.visible.isEmpty {
                        output += filteredChunk.visible
                        await events(.outputChunk(filteredChunk.visible))
                    }

                case .info(let info):
                    completionInfo = info

                case .toolCall(let toolCall):
                    let chunk = "\n[tool call: \(toolCall.function.name)]\n"
                    output += chunk
                    await events(.outputChunk(chunk))
                }
            }
            let trailingChunk = outputFilter.finish()
            if !trailingChunk.reasoning.isEmpty {
                await events(.reasoningChunk(trailingChunk.reasoning))
            }
            if !trailingChunk.visible.isEmpty {
                output += trailingChunk.visible
                await events(.outputChunk(trailingChunk.visible))
            }
        } catch is CancellationError {
            status = .cancelled
            errorMessage = "Run cancelled."
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
        }

        peakFootprint = await sampler.stopAndReturnPeak()
        mlxMemoryAfter = MLXMemorySnapshotRecord(snapshot: Memory.snapshot())

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
            prompt: request.promptContent.benchmarkText,
            imageFilename: request.promptContent.imageFilenames.first,
            imageFilenames: request.promptContent.imageFilenames,
            includedImageCount: request.promptContent.includedImageCount,
            omittedImageCount: request.promptContent.omittedImageCount,
            timing: BenchmarkTiming(
                downloadSeconds: downloadSeconds,
                loadSeconds: loadSeconds,
                firstTokenSeconds: firstTokenSeconds,
                wallSeconds: Date().timeIntervalSince(wallStart)
            ),
            tokenMetrics: BenchmarkTokenMetrics(info: completionInfo),
            mlxMemoryBefore: mlxMemoryBefore,
            mlxMemoryAfter: mlxMemoryAfter,
            processPeakPhysicalFootprintBytes: peakFootprint,
            status: status,
            errorMessage: errorMessage,
            output: output
        )
    }

    func unload() async {
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
        while isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        isRunning = true
        defer { isRunning = false }

        Memory.cacheLimit = runtimePolicy.cacheLimitBytes
        Memory.clearCache()
        _ = try await loadContainerIfNeeded(profile: profile, events: events)
        Memory.clearCache()
    }

    func clearCache() async throws {
        guard !isRunning else {
            throw LocalModelRunnerError.busy
        }
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()
        try AppDirectories.clearHuggingFaceCache()
        try AppDirectories.clearManagedModels()
    }

    #if DEBUG
    func setRunningForTesting(_ value: Bool) {
        isRunning = value
    }
    #endif

    private func loadContainerIfNeeded(
        profile: ModelProfile,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> LoadedContainer {
        if activeProfileID == profile.id, let activeContainer {
            await events(.stage(LocalModelRunnerStage.usingLoaded(profile)))
            return LoadedContainer(container: activeContainer, downloadSeconds: 0)
        }

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
        }

        activeContainer = container
        activeProfileID = profile.id
        await events(.stage(LocalModelRunnerStage.loaded(profile)))
        return LoadedContainer(container: container, downloadSeconds: downloadResult.downloadSeconds)
    }

    nonisolated private static func prepareInput(
        container: ModelContainer,
        promptContent: StudyPromptContent,
        runtimePolicy: ModelRuntimePolicy
    ) async throws -> LMInput {
        let input = try makeUserInput(promptContent: promptContent, runtimePolicy: runtimePolicy)
        return try await container.prepare(input: input)
    }

    nonisolated private static func makeUserInput(
        promptContent: StudyPromptContent,
        runtimePolicy: ModelRuntimePolicy
    ) throws -> UserInput {
        var chat: [Chat.Message] = []
        if !promptContent.systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.append(.system(promptContent.systemInstruction))
        }
        if !promptContent.openingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.append(.user(promptContent.openingText))
        }

        for block in promptContent.sourceBlocks {
            switch block {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chat.append(.user(text))
                }
            case .image(let image):
                if runtimePolicy.supportsVision {
                    chat.append(.user(image.displayCaption, images: [.ciImage(image.image)]))
                }
            }
        }

        if !promptContent.warnings.isEmpty {
            chat.append(.user("Source warnings:\n" + promptContent.warnings.map { "- \($0)" }.joined(separator: "\n")))
        }
        if !promptContent.closingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.append(.user(promptContent.closingText))
        }

        let input = UserInput(
            chat: chat,
            processing: UserInput.Processing(resize: runtimePolicy.generationDefaults.imageResize)
        )
        return input
    }

}

private struct LocalDirectoryOnlyDownloader: Downloader {
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

private extension ModelRuntimeDefaults {
    func generateParameters(maxTokensOverride _: Int? = nil, temperatureOverride: Float? = nil) -> GenerateParameters {
        GenerateParameters(
            maxTokens: nil,
            maxKVSize: maxKVSize,
            kvBits: kvBits,
            temperature: temperatureOverride ?? temperature,
            topP: topP,
            prefillStepSize: prefillStepSize
        )
    }
}

private extension BenchmarkTokenMetrics {
    init(info: GenerateCompletionInfo?) {
        guard let info else {
            self.init(
                promptTokens: nil,
                generatedTokens: nil,
                promptTimeSeconds: nil,
                generationTimeSeconds: nil,
                tokensPerSecond: nil,
                stopReason: nil
            )
            return
        }

        self.init(
            promptTokens: info.promptTokenCount,
            generatedTokens: info.generationTokenCount,
            promptTimeSeconds: info.promptTime,
            generationTimeSeconds: info.generateTime,
            tokensPerSecond: info.tokensPerSecond,
            stopReason: String(describing: info.stopReason)
        )
    }
}
