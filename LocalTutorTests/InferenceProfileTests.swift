//
//  InferenceProfileTests.swift
//  LocalTutorTests
//
//

import Foundation
import Testing
@testable import LocalTutor

struct InferenceProfileTests {
    @Test
    func catalogLoadsFromBundledJSONInTierOrder() {
        let ids = ModelProfile.studyCatalog.map(\.id)

        #expect(ids == ["gemma4E2B", "qwen35_4B", "gemma4E4B", "qwen35_9B", "qwythos9B", "lfm25A1B8B", "gemma4_12B", "gemma4_26B_A4B", "flint40B_A2B"])
        #expect(ModelProfile.studyCatalog.map(\.tier) == ModelProfile.studyCatalog.map(\.tier).sorted())
        #expect(ModelProfile.studyCatalog.allSatisfy { $0.downloadBytes > 0 && $0.kvBytesPerToken > 0 })
    }

    @Test
    func catalogUsesStandardQuantizationsOnly() {
        let vettedThirdPartyRepositories: Set<String> = ["ahmedandaloes/Qwythos-9B-v2-MLX-4bit"]
        for profile in ModelProfile.studyCatalog {
            #expect(!profile.modelIdentifier.localizedCaseInsensitiveContains("optiq"))
            #expect(profile.modelIdentifier.hasPrefix("mlx-community/") || vettedThirdPartyRepositories.contains(profile.modelIdentifier))
        }
    }

    @Test
    func visionProfilesLoadThroughVLMFactoryAndTextThroughLLM() {
        for profile in ModelProfile.studyCatalog {
            switch profile.configuration {
            case .vlm:
                #expect(profile.kind == .vision)
            case .llm:
                #expect(profile.kind == .text)
            case .embedder:
                Issue.record("\(profile.id) should not be an embedder")
            }
        }
    }

    @Test
    func visionProfilesKeepVisionInRuntimePolicy() {
        let policy = ModelRuntimePolicyProvider.policy(for: .gemma4E4B, systemMemoryBytes: 16.gibibytes)

        #expect(policy.supportsVision)
        #expect(policy.documentImageLimit == 4)
        #expect(policy.extractionOptions.imageLimit == 4)
    }

    @Test
    func lfmProfileIsTextOnlyLLM() {
        let lfm = ModelProfile.lfm25A1B8B
        let policy = ModelRuntimePolicyProvider.policy(for: lfm, systemMemoryBytes: 16.gibibytes)

        #expect(lfm.kind == .text)
        #expect(lfm.supportsVision == false)
        #expect(lfm.modelIdentifier == "mlx-community/LFM2.5-8B-A1B-MLX-4bit")
        #expect(policy.documentImageLimit == 0)
        #expect(policy.generationDefaults.imageResize == nil)
        if case .llm(let configuration) = lfm.configuration {
            #expect(configuration.toolCallFormat == .lfm2)
        } else {
            Issue.record("LFM should load through the LLM factory.")
        }
    }

    @Test
    func qwenProfilesDisableThinkingForFastAnswers() {
        #expect(ModelCatalog.disablesThinking(.qwen35_4B))
        #expect(ModelCatalog.disablesThinking(.qwen35_9B))
        #expect(!ModelCatalog.disablesThinking(.gemma4E4B))
        #expect(LocalModelRunner.chatTemplateContext(for: .qwen35_9B)?["enable_thinking"] as? Bool == false)
        #expect(LocalModelRunner.chatTemplateContext(for: .gemma4E2B) == nil)
    }

    @Test
    func recommendedDefaultScalesWithMemory() {
        #expect(ModelCatalog.recommended(forSystemMemory: 8.gibibytes).id == "gemma4E2B")
        #expect(ModelCatalog.recommended(forSystemMemory: 16.gibibytes).id == "gemma4E4B")
        #expect(ModelCatalog.recommended(forSystemMemory: 24.gibibytes).id == "gemma4_12B")
        #expect(ModelCatalog.recommended(forSystemMemory: 64.gibibytes).id == "gemma4_26B_A4B")
    }

