//
//  SourceRetrieval.swift
//  LocalTutor
//

import Foundation

struct SourcePromptContext: Sendable {
    var title: String
    var blocks: [StudyPromptContent.Block]
    var warnings: [String]
    var includedImageCount: Int
    var omittedImageCount: Int
    var imageFilenames: [String]
    var omittedTextChunkCount: Int
}

struct SourceRetrievalResult: Sendable {
    var chunks: [SourceChunk]
    var matchedHeading: String?
}

enum SourceRetriever {
    private static let tokenCache = SourceTokenCache()

    static func retrieve(query: String, indexes: [SourceIndex]) -> SourceRetrievalResult {
        let allChunks = indexes.flatMap(\.chunks)
        let queryTerms = tokenize(query)
        if let matchedHeading = bestHeadingMatch(query: query, queryTerms: queryTerms, chunks: allChunks) {
            let headingMatches = allChunks.filter { $0.headingPath.contains(matchedHeading) }
            return SourceRetrievalResult(
                chunks: headingMatches.sorted(by: sourceOrder),
                matchedHeading: matchedHeading
            )
        }

        let scored = bm25(queryTerms: queryTerms, chunks: allChunks)
        let chunks = scored
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return sourceOrder(lhs.chunk, rhs.chunk)
                }
                return lhs.score > rhs.score
            }
            .map(\.chunk)

        return SourceRetrievalResult(chunks: chunks.isEmpty ? allChunks.sorted(by: sourceOrder) : chunks, matchedHeading: nil)
    }

    static func tokenize(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "about", "can", "could", "from", "for",
            "in", "is", "it", "me", "my", "of", "on", "or", "please",
            "section", "summarize", "summary", "the", "this", "to", "what",
            "who", "with", "you"
        ]
        return text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { ($0.count > 1 || $0.allSatisfy(\.isNumber)) && !stopwords.contains($0) }
    }

    private static func bestHeadingMatch(query: String, queryTerms: [String], chunks: [SourceChunk]) -> String? {
        let querySet = Set(queryTerms)
        guard !querySet.isEmpty else { return nil }

        var best: (heading: String, overlap: Int, coverage: Double, level: Int)?
        let lowercasedQuery = query.lowercased()
        let hasSectionCue = ["section", "chapter", "heading", "phase", "part", "step"].contains { lowercasedQuery.contains($0) }
        let headings = chunks
            .flatMap(\.headingPath)
            .reduce(into: [String]()) { result, heading in
                if !result.contains(heading) {
                    result.append(heading)
                }
            }

        if let exactMatch = exactNumberedHeadingMatch(query: lowercasedQuery, headings: headings) {
            return exactMatch
        }

        for heading in headings {
            let headingTerms = Set(tokenize(heading))
            guard !headingTerms.isEmpty else { continue }
            let overlap = headingTerms.intersection(querySet).count
            guard overlap > 0 else { continue }

            let coverage = Double(overlap) / Double(headingTerms.count)
            let level = heading.split(separator: " ").first?.split(separator: ".").count ?? 1
            let isExplicitSectionMatch = hasSectionCue && coverage >= 0.5
            let isStrongHeadingMatch = overlap >= 2 && coverage >= 0.5
            guard isExplicitSectionMatch || isStrongHeadingMatch else { continue }
            if let current = best {
                if overlap > current.overlap ||
                    (overlap == current.overlap && coverage > current.coverage) ||
                    (overlap == current.overlap && coverage == current.coverage && level < current.level) {
                    best = (heading, overlap, coverage, level)
                }
            } else {
                best = (heading, overlap, coverage, level)
            }
        }

        return best?.heading
    }

    private static func exactNumberedHeadingMatch(query: String, headings: [String]) -> String? {
        let requested = numberedReferences(in: query)
        guard !requested.isEmpty else { return nil }

        for request in requested {
            if let heading = headings.first(where: { heading in
                headingMatches(numberedReference: request, heading: heading)
            }) {
                return heading
            }
        }

        return nil
    }

    private static func numberedReferences(in query: String) -> [(label: String, number: String)] {
        guard let regex = numberedReferenceRegex else {
            return []
        }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        return regex.matches(in: query, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let labelRange = Range(match.range(at: 1), in: query),
                  let numberRange = Range(match.range(at: 2), in: query) else {
                return nil
            }
            return (String(query[labelRange]).lowercased(), String(query[numberRange]))
        }
    }

    private static func headingMatches(
        numberedReference reference: (label: String, number: String),
        heading: String
    ) -> Bool {
        let normalized = normalizeHeading(heading)
        let escapedLabel = NSRegularExpression.escapedPattern(for: reference.label)
        let escapedNumber = NSRegularExpression.escapedPattern(for: reference.number)
        let labelPattern = #"\b\#(escapedLabel)\s+\#(escapedNumber)\b"#
        if normalized.range(of: labelPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        guard reference.label == "section" else {
            return false
        }
        let numberedSectionPattern = #"^\#(escapedNumber)(?:\s|\b)"#
        return normalized.range(of: numberedSectionPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func normalizeHeading(_ heading: String) -> String {
        var normalized = heading.lowercased()
        if let markdownHeadingPrefixRegex {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            normalized = markdownHeadingPrefixRegex.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: ""
            )
        }
        if let whitespaceRegex {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            normalized = whitespaceRegex.stringByReplacingMatches(
                in: normalized,
                range: range,
                withTemplate: " "
            )
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bm25(queryTerms: [String], chunks: [SourceChunk]) -> [(chunk: SourceChunk, score: Double)] {
        guard !queryTerms.isEmpty, !chunks.isEmpty else {
            return chunks.map { ($0, 0) }
        }

        let tokenized = chunks.map(tokenData)
        let docCount = Double(chunks.count)
        let averageLength = max(1.0, Double(tokenized.reduce(0) { $0 + $1.terms.count }) / docCount)
        var documentFrequency: [String: Int] = [:]
        for data in tokenized {
            for term in data.uniqueTerms {
                documentFrequency[term, default: 0] += 1
            }
        }

        let k1 = 1.5
        let b = 0.75
        return chunks.enumerated().map { index, chunk in
            let data = tokenized[index]
            let length = Double(max(1, data.terms.count))
            let score = queryTerms.reduce(0.0) { total, term in
                let frequency = Double(data.counts[term, default: 0])
                guard frequency > 0 else { return total }
                let df = Double(documentFrequency[term, default: 0])
                let idf = log((docCount - df + 0.5) / (df + 0.5) + 1)
                let denominator = frequency + k1 * (1 - b + b * (length / averageLength))
                return total + idf * ((frequency * (k1 + 1)) / denominator)
            }
            return (chunk, score)
        }
    }

    private static func tokenData(for chunk: SourceChunk) -> SourceTokenData {
        let searchableText = chunk.text + " " + chunk.headingPath.joined(separator: " ")
        // hashValue is randomised per process — fine for this in-memory-only cache.
        let key = SourceTokenCache.Key(
            chunkID: chunk.id,
            estimatedTokenCount: chunk.estimatedTokenCount,
            textCount: searchableText.count,
            textHash: searchableText.hashValue
        )
        return tokenCache.value(for: key) {
            let terms = tokenize(searchableText)
            return SourceTokenData(
                terms: terms,
                counts: Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +),
                uniqueTerms: Set(terms)
            )
        }
    }

    private static func sourceOrder(_ lhs: SourceChunk, _ rhs: SourceChunk) -> Bool {
        if lhs.sourceName == rhs.sourceName {
            return lhs.ordinal < rhs.ordinal
        }
        return lhs.sourceName < rhs.sourceName
    }

    private static let numberedReferenceRegex = try? NSRegularExpression(
        pattern: #"\b(phase|section|chapter|part|step)\s+(\d+(?:\.\d+)*)\b"#,
        options: [.caseInsensitive]
    )
    private static let markdownHeadingPrefixRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    private static let whitespaceRegex = try? NSRegularExpression(pattern: #"\s+"#)
}

private struct SourceTokenData {
    var terms: [String]
    var counts: [String: Int]
    var uniqueTerms: Set<String>
}

private final class SourceTokenCache: @unchecked Sendable {
    struct Key: Hashable {
        var chunkID: String
        var estimatedTokenCount: Int
        var textCount: Int
        var textHash: Int
    }

    private let lock = NSLock()
    private var values: [Key: SourceTokenData] = [:]

    // Concurrent callers may compute the same key in parallel (benign duplication);
    // the cache is a pure performance optimisation with no correctness requirements.
    func value(for key: Key, make: () -> SourceTokenData) -> SourceTokenData {
        lock.lock()
        if let value = values[key] {
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = make()

        lock.lock()
        if values.count >= 2_000 {
            values.removeAll(keepingCapacity: true)
        }
        values[key] = value
        lock.unlock()
        return value
    }
}

enum PromptPacker {
    static func promptBudget(for profile: ModelProfile, resourceKind: StudyResourceKind) -> Int {
        let policy = ModelRuntimePolicyProvider.policy(for: profile)
        return promptBudget(for: policy, resourceKind: resourceKind)
    }

    static func promptBudget(for runtimePolicy: ModelRuntimePolicy, resourceKind: StudyResourceKind) -> Int {
        runtimePolicy.sourceTokenBudget(for: resourceKind)
    }

    static func canPreserveCoverage(_ chunks: [SourceChunk], budget: Int) -> Bool {
        let total = totalTokenEstimate(chunks)
        guard total > budget else { return true }
        return total <= 8_000 && total <= Int(Double(budget) * 12)
    }

    static func pack(_ chunks: [SourceChunk], budget: Int) -> (chunks: [SourceChunk], omitted: Int) {
        var remaining = budget
        var selected: [SourceChunk] = []
        for chunk in chunks {
            guard chunk.estimatedTokenCount <= remaining || selected.isEmpty else {
                continue
            }
            if chunk.estimatedTokenCount <= remaining {
                selected.append(chunk)
                remaining -= chunk.estimatedTokenCount
            } else {
                selected.append(trimmed(chunk, toTokenBudget: remaining))
                remaining = 0
            }
            if remaining <= 0 {
                break
            }
        }
        return (selected, max(0, chunks.count - selected.count))
    }

    static func packForCoverage(
        _ chunks: [SourceChunk],
        budget: Int
    ) -> (chunks: [SourceChunk], compactedChunkCount: Int) {
        guard !chunks.isEmpty else { return ([], 0) }
        let total = totalTokenEstimate(chunks)
        guard total > budget else { return (chunks, 0) }

        let allocations = proportionalAllocations(for: chunks, budget: budget)
        var compacted = 0
        let packed = chunks.enumerated().map { index, chunk in
            let tokenBudget = allocations[index]
            guard chunk.estimatedTokenCount > tokenBudget else {
                return chunk
            }
            compacted += 1
            return trimmed(chunk, toTokenBudget: tokenBudget)
        }
        return (packed, compacted)
    }

    static func packForOverview(
        _ chunks: [SourceChunk],
        budget: Int
    ) -> (chunks: [SourceChunk], omitted: Int) {
        guard !chunks.isEmpty else { return ([], 0) }
        let grouped = Dictionary(grouping: chunks, by: \.sourceID)
        let sourceIDs = chunks.map(\.sourceID).reduce(into: [UUID]()) { result, sourceID in
            if !result.contains(sourceID) {
                result.append(sourceID)
            }
        }
        let sourceBudget = max(1, budget / max(1, sourceIDs.count))
        var selected: [SourceChunk] = []

        for sourceID in sourceIDs {
            let sourceChunks = (grouped[sourceID] ?? []).sorted { $0.ordinal < $1.ordinal }
            let slotCount = min(sourceChunks.count, max(1, sourceBudget / 140))
            let tokenBudget = max(1, sourceBudget / max(1, slotCount))

            for index in representativeIndexes(count: sourceChunks.count, slots: slotCount) {
                let chunk = sourceChunks[index]
                selected.append(
                    chunk.estimatedTokenCount > tokenBudget
                        ? trimmed(chunk, toTokenBudget: tokenBudget)
                        : chunk
                )
            }
        }

        selected.sort {
            if $0.sourceName == $1.sourceName {
                return $0.ordinal < $1.ordinal
            }
            return $0.sourceName < $1.sourceName
        }
        return (selected, max(0, chunks.count - selected.count))
    }

    static func fits(_ chunks: [SourceChunk], budget: Int) -> Bool {
        totalTokenEstimate(chunks) <= budget
    }

    private static func representativeIndexes(count: Int, slots: Int) -> [Int] {
        guard count > 0, slots > 0 else { return [] }
        guard slots < count else { return Array(0..<count) }
        guard slots > 1 else { return [0] }

        var indexes: [Int] = []
        for position in 0..<slots {
            let raw = Double(position) * Double(count - 1) / Double(slots - 1)
            let index = min(count - 1, max(0, Int(raw.rounded())))
            if !indexes.contains(index) {
                indexes.append(index)
            }
        }

        var candidate = 0
        while indexes.count < slots, candidate < count {
            if !indexes.contains(candidate) {
                indexes.append(candidate)
            }
            candidate += 1
        }
        return indexes.sorted()
    }

    private static func totalTokenEstimate(_ chunks: [SourceChunk]) -> Int {
        chunks.reduce(0) { $0 + $1.estimatedTokenCount }
    }

    private static func proportionalAllocations(for chunks: [SourceChunk], budget: Int) -> [Int] {
        let total = max(1, totalTokenEstimate(chunks))
        let floor = chunks.count > budget
            ? 1
            : max(1, min(120, budget / max(1, chunks.count * 2)))
        var allocations = chunks.map { chunk in
            min(chunk.estimatedTokenCount, max(floor, Int((Double(chunk.estimatedTokenCount) / Double(total) * Double(budget)).rounded(.down))))
        }

        var allocationTotal = allocations.reduce(0, +)

        while allocationTotal > budget,
              let index = allocations.indices.max(by: { allocations[$0] < allocations[$1] }),
              allocations[index] > 1 {
            let excess = allocationTotal - budget
            let reducible = max(1, allocations[index] - 1)
            let reduction = min(excess, reducible)
            allocations[index] -= reduction
            allocationTotal -= reduction
        }

        while allocationTotal < budget,
              let index = chunks.indices.first(where: { allocations[$0] < chunks[$0].estimatedTokenCount }) {
            let gap = min(budget - allocationTotal, chunks[index].estimatedTokenCount - allocations[index])
            allocations[index] += gap
            allocationTotal += gap
        }

        return allocations
    }

    private static func trimmed(_ chunk: SourceChunk, toTokenBudget budget: Int) -> SourceChunk {
        var copy = chunk
        let charLimit = PromptTokenEstimator.characterLimit(forTokenBudget: budget)
        copy.text = String(chunk.text.prefix(charLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.estimatedTokenCount = PromptTokenEstimator.estimate(copy.text)
        return copy
    }
}

enum SourceContextRenderer {
    static func context(
        title: String,
        chunks: [SourceChunk],
        visualExtracted: [ExtractedSource],
        omittedTextChunkCount: Int,
        supportsVision: Bool = true,
        extraWarnings: [String] = []
    ) -> SourcePromptContext {
        var blocks = chunks.map { chunk in
            StudyPromptContent.Block.text("""
            === \(chunk.displayLocator) ===
            \(chunk.text)
            """)
        }

        var includedImages = 0
        var omittedImages = 0
        var imageFilenames: [String] = []
        var warnings = extraWarnings

        for extracted in visualExtracted {
            warnings.append(contentsOf: extracted.warnings)
            omittedImages += extracted.omittedImageCount
            for block in extracted.blocks {
                guard case .image(let image) = block else { continue }
                guard supportsVision else {
                    omittedImages += 1
                    continue
                }
                blocks.append(.image(image))
                includedImages += 1
                if !imageFilenames.contains(image.sourceName) {
                    imageFilenames.append(image.sourceName)
                }
            }
        }

        if omittedTextChunkCount > 0 {
            warnings.append("\(omittedTextChunkCount) source text chunk\(omittedTextChunkCount == 1 ? "" : "s") did not fit this model call and were handled by retrieval or summarization.")
        }

        return SourcePromptContext(
            title: title,
            blocks: blocks,
            warnings: warnings,
            includedImageCount: includedImages,
            omittedImageCount: omittedImages,
            imageFilenames: imageFilenames,
            omittedTextChunkCount: omittedTextChunkCount
        )
    }
}
