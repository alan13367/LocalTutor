//
//  LocalModelRunnerTests.swift
//  LocalTutorTests
//
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MLXVLM
import Testing
import UniformTypeIdentifiers
@testable import LocalTutor

struct LocalModelRunnerTests {
    @MainActor
    @Test
    func textOnlyImportRejectsImagesButKeepsDocuments() throws {
        let notebook = Notebook(title: "Imports")
        let store = NotebookStore(persistence: nil, initial: [notebook])
        let models = ModelManager(inferenceService: NoopInferenceService(), cacheInfoProvider: { _ in [:] })
        let library = SourceLibrary(store: store, models: models)
        var reported: String?
        library.onError = { reported = $0 }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTutorImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notesURL = directory.appendingPathComponent("notes.md")
        let imageURL = directory.appendingPathComponent("figure.png")
        try "Readable notes".write(to: notesURL, atomically: true, encoding: .utf8)
        try Data().write(to: imageURL)

        library.importURLs([notesURL, imageURL], into: notebook.id, supportsVision: false)

        #expect(store.notebook(notebook.id)?.sources.map(\.displayName) == ["notes.md"])
        #expect(reported?.contains("vision model") == true)
        #expect(StudySource.supportedContentTypes(supportsVision: false).contains(.image) == false)
        #expect(StudySource.supportedContentTypes(supportsVision: true).contains(.image))
    }

