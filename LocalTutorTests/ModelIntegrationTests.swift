//
//  ModelIntegrationTests.swift
//  LocalTutorTests
//
//  Real-model checks. They download a model, so they only run when
//  LOCALTUTOR_INTEGRATION=1 (pass TEST_RUNNER_LOCALTUTOR_INTEGRATION=1 to xcodebuild).
//  LOCALTUTOR_INTEGRATION_MODEL picks a catalog id (default gemma4E2B).
//

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import LocalTutor

private enum Integration {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LOCALTUTOR_INTEGRATION"] == "1"
    }

    static var profile: ModelProfile {
        ProcessInfo.processInfo.environment["LOCALTUTOR_INTEGRATION_MODEL"]
            .flatMap(ModelProfile.profile(withID:)) ?? .gemma4E2B
    }

    static let runner = LocalModelRunner()

    static let notes = """
    [1] notes.md | Photosynthesis
    Photosynthesis converts light energy into chemical energy in chloroplasts. Water is split during the light-dependent reactions, releasing oxygen. The Calvin cycle in the stroma uses ATP and NADPH to fix carbon dioxide with the enzyme RuBisCO.
    """
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct ModelIntegrationTests {
    @Test(.timeLimit(.minutes(30)), arguments: [false, true])
    func followUpChatTurnReusesCachedPrefix(speculative: Bool) async throws {
        let profile = Integration.profile
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        await Integration.runner.setSpeculativeDecoding(speculative)
        let conversation = UUID()
        let instructions = ChatContextPlanner.instructions(
            notebookTitle: "Biology",
            sourceNames: ["notes.md"],
            excerpts: Integration.notes
        )

        let first = try await Integration.runner.chat(
            request: ChatInferenceRequest(
                profile: profile,
                runtimePolicy: policy,
                conversationID: conversation,
                instructions: instructions,
                history: [],
                message: "Where does the oxygen released by photosynthesis come from?",
                images: [],
                maxTokens: 160
            )
        ) { _ in }
        try #require(first.status == .success, "\(first.errorMessage ?? "")")
        #expect(first.output.localizedCaseInsensitiveContains("water"))
        print("[integration] turn 1 (mtp=\(speculative)): \(ChatController.performanceSummary(first)) prompt=\(first.tokenMetrics.promptTokens ?? -1) accepted=\(first.tokenMetrics.acceptedDraftTokens ?? -1)")

        let second = try await Integration.runner.chat(
            request: ChatInferenceRequest(
                profile: profile,
                runtimePolicy: policy,
                conversationID: conversation,
                instructions: instructions,
                history: [ChatHistoryMessage(question: "Where does the oxygen released by photosynthesis come from?", answer: first.output)],
                message: "Which enzyme fixes carbon dioxide?",
                images: [],
                maxTokens: 120
            )
        ) { _ in }
        try #require(second.status == .success, "\(second.errorMessage ?? "")")
        #expect(second.output.localizedCaseInsensitiveContains("rubisco"))
        print("[integration] turn 2 (mtp=\(speculative)): \(ChatController.performanceSummary(second)) prompt=\(second.tokenMetrics.promptTokens ?? -1) cached=\(second.tokenMetrics.cachedPromptTokens ?? -1) accepted=\(second.tokenMetrics.acceptedDraftTokens ?? -1)")
        if speculative, profile.supportsSpeculativeDecoding {
            #expect((second.tokenMetrics.acceptedDraftTokens ?? 0) > 0)
        }
        print("[integration] diagnostics: \(await Integration.runner.conversationDiagnostics().prefix(3_000))")
        #expect((second.tokenMetrics.cachedPromptTokens ?? 0) > 0)
        #expect((second.tokenMetrics.promptTokens ?? .max) < (first.tokenMetrics.promptTokens ?? 0))
    }

    @Test(.timeLimit(.minutes(30)))
    func longContextBeyondTheOldCapAnswersFromTheStart() async throws {
        let profile = Integration.profile
        let policy = ModelRuntimePolicyProvider.policy(for: profile, preference: .extended)
        print("[integration] \(profile.name) context=\(policy.contextTokens) source budget=\(policy.sourceTokenBudget(for: .ask))")
        #expect(policy.contextTokens > 32_768)

        let topics = ["cells", "rivers", "volcanoes", "markets", "planets", "languages", "bridges", "forests"]
        var excerpts = ["[1] notes.md | Lab\nThe lab's secret calibration code is VIOLET-4271."]
        var index = 2
        while PromptTokenEstimator.estimate(excerpts.joined(separator: "\n\n")) < min(80_000, policy.sourceTokenBudget(for: .ask) - 2_000) {
            let topic = topics[index % topics.count]
            excerpts.append("[\(index)] notes.md | Section \(index)\nParagraph \(index) discusses \(topic): observation \(index * 7) was recorded on day \(index % 31 + 1), compared against baseline \(index * 3), and summarized for the review of \(topic) in week \(index % 52 + 1).")
            index += 1
        }
        let instructions = ChatContextPlanner.instructions(
            notebookTitle: "Long notebook",
            sourceNames: ["notes.md"],
            excerpts: excerpts.joined(separator: "\n\n")
        )

        let record = try await Integration.runner.chat(
            request: ChatInferenceRequest(
                profile: profile,
                runtimePolicy: policy,
                conversationID: UUID(),
                instructions: instructions,
                history: [],
                message: "What is the lab's secret calibration code?",
                images: [],
                maxTokens: 60
            )
        ) { _ in }
        await Integration.runner.releaseConversations()
        try #require(record.status == .success, "\(record.errorMessage ?? "")")
        let promptTokens = record.tokenMetrics.promptTokens ?? 0
        let seconds = record.tokenMetrics.promptTimeSeconds ?? 0
        print("[integration] long context: prompt=\(promptTokens) prefill=\(String(format: "%.1f", seconds))s (\(Int(Double(promptTokens) / max(seconds, 0.001))) tok/s) peak=\(record.mlxMemoryAfter.map { ByteCountFormatter.string(fromByteCount: Int64($0.peakBytes), countStyle: .memory) } ?? "?") answer=\(record.output.prefix(120))")
        #expect(promptTokens > 32_768)
        #expect(record.output.contains("4271"))
    }

    @Test(.timeLimit(.minutes(30)))
    func guidedGenerationProducesParseableFlashcards() async throws {
        let profile = Integration.profile
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        let content = StudyPromptContent(
            systemInstruction: StudyPromptBuilder.systemInstruction,
            openingText: StudyResourceKind.flashcards.promptInstruction,
            sourceBlocks: [.text(Integration.notes)],
            closingText: StudyResourceKind.flashcards.jsonSchemaInstruction ?? "",
            includedImageCount: 0,
            omittedImageCount: 0,
            imageFilenames: [],
            warnings: []
        )
        let record = try await Integration.runner.generateStructured(
            request: InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: 900, temperature: 0.2),
            jsonSchema: try #require(StudyResourceKind.flashcards.jsonSchema)
        ) { _ in }

        try #require(record.status == .success, "\(record.errorMessage ?? "")")
        print("[integration] flashcards: \(ChatController.performanceSummary(record))")
        guard case .flashcards(let deck) = StudyArtifactParser.parse(record.output, kind: .flashcards) else {
            Issue.record("Guided output did not parse: \(record.output.prefix(400))")
            return
        }
        #expect(deck.cards.count >= 6)
    }

    @Test(.timeLimit(.minutes(30)))
    func visionModelsReceiveImages() async throws {
        let profile = Integration.profile
        guard profile.supportsVision else { return }
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        let red = CIImage(color: CIColor(red: 0.9, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = DocumentImage(image: red, sourceName: "swatch.png", locator: nil, caption: nil, isStandalone: true, originalSize: red.extent.size)
        let content = StudyPromptBuilder.modelLabContent(prompt: "What single color fills this image? Answer with one word.", image: image)

        let record = try await Integration.runner.run(
            request: InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: 20, temperature: 0)
        ) { _ in }

        try #require(record.status == .success, "\(record.errorMessage ?? "")")
        print("[integration] vision: \(record.output)")
        #expect(record.output.localizedCaseInsensitiveContains("red"))
    }
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct SpeculativeDecodingIntegrationTests {
    @Test(.timeLimit(.minutes(30)))
    func multiTokenPredictionSpeedsUpLongAnswers() async throws {
        let profile = Integration.profile
        guard profile.supportsSpeculativeDecoding else { return }
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        let runner = LocalModelRunner()
        let content = StudyPromptContent(
            systemInstruction: StudyPromptBuilder.systemInstruction,
            openingText: StudyResourceKind.studyGuide.promptInstruction,
            sourceBlocks: [.text(Integration.notes)],
            closingText: "Write the study guide now.",
            includedImageCount: 0,
            omittedImageCount: 0,
            imageFilenames: [],
            warnings: []
        )
        let request = InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: 400, temperature: 0)

        await runner.setSpeculativeDecoding(false)
        let baseline = try await runner.run(request: request) { _ in }
        await runner.setSpeculativeDecoding(true)
        _ = try await runner.run(request: InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: 16, temperature: 0)) { _ in }
        let speculative = try await runner.run(request: request) { _ in }

        try #require(baseline.status == .success && speculative.status == .success, "\(speculative.errorMessage ?? baseline.errorMessage ?? "")")
        let base = baseline.tokenMetrics.tokensPerSecond ?? 0
        let fast = speculative.tokenMetrics.tokensPerSecond ?? 0
        let metrics = speculative.tokenMetrics
        print("[integration] mtp \(profile.id): baseline \(String(format: "%.1f", base)) tok/s → mtp \(String(format: "%.1f", fast)) tok/s (x\(String(format: "%.2f", fast / max(base, 0.1)))) accepted \(metrics.acceptedDraftTokens ?? -1)/\(metrics.proposedDraftTokens ?? -1) passthrough=\(metrics.speculativePassthroughReason ?? "none")")
        print("[integration] drafter error: \(await runner.lastDrafterError ?? "none")")
        #expect(metrics.speculativePassthroughReason == nil)
        #expect((metrics.acceptedDraftTokens ?? 0) > 0)
    }
}

