import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

enum EmbeddingInputKind: Sendable {
    case query
    case document(title: String?)
}

enum EmbeddingServiceEvent: Sendable {
    case downloading(DownloadProgressUpdate)
    case ready
}

enum EmbeddingServiceError: LocalizedError {
    case invalidDimension(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDimension(let dimension):
            "Embedding model returned \(dimension) dimensions instead of \(LocalEmbeddingRunner.dimension)."
        }
    }
}

protocol EmbeddingService: Sendable {
    func prepare(events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void) async throws
    func embedQuery(_ text: String) async throws -> [Float]
    func embedDocuments(_ documents: [EmbeddingDocument]) async throws -> [[Float]]
    func unload() async
}

struct EmbeddingDocument: Sendable {
    var title: String?
    var text: String
}

actor LocalEmbeddingRunner: EmbeddingService {
    static let shared = LocalEmbeddingRunner()
    static let dimension = 768
    static let maximumBatchSize = 8
    static let maximumBatchTokens = 1_024
    static let promptVersion = 1

    private let modelDownloadService: ManagedModelDownloadService
    private var activeContainer: EmbedderModelContainer?
    private var loadTask: Task<EmbedderModelContainer, Error>?

    init(modelDownloadService: ManagedModelDownloadService = .shared) {
        self.modelDownloadService = modelDownloadService
    }

    func prepare(events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void) async throws {
        _ = try await loadContainerIfNeeded(events: events)
        await events(.ready)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        let vectors = try await embed(
            inputs: [Self.formatted(text: text, kind: .query)],
            events: { _ in }
        )
        return vectors[0]
    }

    func embedDocuments(_ documents: [EmbeddingDocument]) async throws -> [[Float]] {
        guard !documents.isEmpty else { return [] }
        let formattedInputs = documents.map {
            Self.formatted(text: $0.text, kind: .document(title: $0.title))
        }
        var result: [[Float]] = []
        var batch: [String] = []
        var batchTokens = 0

        for text in formattedInputs {
            let estimate = PromptTokenEstimator.estimate(text)
            if !batch.isEmpty,
               batch.count >= Self.maximumBatchSize
                || batchTokens + estimate > Self.maximumBatchTokens {
                result.append(contentsOf: try await embed(inputs: batch, events: { _ in }))
                batch.removeAll(keepingCapacity: true)
                batchTokens = 0
            }
            batch.append(text)
            batchTokens += estimate
        }
        if !batch.isEmpty {
            result.append(contentsOf: try await embed(inputs: batch, events: { _ in }))
        }
        return result
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        activeContainer = nil
        Memory.clearCache()
    }

    nonisolated static func formatted(text: String, kind: EmbeddingInputKind) -> String {
        switch kind {
        case .query:
            "task: search result | query: \(text)"
        case .document(let title):
            "title: \(title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled") | text: \(text)"
        }
    }

    private func embed(
        inputs: [String],
        events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void
    ) async throws -> [[Float]] {
        let container = try await loadContainerIfNeeded(events: events)
        return try await container.perform { context in
            let encoded = inputs.map {
                context.tokenizer.encode(text: $0, addSpecialTokens: true)
            }
            let maximumLength = encoded.map(\.count).max() ?? 0
            let paddingToken = context.tokenizer.eosTokenId ?? 0
            let padded = encoded.map {
                $0 + Array(repeating: paddingToken, count: maximumLength - $0.count)
            }
            let masks = encoded.map {
                Array(repeating: Float(1), count: $0.count)
                    + Array(repeating: Float(0), count: maximumLength - $0.count)
            }
            let input = MLXArray(padded.flatMap { $0 }, [padded.count, maximumLength])
            let mask = MLXArray(masks.flatMap { $0 }, [masks.count, maximumLength])
            let output = context.model(
                input,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: mask
            )
            let pooled = context.pooling(output, mask: mask, normalize: true).asType(.float32)
            pooled.eval()
            return try pooled.map { vector in
                let values = vector.asArray(Float.self)
                guard values.count >= Self.dimension else {
                    throw EmbeddingServiceError.invalidDimension(values.count)
                }
                return Array(values.prefix(Self.dimension))
            }
        }
    }

    private nonisolated static func removeLegacyModels() {
        for profile in ModelCatalog.legacyEmbeddingModels {
            _ = try? ModelCacheStore.removeCachedModel(for: profile)
        }
    }

    private func loadContainerIfNeeded(
        events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void
    ) async throws -> EmbedderModelContainer {
        if let activeContainer {
            return activeContainer
        }
        if let loadTask {
            return try await loadTask.value
        }

        let profile = ModelCatalog.embeddingModel
        let modelDownloadService = modelDownloadService
        let task = Task<EmbedderModelContainer, Error> {
            let result = try await modelDownloadService.ensureDownloaded(
                profile: profile,
                progressHandler: { update in
                    Task { await events(.downloading(update)) }
                }
            )
            guard case .embedder(var configuration) = profile.configuration else {
                throw LocalModelRunnerError.unsupportedProfile(profile.id)
            }
            configuration.id = .directory(result.directory)
            configuration.excludedComponents = [.vision, .audio]
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: LocalDirectoryOnlyDownloader(),
                using: TransformersTokenizerLoader(),
                configuration: configuration
            )
            Self.removeLegacyModels()
            return container
        }
        loadTask = task
        do {
            let container = try await task.value
            activeContainer = container
            loadTask = nil
            return container
        } catch {
            loadTask = nil
            throw error
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