    @MainActor
    @Test
    func importingIntoUntitledNotebookNamesItAfterTheFirstFile() throws {
        let notebook = Notebook()
        let store = NotebookStore(persistence: nil, initial: [notebook])
        let library = SourceLibrary(
            store: store,
            models: ModelManager(inferenceService: NoopInferenceService(), cacheInfoProvider: { _ in [:] })
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell_biology-week3.md")
        try "Cells".write(to: url, atomically: true, encoding: .utf8)

        library.importURLs([url], into: notebook.id, supportsVision: true)

        #expect(store.notebook(notebook.id)?.title == "cell biology week3")
    }

    @MainActor
    @Test
    func removingSelectedDownloadedModelClearsSelectionAndDisablesSend() async {
        let previousProfileID = UserDefaults.standard.string(forKey: AppStorageKeys.selectedProfileID)
        defer {
            if let previousProfileID {
                UserDefaults.standard.set(previousProfileID, forKey: AppStorageKeys.selectedProfileID)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.selectedProfileID)
            }
        }

        UserDefaults.standard.removeObject(forKey: AppStorageKeys.selectedProfileID)
        let notebook = Notebook(title: "Chat")
        let store = NotebookStore(persistence: nil, initial: [notebook])
        let models = ModelManager(
            inferenceService: NoopInferenceService(),
            cacheInfoProvider: { profiles in
                Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, ModelCacheInfo.empty) })
            },
            cachedModelRemover: { _ in
                ModelCacheRemovalResult(removedByteCount: 0)
            }
        )
        let chat = ChatController(store: store, models: models)
        models.select(.gemma4E2B, preload: false)
        chat.composerText = "Summarize this"

        #expect(models.selectedProfile?.id == ModelProfile.gemma4E2B.id)
        #expect(chat.canSend(in: notebook))

        models.remove(.gemma4E2B)

        #expect(models.selectedProfile == nil)
        #expect(chat.canSend(in: notebook) == false)
    }

    @Test
    func generationGateQueuesInsteadOfRejecting() async {
        let gate = GenerationGate()
        await gate.acquire()
        #expect(await gate.isOccupied)

        let second = Task {
            await gate.acquire()
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.queuedCount == 1)

        await gate.release()
        #expect(await second.value)
        #expect(await gate.isOccupied)
        await gate.release()
        #expect(await gate.isOccupied == false)
    }

    @Test
    func structuredProgressCountsItemsAsTheyStream() {
        #expect(StudioController.structuredProgress(kind: .quiz, raw: "{\"title\":\"Q\"") == "Composing quiz")
        #expect(StudioController.structuredProgress(kind: .quiz, raw: #"{"questions":[{"prompt":"a"},{"prompt":"b"#) == "Writing question 2")
        #expect(StudioController.structuredProgress(kind: .flashcards, raw: #"{"cards":[{"front":"x"#) == "Writing card 1")
    }

    @Test
    func performanceSummaryReportsReusedTokens() {
        let record = BenchmarkRecord(
            schemaVersion: BenchmarkRecord.schemaVersion,
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            appVersion: "test",
            device: .current,
            profileID: "p",
            profileName: "P",
            modelID: "m",
            kind: "text",
            tier: "eightGB",
            prompt: "",
            imageFilename: nil,
            imageFilenames: [],
            includedImageCount: 0,
            omittedImageCount: 0,
            timing: BenchmarkTiming(downloadSeconds: 0, loadSeconds: 0, firstTokenSeconds: 0.42, wallSeconds: 2),
            tokenMetrics: BenchmarkTokenMetrics(
                promptTokens: 20,
                generatedTokens: 100,
                promptTimeSeconds: 0.1,
                generationTimeSeconds: 2,
                tokensPerSecond: 51.2,
                stopReason: "stop",
                cachedPromptTokens: 9_000
            ),
            mlxMemoryBefore: nil,
            mlxMemoryAfter: nil,
            processPeakPhysicalFootprintBytes: nil,
            status: .success,
            errorMessage: nil,
            output: "Hi"
        )

        let summary = ChatController.performanceSummary(record)
        #expect(summary.contains("51 tok/s"))
        #expect(summary.contains("first token 0.4s"))
        #expect(summary.contains("tokens reused"))
    }

    @Test
    func chatHistoryTrimsOldestTurnsToFitTheWindow() {
        let long = String(repeating: "word ", count: 400)
        let history = (0..<6).map { ChatHistoryMessage(question: "Q\($0) " + long, answer: "A\($0) " + long) }

        let kept = LocalModelRunner.trimmedHistory(history, instructions: "rules", incomingTokens: 50, limit: 1_500)

        #expect(!kept.isEmpty)
        #expect(kept.count < history.count)
        #expect(kept.last == history.last)
    }

    @Test
    func downloadProgressTrackerSuppressesAlreadyCachedCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 100

        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerSuppressesCachedZeroThenCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)

        progress.completedUnitCount = 0
        #expect(tracker.update(progress) == nil)

        progress.completedUnitCount = 100
        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerReportsRealWorkBeforeCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 20

        let update = tracker.update(progress)

        #expect(update?.fraction == 0.2)
        #expect(update?.message == "Downloading 20%")
    }

    @Test
    func downloadProgressTrackerReportsVisibleSubPercentProgress() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 4_450_000_000)
        progress.completedUnitCount = 17_100_000

        let update = tracker.update(progress)

        #expect(DownloadProgressUpdate.percentText(for: 0.00384) == "0.4%")
        #expect(DownloadProgressUpdate.percentText(for: 0.0004) == "<0.1%")
        #expect(update?.message.hasPrefix("Downloading 0.4%") == true)
        #expect(update?.message.contains(" of ") == true)
    }

    @MainActor
    @Test
    func preloadingAppliesEachModelsMultiTokenPredictionChoiceFirst() async throws {
        let moe = ModelCatalog.require("gemma4_26B_A4B")
        let dense = ModelProfile.gemma4E2B
        guard MemoryPreflight.evaluate(profile: moe).canRun else { return }
        let service = RecordingInferenceService()
        let models = ModelManager(inferenceService: service, cacheInfoProvider: { _ in [:] }, downloadService: nil)

        try await models.ensureLoaded(moe)
        try await models.ensureLoaded(dense)

        var expected = ["mtp \(models.usesSpeculativeDecoding(moe))", "preload \(moe.id)"]
        if models.usesSpeculativeDecoding(dense) != models.usesSpeculativeDecoding(moe) {
            expected.append("mtp \(models.usesSpeculativeDecoding(dense))")
        }
        expected.append("preload \(dense.id)")
        #expect(await service.events == expected)
    }

    @Test
    func wiredMemoryCoversWeightsAndTheKVCache() {
        let profile = ModelCatalog.require("gemma4_26B_A4B")
        let policy = ModelRuntimePolicyProvider.policy(for: profile, systemMemoryBytes: 36.gibibytes, preference: .extended, speculative: false)
        let plain = LocalModelRunner.wiredBytes(profile: profile, runtimePolicy: policy, speculative: false)
        let speculative = LocalModelRunner.wiredBytes(profile: profile, runtimePolicy: policy, speculative: true)

        #expect(plain > Int(profile.downloadBytes))
        #expect(speculative > plain + Int(profile.drafterBytes))
    }

    @Test
    func chatTemplateNulEscapeBecomesARealNulCharacter() throws {
        let template = #"{{- t | replace("\x00", "") | replace("<think>", "") -}}"#
        let patched = ChatTemplateCompatibility.patchedTemplate(template)
        #expect(patched == "{{- t | replace(\"\u{0}\", \"\") | replace(\"<think>\", \"\") -}}")
        #expect(ChatTemplateCompatibility.patchedTemplate(patched) == patched)

        let config = try JSONSerialization.data(withJSONObject: ["chat_template": template])
        let json = ChatTemplateCompatibility.patchedTokenizerConfig(String(decoding: config, as: UTF8.self))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(decoded?["chat_template"] == patched)
    }

    @Test
    func flintIncrementalDecodingMatchesAFullPass() async throws {
        let config = """
        {"model_type": "flint", "hidden_size": 64, "num_hidden_layers": 4, "intermediate_size": 96,
         "num_attention_heads": 4, "num_key_value_heads": 2, "head_dim": 16, "num_experts": 8,
         "num_experts_per_tok": 2, "moe_intermediate_size": 32, "shared_expert_intermediate_size": 48,
         "mlp_only_layers": [0], "sliding_window": 3, "rms_norm_eps": 1e-6, "vocab_size": 101,
         "layer_types": ["full_attention", "sliding_attention", "sliding_attention", "full_attention"],
         "rope_parameters": {"rope_theta": 10000.0, "rope_type": "default"}}
        """
        await FlintRegistration.register()
        let model = try await LLMTypeRegistry.shared.createModel(configuration: Data(config.utf8), modelType: "flint")
        let flint = try #require(model as? FlintModel)
        MLXRandom.seed(7)
        let sinks = (0 ..< 4).map { ("model.layers.\($0).self_attn.softmax_offset", MLXRandom.normal([4])) }
        try flint.update(parameters: ModuleParameters.unflattened(Dictionary(uniqueKeysWithValues: sinks)), verify: .noUnusedKeys)

        let tokens = MLXArray([3, 17, 42, 8, 99, 23, 5, 61] as [Int32]).reshaped(1, -1)
        let full = flint(tokens, cache: nil)

        let cache = try flint.newCache(parameters: nil)
        #expect(cache[1] is RotatingKVCache)
        #expect(!(cache[0] is RotatingKVCache))
        let prefill = flint(tokens[0..., ..<6], cache: cache)
        var step = flint(tokens[0..., 6 ..< 7], cache: cache)
        #expect(prefill.shape == [1, 6, 101])
        #expect(allClose(prefill, full[0..., ..<6], atol: 1e-4).item(Bool.self))
        #expect(allClose(step[0..., -1], full[0..., 6], atol: 1e-4).item(Bool.self))
        step = flint(tokens[0..., 7 ..< 8], cache: cache)
        #expect(allClose(step[0..., -1], full[0..., 7], atol: 1e-4).item(Bool.self))
    }

    @Test
    func commonSuffixKeepsOnlyTheSharedTail() {
        #expect(LocalModelRunner.commonSuffix([1, 2, 7, 8, 9], [4, 5, 6, 8, 9]) == [8, 9])
        #expect(LocalModelRunner.commonSuffix([1, 2], [3, 4]) == [])
        #expect(LocalModelRunner.commonSuffix([9], [1, 2, 9]) == [9])
    }

    @Test
    func readingYourQuestionEndsTheDownloadPhase() {
        #expect(LocalModelRunnerStage.endsDownloadPhase(LocalModelRunnerStage.readingQuestion))
    }

    @Test
    func modelBundleProgressReadsAsOneDownloadThatNamesTheDrafter() {
        let bundle = ModelBundleProgress(modelBytes: 3_000_000_000, drafterBytes: 1_000_000_000)

        let model = bundle.update(DownloadProgressUpdate(fraction: 0.5, message: "Downloading 50%"), for: .model)
        #expect(model.fraction == 0.375)
        #expect(model.message.hasPrefix("Downloading model · 37%"))

        let handoff = bundle.update(DownloadProgressUpdate(fraction: 1, message: "Download complete"), for: .model)
        #expect(handoff.fraction == 0.75)
        #expect(handoff.message == "Downloading MTP drafter")

        let drafter = bundle.update(DownloadProgressUpdate(fraction: 0.5, message: "Downloading 50%"), for: .drafter)
        #expect(drafter.fraction == 0.875)
        #expect(drafter.message.hasPrefix("Downloading MTP drafter · 87%"))
        #expect(drafter.message.contains(" of "))

        let done = bundle.update(DownloadProgressUpdate(fraction: 1, message: "Download complete"), for: .drafter)
        #expect(done.fraction == 1)
        #expect(done.message == "Download complete")
    }

    @Test
    func modelBundleProgressLeavesPlainDownloadsAlone() {
        let plain = ModelBundleProgress(modelBytes: 3_000_000_000, drafterBytes: 0)
        let update = DownloadProgressUpdate(fraction: 0.4, message: "Downloading 40% · 1.2 GB of 3 GB")
        #expect(plain.update(update, for: .model) == update)

        let drafterOnly = ModelBundleProgress(modelBytes: 0, drafterBytes: 400_000_000)
        let drafter = drafterOnly.update(DownloadProgressUpdate(fraction: 0.25, message: "Downloading 25%"), for: .drafter)
        #expect(drafter.fraction == 0.25)
        #expect(drafter.message.hasPrefix("Downloading MTP drafter · 25%"))
    }

    @Test
    func downloadProgressTrackerUsesChildProgressFraction() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let parent = Progress(totalUnitCount: 1_000)
        let child = Progress(totalUnitCount: 1_000, parent: parent, pendingUnitCount: 1_000)
        child.completedUnitCount = 250

        let update = tracker.update(parent)

        #expect(update?.fraction == 0.25)
        #expect(update?.message == "Downloading 25%")
    }

    @Test
    func downloadProgressTrackerTreatsLowerFractionsAsNextFileProgress() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 1_000)

        progress.completedUnitCount = 400
        _ = tracker.update(progress)

        progress.completedUnitCount = 100
        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.46) < 0.0001)
        #expect(update?.message == "Downloading 46%")
    }

    @Test
    func downloadProgressTrackerUsesActiveTemporaryDownloadBytesWhenParentStalls() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorDownloadProgressTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let tracker = DownloadProgressTracker(temporaryDirectory: temporaryDirectory)
        let progress = Progress(totalUnitCount: 1_000_000_000)
        progress.completedUnitCount = 100_000_000
        _ = tracker.update(progress)

        let activeDownload = temporaryDirectory.appendingPathComponent("CFNetworkDownload_live.tmp")
        _ = fileManager.createFile(atPath: activeDownload.path, contents: nil)
        let handle = try FileHandle(forWritingTo: activeDownload)
        try handle.truncate(atOffset: 250_000_000)
        try handle.close()

        progress.completedUnitCount = 100_000_000
        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.35) < 0.0001)
        #expect(update?.message.hasPrefix("Downloading 35%") == true)

        let repeatedUpdate = tracker.update(progress)
        #expect(abs((repeatedUpdate?.fraction ?? 0) - 0.35) < 0.0001)

        let growHandle = try FileHandle(forWritingTo: activeDownload)
        try growHandle.truncate(atOffset: 300_000_000)
        try growHandle.close()

        Thread.sleep(forTimeInterval: 0.3)
        let grownUpdate = tracker.update(progress)
        #expect(abs((grownUpdate?.fraction ?? 0) - 0.4) < 0.0001)
        #expect(grownUpdate?.message.hasPrefix("Downloading 40%") == true)
    }

    @Test
    func downloadProgressTrackerDoesNotReportCompletionFromTemporaryBytesAlone() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorDownloadProgressTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let tracker = DownloadProgressTracker(temporaryDirectory: temporaryDirectory)
        let progress = Progress(totalUnitCount: 1_000_000_000)
        progress.completedUnitCount = 900_000_000
        _ = tracker.update(progress)

        let activeDownload = temporaryDirectory.appendingPathComponent("CFNetworkDownload_large.tmp")
        _ = fileManager.createFile(atPath: activeDownload.path, contents: nil)
        let handle = try FileHandle(forWritingTo: activeDownload)
        try handle.truncate(atOffset: 200_000_000)
        try handle.close()

        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.999) < 0.0001)
        #expect(update?.message.hasPrefix("Downloading 99%") == true)
        #expect(update?.message != "Download complete")
    }

    @Test
    func reasoningOutputFilterRemovesThinkBlocks() {
        let raw = """
        <think>
        internal reasoning
        </think>
        # Final answer
        Study this.
        """

        #expect(ReasoningOutputFilter.sanitize(raw) == "\n# Final answer\nStudy this.")
    }

    @Test
    func reasoningOutputFilterRemovesGemmaThinkingChannel() {
        let raw = "<|channel>think\nThinking Process:\n1. Plan the summary.<channel|># Study Summary\nCovers logic."

        #expect(ReasoningOutputFilter.sanitize(raw) == "# Study Summary\nCovers logic.")
    }

    @Test
    func unclosedThinkingRecoversTheAnswerAfterPlanning() {
        let reasoning = "\nThinking Process:\n1. **Plan** the summary.\n\n# Study Summary\n\n## Logic\n* Truth tables [1].\n</think]\n"

        #expect(ReasoningOutputFilter.recoveredAnswer(fromReasoning: reasoning) == "# Study Summary\n\n## Logic\n* Truth tables [1].")
        #expect(ReasoningOutputFilter.recoveredAnswer(fromReasoning: "1. Plan only, no answer yet.") == nil)
    }

    @Test
    func thinkingSystemInstructionDoesNotNameReasoningTags() {
        #expect(!StudyPromptBuilder.thinkingSystemInstruction.contains("<think>"))
        #expect(StudyPromptBuilder.systemInstruction.contains("<think>"))
        #expect(StudyPromptBuilder.thinkingSystemInstruction.hasPrefix("You are LocalTutor"))
    }

    @Test
    func reasoningOutputFilterBuffersSplitThinkTagsWhileStreaming() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<thi") == ReasoningOutputFilter.Chunk())
        #expect(filter.append("nk>hidden") == ReasoningOutputFilter.Chunk(reasoning: "hidden"))
        #expect(filter.append(" still hidden</thi") == ReasoningOutputFilter.Chunk(reasoning: " still hidden"))
        #expect(filter.append("nk>Visible") == ReasoningOutputFilter.Chunk(visible: "Visible"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterKeepsVisibleTextAroundThinkBlocks() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("Intro <think>hidden") == ReasoningOutputFilter.Chunk(visible: "Intro ", reasoning: "hidden"))
        #expect(filter.append("</think> final") == ReasoningOutputFilter.Chunk(visible: " final"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterFlushesUnclosedThinkingAsReasoning() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<think>still thinking") == ReasoningOutputFilter.Chunk(reasoning: "still thinking"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterTreatsGemmaThoughtChannelAsReasoning() {
        let raw = """
        <|channel>thought
        internal reasoning
        <|channel>final# Final answer
        Study this.
        """

        #expect(ReasoningOutputFilter.sanitize(raw) == "# Final answer\nStudy this.")
    }

    @Test
    func reasoningOutputFilterBuffersSplitGemmaThoughtChannelWhileStreaming() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<|chan") == ReasoningOutputFilter.Chunk())
        #expect(filter.append("nel>thought hidden") == ReasoningOutputFilter.Chunk(reasoning: " hidden"))
        #expect(filter.append("<|channel>fi") == ReasoningOutputFilter.Chunk())
        #expect(filter.append("nalVisible") == ReasoningOutputFilter.Chunk(visible: "Visible"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterTreatsGemmaAnalysisChannelAsReasoning() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<|channel|>analysisThinking") == ReasoningOutputFilter.Chunk(reasoning: "Thinking"))
        #expect(filter.append("<|channel|>answerVisible") == ReasoningOutputFilter.Chunk(visible: "Visible"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func managedDownloaderDoesNotClampProgressToSmallerDelegateExpectedBytes() {
        let estimate = ManagedModelDownloadService.fileProgressEstimate(
            totalBytesWritten: 3_000,
            delegateExpectedBytes: 2_000,
            expectedFileBytes: 5_000
        )

        #expect(estimate.writtenBytes == 3_000)
        #expect(estimate.expectedBytes == 5_000)

        let completedEstimate = ManagedModelDownloadService.fileProgressEstimate(
            totalBytesWritten: 7_000,
            delegateExpectedBytes: 2_000,
            expectedFileBytes: 5_000
        )

        #expect(completedEstimate.writtenBytes == 5_000)
        #expect(completedEstimate.expectedBytes == 5_000)
    }

    @Test
    func managedModelStoreRequiresEveryIndexedWeightShard() throws {
        let fileManager = FileManager.default
        let modelDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelDirectory) }

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"model_type":"lfm2"}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"tokenizer_class":"PreTrainedTokenizerFast"}"#.write(
            to: modelDirectory.appendingPathComponent("tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
            .write(
                to: modelDirectory.appendingPathComponent("model.safetensors.index.json"),
                atomically: true,
                encoding: .utf8
            )
        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .lfm25A1B8B) == false)

        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model-00002-of-00002.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .lfm25A1B8B))
    }

    @Test
    func managedModelStoreRequiresVisionMetadataForVisionProfiles() throws {
        let fileManager = FileManager.default
        let modelDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedVisionStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelDirectory) }

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"model_type":"gemma"}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{}"#.write(
            to: modelDirectory.appendingPathComponent("tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .gemma4E2B) == false)

        try #"{"model_type":"gemma","vision_config":{}}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{}"#.write(
            to: modelDirectory.appendingPathComponent("processor_config.json"),
            atomically: true,
            encoding: .utf8
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .gemma4E2B))
    }

    @Test
    func modelCacheStoreRemovesOnlySelectedModel() throws {
        let fileManager = FileManager.default
        let cacheDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorModelCacheTests-\(UUID().uuidString)", isDirectory: true)
        let managedRepositoriesDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedModelCacheTests-\(UUID().uuidString)", isDirectory: true)
        let jobsFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorModelJobs-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: cacheDirectory) }
        defer { try? fileManager.removeItem(at: managedRepositoriesDirectory) }
        defer { try? fileManager.removeItem(at: jobsFileURL) }

        let lfmLocations = try ModelCacheStore.cacheLocations(
            for: ModelProfile.lfm25A1B8B.modelIdentifier,
            cacheDirectory: cacheDirectory
        )
        let gemmaLocations = try ModelCacheStore.cacheLocations(
            for: ModelProfile.gemma4E2B.modelIdentifier,
            cacheDirectory: cacheDirectory
        )

        try writeCacheFixture(
            repository: lfmLocations.repository,
            metadata: lfmLocations.metadata,
            locks: lfmLocations.locks,
            fileManager: fileManager
        )
        try writeCacheFixture(
            repository: gemmaLocations.repository,
            metadata: gemmaLocations.metadata,
            locks: gemmaLocations.locks,
            fileManager: fileManager
        )
        let lfmManagedRepository = ManagedModelStore.repositoryDirectory(
            for: ModelProfile.lfm25A1B8B.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory
        )
        let gemmaManagedRepository = ManagedModelStore.repositoryDirectory(
            for: ModelProfile.gemma4E2B.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory
        )
        try writeManagedRepositoryFixture(lfmManagedRepository, fileManager: fileManager)
        try writeManagedRepositoryFixture(gemmaManagedRepository, fileManager: fileManager)
        try writeJobsFixture(
            jobsFileURL,
            jobs: [
                makePersistedJob(for: .lfm25A1B8B),
                makePersistedJob(for: .gemma4E2B)
            ]
        )

        let before = try ModelCacheStore.cacheInfo(
            for: .lfm25A1B8B,
            cacheDirectory: cacheDirectory,
            managedRepositoriesDirectory: managedRepositoriesDirectory
        )
        let result = try ModelCacheStore.removeCachedModel(
            for: .lfm25A1B8B,
            cacheDirectory: cacheDirectory,
            managedRepositoriesDirectory: managedRepositoriesDirectory,
            jobsFileURL: jobsFileURL
        )

        #expect(before.isCached)
        #expect(before.hasManagedFiles)
        #expect(before.byteCount > 0)
        #expect(result.removedByteCount > 0)
        #expect(fileManager.fileExists(atPath: lfmLocations.repository.path) == false)
        #expect(fileManager.fileExists(atPath: lfmLocations.metadata.path) == false)
        #expect(fileManager.fileExists(atPath: lfmLocations.locks.path) == false)
        #expect(fileManager.fileExists(atPath: lfmManagedRepository.path) == false)
        #expect(fileManager.fileExists(atPath: gemmaLocations.repository.path))
        #expect(fileManager.fileExists(atPath: gemmaLocations.metadata.path))
        #expect(fileManager.fileExists(atPath: gemmaLocations.locks.path))
        #expect(fileManager.fileExists(atPath: gemmaManagedRepository.path))

        let jobsData = try Data(contentsOf: jobsFileURL)
        let manifest = try JSONDecoder().decode(ModelDownloadJobsManifest.self, from: jobsData)
        #expect(manifest.jobs.map(\.id) == [ModelProfile.gemma4E2B.id])
    }

    private func writeCacheFixture(
        repository: URL,
        metadata: URL,
        locks: URL,
        fileManager: FileManager
    ) throws {
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: blobs.appendingPathComponent("weights.safetensors"))

        try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "{}".write(to: metadata.appendingPathComponent("snapshot.json"), atomically: true, encoding: .utf8)

        try fileManager.createDirectory(at: locks, withIntermediateDirectories: true)
        try "lock".write(to: locks.appendingPathComponent("weights.lock"), atomically: true, encoding: .utf8)
    }

    private func writeManagedRepositoryFixture(_ repository: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 32).write(to: repository.appendingPathComponent("weights.safetensors"))
    }

    private func makePersistedJob(for profile: ModelProfile) -> ModelDownloadJob {
        ModelDownloadJob(
            id: profile.id,
            displayName: profile.name,
            modelIdentifier: profile.modelIdentifier,
            revision: "main",
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            lastErrorMessage: nil,
            files: [
                ModelDownloadFileState(
                    relativePath: "weights.safetensors",
                    remoteURL: URL(string: "https://huggingface.co/\(profile.modelIdentifier)/resolve/main/weights.safetensors")!,
                    expectedBytes: 32,
                    writtenBytes: 32,
                    status: .completed,
                    lastErrorMessage: nil
                )
            ]
        )
    }

    private func writeJobsFixture(_ url: URL, jobs: [ModelDownloadJob]) throws {
        let manifest = ModelDownloadJobsManifest(jobs: jobs)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }
}

