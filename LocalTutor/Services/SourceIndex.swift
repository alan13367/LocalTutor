//
//  SourceIndex.swift
//  LocalTutor
//

import CryptoKit
import Foundation

struct SourceFingerprint: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var url: String
    var bookmarkID: String?
    var fileSize: Int64?
    var modifiedAt: Date?
}

struct SourceIndex: Codable, Equatable, Sendable {
    static let schemaVersion = 3

    var sourceID: UUID
    var sourceName: String
    var sourceKind: StudySourceKind
    var fingerprint: SourceFingerprint
    var chunks: [SourceChunk]
    var warnings: [String]

    func rebased(to source: StudySource) -> SourceIndex {
        var copy = self
        copy.sourceID = source.id
        copy.sourceName = source.displayName
        copy.sourceKind = source.kind
        copy.chunks = chunks.map { chunk in
            var chunk = chunk
            chunk.sourceID = source.id
            chunk.sourceName = source.displayName
            return chunk
        }
        return copy
    }
}

struct SourceChunk: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceID: UUID
    var sourceName: String
    var locator: String?
    var headingPath: [String]
    var ordinal: Int
    var text: String
    var estimatedTokenCount: Int
    var embedding: [Float]?

    var headingTitle: String? {
        headingPath.last
    }

    var displayLocator: String {
        var parts: [String] = [sourceName]
        if let locator, !locator.isEmpty {
            parts.append(locator)
        }
        if !headingPath.isEmpty {
            parts.append(headingPath.joined(separator: " > "))
        }
        return parts.joined(separator: " | ")
    }
}

enum SourceIndexBuilder {
    static let targetChunkTokens = 700

    static func build(from extracted: ExtractedSource) async -> SourceIndex {
        let units = extracted.blocks.compactMap { block -> SourceTextUnit? in
            guard case .text(let text) = block else { return nil }
            return SourceTextUnit.parse(text, sourceName: extracted.source.displayName)
        }
        let chunks = await buildChunks(
            units: units,
            sourceID: extracted.source.id,
            sourceName: extracted.source.displayName
        )
        return SourceIndex(
            sourceID: extracted.source.id,
            sourceName: extracted.source.displayName,
            sourceKind: extracted.source.kind,
            fingerprint: SourceIndexStore.fingerprint(for: extracted.source),
            chunks: chunks,
            warnings: extracted.warnings
        )
    }

    static func buildChunks(
        units: [SourceTextUnit],
        sourceID: UUID,
        sourceName: String
    ) async -> [SourceChunk] {
        var headingStack: [SourceHeading] = []
        var bufferText = ""
        var locators: [String] = []
        var ordinal = 0

        // In order to use await inside flush, we need to collect chunks asynchronously or await inline.
        // Actually, to make the logic simple without changing the whole parser loop:
        // We can just construct a temporary list of chunks, and then compute embeddings for them at the end.
        // Or we can do it inside flush if flush is refactored, but it's a local function.
        // Swift allows async closures but local functions can be async.
        
        // We'll collect chunk data first, then compute embeddings.
        struct ChunkData {
            var locator: String?
            var headingPath: [String]
            var ordinal: Int
            var text: String
            var estimatedTokenCount: Int
        }
        var pendingChunks: [ChunkData] = []
        
        func flush() {
            let text = bufferText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                bufferText.removeAll(keepingCapacity: true)
                locators.removeAll()
                return
            }

            ordinal += 1
            pendingChunks.append(
                ChunkData(
                    locator: mergedLocator(locators),
                    headingPath: headingStack.map(\.displayTitle),
                    ordinal: ordinal,
                    text: text,
                    estimatedTokenCount: PromptTokenEstimator.estimate(text)
                )
            )
            bufferText.removeAll(keepingCapacity: true)
            locators.removeAll()
        }

        func appendLine(_ line: String) {
            if bufferText.isEmpty {
                bufferText = line
            } else {
                bufferText.append("\n")
                bufferText.append(line)
            }
        }

        for unit in units {
            let lines = unit.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            for line in lines {
                guard !line.isEmpty else {
                    if !bufferText.isEmpty {
                        bufferText.append("\n")
                    }
                    continue
                }

                if let heading = SourceHeading.parse(line) {
                    flush()
                    headingStack.removeAll { $0.level >= heading.level }
                    headingStack.append(heading)
                    appendLine(line)
                    if let locator = unit.locator {
                        locators.append(locator)
                    }
                    continue
                }

                appendLine(line)
                if let locator = unit.locator {
                    locators.append(locator)
                }

                if PromptTokenEstimator.estimateNonEmptyTrimmedCharacterCount(bufferText.count) >= targetChunkTokens {
                    flush()
                }
            }
        }

        flush()
        
        // Generate embeddings concurrently for all chunks
        let embeddings = await withTaskGroup(of: (Int, [Float]?).self) { group in
            for (index, pending) in pendingChunks.enumerated() {
                group.addTask {
                    let searchableText = pending.text + " " + pending.headingPath.joined(separator: " ")
                    let embedding = try? await LocalEmbeddingRunner.shared.embed(text: searchableText)
                    return (index, embedding)
                }
            }

            var results = [Int: [Float]?]()
            for await (index, embedding) in group {
                results[index] = embedding
            }
            return results
        }

