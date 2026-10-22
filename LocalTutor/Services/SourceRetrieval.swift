//
//  SourceRetrieval.swift
//  LocalTutor
//

import Accelerate
import Foundation

struct SourcePromptContext: Sendable {
    var title: String
    var blocks: [StudyPromptContent.Block]
    var warnings: [String]
    var includedImageCount: Int
    var omittedImageCount: Int
    var imageFilenames: [String]
    var omittedTextChunkCount: Int
    var citations: [SourceCitation] = []
}

struct SourceRetrievalResult: Sendable {
    var chunks: [SourceChunk]
    var matchedHeading: String?
    var mode: RetrievalMode = .lexical
    var warnings: [String] = []
    var selectedChunkIDs: [String] = []
}

enum RetrievalMode: String, Sendable {
    case lexical
    case hybrid
}

enum SourceRetriever {
    private static let tokenCache = SourceTokenCache()
    private static let repository: any SourceIndexRepository = SQLiteSourceIndexRepository.shared

    static func retrieve(query: String, indexes: [SourceIndex]) async -> SourceRetrievalResult {
        let allChunks = indexes.flatMap(\.chunks)
        let queryTerms = tokenize(query)
        if let matchedHeading = bestHeadingMatch(query: query, queryTerms: queryTerms, chunks: allChunks) {
            let headingMatches = allChunks.filter { $0.headingPath.contains(matchedHeading) }
            return SourceRetrievalResult(
                chunks: headingMatches.sorted(by: sourceOrder),
                matchedHeading: matchedHeading,
                selectedChunkIDs: headingMatches.map(\.id)
            )
        }

        let lexical: [SourceChunk]
        var warnings: [String] = []
        do {
            let persisted = try await repository.lexicalSearch(
                query: query,
                fingerprints: indexes.map(\.fingerprint),
                limit: 40
            )
            let currentByID = Dictionary(uniqueKeysWithValues: allChunks.map { ($0.id, $0) })
            let current = persisted.compactMap { currentByID[$0.id] }
            lexical = current.isEmpty
                ? bm25(queryTerms: queryTerms, chunks: allChunks)
                    .filter { $0.score > 0 }
                    .sorted { $0.score > $1.score }
                    .prefix(40)
                    .map(\.chunk)
                : current
        } catch {
            lexical = bm25(queryTerms: queryTerms, chunks: allChunks)
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .prefix(40)
                .map(\.chunk)
            warnings.append("The persistent lexical index was unavailable; LocalTutor used its in-memory index.")
        }

        var dense: [SourceChunk] = []
        do {
            let entries = try await repository.vectorEntries(fingerprints: indexes.map(\.fingerprint))
            let currentIDs = Set(allChunks.map(\.id))
            let currentEntries = entries.filter { currentIDs.contains($0.chunk.id) }
            if !currentEntries.isEmpty {
                let queryVector = try await SourceIndexCoordinator.shared.embedQuery(query)
                let scores = exactScores(query: queryVector, entries: currentEntries)
                dense = zip(currentEntries, scores).map { entry, score in
                    (chunk: entry.chunk, score: score)
                }
                .sorted { $0.score > $1.score }
                .prefix(40)
                .map(\.chunk)
            }
        } catch {
            warnings.append("Semantic search was unavailable for this request.")
        }

        let fused = reciprocalRankFusion(lexical: lexical, dense: dense)
        let selected = Array(fused.prefix(12))
        let expanded = expand(selected, indexes: indexes)
        let fallback = lexical.isEmpty ? allChunks.sorted(by: sourceOrder) : lexical
        return SourceRetrievalResult(
            chunks: expanded.isEmpty ? fallback : expanded,
            matchedHeading: nil,
            mode: dense.isEmpty ? .lexical : .hybrid,
            warnings: warnings,
            selectedChunkIDs: selected.map(\.id)
        )
    }

    static func exactScores(
        query: [Float],
        entries: [SourceVectorEntry]
    ) -> [Float] {
        guard !query.isEmpty,
              entries.allSatisfy({ $0.vector.count == query.count }) else {
            return Array(repeating: -.infinity, count: entries.count)
        }
        let matrix = entries.flatMap(\.vector)
        var scores = Array(repeating: Float(0), count: entries.count)
        vDSP_mmul(
            matrix,
            1,
            query,
            1,
            &scores,
            1,
            vDSP_Length(entries.count),
            1,
            vDSP_Length(query.count)
        )
        return scores
    }

