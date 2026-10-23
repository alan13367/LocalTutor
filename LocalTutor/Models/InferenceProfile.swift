//
//  InferenceProfile.swift
//  LocalTutor
//
//

import Foundation
import CoreGraphics
import MLXLMCommon

enum ModelProfileKind: String, Codable, CaseIterable {
    case text
    case vision
    case drafter
}

typealias InferenceProfileKind = ModelProfileKind

enum ModelTier: String, Codable, CaseIterable, Comparable {
    case eightGB
    case sixteenGB
    case twentyFourGB
    case thirtyTwoGB

    var minimumSystemMemoryBytes: UInt64 {
        switch self {
        case .eightGB: 8.gibibytes
        case .sixteenGB: 16.gibibytes
        case .twentyFourGB: 24.gibibytes
        case .thirtyTwoGB: 32.gibibytes
        }
    }

    var label: String {
        switch self {
        case .eightGB: "8 GB tier"
        case .sixteenGB: "16 GB tier"
        case .twentyFourGB: "24 GB tier"
        case .thirtyTwoGB: "32 GB tier"
        }
    }

    static func tier(forSystemMemory bytes: UInt64) -> ModelTier {
        allCases.last { bytes >= $0.minimumSystemMemoryBytes } ?? .eightGB
    }

    static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        lhs.minimumSystemMemoryBytes < rhs.minimumSystemMemoryBytes
    }
}

typealias InferenceTier = ModelTier

struct ModelRuntimeDefaults: Equatable, Sendable {
    var maxTokens: Int
    var temperature: Float
    var topP: Float
    var topK = 0
    var prefillStepSize: Int
    var maxContextTokens: Int
    var kvBits: Int?
    var imageResize: CGSize?
    var documentImageLimit: Int
    var minEmbeddedImageDimension: CGFloat

    static let text = ModelRuntimeDefaults(
        maxTokens: 2_048,
        temperature: 0.3,
        topP: 0.9,
        prefillStepSize: 512,
        maxContextTokens: 32_768,
        kvBits: 8,
        imageResize: nil,
        documentImageLimit: 0,
        minEmbeddedImageDimension: 64
    )

    static let vision = ModelRuntimeDefaults(
        maxTokens: 2_048,
        temperature: 0.3,
        topP: 0.9,
        prefillStepSize: 512,
        maxContextTokens: 32_768,
        kvBits: 8,
        imageResize: CGSize(width: 1024, height: 1024),
        documentImageLimit: 4,
        minEmbeddedImageDimension: 64
    )

    func withDocumentImageLimit(_ limit: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.documentImageLimit = limit
        return copy
    }

    func withMaxContextTokens(_ maxContextTokens: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.maxContextTokens = maxContextTokens
        return copy
    }

    func withMaxTokens(_ maxTokens: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.maxTokens = maxTokens
        return copy
    }

    func withPrefillStepSize(_ prefillStepSize: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.prefillStepSize = prefillStepSize
        return copy
    }

    func generateParameters(
        maxTokensOverride: Int? = nil,
        temperatureOverride: Float? = nil
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokensOverride ?? maxTokens,
            kvBits: kvBits,
            temperature: temperatureOverride ?? temperature,
            topP: topP,
            topK: topK,
            prefill: PrefillParameters(stepSize: prefillStepSize)
        )
    }
}

typealias GenerationDefaults = ModelRuntimeDefaults

enum ProfileModelConfiguration: Sendable {
    case llm(ModelConfiguration)
    case vlm(ModelConfiguration)
    case embedder(ModelConfiguration)
}

struct ModelProfile: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let modelIdentifier: String
    let kind: ModelProfileKind
    let tier: ModelTier
    let minimumSystemMemoryBytes: UInt64
    let defaults: ModelRuntimeDefaults
    let configuration: ProfileModelConfiguration
    var publisher: String = ""
    var summary: String = ""
    var parameterScale: String = ""
    var strengths: [String] = []
    var isRecommended: Bool = false
    var downloadBytes: UInt64 = 0
    var kvBytesPerToken: Int = 32_768
    var drafterRepository: String?
    var drafterBytes: UInt64 = 0
    var speculativeDecodingByDefault = true

    var supportsVision: Bool { kind == .vision }

    var supportsSpeculativeDecoding: Bool { drafterRepository != nil }

    var drafterProfile: ModelProfile? {
        guard let drafterRepository else { return nil }
        return ModelProfile(
            id: "\(id).drafter",
            name: "\(name) speed-up",
            subtitle: "Multi-token prediction drafter",
            modelIdentifier: drafterRepository,
            kind: .drafter,
            tier: tier,
            minimumSystemMemoryBytes: minimumSystemMemoryBytes,
            defaults: .text,
            configuration: .embedder(ModelConfiguration(id: drafterRepository)),
            downloadBytes: drafterBytes
        )
    }

    var totalDownloadBytes: UInt64 { downloadBytes + (speculativeDecodingByDefault ? drafterBytes : 0) }

    var minimumSystemMemoryDescription: String {
        ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(minimumSystemMemoryBytes))
    }

    var downloadSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalDownloadBytes), countStyle: .file)
    }

    var tierLabel: String {
        tier.label
    }
}

typealias InferenceProfile = ModelProfile

extension ModelProfile {
    static var gemma4E2B: ModelProfile { ModelCatalog.require("gemma4E2B") }
    static var gemma4E4B: ModelProfile { ModelCatalog.require("gemma4E4B") }
    static var qwen35_4B: ModelProfile { ModelCatalog.require("qwen35_4B") }
    static var qwen35_9B: ModelProfile { ModelCatalog.require("qwen35_9B") }
    static var lfm25A1B8B: ModelProfile { ModelCatalog.require("lfm25A1B8B") }
    static var studyCatalog: [ModelProfile] { ModelCatalog.studyCatalog }

    static func profile(withID id: String) -> ModelProfile? {
        ModelCatalog.profile(withID: id)
    }

    static func profile(owningDrafterID id: String) -> ModelProfile? {
        ModelCatalog.studyCatalog.first { $0.drafterProfile?.id == id }
    }

    static var recommendedDefault: ModelProfile {
        ModelCatalog.recommendedDefault
    }
}