@Suite(.serialized, .enabled(if: Integration.isEnabled && SystemModelHelper.availability.isAvailable))
struct SystemModelIntegrationTests {
    @Test(.timeLimit(.minutes(5)))
    func appleIntelligenceWritesGuidesTitlesAndAnswers() async throws {
        let guide = try await SystemModelHelper.sourceGuide(sourceName: "notes.md", text: Integration.notes)
        print("[integration] guide: \(guide.summary) | \(guide.topics) | \(guide.questions)")
        #expect(!guide.summary.isEmpty)
        #expect((3...6).contains(guide.topics.count))
        #expect(guide.questions.count == 3)

        let title = try await SystemModelHelper.chatTitle(question: "Which enzyme fixes CO2?", answer: "RuBisCO fixes carbon dioxide in the Calvin cycle.")
        print("[integration] title: \(title)")
        #expect(!title.isEmpty)
        #expect(title.split(separator: " ").count <= 8)

        let counter = UpdateCounter()
        let answer = try await SystemModelHelper.streamAnswer(
            instructions: ChatContextPlanner.instructions(notebookTitle: "Biology", sourceNames: ["notes.md"], excerpts: Integration.notes),
            history: [],
            message: "Which enzyme fixes carbon dioxide?"
        ) { _ in counter.value += 1 }
        let updates = await counter.value
        print("[integration] system answer (\(updates) updates): \(answer.prefix(200))")
        #expect(answer.localizedCaseInsensitiveContains("rubisco"))
        #expect(updates > 1)
    }
}

