import Foundation
import SQLite3
import Testing
@testable import LocalTutor

@Suite("Native source indexing")
struct SourceIndexingTests {
    @Test("Recursive chunking enforces hard limits and creates parents")
    func recursiveChunkingLimits() async {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/long-source.md"))
        let paragraph = Array(repeating: "Retrieval quality depends on coherent local context.", count: 900)
            .joined(separator: " ")
        let extracted = ExtractedSource(
            source: source,
            blocks: [.text("# Retrieval\n\n\(paragraph)")],
            failureReason: nil
        )

        let index = await SourceIndexBuilder.build(from: extracted)

        #expect(index.parents.count == 1)
        #expect(index.chunks.count > 1)
        #expect(index.chunks.allSatisfy { $0.estimatedTokenCount <= SourceIndexBuilder.maximumChunkTokens })
        #expect(index.chunks.allSatisfy { $0.parentID == index.parents[0].id })
        #expect(Set(index.chunks.map(\.id)).count == index.chunks.count)
    }

    @Test("Embedding prompts are asymmetric")
    func embeddingPrompts() {
        #expect(
            LocalEmbeddingRunner.formatted(text: "How does RRF work?", kind: .query)
                == "task: search result | query: How does RRF work?"
        )
        #expect(
            LocalEmbeddingRunner.formatted(
                text: "RRF combines ranked lists.",
                kind: .document(title: "Fusion")
            ) == "title: Fusion | text: RRF combines ranked lists."
        )
    }

    @Test("Foreground query embedding does not wait for tutor generation")
    func foregroundQueryEmbedding() async throws {
        let embeddingService = RecordingEmbeddingService()
        let coordinator = SourceIndexCoordinator(
            embeddingService: embeddingService,
            idleUnloadDelay: .milliseconds(20)
        )
        await coordinator.setTutorGenerationActive(true)

        let queryTask = Task {
            try await coordinator.embedQuery("How does retrieval work?")
        }
        try await Task.sleep(for: .milliseconds(50))
        let queryCountWhileActive = await embeddingService.queryCount
        await coordinator.setTutorGenerationActive(false)
        _ = try await queryTask.value

        #expect(queryCountWhileActive == 1)
    }

    @Test("Manual embedding preparation reschedules idle unload")
    func manualPreparationUnload() async throws {
        let embeddingService = RecordingEmbeddingService()
        let coordinator = SourceIndexCoordinator(
            embeddingService: embeddingService,
            idleUnloadDelay: .milliseconds(200)
        )

        try await coordinator.prepareEmbeddingModel { _ in }
        try await Task.sleep(for: .milliseconds(20))
        try await coordinator.prepareEmbeddingModel { _ in }
        try await Task.sleep(for: .milliseconds(50))

        let unloadCountBeforeDelay = await embeddingService.unloadCount
        #expect(unloadCountBeforeDelay == 0)

        try await Task.sleep(for: .milliseconds(200))

        let prepareCount = await embeddingService.prepareCount
        let unloadCountAfterDelay = await embeddingService.unloadCount
        #expect(prepareCount == 2)
        #expect(unloadCountAfterDelay == 1)
    }

    @Test(
        "Real EmbeddingGemma produces normalized 768-dimensional vectors",
        .enabled(if: ProcessInfo.processInfo.environment["LOCALTUTOR_RUN_EMBEDDING_INTEGRATION"] == "1")
    )
    func realEmbeddingIntegration() async throws {
        let vector = try await LocalEmbeddingRunner.shared.embedQuery("local semantic retrieval")
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })

        #expect(vector.count == LocalEmbeddingRunner.dimension)
        #expect(abs(norm - 1) < 0.001)
        await LocalEmbeddingRunner.shared.unload()
    }

    @Test("Edited sources replace prior persisted indexes")
    func editedSourceReindex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("notes.md")
        let unchanged = "Reciprocal rank fusion combines lexical and semantic rankings."
        let firstText = "# Search\n\n\(unchanged)\n\n# Appendix\n\nOriginal appendix text."
        try Data(firstText.utf8).write(to: sourceURL)
        var source = StudySource(url: sourceURL)
        let repository = SQLiteSourceIndexRepository(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )

        let first = await SourceIndexBuilder.build(
            from: ExtractedSource(
                source: source,
                blocks: [.text(firstText)]
            )
        )
        try await repository.store(first, state: .lexicalOnly)

        let secondText = "# Search\n\n\(unchanged)\n\n# Appendix\n\nRevised appendix text."
        try Data(secondText.utf8).write(to: sourceURL)
        var editedSource = StudySource(url: sourceURL)
        editedSource.id = source.id
        let second = await SourceIndexBuilder.build(
            from: ExtractedSource(
                source: editedSource,
                blocks: [.text(secondText)]
            )
        )
        #expect(second.fingerprint != first.fingerprint)
        #expect(Set(second.chunks.map(\.id)).intersection(first.chunks.map(\.id)).isEmpty == false)

        try await repository.store(second, state: .lexicalOnly)

        let statistics = await repository.statistics()
        let cached = await repository.cachedIndex(for: source)
        let stale = try await repository.lexicalSearch(
            query: "semantic rankings",
            fingerprints: [first.fingerprint],
            limit: 10
        )

        #expect(statistics.documentCount == 1)
        #expect(statistics.chunkCount == second.chunks.count)
        #expect(cached?.fingerprint == second.fingerprint)
        #expect(stale.isEmpty)
    }

    @Test("Recursive chunking preserves punctuation and spacing")
    func recursiveChunkingPreservesText() async {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/punctuation.md"))
        let sentence = Array(repeating: "Alpha beta gamma delta.", count: 120).joined(separator: " ")
        let extracted = ExtractedSource(
            source: source,
            blocks: [.text("# Section\n\n\(sentence)")]
        )

        let index = await SourceIndexBuilder.build(from: extracted)
        let reconstructed = index.chunks.map(\.text).joined()

        #expect(index.chunks.count > 1)
        #expect(reconstructed.contains(". "))
        #expect(!reconstructed.contains("gamma.Alpha"))
        #expect(reconstructed.filter { $0 == "." }.count >= sentence.filter { $0 == "." }.count)
    }

    @Test("SQLite stores FTS rows, metadata, and binary vectors")
    func sqliteRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("notes.md")
        try Data("# Search\n\nReciprocal rank fusion combines lexical and semantic rankings.".utf8)
            .write(to: sourceURL)
        let source = StudySource(url: sourceURL)
        let extracted = ExtractedSource(
            source: source,
            blocks: [.text("# Search\n\nReciprocal rank fusion combines lexical and semantic rankings.")]
        )
        let index = await SourceIndexBuilder.build(from: extracted)
        let repository = SQLiteSourceIndexRepository(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )

        try await repository.store(index, state: .lexicalOnly)
        let cached = await repository.cachedIndex(for: source)
        let lexical = try await repository.lexicalSearch(
            query: "semantic rankings",
            fingerprints: [index.fingerprint],
            limit: 10
        )
        let vector = Array(repeating: Float(0), count: LocalEmbeddingRunner.dimension)
        try await repository.storeVectors(
            Dictionary(uniqueKeysWithValues: index.chunks.map { ($0.id, vector) }),
            fingerprint: index.fingerprint
        )
        let vectors = try await repository.vectorEntries(fingerprints: [index.fingerprint])
        let statistics = await repository.statistics()

        #expect(cached?.chunks == index.chunks)
        #expect(lexical.first?.id == index.chunks.first?.id)
        #expect(vectors.count == index.chunks.count)
        #expect(vectors.first?.vector.count == LocalEmbeddingRunner.dimension)
        #expect(statistics.documentCount == 1)
        #expect(statistics.vectorCount == index.chunks.count)

        try await repository.clear()
        let cleared = await repository.statistics()
        #expect(cleared.documentCount == 0)
        #expect(cleared.chunkCount == 0)
        #expect(cleared.vectorCount == 0)
    }

    @Test("FTS search remains scoped to attached fingerprints")
    func sourceFiltering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SQLiteSourceIndexRepository(
            databaseURL: root.appendingPathComponent("index.sqlite3")
        )

        let first = try await makeIndex(
            root: root,
            name: "first.md",
            text: "# Topic\n\nOranges contain citrus compounds."
        )
        let second = try await makeIndex(
            root: root,
            name: "second.md",
            text: "# Topic\n\nOranges are mentioned in a separate private source."
        )
        try await repository.store(first, state: .lexicalOnly)
        try await repository.store(second, state: .lexicalOnly)

        let results = try await repository.lexicalSearch(
            query: "oranges",
            fingerprints: [first.fingerprint],
            limit: 10
        )

        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.sourceName == "first.md" })
    }

    @Test("Embedding documents use the nearest heading or the model's untitled prompt")
    func embeddingDocumentTitle() {
        var chunk = chunk(id: "1")
        chunk.headingPath = ["# Biology", "## 2. Cells", "2.1 Membranes"]
        #expect(EmbeddingDocument(chunk: chunk).title == "2.1 Membranes")

        chunk.headingPath = []
        let document = EmbeddingDocument(chunk: chunk)
        #expect(document.title == nil)
        #expect(
            LocalEmbeddingRunner.formatted(text: document.text, kind: .document(title: document.title))
                == "title: none | text: 1"
        )
    }

    @Test("Legacy full-text index is rebuilt with stemming")
    func legacyFullTextIndexMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("index.sqlite3")
        let index = try await makeIndex(
            root: root,
            name: "notes.md",
            text: "# Photosynthesis\n\nThe light reaction splits water."
        )
        try await SQLiteSourceIndexRepository(databaseURL: databaseURL).store(index, state: .lexicalOnly)

        var handle: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
        let legacySchema = """
            DROP TABLE chunk_fts;
            CREATE VIRTUAL TABLE chunk_fts USING fts5(
                text, heading, source_name, locator,
                content='chunks', content_rowid='rowid', tokenize='unicode61'
            );
            INSERT INTO chunk_fts(chunk_fts) VALUES('rebuild');
            PRAGMA user_version = 0;
            """
        #expect(sqlite3_exec(handle, legacySchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let results = try await SQLiteSourceIndexRepository(databaseURL: databaseURL).lexicalSearch(
            query: "reactions",
            fingerprints: [index.fingerprint],
            limit: 10
        )

        #expect(results.map(\.id) == index.chunks.map(\.id))
    }

    @Test("RRF equals or improves component retrieval metrics")
    func reciprocalRankFusionMetrics() {
        let relevantA = chunk(id: "a")
        let relevantB = chunk(id: "b")
        let noiseC = chunk(id: "c")
        let noiseD = chunk(id: "d")
        let lexical = [relevantA, noiseC, relevantB, noiseD]
        let dense = [relevantA, relevantB, noiseD, noiseC]
        let fused = SourceRetriever.reciprocalRankFusion(lexical: lexical, dense: dense)
        let relevant: [Set<String>] = [["a", "b"]]

        let lexicalMetrics = RetrievalEvaluator.metrics(
            rankedChunkIDs: [lexical.map(\.id)],
            relevantChunkIDs: relevant
        )
        let denseMetrics = RetrievalEvaluator.metrics(
            rankedChunkIDs: [dense.map(\.id)],
            relevantChunkIDs: relevant
        )
        let hybridMetrics = RetrievalEvaluator.metrics(
            rankedChunkIDs: [fused.map(\.id)],
            relevantChunkIDs: relevant
        )

        #expect(hybridMetrics.recallAtFive >= lexicalMetrics.recallAtFive)
        #expect(hybridMetrics.recallAtFive >= denseMetrics.recallAtFive)
        #expect(hybridMetrics.meanReciprocalRankAtTen >= lexicalMetrics.meanReciprocalRankAtTen)
        #expect(hybridMetrics.meanReciprocalRankAtTen >= denseMetrics.meanReciprocalRankAtTen)
    }

    @Test("Exact scoring stays interactive for ten thousand chunks")
    func exactScoringPerformance() {
        let dimension = LocalEmbeddingRunner.dimension
        let query = Array(repeating: Float(1) / sqrt(Float(dimension)), count: dimension)
        let entries = (0..<10_000).map { index in
            SourceVectorEntry(chunk: chunk(id: "\(index)"), vector: query)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let scores = SourceRetriever.exactScores(query: query, entries: entries)
        let elapsed = started.duration(to: clock.now)

        #expect(scores.count == 10_000)
        #expect(elapsed < .milliseconds(500))
    }

    private func makeIndex(root: URL, name: String, text: String) async throws -> SourceIndex {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let source = StudySource(url: url)
        return await SourceIndexBuilder.build(
            from: ExtractedSource(source: source, blocks: [.text(text)])
        )
    }

    private func chunk(id: String) -> SourceChunk {
        SourceChunk(
            id: id,
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sourceName: "fixture.md",
            locator: nil,
            headingPath: [],
            ordinal: Int(id) ?? 0,
            text: id,
            estimatedTokenCount: 1
        )
    }
}

private actor RecordingEmbeddingService: EmbeddingService {
    private(set) var prepareCount = 0
    private(set) var queryCount = 0
    private(set) var unloadCount = 0

    func prepare(
        events: nonisolated(nonsending) @escaping @Sendable (EmbeddingServiceEvent) async -> Void
    ) async throws {
        prepareCount += 1
        await events(.ready)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        queryCount += 1
        return [1]
    }

    func embedDocuments(_ documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documents.map { _ in [1] }
    }

    func unload() {
        unloadCount += 1
    }
}
