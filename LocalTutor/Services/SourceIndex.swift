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
    static let schemaVersion = 6

    var sourceID: UUID
    var sourceName: String
    var sourceKind: StudySourceKind
    var fingerprint: SourceFingerprint
    var parents: [SourceParentSection] = []
    var chunks: [SourceChunk]
    var warnings: [String]

    func rebased(to source: StudySource) -> SourceIndex {
        var copy = self
        copy.sourceID = source.id
        copy.sourceName = source.displayName
        copy.sourceKind = source.kind
        copy.parents = parents.map { parent in
            var parent = parent
            parent.sourceID = source.id
            parent.sourceName = source.displayName
            return parent
        }
        copy.chunks = chunks.map { chunk in
            var chunk = chunk
            chunk.sourceID = source.id
            chunk.sourceName = source.displayName
            return chunk
        }
        return copy
    }
}

enum SourceElementKind: String, Codable, Equatable, Sendable {
    case heading
    case paragraph
    case list
    case table
    case mixed
}

struct SourceLocatorRange: Codable, Equatable, Sendable {
    var raw: String?
    var startPage: Int?
    var endPage: Int?

    var displayValue: String? {
        if let startPage, let endPage, startPage != endPage {
            return "pages \(startPage)-\(endPage)"
        }
        if let startPage {
            return "page \(startPage)"
        }
        return raw
    }
}

struct SourceParentSection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceID: UUID
    var sourceName: String
    var locatorRange: SourceLocatorRange
    var headingPath: [String]
    var ordinal: Int
    var text: String
    var estimatedTokenCount: Int
}