    @Test
    func contextWindowGrowsWithMemoryUpToTheModelLimit() {
        let architecture = ModelArchitecture(nativeContextTokens: 131_072, kvBytesPerToken: 16_384, fixedCacheBytes: 0)
        func context(_ memory: UInt64) -> Int {
            ModelRuntimePolicyProvider.policy(
                for: .gemma4E4B,
                systemMemoryBytes: memory,
                preference: .extended,
                architecture: architecture
            ).contextTokens
        }

        #expect(context(8.gibibytes) == ContextBudget.minimumContextTokens)
        #expect(context(12.gibibytes) > context(8.gibibytes))
        #expect(context(12.gibibytes) < context(16.gibibytes))
        #expect(context(16.gibibytes) == 131_072)
        #expect(context(128.gibibytes) == 131_072)
        #expect(context(36.gibibytes) % 1_024 == 0)
    }

    @Test
    func balancedContextFollowsMeasuredPrefillSpeed() {
        let architecture = ModelArchitecture(nativeContextTokens: 131_072, kvBytesPerToken: 6_144, fixedCacheBytes: 0)
        func context(_ speed: Double?, _ preference: ContextPreference = .standard) -> Int {
            ModelRuntimePolicyProvider.policy(
                for: .gemma4E2B,
                systemMemoryBytes: 36.gibibytes,
                preference: preference,
                architecture: architecture,
                prefillTokensPerSecond: speed
            ).contextTokens
        }

        #expect(context(1_000) == 24_576)
        #expect(context(4_000) == 99_328)
        #expect(context(1_000) < context(4_000))
        #expect(context(1_000, .extended) == 131_072)
    }

    @Test
    func flintUsesItsRecommendedSamplingAndAnUnquantizedCache() {
        let flint = ModelCatalog.require("flint40B_A2B")
        #expect(flint.tier == .thirtyTwoGB)
        #expect(!flint.supportsVision)
        #expect(!flint.supportsSpeculativeDecoding)
        #expect(!flint.isRecommended)
        #expect(flint.defaults.kvBits == nil)
        #expect(flint.defaults.maxTokens == 8_192)

        let parameters = flint.defaults.generateParameters()
        #expect(parameters.temperature == 1.0)
        #expect(parameters.topP == 0.95)
        #expect(parameters.topK == 20)
        #expect(parameters.kvBits == nil)
        #expect(ModelProfile.gemma4E2B.defaults.generateParameters().topK == 0)
    }

    @Test
    func multiTokenPredictionIsOffByDefaultOnlyForTheMixtureOfExperts() {
        let moe = ModelCatalog.require("gemma4_26B_A4B")
        #expect(moe.supportsSpeculativeDecoding)
        #expect(!moe.speculativeDecodingByDefault)
        #expect(moe.totalDownloadBytes == moe.downloadBytes)
        let dense = ModelProfile.studyCatalog.filter { $0.supportsSpeculativeDecoding && $0.id != moe.id }
        #expect(!dense.isEmpty)
        #expect(dense.filter { !$0.speculativeDecodingByDefault }.isEmpty)
    }

    @Test
    func speculativeDecodingChoiceIsPerModelAndRespectsTheOldGlobalOptOut() {
        let moe = ModelCatalog.require("gemma4_26B_A4B")
        let dense = ModelProfile.gemma4E2B
        func resolve(_ profile: ModelProfile, _ choices: [String: Bool], _ legacy: Bool?) -> Bool {
            SpeculativeDecodingPreference.isEnabled(for: profile, choices: choices, legacyChoice: legacy)
        }

        #expect(resolve(dense, [:], nil))
        #expect(!resolve(moe, [:], nil))
        #expect(resolve(moe, [moe.id: true], nil))
        #expect(!resolve(dense, [dense.id: false], nil))
        #expect(!resolve(dense, [:], false))
        #expect(resolve(dense, [dense.id: true], false))
        #expect(!resolve(moe, [:], true))
        #expect(!resolve(ModelProfile.qwen35_4B, [ModelProfile.qwen35_4B.id: true], nil))
    }