@MainActor
private final class UpdateCounter {
    var value = 0
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct EmbeddingIntegrationTests {
    @Test(.timeLimit(.minutes(30)))
    func embeddingModelRanksMatchingPassagesFirstAcrossLanguages() async throws {
        let embedder = LocalEmbeddingRunner()
        defer { Task { await embedder.unload() } }
        try await embedder.prepare { _ in }

        let documents = try await embedder.embedDocuments([
            EmbeddingDocument(title: "Planets", text: "Mars is known as the Red Planet because of iron oxide on its surface."),
            EmbeddingDocument(title: "Planets", text: "Venus is often called Earth's twin because of its similar size."),
            EmbeddingDocument(title: "Sistema respiratorio", text: "Los pulmones permiten el intercambio de gases: el oxígeno pasa de los alvéolos a la sangre."),
            EmbeddingDocument(title: "Aparato digestivo", text: "El estómago mezcla los alimentos con jugos gástricos para comenzar la digestión de las proteínas.")
        ])
        #expect(documents.count == 4)
        #expect(documents.allSatisfy { $0.count == LocalEmbeddingRunner.dimension })
        for vector in documents {
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            #expect(abs(norm - 1) < 0.01)
        }

        func ranking(_ query: String) async throws -> [Int] {
            let vector = try await embedder.embedQuery(query)
            let scores = documents.map { zip($0, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
            return scores.indices.sorted { scores[$0] > scores[$1] }
        }
        #expect(try await ranking("Which planet is known as the Red Planet?").first == 0)
        #expect(try await ranking("¿Cuál es la función de los pulmones?").first == 2)
        #expect(try await ranking("How do the lungs move oxygen into the blood?").first == 2)

        let single = try await embedder.embedDocuments([
            EmbeddingDocument(title: "Planets", text: "Venus is often called Earth's twin because of its similar size.")
        ])
        let paddedVsAlone = zip(single[0], documents[1]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(paddedVsAlone > 0.999)
    }
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct EmbeddingMemoryIntegrationTests {
    @Test(.timeLimit(.minutes(30)))
    func embeddingModelMemoryFootprint() async throws {
        Memory.clearCache()
        let before = Memory.activeMemory
        let embedder = LocalEmbeddingRunner()
        try await embedder.prepare { _ in }
        let loaded = Memory.activeMemory - before
        Memory.peakMemory = 0
        let chunk = String(repeating: "Los pulmones permiten el intercambio de gases entre el aire y la sangre. ", count: 30)
        _ = try await embedder.embedDocuments(Array(repeating: EmbeddingDocument(title: "Sistema respiratorio", text: chunk), count: 8))
        let peak = Memory.peakMemory - before
        await embedder.unload()
        Memory.clearCache()
        let gb = { (bytes: Int) in String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }
        print("[embedding-memory] weights=\(gb(loaded)) peak while embedding 8×\(PromptTokenEstimator.estimate(chunk)) tokens=\(gb(peak)) after unload=\(gb(Memory.activeMemory - before))")
        #expect(loaded < 700 * 1_048_576)
    }
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct DownloadResumeIntegrationTests {
    @Test(.timeLimit(.minutes(10)))
    func pausedDownloadsResumeFromThePartialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTutorResume-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let service = ManagedModelDownloadService(
            repositoriesDirectory: root.appendingPathComponent("repos", isDirectory: true),
            stagingDirectory: staging,
            jobsFileURL: root.appendingPathComponent("jobs.json")
        )
        let profile = ModelProfile(
            id: "resume-test",
            name: "Resume test",
            subtitle: "",
            modelIdentifier: "mlx-community/gemma-4-E4B-it-assistant-bf16",
            kind: .drafter,
            tier: .eightGB,
            minimumSystemMemoryBytes: 0,
            defaults: .text,
            configuration: .embedder(.init(id: "mlx-community/gemma-4-E4B-it-assistant-bf16"))
        )
        let progress = ProgressLog()

        let first = Task {
            try await service.ensureDownloaded(profile: profile) { update in
                Task { await progress.record(update.fraction ?? 0) }
            }
        }
        func partialSize() -> Int {
            let entries = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return entries.filter { $0.pathExtension == "partial" }
                .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                .max() ?? 0
        }
        while partialSize() < 20_000_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        first.cancel()
        let firstOutcome = await first.result
        print("[integration] early fractions: \(await progress.history.map { String(format: "%.4f", $0) })")
        print("[integration] first attempt ended: \(String(describing: firstOutcome).prefix(160))")

        let partials = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "partial" }
        let partialBytes = try partials.first?.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let pending = await service.pendingDownloads()
        print("[integration] paused with \(partialBytes) partial bytes, pending fraction \(pending.first?.fraction ?? -1)")
        #expect(partialBytes > 0)
        #expect((pending.first?.fraction ?? 0) > 0.1)

        await progress.reset()
        let result = try await service.ensureDownloaded(profile: profile) { update in
            Task { await progress.record(update.fraction ?? 0) }
        }
        let firstResumed = await progress.first
        print("[integration] resumed at \(firstResumed)")
        #expect(firstResumed > 0.1)
        #expect(ManagedModelStore.isUsableModelDirectory(result.directory, for: profile))
        #expect(await service.pendingDownloads().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        #expect(leftovers.filter { $0.pathExtension == "partial" }.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProgressLog {
    private(set) var latest: Double = 0
    private(set) var first: Double = -1
    private(set) var history: [Double] = []

    func record(_ fraction: Double) {
        if history.count < 12 { history.append(fraction) }
        latest = max(latest, fraction)
        if first < 0, fraction > 0 { first = fraction }
    }

    func reset() {
        latest = 0
        first = -1
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALTUTOR_KV_BENCH"] == "1"))
struct KVCacheBenchmarkTests {
    private struct Variant {
        var name: String
        var kvCache: KVCacheConfiguration?
    }

    private static let variants: [Variant] = [
        Variant(name: "fp16", kvCache: nil),
        Variant(name: "affine8", kvCache: KVCacheConfiguration(strategy: .affine(.eightBit))),
        Variant(name: "turbo0v4", kvCache: KVCacheConfiguration(strategy: .turboQuant(.qualityFirst))),
        Variant(name: "turbo8v3", kvCache: KVCacheConfiguration(strategy: .turboQuant(.balanced))),
        Variant(name: "affine4", kvCache: KVCacheConfiguration(strategy: .affine(.fourBit)))
    ]

    private static var profiles: [ModelProfile] {
        let ids = ProcessInfo.processInfo.environment["LOCALTUTOR_KV_BENCH_MODELS"]?.split(separator: ",").map(String.init)
            ?? ModelProfile.studyCatalog.map(\.id)
        return ids.compactMap(ModelProfile.profile(withID:)).filter {
            ManagedModelStore.isUsableModelDirectory(
                ManagedModelStore.repositoryDirectory(for: $0.modelIdentifier),
                for: $0,
                fileManager: .default
            )
        }
    }

    private static func instructions(targetTokens: Int) -> String {
        let topics = ["cells", "rivers", "volcanoes", "markets", "planets", "languages", "bridges", "forests"]
        var excerpts = ["[1] notes.md | Lab\nThe lab's secret calibration code is VIOLET-4271."]
        var index = 2
        while PromptTokenEstimator.estimate(excerpts.joined(separator: "\n\n")) < targetTokens {
            let topic = topics[index % topics.count]
            excerpts.append("[\(index)] notes.md | Section \(index)\nParagraph \(index) discusses \(topic): observation \(index * 7) was recorded on day \(index % 31 + 1), compared against baseline \(index * 3), and summarized for the review of \(topic) in week \(index % 52 + 1).")
            index += 1
        }
        return ChatContextPlanner.instructions(notebookTitle: "Long notebook", sourceNames: ["notes.md"], excerpts: excerpts.joined(separator: "\n\n"))
    }

    @Test(.timeLimit(.minutes(60)))
    func compareKVCacheStrategies() async throws {
        let instructions = Self.instructions(targetTokens: 24_000)
        let question = "What is the lab's secret calibration code? Then explain in about 150 words what the notes say about volcanoes and rivers."
        var rows: [String] = []

        for profile in Self.profiles {
            if profile.supportsSpeculativeDecoding {
                let runner = LocalModelRunner()
                await runner.setSpeculativeDecoding(true)
                let record = try await runner.chat(
                    request: ChatInferenceRequest(
                        profile: profile,
                        runtimePolicy: ModelRuntimePolicyProvider.policy(for: profile, preference: .extended),
                        conversationID: UUID(),
                        instructions: instructions,
                        history: [],
                        message: question,
                        images: [],
                        maxTokens: 256,
                        temperature: 0
                    )
                ) { _ in }
                await runner.unload()
                let tps = record.tokenMetrics.tokensPerSecond ?? 0
                rows.append("\(profile.id) | fp16+MTP | \(String(format: "%.1f", tps)) tok/s | kv=? | peak=\(record.mlxMemoryAfter.map { Self.gb(Int($0.peakBytes)) } ?? "?") | needle=\(record.output.contains("4271")) | match=—")
            }

            let directory = ManagedModelStore.repositoryDirectory(for: profile.modelIdentifier)
            let container: ModelContainer
            switch profile.configuration {
            case .llm(var configuration):
                configuration.id = .directory(directory)
                container = try await LLMModelFactory.shared.loadContainer(
                    from: LocalDirectoryOnlyDownloader(), using: TransformersTokenizerLoader(), configuration: configuration)
            case .vlm(var configuration):
                configuration.id = .directory(directory)
                container = try await VLMModelFactory.shared.loadContainer(
                    from: LocalDirectoryOnlyDownloader(), using: TransformersTokenizerLoader(), configuration: configuration)
                await container.update { $0.processor = TextMaskNormalizingProcessor(base: $0.processor) }
            case .embedder:
                continue
            }

            var reference: String?
            for variant in Self.variants {
                Memory.clearCache()
                Memory.peakMemory = 0
                let session = ChatSession(
                    container,
                    instructions: instructions,
                    generateParameters: GenerateParameters(
                        maxTokens: 256,
                        kvCache: variant.kvCache,
                        temperature: 0,
                        prefill: PrefillParameters(stepSize: profile.defaults.prefillStepSize)
                    ),
                    additionalContext: LocalModelRunner.chatTemplateContext(for: profile)
                )
                var output = ""
                var info: GenerateCompletionInfo?
                do {
                    for try await generation in session.streamDetails(to: [.user(question, images: [])]) {
                        switch generation {
                        case .chunk(let text): output += text
                        case .info(let value): info = value
                        default: break
                        }
                    }
                } catch {
                    rows.append("\(profile.id) | \(variant.name) | failed: \(error.localizedDescription)")
                    continue
                }
                let status = try? await session.cacheStatus()
                let kvBytes = status?.memoryBytes ?? 0
                if let status {
                    let layers = status.layers.map { "\($0.kind)/\($0.state)/\(String(describing: $0.reason))/\($0.memoryBytes / 1_048_576)MB" }
                    let summary = Dictionary(layers.map { ($0, 1) }, uniquingKeysWith: +).map { "\($0.value)x \($0.key)" }.sorted()
                    rows.append("   \(variant.name): compressed=\(status.compressedLayerCount) pending=\(status.pendingLayerCount) skipped=\(status.skippedLayerCount) \(summary)")
                }
                let visible = ReasoningOutputFilter.sanitize(output)
                if reference == nil { reference = visible }
                let match = Self.matchingPrefixFraction(visible, reference ?? visible)
                rows.append("\(profile.id) | \(variant.name) | \(String(format: "%.1f", info?.tokensPerSecond ?? 0)) tok/s | kv=\(Self.gb(kvBytes)) | peak=\(Self.gb(Memory.peakMemory)) | needle=\(visible.contains("4271")) | match=\(Int(match * 100))% | prompt=\(info?.promptTokenCount ?? 0)")
            }
            Memory.clearCache()
        }
        print("[kv-bench]\n" + rows.joined(separator: "\n"))
    }

    private static func matchingPrefixFraction(_ text: String, _ reference: String) -> Double {
        let common = zip(text, reference).prefix { $0 == $1 }.count
        return Double(common) / Double(max(1, reference.count))
    }

    private static func gb(_ bytes: Int) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}

@Suite(.serialized, .enabled(if: Integration.isEnabled))
struct MultimodalPrefillIntegrationTests {
    @Test(.timeLimit(.minutes(30)))
    func notebookSizedPromptWithImagesStaysWithinMemory() async throws {
        let profile = Integration.profile
        guard profile.supportsVision else { return }
        let policy = ModelRuntimePolicyProvider.policy(for: profile, preference: .extended)
        let topics = ["automata", "grammars", "complexity", "logic", "search", "planning", "probability", "learning"]
        let paragraphs = (1 ... 540).map { index in
            "Section \(index). Lecture \(index % 14 + 1) covers \(topics[index % topics.count]): definition \(index * 7 % 97) relates state \(index % 23) to transition \(index * 3 % 41), and the proof sketch reduces case \(index % 5) to lemma \(index % 11) before generalising."
        }
        let content = StudyPromptContent(
            systemInstruction: StudyPromptBuilder.systemInstruction,
            openingText: StudyResourceKind.summary.promptInstruction,
            sourceBlocks: [.text(paragraphs.joined(separator: "\n\n"))] + Self.figures.map { .image($0) },
            closingText: "Write the summary now.",
            includedImageCount: Self.figures.count,
            omittedImageCount: 0,
            imageFilenames: Self.figures.map(\.sourceName),
            warnings: []
        )

        let record = try await Integration.runner.run(
            request: InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: 48, temperature: 0)
        ) { _ in }

        try #require(record.status == .success, "\(record.errorMessage ?? "")")
        let peak = record.mlxMemoryAfter?.peakBytes ?? 0
        print("[integration] multimodal prefill \(profile.id): prompt=\(record.tokenMetrics.promptTokens ?? -1) tokens, generated=\(record.tokenMetrics.generatedTokens ?? -1) stop=\(record.tokenMetrics.stopReason ?? "-"), mlx peak=\(Self.gb(peak)), process peak=\(Self.gb(record.processPeakPhysicalFootprintBytes ?? 0)), output=\(record.output.prefix(120))")
        #expect((record.tokenMetrics.promptTokens ?? 0) > 20_000)
        #expect(peak < 8 * 1_073_741_824)
        #expect((record.tokenMetrics.generatedTokens ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(30)))
    func chunkedImagePrefillMatchesSinglePass() async throws {
        let profile = Integration.profile
        guard profile.supportsVision, case .vlm(var configuration) = profile.configuration else { return }
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        let download = try await ManagedModelDownloadService.shared.ensureDownloaded(profile: profile) { _ in }
        configuration.id = .directory(download.directory)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: LocalDirectoryOnlyDownloader(),
            using: TransformersTokenizerLoader(),
            configuration: configuration
        )
        let content = StudyPromptContent(
            systemInstruction: StudyPromptBuilder.systemInstruction,
            openingText: "Explain how the two figures relate to these notes.",
            sourceBlocks: [.text(Integration.notes), .image(Self.figures[0]), .text("Second figure:"), .image(Self.figures[1])],
            closingText: "Answer in one sentence.",
            includedImageCount: 2,
            omittedImageCount: 0,
            imageFilenames: Self.figures.map(\.sourceName),
            warnings: []
        )
        let input = UncheckedSendableBox(try await container.prepare(
            input: LocalModelRunner.makeUserInput(promptContent: content, profile: profile, runtimePolicy: policy)
        ))

        let comparison = try await container.perform { context in
            func lastLogits(_ prefill: PrefillParameters) throws -> (logits: MLXArray, offset: Int) {
                let cache = try context.model.newCache(parameters: nil)
                guard case .logits(let output) = try context.model.prepare(input.value, cache: cache, state: nil, prefill: prefill) else {
                    throw CancellationError()
                }
                let logits = output.logits[0, -1].asType(.float32)
                eval(logits)
                return (logits, cache.first?.offset ?? -1)
            }
            let single = try lastLogits(PrefillParameters(chunking: .unchunked))
            let chunked = try lastLogits(PrefillParameters(stepSize: 48))
            let cosine = (single.logits * chunked.logits).sum() / (sqrt((single.logits * single.logits).sum()) * sqrt((chunked.logits * chunked.logits).sum()))
            return (
                promptTokens: input.value.text.tokens.size,
                offsets: [single.offset, chunked.offset],
                sameTop: (argMax(single.logits) .== argMax(chunked.logits)).item(Bool.self),
                cosine: cosine.item(Float.self),
                maxDifference: abs(single.logits - chunked.logits).max().item(Float.self)
            )
        }

        print("[integration] chunked vs single-pass \(profile.id): prompt=\(comparison.promptTokens) offsets=\(comparison.offsets) sameTop=\(comparison.sameTop) cosine=\(comparison.cosine) maxDiff=\(comparison.maxDifference)")
        #expect(comparison.offsets[0] == comparison.offsets[1])
        #expect(comparison.sameTop)
        #expect(comparison.cosine > 0.999)
    }

    private static let figures: [DocumentImage] = [
        CIImage(color: CIColor(red: 0.9, green: 0.05, blue: 0.05)),
        CIImage(color: CIColor(red: 0.05, green: 0.2, blue: 0.9))
    ].enumerated().map { index, color in
        let image = color.cropped(to: CGRect(x: 0, y: 0, width: 768, height: 1024))
        return DocumentImage(image: image, sourceName: "notes_\(index + 1).pdf", locator: "page \(index + 4)", caption: "Page render with visual material", isStandalone: false, originalSize: image.extent.size)
    }

    private static func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALTUTOR_EVAL_URL"] != nil))
struct NotebookSummaryEvaluation {
    @Test(.timeLimit(.minutes(60)))
    func summarizeServedNotebook() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["LOCALTUTOR_EVAL_URL"].flatMap(URL.init(string:)))
        let names = (ProcessInfo.processInfo.environment["LOCALTUTOR_EVAL_FILES"] ?? "notes_1.pdf,notes_2.pdf,notes_3.pdf").split(separator: ",").map(String.init)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sources: [StudySource] = []
        for name in names {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            sources.append(StudySource(url: url))
        }
        let profile = Integration.profile
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        let user = StudyTurnUser(focus: "", resourceKind: .summary, sources: sources, isRefinement: false)
        let variants = (ProcessInfo.processInfo.environment["LOCALTUTOR_EVAL_VARIANTS"] ?? "current,noImages").split(separator: ",").map(String.init)
        print("[eval] \(profile.id) context=\(policy.contextTokens) budget=\(PromptPacker.promptBudget(for: policy, resourceKind: .summary))")

        for variant in variants {
            let started = Date()
            var content = try await SourceContextPlanner.content(
                for: user, history: [], profile: profile, runtimePolicy: policy,
                generateIntermediate: { content, maxTokens, temperature in
                    let record = try await Integration.runner.run(
                        request: InferenceRequest(profile: profile, runtimePolicy: policy, promptContent: content, maxTokens: maxTokens, temperature: temperature)
                    ) { _ in }
                    print("[eval] intermediate \(record.tokenMetrics.generatedTokens ?? -1) tokens, language=\(ResponseLanguage.detect(record.output)?.rawValue ?? "?"): \(record.output.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
                    return record.output
                },
                status: { message in print("[eval] status: \(message)") }
            )
            if variant == "noImages" {
                content.sourceBlocks = content.sourceBlocks.filter { if case .image = $0 { return false } else { return true } }
            }
            let images = content.sourceBlocks.filter { if case .image = $0 { return true } else { return false } }.count
            let repeats = Int(ProcessInfo.processInfo.environment["LOCALTUTOR_EVAL_REPEATS"] ?? "1") ?? 1
            var record: BenchmarkRecord!
            for attempt in 1 ... repeats {
                let reasoning = ReasoningRecorder()
                record = try await Integration.runner.run(
                    request: StudioController.request(for: .summary, profile: profile, policy: policy, content: content)
                ) { event in
                    if case .reasoningChunk(let chunk) = event { await reasoning.append(chunk) }
                }
                let reasoningText = await reasoning.text
                print("[eval] attempt \(attempt): visible=\(record.output.count) reasoning=\(reasoningText.count) generated=\(record.tokenMetrics.generatedTokens ?? -1) stop=\(record.tokenMetrics.stopReason ?? "-")")
                if record.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("[eval] empty-visible reasoning tail: \(reasoningText.suffix(1500).replacingOccurrences(of: "\n", with: "⏎"))")
                    let markers = ["<channel|>", "<|channel>", "</think>", "<think>", "<|channel|>", "final", "<turn|>"]
                    print("[eval] markers: \(markers.map { "\($0)=\(reasoningText.components(separatedBy: $0).count - 1)" })")
                }
            }
            print("[eval] ===== \(variant): status=\(record.status) prompt=\(record.tokenMetrics.promptTokens ?? -1) images=\(images) generated=\(record.tokenMetrics.generatedTokens ?? -1) seconds=\(Int(Date().timeIntervalSince(started))) peak=\(String(format: "%.2f GB", Double(record.mlxMemoryAfter?.peakBytes ?? 0) / 1_073_741_824))")
            print("[eval] warnings: \(content.warnings)")
            print("[eval-output-begin \(variant)]\n\(record.output)\n[eval-output-end \(variant)]")
        }
    }
}

private actor ReasoningRecorder {
    private(set) var text = ""

    func append(_ chunk: String) {
        text += chunk
    }
}
