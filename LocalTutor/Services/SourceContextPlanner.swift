//
//  SourceContextPlanner.swift
//  LocalTutor
//

import Foundation

enum SourceContextPlannerError: LocalizedError {
    case intermediateFailed(String)

    var errorDescription: String? {
        switch self {
        case .intermediateFailed(let message):
            message
        }
    }
}

enum SourceContextPlanner {
    typealias IntermediateGenerator = @Sendable (_ content: StudyPromptContent, _ maxTokens: Int?, _ temperature: Float?) async throws -> String
    typealias StatusHandler = @Sendable (_ message: String) async -> Void

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        generateIntermediate: IntermediateGenerator?,
        status: StatusHandler
    ) async throws -> StudyPromptContent {
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        return try await content(
            for: user,
            history: history,
            profile: profile,
            runtimePolicy: runtimePolicy,
            generateIntermediate: generateIntermediate,
            status: status
        )
    }

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        generateIntermediate: IntermediateGenerator?,
        status: StatusHandler
    ) async throws -> StudyPromptContent {
        await status("Indexing sources")
        let prepared = await prepareSources(user.sources, runtimePolicy: runtimePolicy)
        let budget = PromptPacker.promptBudget(for: runtimePolicy, resourceKind: user.resourceKind)
        let chunks = prepared.indexes.flatMap(\.chunks).sorted { lhs, rhs in
            if lhs.sourceName == rhs.sourceName { return lhs.ordinal < rhs.ordinal }
            return lhs.sourceName < rhs.sourceName
        }

        let context: SourcePromptContext
        if shouldUseWholeDocument(user: user) {
            context = try await wholeDocumentContext(
                user: user,
                history: history,
                profile: profile,
                chunks: chunks,
                visualExtracted: prepared.visualExtracted,
                budget: budget,
                generateIntermediate: generateIntermediate,
                status: status
            )
        } else {
            context = try await targetedContext(
                user: user,
                history: history,
                profile: profile,
                chunks: chunks,
                indexes: prepared.indexes,
                visualExtracted: prepared.visualExtracted,
                budget: budget,
                generateIntermediate: generateIntermediate,
                status: status
            )
        }

        return StudyPromptBuilder.content(
            for: user,
            history: history,
            sourceContext: context
        )
    }

    static func shouldUseWholeDocument(user: StudyTurnUser) -> Bool {
        let hasFocus = !user.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasFocus else { return false }
        switch user.resourceKind {
        case .summary, .beginnerExplanation, .cheatSheet, .flashcards, .quiz:
            return true
        case .ask:
            return false
        }
    }

    static func sectionGroups(for chunks: [SourceChunk], budget: Int) -> [[SourceChunk]] {
        var groups: [[SourceChunk]] = []
        var current: [SourceChunk] = []
        var currentKey: String?
        var currentTokens = 0

        for chunk in chunks {
            let key = sectionGroupingKey(for: chunk)
            let wouldOverflow = currentTokens + chunk.estimatedTokenCount > budget
            if !current.isEmpty, (key != currentKey || wouldOverflow) {
                groups.append(current)
                current = []
                currentTokens = 0
            }
            current.append(chunk)
            currentKey = key
            currentTokens += chunk.estimatedTokenCount
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func sectionGroupingKey(for chunk: SourceChunk) -> String {
        guard let firstHeading = chunk.headingPath.first else {
            return "\(chunk.sourceName)-\(chunk.ordinal)"
        }
        if firstHeading.hasPrefix("# "), chunk.headingPath.count > 1 {
            return chunk.headingPath[1]
        }
        return firstHeading
    }

    static func budgetGroups(for chunks: [SourceChunk], budget: Int) -> [[SourceChunk]] {
        var groups: [[SourceChunk]] = []
        var current: [SourceChunk] = []
        var currentTokens = 0

        for chunk in chunks {
            let wouldOverflow = currentTokens + chunk.estimatedTokenCount > budget
            if !current.isEmpty, wouldOverflow {
                groups.append(current)
                current = []
                currentTokens = 0
            }
            current.append(chunk)
            currentTokens += chunk.estimatedTokenCount
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func prepareSources(
        _ sources: [StudySource],
        runtimePolicy: ModelRuntimePolicy
    ) async -> (indexes: [SourceIndex], visualExtracted: [ExtractedSource]) {
        var indexes: [SourceIndex] = []
        var visualExtracted: [ExtractedSource] = []
        var remainingImages = runtimePolicy.documentImageLimit

        for source in sources {
            let cached = await SourceIndexStore.shared.cachedIndex(for: source)
            if let cached {
                indexes.append(cached.rebased(to: source))
            }

            let needsExtraction = cached == nil || remainingImages > 0 || source.isImage
            guard needsExtraction else { continue }

            let options = runtimePolicy.extractionOptions(imageLimit: remainingImages)
            let extracted = await SourceExtractor.extract([source], options: options).first
                ?? ExtractedSource(source: source, blocks: [], failureReason: "No content was extracted.")
            remainingImages = max(0, remainingImages - extracted.includedImageCount)

            if cached == nil {
                let index = SourceIndexBuilder.build(from: extracted)
                indexes.append(index)
                await SourceIndexStore.shared.store(index)
            }
            if extracted.includedImageCount > 0 || !extracted.warnings.isEmpty || extracted.omittedImageCount > 0 {
                visualExtracted.append(extracted)
            }
        }

        return (indexes, visualExtracted)
    }

    private static func wholeDocumentContext(
        user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        chunks: [SourceChunk],
        visualExtracted: [ExtractedSource],
        budget: Int,
        generateIntermediate: IntermediateGenerator?,
        status: StatusHandler
    ) async throws -> SourcePromptContext {
        guard !chunks.isEmpty else {
            return SourceContextRenderer.context(
                title: "No readable source text was found.",
                chunks: [],
                visualExtracted: visualExtracted,
                omittedTextChunkCount: 0
            )
        }

        if PromptPacker.fits(chunks, budget: budget) {
            return SourceContextRenderer.context(
                title: "Full source contents selected.",
                chunks: chunks,
                visualExtracted: visualExtracted,
                omittedTextChunkCount: 0
            )
        }

        if PromptPacker.canPreserveCoverage(chunks, budget: budget) {
            let packed = PromptPacker.packForCoverage(chunks, budget: budget)
            return SourceContextRenderer.context(
                title: "Full source coverage selected with compacted excerpts.",
                chunks: packed.chunks,
                visualExtracted: visualExtracted,
                omittedTextChunkCount: 0,
                extraWarnings: packed.compactedChunkCount == 0 ? [] : [
                    "\(packed.compactedChunkCount) source chunk\(packed.compactedChunkCount == 1 ? "" : "s") were compacted proportionally to keep the whole document in one model call."
                ]
            )
        }

        guard let generateIntermediate else {
            let packed = PromptPacker.pack(chunks, budget: budget)
            return SourceContextRenderer.context(
                title: "Retrieved source excerpts selected.",
                chunks: packed.chunks,
                visualExtracted: visualExtracted,
                omittedTextChunkCount: packed.omitted
            )
        }

        let distilled = try await distillToFit(
            user: user,
            history: history,
            profile: profile,
            chunks: chunks,
            budget: budget,
            generateIntermediate: generateIntermediate,
            status: status
        )
        return SourceContextRenderer.context(
            title: "Distilled full-document source summaries selected.",
            chunks: distilled,
            visualExtracted: visualExtracted,
            omittedTextChunkCount: 0
        )
    }

    private static func targetedContext(
        user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        chunks: [SourceChunk],
        indexes: [SourceIndex],
        visualExtracted: [ExtractedSource],
        budget: Int,
        generateIntermediate: IntermediateGenerator?,
        status: StatusHandler
    ) async throws -> SourcePromptContext {
        let query = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        await status(query.isEmpty ? "Retrieving sources" : "Retrieving \(query)")
        let retrieval = SourceRetriever.retrieve(query: query, indexes: indexes)
        let selected = retrieval.chunks.isEmpty ? chunks : retrieval.chunks

        if !selected.isEmpty,
           !PromptPacker.fits(selected, budget: budget),
           retrieval.matchedHeading != nil,
           let generateIntermediate {
            let distilled = try await distillToFit(
                user: user,
                history: history,
                profile: profile,
                chunks: selected,
                budget: budget,
                generateIntermediate: generateIntermediate,
                status: status
            )
            return SourceContextRenderer.context(
                title: "Distilled \(retrieval.matchedHeading ?? "section") source summaries selected.",
                chunks: distilled,
                visualExtracted: visualExtracted,
                omittedTextChunkCount: 0
            )
        }

        let packed = PromptPacker.pack(selected, budget: budget)
        return SourceContextRenderer.context(
            title: retrieval.matchedHeading.map { "Retrieved section: \($0)" } ?? "Retrieved relevant source excerpts.",
            chunks: packed.chunks,
            visualExtracted: visualExtracted,
            omittedTextChunkCount: packed.omitted
        )
    }

    private static func distillToFit(
        user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        chunks: [SourceChunk],
        budget: Int,
        generateIntermediate: IntermediateGenerator,
        status: StatusHandler
    ) async throws -> [SourceChunk] {
        var maxSummaryTokens = 512
        var summaries = try await distill(
            user: user,
            history: history,
            profile: profile,
            chunks: chunks,
            budget: budget,
            preserveSections: true,
            maxSummaryTokens: maxSummaryTokens,
            generateIntermediate: generateIntermediate,
            status: status
        )

        while !PromptPacker.fits(summaries, budget: budget), summaries.count > 1 {
            let previousCount = summaries.count
            if maxSummaryTokens > 128 {
                maxSummaryTokens = max(128, maxSummaryTokens / 2)
            }
            let reduced = try await distill(
                user: user,
                history: history,
                profile: profile,
                chunks: summaries,
                budget: budget,
                preserveSections: false,
                maxSummaryTokens: maxSummaryTokens,
                generateIntermediate: generateIntermediate,
                status: status
            )
            summaries = reduced
            if summaries.count >= previousCount, maxSummaryTokens == 128 {
                break
            }
        }

        return PromptPacker.fits(summaries, budget: budget)
            ? summaries
            : PromptPacker.pack(summaries, budget: budget).chunks
    }

    private static func distill(
        user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        chunks: [SourceChunk],
        budget: Int,
        preserveSections: Bool,
        maxSummaryTokens: Int,
        generateIntermediate: IntermediateGenerator,
        status: StatusHandler
    ) async throws -> [SourceChunk] {
        let groups = preserveSections
            ? sectionGroups(for: chunks, budget: budget)
            : budgetGroups(for: chunks, budget: budget)
        var summaries: [SourceChunk] = []

        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            await status("Summarizing section \(index + 1) of \(groups.count)")
            let prompt = intermediatePrompt(
                user: user,
                history: history,
                profile: profile,
                chunks: group,
                index: index,
                total: groups.count,
                maxSummaryTokens: maxSummaryTokens
            )
            let output = try await generateIntermediate(prompt, maxSummaryTokens, 0.1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                throw SourceContextPlannerError.intermediateFailed("The local model returned an empty source summary.")
            }
            let first = group[0]
            summaries.append(
                SourceChunk(
                    id: "summary-\(index + 1)-\(first.id)",
                    sourceID: first.sourceID,
                    sourceName: first.sourceName,
                    locator: first.locator,
                    headingPath: first.headingPath.isEmpty ? ["Source summary \(index + 1)"] : first.headingPath,
                    ordinal: index + 1,
                    text: output,
                    estimatedTokenCount: PromptTokenEstimator.estimate(output)
                )
            )
        }

        return summaries
    }

    private static func intermediatePrompt(
        user: StudyTurnUser,
        history: [StudyTurn],
        profile: ModelProfile,
        chunks: [SourceChunk],
        index: Int,
        total: Int,
        maxSummaryTokens: Int
    ) -> StudyPromptContent {
        let context = SourceContextRenderer.context(
            title: "Source section \(index + 1) of \(total) selected for intermediate distillation.",
            chunks: chunks,
            visualExtracted: [],
            omittedTextChunkCount: 0
        )
        let focus = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = focus.isEmpty
            ? "Create source-grounded study notes for a later \(user.resourceKind.title.lowercased()) response."
            : "Create source-grounded study notes relevant to: \(focus)"

        return StudyPromptContent(
            systemInstruction: "You are LocalTutor, a private local study tutor running on the student's Mac.",
            openingText: """
            Intermediate source distillation.
            \(goal)
            Keep exact facts, names, numbers, formulas, and page/section clues. Fit within about \(maxSummaryTokens) tokens. Do not add outside knowledge.
            """,
            sourceBlocks: context.blocks,
            closingText: "Return concise markdown notes only. Do not address the student yet.",
            includedImageCount: 0,
            omittedImageCount: 0,
            imageFilenames: [],
            warnings: context.warnings
        )
    }
}
