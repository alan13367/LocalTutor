//
//  InferenceProfile.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import CoreGraphics
import MLXLLM
import MLXVLM
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

    static let text = GenerationDefaults(
        maxTokens: 512,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 2048,
        kvBits: 4,
        imageResize: nil
    )

    static let vision = GenerationDefaults(
        maxTokens: 256,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 2048,
        kvBits: 4,
        imageResize: CGSize(width: 1024, height: 1024)
    )
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

    var minimumSystemMemoryDescription: String {
        ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(minimumSystemMemoryBytes))
    }
}

extension InferenceProfile {
    static let gemma4E2B = InferenceProfile(
        id: "gemma4E2B",
        name: "Gemma 4 E2B",
        subtitle: "8GB baseline, text and vision capable",
        modelIdentifier: "mlx-community/gemma-4-e2b-it-4bit",
        kind: .vision,
        tier: .eightGB,
        minimumSystemMemoryBytes: 8.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.gemma4_E2B_it_4bit)
    )

    static let gemma4E4B = InferenceProfile(
        id: "gemma4E4B",
        name: "Gemma 4 E4B",
        subtitle: "16GB tier, stronger multimodal reasoning",
        modelIdentifier: "mlx-community/gemma-4-e4b-it-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.gemma4_E4B_it_4bit)
    )

    static let v0Catalog: [InferenceProfile] = [
        .gemma4E2B,
        .gemma4E4B
    ]

    static var recommendedDefault: InferenceProfile {
        ProcessInfo.processInfo.physicalMemory >= 16.gibibytes ? .gemma4E4B : .gemma4E2B
    }
}