    @Test
    func turningOffTheDrafterLeavesMoreRoomForContext() {
        let moe = ModelCatalog.require("gemma4_26B_A4B")
        let architecture = ModelArchitecture.catalogEstimate(for: moe)
        let workingSet = ContextBudget.workingSetBytes(forSystemMemory: 36.gibibytes)
        let withDrafter = ContextBudget.memoryFit(for: moe, architecture: architecture, workingSetBytes: workingSet, speculative: true)
        let without = ContextBudget.memoryFit(for: moe, architecture: architecture, workingSetBytes: workingSet, speculative: false)
        #expect(without > withDrafter)
        #expect(ContextBudget.memoryFit(for: moe, architecture: architecture, workingSetBytes: workingSet) == without)
    }

    @Test
    func contextWindowNeverExceedsModelLimitOrMemoryFit() {
        let architecture = ModelArchitecture.catalogEstimate(for: .gemma4E2B)
        let policy = ModelRuntimePolicyProvider.policy(for: .gemma4E2B, systemMemoryBytes: 128.gibibytes, preference: .extended, architecture: architecture)
        #expect(policy.contextTokens == architecture.nativeContextTokens)

        let e4b = ModelArchitecture.catalogEstimate(for: .gemma4E4B)
        let fit = ContextBudget.memoryFit(for: .gemma4E4B, architecture: e4b, workingSetBytes: ContextBudget.workingSetBytes(forSystemMemory: 8.gibibytes))
        let tight = ContextBudget.contextTokens(for: .gemma4E4B, systemMemoryBytes: 8.gibibytes, preference: .extended, architecture: e4b)
        #expect(tight <= max(ContextBudget.minimumContextTokens, fit))
    }

    @Test
    func architectureReadsKVCostFromGemma4Config() throws {
        let config: [String: Any] = ["text_config": [
            "num_hidden_layers": 35,
            "num_key_value_heads": 1,
            "num_attention_heads": 8,
            "head_dim": 256,
            "global_head_dim": 512,
            "sliding_window": 512,
            "num_kv_shared_layers": 20,
            "max_position_embeddings": 131_072,
            "layer_types": (0..<35).map { ($0 + 1) % 5 == 0 ? "full_attention" : "sliding_attention" }
        ]]
        let data = try JSONSerialization.data(withJSONObject: config)
        let architecture = try #require(ModelArchitecture.parse(configData: data))

        #expect(architecture.nativeContextTokens == 131_072)
        #expect(architecture.kvBytesPerToken == 3 * 2 * 512 * 2)
        #expect(architecture.fixedCacheBytes == 12 * 512 * 2 * 256 * 2)
    }

    @Test
    func architectureIgnoresLinearAttentionLayers() throws {
        let config = """
        {"text_config": {"num_hidden_layers": 4, "num_key_value_heads": 4, "num_attention_heads": 16, "head_dim": 256,
         "max_position_embeddings": 262144,
         "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"]}}
        """
        let architecture = try #require(ModelArchitecture.parse(configData: Data(config.utf8)))

        #expect(architecture.kvBytesPerToken == 2 * 4 * 256 * 2)
        #expect(architecture.fixedCacheBytes == 0)
    }

    @Test
    func prefillSpeedIsSmoothedAndIgnoresTinyPrompts() throws {
        let defaults = try #require(UserDefaults(suiteName: "PrefillSpeedStoreTests-\(UUID().uuidString)"))
        PrefillSpeedStore.record(promptTokens: 200, seconds: 1, for: "m", defaults: defaults)
        #expect(PrefillSpeedStore.tokensPerSecond(for: "m", defaults: defaults) == nil)

        PrefillSpeedStore.record(promptTokens: 4_000, seconds: 2, for: "m", defaults: defaults)
        #expect(PrefillSpeedStore.tokensPerSecond(for: "m", defaults: defaults) == 2_000)

        PrefillSpeedStore.record(promptTokens: 4_000, seconds: 1, for: "m", defaults: defaults)
        #expect(PrefillSpeedStore.tokensPerSecond(for: "m", defaults: defaults) == 2_600)
    }

