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
}

typealias InferenceProfileKind = ModelProfileKind

enum ModelTier: String, Codable, CaseIterable {
    case eightGB
    case sixteenGB
}

typealias InferenceTier = ModelTier

struct ModelRuntimeDefaults: Equatable, Sendable {
    var maxTokens: Int
    var temperature: Float
    var topP: Float
    var prefillStepSize: Int
    var maxKVSize: Int
    var kvBits: Int
    var imageResize: CGSize?
    var documentImageLimit: Int
    var minEmbeddedImageDimension: CGFloat

    static let text = ModelRuntimeDefaults(
        maxTokens: 1024,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 6144,
        kvBits: 4,
        imageResize: nil,
        documentImageLimit: 0,
        minEmbeddedImageDimension: 64
    )

    static let vision = ModelRuntimeDefaults(
        maxTokens: 1024,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 6144,
        kvBits: 4,
        imageResize: CGSize(width: 1024, height: 1024),
        documentImageLimit: 2,
        minEmbeddedImageDimension: 64
    )

    func withDocumentImageLimit(_ limit: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.documentImageLimit = limit
        return copy
    }

    func withMaxKVSize(_ maxKVSize: Int) -> ModelRuntimeDefaults {
        var copy = self
        copy.maxKVSize = maxKVSize
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
}

typealias GenerationDefaults = ModelRuntimeDefaults

enum ProfileModelConfiguration: Sendable {
    case llm(ModelConfiguration)
    case vlm(ModelConfiguration)
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

    var supportsVision: Bool { kind == .vision }

    var minimumSystemMemoryDescription: String {
        ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(minimumSystemMemoryBytes))
    }

    var tierLabel: String {
        switch tier {
        case .eightGB: "8 GB tier"
        case .sixteenGB: "16 GB tier"
        }
    }
}

typealias InferenceProfile = ModelProfile

extension ModelProfile {
    static let gemma4E2B = ModelCatalog.gemma4E2B
    static let gemma4E4B = ModelCatalog.gemma4E4B
    static let qwen3VL4B = ModelCatalog.qwen3VL4B
    static let lfm25A1B8B = ModelCatalog.lfm25A1B8B
    static let v0Catalog = ModelCatalog.v0Catalog
    static let studyCatalog = ModelCatalog.studyCatalog

    static func profile(withID id: String) -> ModelProfile? {
        ModelCatalog.profile(withID: id)
    }

    static var recommendedDefault: ModelProfile {
        ModelCatalog.recommendedDefault
    }
}
