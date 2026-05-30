//
//  InferenceProfileTests.swift
//  LocalTutorTests
//
//

import Testing
@testable import LocalTutor

struct InferenceProfileTests {
    @Test
    func v0CatalogContainsGemma4BaseProfiles() {
        let profiles = InferenceProfile.v0Catalog

        #expect(profiles.map(\.id) == ["gemma4E2B", "gemma4E4B"])
        #expect(profiles.allSatisfy { $0.kind == .vision })
        #expect(profiles.map(\.modelIdentifier) == [
            "mlx-community/gemma-4-e2b-it-4bit",
            "mlx-community/gemma-4-e4b-it-4bit"
        ])
        #expect(profiles.map(\.minimumSystemMemoryBytes) == [
            8.gibibytes,
            16.gibibytes
        ])
        #expect(profiles.map(\.defaults.documentImageLimit) == [2, 4])
        #expect(profiles.map(\.defaults.maxKVSize) == [6_144, 2_048])
        #expect(InferenceProfile.gemma4E4B.defaults.maxTokens == 512)
        #expect(InferenceProfile.gemma4E4B.defaults.prefillStepSize == 64)
    }

    @Test
    func studyCatalogContainsOnlyReliableStructuredOutputProfiles() {
        let profiles = InferenceProfile.studyCatalog

        #expect(profiles.map(\.id) == ["gemma4E2B", "gemma4E4B", "qwen3VL4B"])
        #expect(InferenceProfile.qwen3VL4B.defaults.maxKVSize == 2_048)
        #expect(InferenceProfile.qwen3VL4B.defaults.maxTokens == 512)
        #expect(InferenceProfile.qwen3VL4B.defaults.prefillStepSize == 64)
    }

    @Test
    func e4BPromptBudgetLeavesRuntimeHeadroom() {
        let budget = PromptPacker.promptBudget(for: .gemma4E4B, resourceKind: .summary)

        #expect(budget <= InferenceProfile.gemma4E4B.defaults.maxKVSize / 3)
        #expect(budget >= 256)
    }
}