    @Test
    func sourceBudgetIsMuchLargerThanTheOldFixedWindow() {
        var policy = ModelRuntimePolicyProvider.policy(for: .gemma4E4B, systemMemoryBytes: 16.gibibytes, preference: .extended)
        policy.contextTokens = 16_384

        #expect(policy.sourceTokenBudget(for: .ask) == 16_384 - 2_048 - 1_200 - 3_276 - 4 * 640)
        #expect(policy.sourceTokenBudget(for: .summary) > policy.sourceTokenBudget(for: .ask))
        #expect(PromptPacker.promptBudget(for: policy, resourceKind: .summary) > 682 * 10)
    }

    @Test
    func generationParametersUseQuantizedUnboundedCache() {
        let parameters = ModelRuntimeDefaults.vision.generateParameters()

        #expect(parameters.maxKVSize == nil)
        #expect(parameters.kvBits == 8)
        #expect(parameters.maxTokens == ModelRuntimeDefaults.vision.maxTokens)
        #expect(parameters.prefill.stepSize == ModelRuntimeDefaults.vision.prefillStepSize)
    }

    @Test
    func generationParameterOverridesAreHonored() {
        let parameters = ModelRuntimeDefaults.text.generateParameters(
            maxTokensOverride: 128,
            temperatureOverride: 0.05
        )

        #expect(parameters.maxTokens == 128)
        #expect(parameters.temperature == 0.05)
    }

    @Test
    func legacyInferenceAliasesRemainSourceCompatible() {
        #expect(InferenceProfile.gemma4E2B.id == ModelProfile.gemma4E2B.id)
        #expect(InferenceProfileCatalog.studyCatalog.map(\.id) == ModelCatalog.studyCatalog.map(\.id))
        #expect(GenerationDefaults.vision == ModelRuntimeDefaults.vision)
    }

    @Test
    func smallAndLargeGemmaModelsShipMultiTokenPredictionDrafters() {
        let withDrafter = ModelProfile.studyCatalog.filter(\.supportsSpeculativeDecoding).map(\.id)

        #expect(withDrafter == ["gemma4E2B", "gemma4E4B", "gemma4_12B", "gemma4_26B_A4B"])
        #expect(!ModelProfile.qwen35_4B.supportsSpeculativeDecoding)
        #expect(!ModelProfile.lfm25A1B8B.supportsSpeculativeDecoding)

        let drafter = ModelProfile.gemma4E2B.drafterProfile
        #expect(drafter?.kind == .drafter)
        #expect(drafter?.modelIdentifier == "mlx-community/gemma-4-E2B-it-assistant-bf16")
        #expect(ModelProfile.gemma4E2B.totalDownloadBytes == ModelProfile.gemma4E2B.downloadBytes + 190_000_000)
        for profile in ModelProfile.studyCatalog {
            #expect(!(profile.drafterRepository ?? "").localizedCaseInsensitiveContains("optiq"))
        }
    }

    @Test
    func drafterDirectoriesDoNotNeedTokenizerFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drafter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gemma4_assistant"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("model.safetensors"))
        let drafter = try #require(ModelProfile.gemma4E4B.drafterProfile)

        #expect(ManagedModelStore.isUsableModelDirectory(directory, for: drafter))
        #expect(!ManagedModelStore.isUsableModelDirectory(directory, for: .lfm25A1B8B))
    }

    @Test
    func pausedDownloadsDescribeTheirProgress() {
        #expect(ModelManager.pausedMessage(fraction: 0.42) == "Paused at 42%")
        #expect(ModelManager.pausedMessage(fraction: nil) == "Download paused")
        #expect(PendingModelDownload(profileID: "x", writtenBytes: 50, totalBytes: 200).fraction == 0.25)
        #expect(ModelDownloadPhase.downloading.isTransferring)
        #expect(!ModelDownloadPhase.paused.isTransferring)
    }
}
