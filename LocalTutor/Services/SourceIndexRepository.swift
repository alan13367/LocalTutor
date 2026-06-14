import Foundation
import SQLite3

enum SourceIndexState: String, Codable, Sendable {
    case lexicalOnly
    case embedding
    case ready
    case failed
}

struct SourceVectorEntry: Sendable {
    var chunk: SourceChunk
    var vector: [Float]
}

struct SourceIndexStatistics: Sendable {
    var documentCount: Int
    var chunkCount: Int
    var vectorCount: Int
    var diskBytes: Int64
}

protocol SourceIndexRepository: Sendable {
    func cachedIndex(for source: StudySource) async -> SourceIndex?
    func store(_ index: SourceIndex, state: SourceIndexState) async throws
    func lexicalSearch(query: String, fingerprints: [SourceFingerprint], limit: Int) async throws -> [SourceChunk]
    func vectorEntries(fingerprints: [SourceFingerprint]) async throws -> [SourceVectorEntry]
    func storeVectors(_ vectors: [String: [Float]], fingerprint: SourceFingerprint) async throws
    func updateState(_ state: SourceIndexState, fingerprint: SourceFingerprint) async throws
    func statistics() async -> SourceIndexStatistics
    func clear() async throws
}

actor SQLiteSourceIndexRepository: SourceIndexRepository {
    static let shared = SQLiteSourceIndexRepository()

    private let fileManager: FileManager
    private let databaseURL: URL?
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func cachedIndex(for source: StudySource) -> SourceIndex? {
        do {
            try openIfNeeded()
            let fingerprint = SourceIndexStore.fingerprint(for: source)
            guard let document = try documentRow(key: fingerprint.cacheKey),
                  document.chunkerVersion == SourceIndex.schemaVersion else {
                return nil
            }
            let parents = try loadParents(documentID: document.id)
            let chunks = try loadChunks(documentID: document.id)
            return SourceIndex(
                sourceID: source.id,
                sourceName: source.displayName,
                sourceKind: source.kind,
                fingerprint: fingerprint,
                parents: parents,
                chunks: chunks,
                warnings: document.warnings
            )
        } catch {
            return nil
        }
    }

    func store(_ index: SourceIndex, state: SourceIndexState = .lexicalOnly) throws {
        try openIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            let key = index.fingerprint.cacheKey
            try execute(
                "DELETE FROM documents WHERE source_id = ?",
                bindings: [.text(index.sourceID.uuidString)]
            )
            try execute(
                """
                INSERT INTO documents (
                    fingerprint_key, fingerprint_json, source_id, source_name, source_kind,
                    warnings_json, chunker_version, embedding_model_id,
                    embedding_prompt_version, vector_dimension, state
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(key),
                    .blob(try encoder.encode(index.fingerprint)),
                    .text(index.sourceID.uuidString),
                    .text(index.sourceName),
                    .text(index.sourceKind.rawValue),
                    .blob(try encoder.encode(index.warnings)),
                    .integer(Int64(SourceIndex.schemaVersion)),
                    .text(ModelCatalog.embeddingGemma300M.modelIdentifier),
                    .integer(Int64(LocalEmbeddingRunner.promptVersion)),
                    .integer(Int64(LocalEmbeddingRunner.dimension)),
                    .text(state.rawValue)
                ]
            )
            let documentID = sqlite3_last_insert_rowid(database)

            for parent in index.parents {
                try execute(
                    """
                    INSERT INTO parent_sections (
                        id, document_id, source_id, source_name, locator_raw,
                        start_page, end_page, heading_json, ordinal, text, token_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(parent.id),
                        .integer(documentID),
                        .text(parent.sourceID.uuidString),
                        .text(parent.sourceName),
                        .optionalText(parent.locatorRange.raw),
                        .optionalInteger(parent.locatorRange.startPage.map(Int64.init)),
                        .optionalInteger(parent.locatorRange.endPage.map(Int64.init)),
                        .blob(try encoder.encode(parent.headingPath)),
                        .integer(Int64(parent.ordinal)),
                        .text(parent.text),
                        .integer(Int64(parent.estimatedTokenCount))
                    ]
                )
            }

            for chunk in index.chunks {
                try execute(
                    """
                    INSERT INTO chunks (
                        id, document_id, source_id, source_name, locator, locator_raw,
                        start_page, end_page, heading, heading_json, parent_id,
                        element_kind, ordinal, text, token_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(chunk.id),
                        .integer(documentID),
                        .text(chunk.sourceID.uuidString),
                        .text(chunk.sourceName),
                        .optionalText(chunk.locator),
                        .optionalText(chunk.locatorRange.raw),
                        .optionalInteger(chunk.locatorRange.startPage.map(Int64.init)),
                        .optionalInteger(chunk.locatorRange.endPage.map(Int64.init)),
                        .text(chunk.headingPath.joined(separator: " > ")),
                        .blob(try encoder.encode(chunk.headingPath)),
                        .optionalText(chunk.parentID),
                        .text(chunk.elementKind.rawValue),
                        .integer(Int64(chunk.ordinal)),
                        .text(chunk.text),
                        .integer(Int64(chunk.estimatedTokenCount))
                    ]
                )
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func lexicalSearch(
        query: String,
        fingerprints: [SourceFingerprint],
        limit: Int
    ) throws -> [SourceChunk] {
        try openIfNeeded()
        let keys = fingerprints.map(\.cacheKey)
        guard !keys.isEmpty else { return [] }
        let terms = SourceRetriever.tokenize(query)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = """
            SELECT c.id, c.source_id, c.source_name, c.locator, c.locator_raw,
                   c.start_page, c.end_page, c.heading_json, c.parent_id,
                   c.element_kind, c.ordinal, c.text, c.token_count
            FROM chunk_fts
            JOIN chunks c ON c.rowid = chunk_fts.rowid
            JOIN documents d ON d.id = c.document_id
            WHERE chunk_fts MATCH ? AND d.fingerprint_key IN (\(placeholders))
            ORDER BY bm25(chunk_fts)
            LIMIT ?
            """
        var bindings: [SQLiteBinding] = [.text(match)]
        bindings.append(contentsOf: keys.map(SQLiteBinding.text))
        bindings.append(.integer(Int64(limit)))
        return try queryChunks(sql, bindings: bindings)
    }

    func vectorEntries(fingerprints: [SourceFingerprint]) throws -> [SourceVectorEntry] {
        try openIfNeeded()
        let keys = fingerprints.map(\.cacheKey)
        guard !keys.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = """
            SELECT c.id, c.source_id, c.source_name, c.locator, c.locator_raw,
                   c.start_page, c.end_page, c.heading_json, c.parent_id,
                   c.element_kind, c.ordinal, c.text, c.token_count, v.vector
            FROM chunk_vectors v
            JOIN chunks c ON c.id = v.chunk_id
            JOIN documents d ON d.id = c.document_id
            WHERE d.fingerprint_key IN (\(placeholders))
              AND v.model_id = ? AND v.prompt_version = ? AND v.dimension = ?
            """
        let bindings = keys.map(SQLiteBinding.text) + [
            .text(ModelCatalog.embeddingGemma300M.modelIdentifier),
            .integer(Int64(LocalEmbeddingRunner.promptVersion)),
            .integer(Int64(LocalEmbeddingRunner.dimension))
        ]
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var entries: [SourceVectorEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let chunk = try decodeChunk(statement)
            let data = columnData(statement, index: 13)
            entries.append(SourceVectorEntry(chunk: chunk, vector: data.floatArray))
        }
        return entries
    }

    func storeVectors(_ vectors: [String: [Float]], fingerprint: SourceFingerprint) throws {
        try openIfNeeded()
        try execute("BEGIN IMMEDIATE")
        do {
            for (chunkID, vector) in vectors {
                guard vector.count == LocalEmbeddingRunner.dimension else { continue }
                try execute(
                    """
                    INSERT OR REPLACE INTO chunk_vectors (
                        chunk_id, model_id, prompt_version, dimension, vector
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(chunkID),
                        .text(ModelCatalog.embeddingGemma300M.modelIdentifier),
                        .integer(Int64(LocalEmbeddingRunner.promptVersion)),
                        .integer(Int64(vector.count)),
                        .blob(Data(floatArray: vector))
                    ]
                )
            }
            try execute(
                """
                UPDATE documents
                SET state = ?, embedding_model_id = ?, embedding_prompt_version = ?, vector_dimension = ?
                WHERE fingerprint_key = ?
                """,
                bindings: [
                    .text(SourceIndexState.ready.rawValue),
                    .text(ModelCatalog.embeddingGemma300M.modelIdentifier),
                    .integer(Int64(LocalEmbeddingRunner.promptVersion)),
                    .integer(Int64(LocalEmbeddingRunner.dimension)),
                    .text(fingerprint.cacheKey)
                ]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func updateState(_ state: SourceIndexState, fingerprint: SourceFingerprint) throws {
        try openIfNeeded()
        try execute(
            "UPDATE documents SET state = ? WHERE fingerprint_key = ?",
            bindings: [.text(state.rawValue), .text(fingerprint.cacheKey)]
        )
    }

    func statistics() -> SourceIndexStatistics {
        do {
            try openIfNeeded()
            let documents = try scalarInt("SELECT COUNT(*) FROM documents")
            let chunks = try scalarInt("SELECT COUNT(*) FROM chunks")
            let vectors = try scalarInt("SELECT COUNT(*) FROM chunk_vectors")
            let url = try resolvedDatabaseURL()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return SourceIndexStatistics(
                documentCount: documents,
                chunkCount: chunks,
                vectorCount: vectors,
                diskBytes: size
            )
        } catch {
            return SourceIndexStatistics(documentCount: 0, chunkCount: 0, vectorCount: 0, diskBytes: 0)
        }
    }

    func clear() throws {
        try openIfNeeded()
        try execute("DELETE FROM documents")
        try execute("DELETE FROM chunk_fts")
        try execute("VACUUM")
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        let url = try resolvedDatabaseURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SQLiteRepositoryError.openFailed(url.path)
        }
        database = handle
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
        try createSchema()
        try removeLegacyJSONIndexes()
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY,
                fingerprint_key TEXT NOT NULL UNIQUE,
                fingerprint_json BLOB NOT NULL,
                source_id TEXT NOT NULL,
                source_name TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                warnings_json BLOB NOT NULL,
                chunker_version INTEGER NOT NULL,
                embedding_model_id TEXT NOT NULL,
                embedding_prompt_version INTEGER NOT NULL,
                vector_dimension INTEGER NOT NULL,
                state TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS parent_sections (
                id TEXT PRIMARY KEY,
                document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                source_name TEXT NOT NULL,
                locator_raw TEXT,
                start_page INTEGER,
                end_page INTEGER,
                heading_json BLOB NOT NULL,
                ordinal INTEGER NOT NULL,
                text TEXT NOT NULL,
                token_count INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chunks (
                rowid INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                source_name TEXT NOT NULL,
                locator TEXT,
                locator_raw TEXT,
                start_page INTEGER,
                end_page INTEGER,
                heading TEXT NOT NULL,
                heading_json BLOB NOT NULL,
                parent_id TEXT,
                element_kind TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                text TEXT NOT NULL,
                token_count INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
                text, heading, source_name, locator,
                content='chunks', content_rowid='rowid', tokenize='unicode61'
            )
            """
        )
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunk_fts(rowid, text, heading, source_name, locator)
                VALUES (new.rowid, new.text, new.heading, new.source_name, new.locator);
            END
            """
        )
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunk_fts(chunk_fts, rowid, text, heading, source_name, locator)
                VALUES ('delete', old.rowid, old.text, old.heading, old.source_name, old.locator);
            END
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chunk_vectors (
                chunk_id TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS chunks_document_ordinal ON chunks(document_id, ordinal)")
    }

    private func resolvedDatabaseURL() throws -> URL {
        if let databaseURL {
            return databaseURL
        }
        if ProcessInfo.processInfo.isRunningLocalTutorTests {
            return fileManager.temporaryDirectory
                .appendingPathComponent("LocalTutorTests-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("source-index.sqlite3")
        }
        return try AppDirectories.sourceIndexes(fileManager: fileManager)
            .appendingPathComponent("source-index.sqlite3")
    }

    private func removeLegacyJSONIndexes() throws {
        guard !ProcessInfo.processInfo.isRunningLocalTutorTests else { return }
        let directory = try AppDirectories.sourceIndexes(fileManager: fileManager)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    private struct DocumentRow {
        var id: Int64
        var fingerprint: SourceFingerprint
        var warnings: [String]
        var chunkerVersion: Int
    }

    private func documentRow(key: String) throws -> DocumentRow? {
        let statement = try prepare(
            "SELECT id, fingerprint_json, warnings_json, chunker_version FROM documents WHERE fingerprint_key = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(key)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return DocumentRow(
            id: sqlite3_column_int64(statement, 0),
            fingerprint: try decoder.decode(SourceFingerprint.self, from: columnData(statement, index: 1)),
            warnings: try decoder.decode([String].self, from: columnData(statement, index: 2)),
            chunkerVersion: Int(sqlite3_column_int64(statement, 3))
        )
    }

    private func loadParents(documentID: Int64) throws -> [SourceParentSection] {
        let statement = try prepare(
            """
            SELECT id, source_id, source_name, locator_raw, start_page, end_page,
                   heading_json, ordinal, text, token_count
            FROM parent_sections WHERE document_id = ? ORDER BY ordinal
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind([.integer(documentID)], to: statement)
        var result: [SourceParentSection] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                SourceParentSection(
                    id: columnString(statement, index: 0),
                    sourceID: UUID(uuidString: columnString(statement, index: 1)) ?? UUID(),
                    sourceName: columnString(statement, index: 2),
                    locatorRange: SourceLocatorRange(
                        raw: optionalColumnString(statement, index: 3),
                        startPage: optionalColumnInt(statement, index: 4),
                        endPage: optionalColumnInt(statement, index: 5)
                    ),
                    headingPath: try decoder.decode([String].self, from: columnData(statement, index: 6)),
                    ordinal: Int(sqlite3_column_int64(statement, 7)),
                    text: columnString(statement, index: 8),
                    estimatedTokenCount: Int(sqlite3_column_int64(statement, 9))
                )
            )
        }
        return result
    }

    private func loadChunks(documentID: Int64) throws -> [SourceChunk] {
        try queryChunks(
            """
            SELECT id, source_id, source_name, locator, locator_raw, start_page,
                   end_page, heading_json, parent_id, element_kind, ordinal, text, token_count
            FROM chunks WHERE document_id = ? ORDER BY ordinal
            """,
            bindings: [.integer(documentID)]
        )
    }

    private func queryChunks(_ sql: String, bindings: [SQLiteBinding]) throws -> [SourceChunk] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var chunks: [SourceChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chunks.append(try decodeChunk(statement))
        }
        return chunks
    }

    private func decodeChunk(_ statement: OpaquePointer?) throws -> SourceChunk {
        SourceChunk(
            id: columnString(statement, index: 0),
            sourceID: UUID(uuidString: columnString(statement, index: 1)) ?? UUID(),
            sourceName: columnString(statement, index: 2),
            locator: optionalColumnString(statement, index: 3),
            locatorRange: SourceLocatorRange(
                raw: optionalColumnString(statement, index: 4),
                startPage: optionalColumnInt(statement, index: 5),
                endPage: optionalColumnInt(statement, index: 6)
            ),
            headingPath: try decoder.decode([String].self, from: columnData(statement, index: 7)),
            parentID: optionalColumnString(statement, index: 8),
            elementKind: SourceElementKind(rawValue: columnString(statement, index: 9)) ?? .paragraph,
            ordinal: Int(sqlite3_column_int64(statement, 10)),
            text: columnString(statement, index: 11),
            estimatedTokenCount: Int(sqlite3_column_int64(statement, 12))
        )
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        return statement
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE || sqlite3_column_count(statement) > 0 else {
            throw currentError()
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqliteTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
    }

    private func currentError() -> SQLiteRepositoryError {
        SQLiteRepositoryError.operationFailed(
            database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        )
    }
}

private enum SQLiteBinding {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null

    static func optionalText(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.text) ?? .null
    }

    static func optionalInteger(_ value: Int64?) -> SQLiteBinding {
        value.map(SQLiteBinding.integer) ?? .null
    }
}

private enum SQLiteRepositoryError: LocalizedError {
    case openFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            "Could not open the source index at \(path)."
        case .operationFailed(let message):
            "Source index operation failed: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
}

private func optionalColumnString(_ statement: OpaquePointer?, index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnString(statement, index: index)
}

private func optionalColumnInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
        ? nil
        : Int(sqlite3_column_int64(statement, index))
}

private func columnData(_ statement: OpaquePointer?, index: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: count)
}

private extension Data {
    init(floatArray: [Float]) {
        self = floatArray.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var floatArray: [Float] {
        withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }
}

extension SourceFingerprint {
    var cacheKey: String {
        let raw = "\(schemaVersion)|\(url)|\(bookmarkID ?? "")|\(fileSize ?? -1)|\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        return SourceIndexStore.digestHex(Data(raw.utf8))
    }
}

extension ProcessInfo {
    var isRunningLocalTutorTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING"] != nil
    }
}