private actor RecordingInferenceService: InferenceService {
    private(set) var events: [String] = []

    func run(
        request _: InferenceRequest,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func chat(
        request _: ChatInferenceRequest,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func generateStructured(
        request _: InferenceRequest,
        jsonSchema _: String,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func preload(
        profile: ModelProfile,
        runtimePolicy _: ModelRuntimePolicy,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {
        events.append("preload \(profile.id)")
    }

    func unload() async {}

    func releaseConversations() async {}

    func setSpeculativeDecoding(_ enabled: Bool) async {
        events.append("mtp \(enabled)")
    }

    func clearCache() async throws {}
}

private struct NoopInferenceService: InferenceService {
    func run(
        request _: InferenceRequest,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func chat(
        request _: ChatInferenceRequest,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func generateStructured(
        request _: InferenceRequest,
        jsonSchema _: String,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func preload(
        profile _: ModelProfile,
        runtimePolicy _: ModelRuntimePolicy,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {}

    func unload() async {}

    func releaseConversations() async {}

    func setSpeculativeDecoding(_: Bool) async {}

    func clearCache() async throws {}
}

@Suite("Gemma 4 multimodal prefill")
struct Gemma4MultimodalPrefillTests {
    private let tokenTypes: [Int32] = [0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 0]

    @Test("Prefill windows never split a vision block and end on the last token")
    func prefillRanges() {
        let blocks = gemma4VisionBlocks(tokenTypes: tokenTypes)
        #expect(blocks == [2 ..< 5, 7 ..< 11])
        let ranges = gemma4MultimodalPrefillRanges(total: tokenTypes.count, visionBlocks: blocks, stepSize: 3)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last == 13 ..< 14)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(ranges.allSatisfy { range in
            blocks.allSatisfy { !($0.lowerBound < range.upperBound && range.upperBound < $0.upperBound) }
        })
    }

    @Test("Chunked block-bidirectional masks match the single-pass mask", arguments: [nil, 4] as [Int?])
    func chunkedMasksMatchSinglePass(windowSize: Int?) {
        let total = tokenTypes.count
        let types = MLXArray(tokenTypes).expandedDimensions(axis: 0)
        guard case .array(let full) = gemma4ApplyBlockwiseBidirectionalOverlay(
            .array(createCausalMask(n: total, offset: 0, windowSize: windowSize)),
            tokenTypeIds: types, sequenceLength: total, windowSize: windowSize
        ) else {
            Issue.record("single-pass mask was not an array")
            return
        }
        let ranges = gemma4MultimodalPrefillRanges(
            total: total, visionBlocks: gemma4VisionBlocks(tokenTypes: tokenTypes), stepSize: 3)
        for range in ranges where range.count > 1 {
            guard case .array(let chunk) = gemma4ApplyBlockwiseBidirectionalOverlay(
                .array(createCausalMask(n: range.count, offset: range.lowerBound, windowSize: windowSize)),
                tokenTypeIds: types[0..., range], sequenceLength: range.count, windowSize: windowSize
            ) else {
                Issue.record("chunk mask was not an array")
                continue
            }
            let expected = full[0..., 0..., range, ..<range.upperBound]
            #expect(chunk.shape == expected.shape)
            #expect(arrayEqual(chunk, expected).item(Bool.self), "window \(String(describing: windowSize)) chunk \(range)")
        }
    }
}