struct SourceChunk: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceID: UUID
    var sourceName: String
    var locator: String?
    var locatorRange = SourceLocatorRange(raw: nil, startPage: nil, endPage: nil)
    var headingPath: [String]
    var parentID: String? = nil
    var elementKind: SourceElementKind = .paragraph
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
    static let targetChunkTokens = 600
    static let maximumChunkTokens = 800
    static let overlapTokens = 90
    static let parentExpansionLimit = 1_200

    static func build(from extracted: ExtractedSource) async -> SourceIndex {
        let units = extracted.blocks.compactMap { block -> SourceTextUnit? in
            guard case .text(let text) = block else { return nil }
            return SourceTextUnit.parse(text, sourceName: extracted.source.displayName)
        }
        let built = buildStructure(
            units: units,
            sourceID: extracted.source.id,
            sourceName: extracted.source.displayName
        )
        return SourceIndex(
            sourceID: extracted.source.id,
            sourceName: extracted.source.displayName,
            sourceKind: extracted.source.kind,
            fingerprint: SourceIndexStore.fingerprint(for: extracted.source),
            parents: built.parents,
            chunks: built.chunks,
            warnings: extracted.warnings
        )
    }

    static func buildChunks(
        units: [SourceTextUnit],
        sourceID: UUID,
        sourceName: String
    ) async -> [SourceChunk] {
        buildStructure(
            units: units,
            sourceID: sourceID,
            sourceName: sourceName
        ).chunks
    }

    private static func buildStructure(
        units: [SourceTextUnit],
        sourceID: UUID,
        sourceName: String
    ) -> (parents: [SourceParentSection], chunks: [SourceChunk]) {
        var headingStack: [SourceHeading] = []
        var sections: [SectionDraft] = []
        var current = SectionDraft(headingPath: [], lines: [], locators: [])

        func flushSection() {
            guard !current.lines.isEmpty else { return }
            sections.append(current)
            current = SectionDraft(
                headingPath: headingStack.map(\.displayTitle),
                lines: [],
                locators: []
            )
        }

        for unit in units {
            let lines = unit.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            for line in lines {
                guard !line.isEmpty else {
                    if !current.lines.isEmpty, current.lines.last != "" {
                        current.lines.append("")
                    }
                    continue
                }

                if let heading = SourceHeading.parse(line) {
                    flushSection()
                    headingStack.removeAll { $0.level >= heading.level }
                    headingStack.append(heading)
                    current.headingPath = headingStack.map(\.displayTitle)
                    current.lines.append(line)
                    if let locator = unit.locator {
                        current.locators.append(locator)
                    }
                    continue
                }

                current.lines.append(line)
                if let locator = unit.locator {
                    current.locators.append(locator)
                }
            }
        }

        flushSection()
        var parents: [SourceParentSection] = []
        var chunks: [SourceChunk] = []

        for (sectionIndex, section) in sections.enumerated() {
            let text = section.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let locatorRange = makeLocatorRange(section.locators)
            let parentID = stableID(
                sourceID: sourceID,
                namespace: "parent",
                ordinal: sectionIndex,
                text: text
            )
            parents.append(
                SourceParentSection(
                    id: parentID,
                    sourceID: sourceID,
                    sourceName: sourceName,
                    locatorRange: locatorRange,
                    headingPath: section.headingPath,
                    ordinal: sectionIndex + 1,
                    text: text,
                    estimatedTokenCount: PromptTokenEstimator.estimate(text)
                )
            )

            let pieces = recursivePieces(text)
            let windows = packedWindows(pieces)
            for window in windows {
                let ordinal = chunks.count + 1
                let chunkText = window.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                chunks.append(
                    SourceChunk(
                        id: stableID(
                            sourceID: sourceID,
                            namespace: parentID,
                            ordinal: ordinal,
                            text: chunkText
                        ),
                        sourceID: sourceID,
                        sourceName: sourceName,
                        locator: locatorRange.displayValue,
                        locatorRange: locatorRange,
                        headingPath: section.headingPath,
                        parentID: parentID,
                        elementKind: elementKind(for: chunkText),
                        ordinal: ordinal,
                        text: chunkText,
                        estimatedTokenCount: PromptTokenEstimator.estimate(chunkText)
                    )
                )
            }
        }

        return (parents, chunks)
    }

    private struct SectionDraft {
        var headingPath: [String]
        var lines: [String]
        var locators: [String]
    }

    private static func makeLocatorRange(_ locators: [String]) -> SourceLocatorRange {
        let unique = Array(NSOrderedSet(array: locators)).compactMap { $0 as? String }
        let pages = unique.compactMap(pageNumber(in:))
        return SourceLocatorRange(
            raw: unique.isEmpty ? nil : unique.joined(separator: " - "),
            startPage: pages.first,
            endPage: pages.last
        )
    }

    private static func recursivePieces(_ text: String) -> [String] {
        split(text, separators: ["\n\n", "\n", ". ", " "])
    }

    private static func split(_ text: String, separators: [String]) -> [String] {
        guard PromptTokenEstimator.estimate(text) > maximumChunkTokens,
              let separator = separators.first else {
            return [text]
        }
        let pieces = splitPreservingSeparator(text, separator: separator)
        guard pieces.count > 1 else {
            let characterLimit = PromptTokenEstimator.characterLimit(forTokenBudget: maximumChunkTokens)
            return stride(from: 0, to: text.count, by: characterLimit).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: min(characterLimit, text.distance(from: start, to: text.endIndex)))
                return String(text[start..<end])
            }
        }
        return pieces.flatMap { split($0, separators: Array(separators.dropFirst())) }
    }

    private static func splitPreservingSeparator(_ text: String, separator: String) -> [String] {
        guard !separator.isEmpty else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            if let range = text.range(of: separator, range: start..<text.endIndex) {
                let piece = String(text[start..<range.upperBound])
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pieces.append(piece)
                }
                start = range.upperBound
            } else {
                let piece = String(text[start..<text.endIndex])
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pieces.append(piece)
                }
                break
            }
        }
        return pieces
    }

    private static func packedWindows(_ pieces: [String]) -> [[String]] {
        var windows: [[String]] = []
        var current: [String] = []
        var tokens = 0

        for piece in pieces {
            let pieceTokens = PromptTokenEstimator.estimate(piece)
            if !current.isEmpty, tokens + pieceTokens > targetChunkTokens {
                windows.append(current)
                current = overlapSuffix(from: current)
                tokens = current.reduce(0) { $0 + PromptTokenEstimator.estimate($1) }
                if tokens + pieceTokens > maximumChunkTokens {
                    current.removeAll(keepingCapacity: true)
                    tokens = 0
                }
            }
            if pieceTokens > maximumChunkTokens {
                if !current.isEmpty {
                    windows.append(current)
                    current = []
                    tokens = 0
                }
                windows.append([piece])
            } else {
                current.append(piece)
                tokens += pieceTokens
            }
        }
        if !current.isEmpty {
            windows.append(current)
        }
        return windows
    }

    private static func overlapSuffix(from pieces: [String]) -> [String] {
        var result: [String] = []
        var tokens = 0
        for piece in pieces.reversed() {
            let count = PromptTokenEstimator.estimate(piece)
            guard tokens + count <= overlapTokens || result.isEmpty else { break }
            result.insert(piece, at: 0)
            tokens += count
        }
        return result
    }

    private static func elementKind(for text: String) -> SourceElementKind {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }) {
            return .list
        }
        if lines.count > 1, lines.allSatisfy({ $0.contains("|") || $0.contains("\t") || $0.contains(",") }) {
            return .table
        }
        if lines.first.map({ SourceHeading.parse($0) != nil }) == true, lines.count == 1 {
            return .heading
        }
        return lines.first.map({ SourceHeading.parse($0) != nil }) == true ? .mixed : .paragraph
    }

    private static func stableID(
        sourceID: UUID,
        namespace: String,
        ordinal: Int,
        text: String
    ) -> String {
        let value = "\(sourceID.uuidString)|\(namespace)|\(ordinal)|\(text)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private let repository: any SourceIndexRepository

    init(repository: any SourceIndexRepository = SQLiteSourceIndexRepository.shared) {
        self.repository = repository
    }

    func cachedIndex(for source: StudySource) async -> SourceIndex? {
        await repository.cachedIndex(for: source)
    }

    func store(_ index: SourceIndex) async {
        try? await repository.store(index, state: .lexicalOnly)
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

    static func digestHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