        var finalChunks: [SourceChunk] = []
        finalChunks.reserveCapacity(pendingChunks.count)
        for (index, pending) in pendingChunks.enumerated() {
            finalChunks.append(
                SourceChunk(
                    id: "\(sourceID.uuidString)-\(pending.ordinal)",
                    sourceID: sourceID,
                    sourceName: sourceName,
                    locator: pending.locator,
                    headingPath: pending.headingPath,
                    ordinal: pending.ordinal,
                    text: pending.text,
                    estimatedTokenCount: pending.estimatedTokenCount,
                    embedding: embeddings[index] ?? nil
                )
            )
        }

        return finalChunks
    }

    private static func mergedLocator(_ locators: [String]) -> String? {
        let unique = Array(NSOrderedSet(array: locators)).compactMap { $0 as? String }
        guard let first = unique.first else { return nil }
        if unique.count == 1 {
            return first
        }
        if let firstPage = pageNumber(in: first),
           let lastPage = unique.compactMap(pageNumber(in:)).last,
           firstPage != lastPage {
            return "pages \(firstPage)-\(lastPage)"
        }
        return "\(first) - \(unique.last ?? first)"
    }

    private static func pageNumber(in locator: String) -> Int? {
        guard let regex = pageNumberRegex else {
            return nil
        }
        let range = NSRange(locator.startIndex..<locator.endIndex, in: locator)
        guard let match = regex.firstMatch(in: locator, range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: locator) else {
            return nil
        }
        return Int(locator[numberRange])
    }

    private static let pageNumberRegex = try? NSRegularExpression(
        pattern: #"\bpage\s+(\d+)\b"#,
        options: [.caseInsensitive]
    )
}

struct SourceTextUnit: Equatable, Sendable {
    var locator: String?
    var text: String

    static func parse(_ raw: String, sourceName: String) -> SourceTextUnit {
        var lines = raw.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.hasPrefix("==="),
              first.hasSuffix("===") else {
            return SourceTextUnit(locator: nil, text: raw)
        }

        lines.removeFirst()
        let header = first
            .trimmingCharacters(in: CharacterSet(charactersIn: "= "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let locator = header
            .replacingOccurrences(of: sourceName, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceTextUnit(
            locator: locator.isEmpty ? nil : locator,
            text: lines.joined(separator: "\n")
        )
    }
}

struct SourceHeading: Equatable, Sendable {
    var number: String
    var title: String

    var level: Int {
        if number.allSatisfy({ $0 == "#" }) {
            return number.count
        }
        return number.split(separator: ".").count
    }

    var displayTitle: String {
        "\(number) \(title)"
    }

    static func parse(_ line: String) -> SourceHeading? {
        if let heading = parseMarkdownHeading(line) {
            return heading
        }
        return parseNumberedHeading(line)
    }

    private static func parseMarkdownHeading(_ line: String) -> SourceHeading? {
        guard let regex = markdownHeadingRegex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 3,
              let markerRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let title = String(line[titleRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        return SourceHeading(number: String(line[markerRange]), title: title)
    }

    private static func parseNumberedHeading(_ line: String) -> SourceHeading? {
        guard let regex = numberedHeadingRegex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 3,
              let numberRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.hasSuffix(".") else { return nil }
        return SourceHeading(number: String(line[numberRange]), title: title)
    }

    private static let markdownHeadingRegex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.+?)\s*#*$"#)
    private static let numberedHeadingRegex = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)*)\s+([^\d].{1,120})$"#)
}

enum PromptTokenEstimator {
    static let charactersPerToken = 3

    static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return estimateNonEmptyTrimmedCharacterCount(trimmed.count)
    }

    static func estimateNonEmptyTrimmedCharacterCount(_ count: Int) -> Int {
        max(1, (count + charactersPerToken - 1) / charactersPerToken)
    }

    static func characterLimit(forTokenBudget budget: Int) -> Int {
        max(1, budget) * charactersPerToken
    }
}

actor SourceIndexStore {
    static let shared = SourceIndexStore()

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "NaN")
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "NaN")
        self.decoder = decoder
    }

    func cachedIndex(for source: StudySource) -> SourceIndex? {
        let fingerprint = Self.fingerprint(for: source)
        let url = cacheURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let index = try? decoder.decode(SourceIndex.self, from: data),
              index.fingerprint == fingerprint else {
            return nil
        }
        return index
    }

    func store(_ index: SourceIndex) {
        let url = cacheURL(for: index.fingerprint)
        do {
            let data = try encoder.encode(index)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Source indexes are disposable caches; failed writes should not
            // interrupt the study flow.
        }
    }

    static func fingerprint(for source: StudySource) -> SourceFingerprint {
        let url = source.accessibleURL
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SourceFingerprint(
            schemaVersion: SourceIndex.schemaVersion,
            url: url.absoluteString,
            bookmarkID: source.bookmarkData.map(Self.digestHex),
            fileSize: values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate
        )
    }

    private func cacheURL(for fingerprint: SourceFingerprint) -> URL {
        let directory = (try? AppDirectories.sourceIndexes(fileManager: fileManager))
            ?? fileManager.temporaryDirectory
        return directory.appendingPathComponent(cacheKey(for: fingerprint)).appendingPathExtension("json")
    }

    private func cacheKey(for fingerprint: SourceFingerprint) -> String {
        let raw = "\(fingerprint.schemaVersion)|\(fingerprint.url)|\(fingerprint.bookmarkID ?? "")|\(fingerprint.fileSize ?? -1)|\(fingerprint.modifiedAt?.timeIntervalSince1970 ?? 0)"
        return Self.digestHex(Data(raw.utf8))
    }

    private static func digestHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
