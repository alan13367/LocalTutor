//
//  InferenceProfile.swift
//  LocalTutor
//
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
        maxTokens: 1024,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 6144,
        kvBits: 4,
        imageResize: nil
    )

    static let vision = GenerationDefaults(
        maxTokens: 1024,
        temperature: 0.2,
        topP: 0.9,
        prefillStepSize: 256,
        maxKVSize: 6144,
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
    static let gemma4E2B = InferenceProfile(
        id: "gemma4E2B",
        name: "Gemma 4 E2B",
        subtitle: "8GB baseline, text and vision capable",
        modelIdentifier: "mlx-community/gemma-4-e2b-it-4bit",
        kind: .vision,
        tier: .eightGB,
        minimumSystemMemoryBytes: 8.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.gemma4_E2B_it_4bit),
        publisher: "Google",
        summary: "Compact multimodal tutor. The fastest Gemma 4 build, tuned for Macs with 8 GB unified memory.",
        parameterScale: "≈ 2B params · 4-bit MLX",
        strengths: ["Vision", "Fast on 8 GB", "Multilingual"],
        isRecommended: true
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
        configuration: .vlm(VLMRegistry.gemma4_E4B_it_4bit),
        publisher: "Google",
        summary: "Balanced multimodal model. Best baseline quality for 16 GB Macs across study tasks.",
        parameterScale: "≈ 4B params · 4-bit MLX",
        strengths: ["Vision", "Stronger reasoning", "Long context"],
        isRecommended: true
    )

    static let qwen3VL4B = InferenceProfile(
        id: "qwen3VL4B",
        name: "Qwen3-VL 4B",
        subtitle: "Alibaba multimodal, sharp at diagrams and text",
        modelIdentifier: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.qwen3VL4BInstruct4Bit),
        publisher: "Alibaba",
        summary: "Top-tier small vision model. Excellent OCR and document understanding for screenshots and slides.",
        parameterScale: "≈ 4B params · 4-bit MLX",
        strengths: ["Best-in-class OCR", "Diagrams", "Long answers"]
    )

    static let qwen25VL3B = InferenceProfile(
        id: "qwen25VL3B",
        name: "Qwen2.5-VL 3B",
        subtitle: "Lighter Qwen multimodal — fits 8 GB Macs",
        modelIdentifier: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        kind: .vision,
        tier: .eightGB,
        minimumSystemMemoryBytes: 8.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.qwen2_5VL3BInstruct4Bit),
        publisher: "Alibaba",
        summary: "Compact vision model with strong reading-comprehension on screenshots and notes.",
        parameterScale: "≈ 3B params · 4-bit MLX",
        strengths: ["Strong OCR", "Fast", "Good at notes"]
    )

    static let gemma3VL4B = InferenceProfile(
        id: "gemma3VL4B",
        name: "Gemma 3 4B (Vision)",
        subtitle: "QAT-tuned Gemma 3 multimodal",
        modelIdentifier: "mlx-community/gemma-3-4b-it-qat-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.gemma3_4B_qat_4bit),
        publisher: "Google",
        summary: "Quantization-aware Gemma 3 with solid vision performance — a reliable alternative to Gemma 4.",
        parameterScale: "≈ 4B params · QAT 4-bit MLX",
        strengths: ["Vision", "Reliable", "Multilingual"]
    )

    static let smolVLM = InferenceProfile(
        id: "smolVLM",
        name: "SmolVLM 2.2B",
        subtitle: "Featherweight vision model",
        modelIdentifier: "mlx-community/SmolVLM-Instruct-4bit",
        kind: .vision,
        tier: .eightGB,
        minimumSystemMemoryBytes: 8.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.smolvlminstruct4bit),
        publisher: "Hugging Face",
        summary: "Tiny multimodal model that loads instantly. Great for quick screenshots and short answers.",
        parameterScale: "≈ 2.2B params · 4-bit MLX",
        strengths: ["Tiny", "Instant load", "Snappy"]
    )

    static let mistralSmall3 = InferenceProfile(
        id: "mistralSmall3",
        name: "Ministral 3 (Vision)",
        subtitle: "Mistral's compact multimodal model",
        modelIdentifier: "mlx-community/Mistral-Small-3.1-3B-Instruct-2503-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: .vision,
        configuration: .vlm(VLMRegistry.mistral3_3B_Instruct_4bit),
        publisher: "Mistral AI",
        summary: "Polished writing voice with multimodal input. Strong at structured study summaries and outlines.",
        parameterScale: "≈ 3B params · 4-bit MLX",
        strengths: ["Crisp writing", "Vision", "Outlines"]
    )

    /// The original v0 catalog. Retained so existing tests keep passing.
    static let v0Catalog: [InferenceProfile] = [
        .gemma4E2B,
        .gemma4E4B
    ]

    /// Full curated catalog shown in Settings. All entries are vision-capable, MLX-format,
    /// and gated by minimum unified-memory tier.
    static let studyCatalog: [InferenceProfile] = [
        .gemma4E2B,
        .qwen25VL3B,
        .smolVLM,
        .gemma4E4B,
        .qwen3VL4B,
        .gemma3VL4B,
        .mistralSmall3
    ]

    static func profile(withID id: String) -> InferenceProfile? {
        studyCatalog.first { $0.id == id }
    }

    static var recommendedDefault: InferenceProfile {
        ProcessInfo.processInfo.physicalMemory >= 16.gibibytes ? .gemma4E4B : .gemma4E2B
    }
}