    static func reciprocalRankFusion(
        lexical: [SourceChunk],
        dense: [SourceChunk]
    ) -> [SourceChunk] {
        var chunks: [String: SourceChunk] = [:]
        var scores: [String: Double] = [:]
        for (rank, chunk) in lexical.enumerated() {
            chunks[chunk.id] = chunk
            scores[chunk.id, default: 0] += 1 / Double(60 + rank + 1)
        }
        for (rank, chunk) in dense.enumerated() {
            chunks[chunk.id] = chunk
            scores[chunk.id, default: 0] += 1 / Double(60 + rank + 1)
        }
        return scores.sorted {
            if $0.value == $1.value {
                guard let lhs = chunks[$0.key], let rhs = chunks[$1.key] else { return $0.key < $1.key }
                return sourceOrder(lhs, rhs)
            }
            return $0.value > $1.value
        }
        .compactMap { chunks[$0.key] }
    }

    private static func expand(_ selected: [SourceChunk], indexes: [SourceIndex]) -> [SourceChunk] {
        let allChunks = indexes.flatMap(\.chunks)
        let parents = Dictionary(uniqueKeysWithValues: indexes.flatMap(\.parents).map { ($0.id, $0) })
        var expanded: [SourceChunk] = []
        var seen: Set<String> = []

        for chunk in selected {
            if let parentID = chunk.parentID,
               let parent = parents[parentID],
               parent.estimatedTokenCount <= SourceIndexBuilder.parentExpansionLimit {
                let parentChunk = SourceChunk(
                    id: "parent-\(parent.id)",
                    sourceID: parent.sourceID,
                    sourceName: parent.sourceName,
                    locator: parent.locatorRange.displayValue,
                    locatorRange: parent.locatorRange,
                    headingPath: parent.headingPath,
                    parentID: parent.id,
                    elementKind: .mixed,
                    ordinal: chunk.ordinal,
                    text: parent.text,
                    estimatedTokenCount: parent.estimatedTokenCount
                )
                if seen.insert(parentChunk.id).inserted {
                    expanded.append(parentChunk)
                }
                continue
            }

            let siblings = allChunks
                .filter { $0.sourceID == chunk.sourceID && $0.parentID == chunk.parentID }
                .sorted { $0.ordinal < $1.ordinal }
            guard let index = siblings.firstIndex(where: { $0.id == chunk.id }) else {
                if seen.insert(chunk.id).inserted { expanded.append(chunk) }
                continue
            }
            let lower = max(0, index - 1)
            let upper = min(siblings.count - 1, index + 1)
            for sibling in siblings[lower...upper] where seen.insert(sibling.id).inserted {
                expanded.append(sibling)
            }
        }
        return mergeContiguous(expanded)
    }

    private static func mergeContiguous(_ chunks: [SourceChunk]) -> [SourceChunk] {
        var result: [SourceChunk] = []
        for chunk in chunks {
            guard var previous = result.last,
                  previous.sourceID == chunk.sourceID,
                  previous.parentID == chunk.parentID,
                  chunk.ordinal == previous.ordinal + 1 else {
                result.append(chunk)
                continue
            }
            result.removeLast()
            let addition = removingOverlap(prefix: previous.text, suffix: chunk.text)
            previous.text += addition.isEmpty ? "" : "\n\n\(addition)"
            previous.estimatedTokenCount = PromptTokenEstimator.estimate(previous.text)
            previous.locatorRange.endPage = chunk.locatorRange.endPage ?? previous.locatorRange.endPage
            previous.locator = previous.locatorRange.displayValue
            result.append(previous)
        }
        return result
    }

    private static func removingOverlap(prefix: String, suffix: String) -> String {
        let prefixWords = prefix.split(whereSeparator: \.isWhitespace)
        let suffixWords = suffix.split(whereSeparator: \.isWhitespace)
        let maximum = min(overlapLimit(prefixWords.count), suffixWords.count)
        for count in stride(from: maximum, through: 1, by: -1) {
            if prefixWords.suffix(count).elementsEqual(suffixWords.prefix(count)) {
                return suffixWords.dropFirst(count).joined(separator: " ")
            }
        }
        return suffix
    }

    private static func overlapLimit(_ count: Int) -> Int {
        min(count, SourceIndexBuilder.overlapTokens * PromptTokenEstimator.charactersPerToken)
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
        let citations = chunks.enumerated().map { offset, chunk in
            SourceCitation(index: offset + 1, chunk: chunk)
        }
        var blocks = chunks.enumerated().map { offset, chunk in
            StudyPromptContent.Block.text(numberedExcerpt(chunk, index: offset + 1))
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
            omittedTextChunkCount: omittedTextChunkCount,
            citations: citations
        )
    }

    static func numberedExcerpt(_ chunk: SourceChunk, index: Int) -> String {
        """
        [\(index)] \(chunk.displayLocator)
        \(chunk.text)
        """
    }
}
