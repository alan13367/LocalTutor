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
    static let schemaVersion = 2

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

    static func build(from extracted: ExtractedSource) -> SourceIndex {
        let units = extracted.blocks.compactMap { block -> SourceTextUnit? in
            guard case .text(let text) = block else { return nil }
            return SourceTextUnit.parse(text, sourceName: extracted.source.displayName)
        }
        let chunks = buildChunks(
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
    ) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        var headingStack: [SourceHeading] = []
        var buffer: [String] = []
        var locators: [String] = []
        var ordinal = 0

        func flush() {
            let text = buffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                buffer.removeAll()
                locators.removeAll()
                return
            }

            ordinal += 1
            chunks.append(
                SourceChunk(
                    id: "\(sourceID.uuidString)-\(ordinal)",
                    sourceID: sourceID,
                    sourceName: sourceName,
                    locator: mergedLocator(locators),
                    headingPath: headingStack.map(\.displayTitle),
                    ordinal: ordinal,
                    text: text,
                    estimatedTokenCount: PromptTokenEstimator.estimate(text)
                )
            )
            buffer.removeAll()
            locators.removeAll()
        }

        for unit in units {
            let lines = unit.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            for line in lines {
                guard !line.isEmpty else {
                    if !buffer.isEmpty {
                        buffer.append("")
                    }
                    continue
                }

                if let heading = SourceHeading.parse(line) {
                    flush()
                    headingStack.removeAll { $0.level >= heading.level }
                    headingStack.append(heading)
                    buffer.append(line)
                    if let locator = unit.locator {
                        locators.append(locator)
                    }
                    continue
                }

                buffer.append(line)
                if let locator = unit.locator {
                    locators.append(locator)
                }

                if PromptTokenEstimator.estimate(buffer.joined(separator: "\n")) >= targetChunkTokens {
                    flush()
                }
            }
        }

        flush()
        return chunks
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
        let pattern = #"\bpage\s+(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
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
        let pattern = #"^(#{1,6})\s+(.+?)\s*#*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
        let pattern = #"^(\d+(?:\.\d+)*)\s+([^\d].{1,120})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
}

enum PromptTokenEstimator {
    static let charactersPerToken = 3

    static func estimate(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, (trimmed.count + charactersPerToken - 1) / charactersPerToken)
    }

    static func characterLimit(forTokenBudget budget: Int) -> Int {
        max(1, budget) * charactersPerToken
    }
}

actor SourceIndexStore {
    static let shared = SourceIndexStore()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func cachedIndex(for source: StudySource) -> SourceIndex? {
        let fingerprint = Self.fingerprint(for: source)
        let url = cacheURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder.localTutorSourceIndex.decode(SourceIndex.self, from: data),
              index.fingerprint == fingerprint else {
            return nil
        }
        return index
    }

    func store(_ index: SourceIndex) {
        let url = cacheURL(for: index.fingerprint)
        do {
            let data = try JSONEncoder.localTutorSourceIndex.encode(index)
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

private extension JSONEncoder {
    static var localTutorSourceIndex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var localTutorSourceIndex: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
