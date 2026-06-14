import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN
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
    static let maximumBatchTokens = 4_096
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
            let pooled = context.pooling(output, mask: mask, normalize: true)
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

    private func loadContainerIfNeeded(
        events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void
    ) async throws -> EmbedderModelContainer {
        if let activeContainer {
            return activeContainer
        }
        if let loadTask {
            return try await loadTask.value
        }

        let profile = ModelCatalog.embeddingGemma300M
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
            return try await Self.loadCompatibleContainer(
                directory: result.directory,
                configuration: configuration
            )
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

    private nonisolated static func loadCompatibleContainer(
        directory: URL,
        configuration: ModelConfiguration
    ) async throws -> EmbedderModelContainer {
        let configurationData = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        let modelConfiguration = try JSONDecoder().decode(
            Gemma3Configuration.self,
            from: configurationData
        )
        let baseConfiguration = try JSONDecoder().decode(
            BaseConfiguration.self,
            from: configurationData
        )

        var weights: [String: MLXArray] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "safetensors" else { continue }
            for (key, value) in try loadArrays(url: url) {
                weights[key] = value
            }
        }
        if let embeddingWeight = weights["model.embed_tokens.weight"],
           embeddingWeight.dim(0) > modelConfiguration.vocabularySize {
            weights["model.embed_tokens.weight"] =
                embeddingWeight[0..<modelConfiguration.vocabularySize]
        }
        weights = weights.filter {
            !$0.key.contains("self_attn.rotary_emb.inv_freq")
                && !$0.key.contains("lm_head")
        }

        let projectionSize =
            weights["dense.0.weight"]?.dim(0)
            ?? weights["dense.0.scales"]?.dim(0)
            ?? modelConfiguration.intermediateSize
        let model = EmbeddingGemma(modelConfiguration)
        var modules = ModuleChildren()
        modules["dense"] = .array([
            .value(Linear(
                modelConfiguration.hiddenSize,
                projectionSize,
                bias: false
            )),
            .value(Linear(
                projectionSize,
                modelConfiguration.hiddenSize,
                bias: false
            ))
        ])
        model.update(modules: modules)

        if let perLayerQuantization = baseConfiguration.perLayerQuantization {
            quantize(model: model) { path, _ in
                guard weights["\(path).scales"] != nil else { return nil }
                return perLayerQuantization.quantization(layer: path)?.asTuple
            }
        }
        try model.update(
            parameters: ModuleParameters.unflattened(weights),
            verify: [.all]
        )
        eval(model)

        let tokenizer = try await TransformersTokenizerLoader().load(from: directory)
        return EmbedderModelContainer(
            context: EmbedderModelContext(
                configuration: configuration,
                model: model,
                tokenizer: tokenizer,
                pooling: Pooling(strategy: .none)
            )
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
