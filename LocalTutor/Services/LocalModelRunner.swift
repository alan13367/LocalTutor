//
//  LocalModelRunner.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

enum LocalModelRunnerEvent: Sendable {
    case stage(String)
    case downloadProgress(Double, String)
    case outputChunk(String)
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

actor LocalModelRunner {
    private var activeContainer: ModelContainer?
    private var activeProfileID: String?
    private var isRunning = false

    func run(
        profile: InferenceProfile,
        prompt: String,
        imageURL: URL?,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
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
        var peakFootprint: UInt64?
        var mlxMemoryBefore: MLXMemorySnapshotRecord?
        var mlxMemoryAfter: MLXMemorySnapshotRecord?

        let sampler = MemorySampler()
        await sampler.start()

        let securityAccess = imageURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if securityAccess {
                imageURL?.stopAccessingSecurityScopedResource()
            }
        }

        do {
            Memory.cacheLimit = 20 * 1024 * 1024
            Memory.peakMemory = 0
            mlxMemoryBefore = MLXMemorySnapshotRecord(snapshot: Memory.snapshot())

            try Task.checkCancellation()
            let loadStart = Date()
            let loadResult = try await loadContainerIfNeeded(profile: profile, events: events)
            let container = loadResult.container
            downloadSeconds = loadResult.downloadSeconds
            loadSeconds = max(0, Date().timeIntervalSince(loadStart) - downloadSeconds)

            try Task.checkCancellation()
            await events(.stage("Preparing prompt"))
            let preparedInput = try await Self.prepareInput(
                container: container,
                prompt: prompt,
                profile: profile,
                imageURL: imageURL
            )

            try Task.checkCancellation()
            await events(.stage("Generating"))
            let stream = try await container.generate(
                input: preparedInput,
                parameters: profile.defaults.generateParameters
            )

            for await generation in stream {
                try Task.checkCancellation()

                switch generation {
                case .chunk(let chunk):
                    if firstTokenSeconds == nil {
                        firstTokenSeconds = Date().timeIntervalSince(wallStart)
                    }
                    output += chunk
                    await events(.outputChunk(chunk))

                case .info(let info):
                    completionInfo = info

                case .toolCall(let toolCall):
                    let chunk = "\n[tool call: \(toolCall.function.name)]\n"
                    output += chunk
                    await events(.outputChunk(chunk))
                }
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
            prompt: prompt,
            imageFilename: imageURL?.lastPathComponent,
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

    func unload() {
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()
    }

    func clearCache() throws {
        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()
        try AppDirectories.clearHuggingFaceCache()
    }

    #if DEBUG
    func setRunningForTesting(_ value: Bool) {
        isRunning = value
    }
    #endif

    private func loadContainerIfNeeded(
        profile: InferenceProfile,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> LoadedContainer {
        if activeProfileID == profile.id, let activeContainer {
            await events(.stage("Using loaded \(profile.name)"))
            return LoadedContainer(container: activeContainer, downloadSeconds: 0)
        }

        activeContainer = nil
        activeProfileID = nil
        Memory.clearCache()

        await events(.stage("Loading \(profile.name)"))
        let tracker = DownloadProgressTracker()
        let cacheURL = try AppDirectories.huggingFaceCache()
        let hubClient = HubClient(
            userAgent: "LocalTutor/\(AppInfo.version)",
            cache: HubCache(cacheDirectory: cacheURL)
        )
        let downloader = HuggingFaceModelDownloader(hubClient: hubClient)
        let tokenizerLoader = TransformersTokenizerLoader()

        let progressHandler: @Sendable (Progress) -> Void = { progress in
            let update = tracker.update(progress)
            Task {
                await events(.downloadProgress(update.fraction, update.description))
            }
        }

        let container: ModelContainer
        switch profile.configuration {
        case .llm(let configuration):
            container = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration,
                progressHandler: progressHandler
            )

        case .vlm(let configuration):
            container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: tokenizerLoader,
                configuration: configuration,
                progressHandler: progressHandler
            )
        }

        activeContainer = container
        activeProfileID = profile.id
        await events(.stage("Loaded \(profile.name)"))
        return LoadedContainer(container: container, downloadSeconds: tracker.downloadSeconds)
    }

    nonisolated private static func prepareInput(
        container: ModelContainer,
        prompt: String,
        profile: InferenceProfile,
        imageURL: URL?
    ) async throws -> LMInput {
        let input = try makeUserInput(prompt: prompt, profile: profile, imageURL: imageURL)
        return try await container.prepare(input: input)
    }

    nonisolated private static func makeUserInput(
        prompt: String,
        profile: InferenceProfile,
        imageURL: URL?
    ) throws -> UserInput {
        let images = imageURL.map { [UserInput.Image.url($0)] } ?? []
        var input = UserInput(prompt: prompt, images: images)
        input.processing = UserInput.Processing(resize: profile.defaults.imageResize)
        return input
    }
}

private struct LoadedContainer: Sendable {
    var container: ModelContainer
    var downloadSeconds: Double
}

private extension GenerationDefaults {
    var generateParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxKVSize,
            kvBits: kvBits,
            temperature: temperature,
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
