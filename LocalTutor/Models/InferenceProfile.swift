//
//  InferenceProfile.swift
//  LocalTutor
//
//

import Foundation
import CoreGraphics
import MLXLMCommon

enum InferenceProfileKind: String, Codable, CaseIterable {
    case text
    case vision
}

enum InferenceTier: String, Codable, CaseIterable {
    case eightGB
    case sixteenGB
}

struct GenerationDefaults: Equatable, Sendable {
    var maxTokens: Int
    var temperature: Float
    var topP: Float
    var prefillStepSize: Int
    var maxKVSize: Int
    var kvBits: Int
    var imageResize: CGSize?
    var documentImageLimit: Int
    var minEmbeddedImageDimension: CGFloat

    static let text = GenerationDefaults(
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

    static let vision = GenerationDefaults(
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

    func withDocumentImageLimit(_ limit: Int) -> GenerationDefaults {
        var copy = self
        copy.documentImageLimit = limit
        return copy
    }

    func withMaxKVSize(_ maxKVSize: Int) -> GenerationDefaults {
        var copy = self
        copy.maxKVSize = maxKVSize
        return copy
    }

    func withMaxTokens(_ maxTokens: Int) -> GenerationDefaults {
        var copy = self
        copy.maxTokens = maxTokens
        return copy
    }

    func withPrefillStepSize(_ prefillStepSize: Int) -> GenerationDefaults {
        var copy = self
        copy.prefillStepSize = prefillStepSize
        return copy
    }
}

enum ProfileModelConfiguration: Sendable {
    case llm(ModelConfiguration)
    case vlm(ModelConfiguration)
}

struct InferenceProfile: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let modelIdentifier: String
    let kind: InferenceProfileKind
    let tier: InferenceTier
    let minimumSystemMemoryBytes: UInt64
    let defaults: GenerationDefaults
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

extension InferenceProfile {
    static let gemma4E2B = InferenceProfileCatalog.gemma4E2B
    static let gemma4E4B = InferenceProfileCatalog.gemma4E4B
    static let qwen3VL4B = InferenceProfileCatalog.qwen3VL4B
    static let v0Catalog = InferenceProfileCatalog.v0Catalog
    static let studyCatalog = InferenceProfileCatalog.studyCatalog

    static func profile(withID id: String) -> InferenceProfile? {
        InferenceProfileCatalog.profile(withID: id)
    }

    static var recommendedDefault: InferenceProfile {
        InferenceProfileCatalog.recommendedDefault
    }
}
