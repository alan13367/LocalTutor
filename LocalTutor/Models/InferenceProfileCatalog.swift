//
//  InferenceProfileCatalog.swift
//  LocalTutor
//

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

struct ModelCatalogFile: Decodable {
    var version: Int
    var models: [ModelCatalogEntry]
}

struct ModelCatalogEntry: Decodable, Equatable {
    enum Loader: String, Decodable {
        case llm
        case vlm
    }

    var id: String
    var name: String
    var subtitle: String
    var repository: String
    var loader: Loader
    var kind: ModelProfileKind
    var tier: ModelTier
    var publisher: String
    var summary: String
    var parameterScale: String
    var strengths: [String]
    var recommended: Bool
    var downloadBytes: UInt64
    var kvBytesPerToken: Int
    var maxContextTokens: Int
    var documentImageLimit: Int?
    var disableThinking: Bool?
    var toolCallFormat: String?
    var maxTokens: Int?
    var temperature: Float?
    var drafterRepository: String?
    var drafterBytes: UInt64?
}

enum ModelCatalog {
    static let embeddingModel = ModelProfile(
        id: "embeddingGemma2",
        name: "EmbeddingGemma 2",
        subtitle: "Background model for Dense Semantic Retrieval",
        modelIdentifier: "mlx-community/embeddinggemma-2-8bit",
        kind: .text,
        tier: .eightGB,
        minimumSystemMemoryBytes: 4.gibibytes,
        defaults: ModelRuntimeDefaults.text,
        configuration: .embedder(
            ModelConfiguration(
                id: "mlx-community/embeddinggemma-2-8bit"
            )
        ),
        publisher: "Google",
        summary: "Multilingual embedding model used silently by the app for semantic retrieval. Only its text encoder is loaded.",
        parameterScale: "270M text encoder · 8-bit MLX",
        strengths: ["Embeddings", "Multilingual", "8K context"],
        downloadBytes: 1_267_000_000
    )

    static let legacyEmbeddingModels: [ModelProfile] = [
        ModelProfile(
            id: "embeddingGemma300M",
            name: "Embedding Gemma 300M",
            subtitle: "Background model for Dense Semantic Retrieval",
            modelIdentifier: "mlx-community/embeddinggemma-300m-4bit",
            kind: .text,
            tier: .eightGB,
            minimumSystemMemoryBytes: 4.gibibytes,
            defaults: ModelRuntimeDefaults.text,
            configuration: .embedder(ModelConfiguration(id: "mlx-community/embeddinggemma-300m-4bit")),
            publisher: "Google",
            summary: "",
            parameterScale: "300M params · 4-bit MLX",
            strengths: [],
            downloadBytes: 230_000_000
        )
    ]

    static let entries: [ModelCatalogEntry] = loadEntries()

    static let studyCatalog: [ModelProfile] = entries.map(profile(from:))

    static func profile(withID id: String) -> ModelProfile? {
        studyCatalog.first { $0.id == id }
    }

    static func require(_ id: String) -> ModelProfile {
        guard let profile = profile(withID: id) else {
            preconditionFailure("Model \(id) is missing from ModelCatalog.json")
        }
        return profile
    }

    static func disablesThinking(_ profile: ModelProfile) -> Bool {
        entries.first { $0.id == profile.id }?.disableThinking ?? false
    }

    static var recommendedDefault: ModelProfile {
        recommended(forSystemMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func recommended(forSystemMemory bytes: UInt64) -> ModelProfile {
        let tier = ModelTier.tier(forSystemMemory: bytes)
        let candidates = studyCatalog.filter { $0.isRecommended && $0.tier <= tier }
        return candidates.max { $0.tier < $1.tier } ?? studyCatalog[0]
    }

    static func profile(from entry: ModelCatalogEntry) -> ModelProfile {
        let base: ModelRuntimeDefaults = entry.kind == .vision ? .vision : .text
        var defaults = base.withMaxContextTokens(entry.maxContextTokens)
        if let limit = entry.documentImageLimit {
            defaults = defaults.withDocumentImageLimit(limit)
        }
        if let maxTokens = entry.maxTokens {
            defaults = defaults.withMaxTokens(maxTokens)
        }
        if let temperature = entry.temperature {
            defaults.temperature = temperature
        }

        return ModelProfile(
            id: entry.id,
            name: entry.name,
            subtitle: entry.subtitle,
            modelIdentifier: entry.repository,
            kind: entry.kind,
            tier: entry.tier,
            minimumSystemMemoryBytes: entry.tier.minimumSystemMemoryBytes,
            defaults: defaults,
            configuration: configuration(for: entry),
            publisher: entry.publisher,
            summary: entry.summary,
            parameterScale: entry.parameterScale,
            strengths: entry.strengths,
            isRecommended: entry.recommended,
            downloadBytes: entry.downloadBytes,
            kvBytesPerToken: entry.kvBytesPerToken,
            drafterRepository: entry.drafterRepository,
            drafterBytes: entry.drafterBytes ?? 0
        )
    }

    private static func configuration(for entry: ModelCatalogEntry) -> ProfileModelConfiguration {
        switch entry.loader {
        case .vlm:
            return .vlm(VLMModelFactory.shared.configuration(id: entry.repository))
        case .llm:
            var configuration = LLMModelFactory.shared.configuration(id: entry.repository)
            if let format = entry.toolCallFormat.flatMap(ToolCallFormat.init(rawValue:)) {
                configuration.toolCallFormat = format
            }
            return .llm(configuration)
        }
    }

    private static func loadEntries() -> [ModelCatalogEntry] {
        let bundles = [Bundle.main, Bundle(for: CatalogBundleToken.self)]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "ModelCatalog", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ModelCatalogFile.self, from: data),
                  !file.models.isEmpty else {
                continue
            }
            return file.models
        }
        preconditionFailure("ModelCatalog.json is missing from the app bundle")
    }
}

private final class CatalogBundleToken {}

typealias InferenceProfileCatalog = ModelCatalog
