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
        let profiles = ModelProfile.v0Catalog

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
        #expect(ModelProfile.gemma4E4B.defaults.maxTokens == 512)
        #expect(ModelProfile.gemma4E4B.defaults.prefillStepSize == 64)
    }

    @Test
    func studyCatalogContainsOnlyReliableStructuredOutputProfiles() {
        let profiles = ModelProfile.studyCatalog

        #expect(profiles.map(\.id) == ["gemma4E2B", "gemma4E4B", "qwen3VL4B"])
        #expect(ModelProfile.qwen3VL4B.defaults.maxKVSize == 2_048)
        #expect(ModelProfile.qwen3VL4B.defaults.maxTokens == 512)
        #expect(ModelProfile.qwen3VL4B.defaults.prefillStepSize == 64)
    }

    @Test
    func legacyInferenceAliasesRemainSourceCompatible() {
        #expect(InferenceProfile.gemma4E2B.id == ModelProfile.gemma4E2B.id)
        #expect(InferenceProfileCatalog.studyCatalog.map(\.id) == ModelCatalog.studyCatalog.map(\.id))
        #expect(GenerationDefaults.vision == ModelRuntimeDefaults.vision)
    }

    @Test
    func e4BPromptBudgetLeavesRuntimeHeadroom() {
        let budget = PromptPacker.promptBudget(for: .gemma4E4B, resourceKind: .summary)

        #expect(budget <= ModelProfile.gemma4E4B.defaults.maxKVSize / 3)
        #expect(budget >= 256)
    }

    @Test
    func runtimePolicyMatchesCurrentModelConstants() {
        let e2B = ModelRuntimePolicyProvider.policy(for: .gemma4E2B, systemMemoryBytes: 16.gibibytes)
        let e4B = ModelRuntimePolicyProvider.policy(for: .gemma4E4B, systemMemoryBytes: 16.gibibytes)
        let qwen = ModelRuntimePolicyProvider.policy(for: .qwen3VL4B, systemMemoryBytes: 16.gibibytes)

        #expect(e2B.generationDefaults == ModelProfile.gemma4E2B.defaults)
        #expect(e4B.generationDefaults == ModelProfile.gemma4E4B.defaults)
        #expect(qwen.generationDefaults == ModelProfile.qwen3VL4B.defaults)

        #expect(e2B.cacheLimitBytes == 128 * 1024 * 1024)
        #expect(e4B.cacheLimitBytes == 64 * 1024 * 1024)
        #expect(qwen.cacheLimitBytes == 64 * 1024 * 1024)
        #expect([e2B.documentImageLimit, e4B.documentImageLimit, qwen.documentImageLimit] == [2, 4, 4])
    }

    @Test
    func promptBudgetsMatchCurrentRuntimePolicy() {
        let e2B = ModelRuntimePolicyProvider.policy(for: .gemma4E2B, systemMemoryBytes: 16.gibibytes)
        let e4B = ModelRuntimePolicyProvider.policy(for: .gemma4E4B, systemMemoryBytes: 16.gibibytes)

        #expect(PromptPacker.promptBudget(for: e2B, resourceKind: .summary) == 2_048)
        #expect(PromptPacker.promptBudget(for: e2B, resourceKind: .quiz) == 2_048)
        #expect(PromptPacker.promptBudget(for: e4B, resourceKind: .summary) == 682)
        #expect(PromptPacker.promptBudget(for: e4B, resourceKind: .quiz) == 682)
    }
}
