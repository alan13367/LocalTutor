//
//  InferenceProfileCatalog.swift
//  LocalTutor
//

import Foundation
import MLXVLM

enum ModelCatalog {
    static let gemma4E2B = ModelProfile(
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

    static let gemma4E4B = ModelProfile(
        id: "gemma4E4B",
        name: "Gemma 4 E4B",
        subtitle: "16GB tier, stronger multimodal reasoning",
        modelIdentifier: "mlx-community/gemma-4-e4b-it-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: ModelRuntimeDefaults.vision
            .withDocumentImageLimit(4)
            .withMaxTokens(512)
            .withMaxKVSize(2_048)
            .withPrefillStepSize(64),
        configuration: .vlm(VLMRegistry.gemma4_E4B_it_4bit),
        publisher: "Google",
        summary: "Balanced multimodal model. Best baseline quality for 16 GB Macs across study tasks.",
        parameterScale: "≈ 4B params · 4-bit MLX",
        strengths: ["Vision", "Stronger reasoning", "Long context"],
        isRecommended: true
    )

    static let qwen3VL4B = ModelProfile(
        id: "qwen3VL4B",
        name: "Qwen3-VL 4B",
        subtitle: "Alibaba multimodal, sharp at diagrams and text",
        modelIdentifier: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        kind: .vision,
        tier: .sixteenGB,
        minimumSystemMemoryBytes: 16.gibibytes,
        defaults: ModelRuntimeDefaults.vision
            .withDocumentImageLimit(4)
            .withMaxTokens(512)
            .withMaxKVSize(2_048)
            .withPrefillStepSize(64),
        configuration: .vlm(VLMRegistry.qwen3VL4BInstruct4Bit),
        publisher: "Alibaba",
        summary: "Top-tier small vision model. Excellent OCR and document understanding for screenshots and slides.",
        parameterScale: "≈ 4B params · 4-bit MLX",
        strengths: ["Best-in-class OCR", "Diagrams", "Long answers"]
    )

    /// The original v0 catalog. Retained so existing tests keep passing.
    static let v0Catalog: [ModelProfile] = [
        gemma4E2B,
        gemma4E4B
    ]

    /// Full curated catalog shown in Settings. All entries are vision-capable, MLX-format,
    /// and gated by minimum unified-memory tier.
    static let studyCatalog: [ModelProfile] = [
        gemma4E2B,
        gemma4E4B,
        qwen3VL4B
    ]

    static func profile(withID id: String) -> ModelProfile? {
        studyCatalog.first { $0.id == id }
    }

    static var recommendedDefault: ModelProfile {
        ProcessInfo.processInfo.physicalMemory >= 16.gibibytes ? gemma4E4B : gemma4E2B
    }
}

typealias InferenceProfileCatalog = ModelCatalog
