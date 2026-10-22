//
//  ChatContextPlanner.swift
//  LocalTutor
//

import Foundation
import NaturalLanguage

struct ChatPlan: Sendable {
    enum Mode: String, Sendable {
        case fullNotebook
        case retrieval
        case noSources
    }

    var mode: Mode
    var instructions: String
    var message: String
    var images: [DocumentImage]
    var citations: [SourceCitation]
    var warnings: [String]
}

enum ChatContextPlanner {
    typealias StatusHandler = SourceContextPlanner.StatusHandler

    static func plan(
        question: String,
        history: [StudyTurn],
        isRefinement: Bool = false,
        sources: [StudySource],
        notebookTitle: String,
        runtimePolicy: ModelRuntimePolicy,
        status: StatusHandler
    ) async throws -> ChatPlan {
        let earlierQuestions = history.filter { !$0.user.isRefinement }.map(\.user.focus)
        let askedQuestion = isRefinement ? nil : question
        guard !sources.isEmpty else {
            let language = ResponseLanguage.resolve(question: askedQuestion, earlierQuestions: earlierQuestions, sourceText: "")
            return ChatPlan(
                mode: .noSources,
                instructions: instructions(notebookTitle: notebookTitle, sourceNames: [], excerpts: nil, language: language),
                message: question,
                images: [],
                citations: [],
                warnings: []
            )
        }

        await status("Reading sources")
        let prepared = try await SourceContextPlanner.prepareSources(
            sources,
            runtimePolicy: runtimePolicy,
            status: status
        )
        let images = prepared.visualExtracted.flatMap { extracted in
            extracted.blocks.compactMap { block -> DocumentImage? in
                guard case .image(let image) = block else { return nil }
                return image
            }
        }
        let usableImages = runtimePolicy.supportsVision ? Array(images.prefix(runtimePolicy.documentImageLimit)) : []
        let warnings = prepared.visualExtracted.flatMap(\.warnings)
        let sourceNames = sources.map(\.displayName)
        let ordered = orderedChunks(prepared.indexes, sources: sources)
        let budget = runtimePolicy.sourceTokenBudget(for: .ask)
        let language = ResponseLanguage.resolve(
            question: askedQuestion,
            earlierQuestions: earlierQuestions,
            sourceText: ResponseLanguage.sourceSample(ordered.map(\.text))
        )

        if PromptPacker.fits(ordered, budget: budget) {
            let citations = ordered.enumerated().map { SourceCitation(index: $0.offset + 1, chunk: $0.element) }
            let excerpts = ordered.enumerated()
                .map { SourceContextRenderer.numberedExcerpt($0.element, index: $0.offset + 1) }
                .joined(separator: "\n\n")
            return ChatPlan(
                mode: .fullNotebook,
                instructions: instructions(notebookTitle: notebookTitle, sourceNames: sourceNames, excerpts: excerpts, language: language),
                message: question,
                images: usableImages,
                citations: citations,
                warnings: warnings
            )
        }

        let query = retrievalQuery(question: question, history: history)
        await status("Searching your sources")
        let retrieval = await SourceRetriever.retrieve(query: query, indexes: prepared.indexes)
        let candidates = retrieval.chunks.isEmpty ? ordered : retrieval.chunks
        let packed = PromptPacker.pack(candidates, budget: budget).chunks
        let citations = packed.enumerated().map { SourceCitation(index: $0.offset + 1, chunk: $0.element) }
        let excerpts = packed.enumerated()
            .map { SourceContextRenderer.numberedExcerpt($0.element, index: $0.offset + 1) }
            .joined(separator: "\n\n")
        let message = """
        Relevant source excerpts for this question:

        \(excerpts)

        Question: \(question)
        """
        return ChatPlan(
            mode: .retrieval,
            instructions: instructions(notebookTitle: notebookTitle, sourceNames: sourceNames, excerpts: nil, language: language),
            message: message,
            images: usableImages,
            citations: citations,
            warnings: warnings + retrieval.warnings
        )
    }

    static func orderedChunks(_ indexes: [SourceIndex], sources: [StudySource]) -> [SourceChunk] {
        let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        return indexes.flatMap(\.chunks).sorted { lhs, rhs in
            let left = order[lhs.sourceID] ?? .max
            let right = order[rhs.sourceID] ?? .max
            if left == right { return lhs.ordinal < rhs.ordinal }
            return left < right
        }
    }

    static func retrievalQuery(question: String, history: [StudyTurn]) -> String {
        let words = question.split(whereSeparator: \.isWhitespace)
        guard words.count < 7, let previous = history.last?.user.focus, !previous.isEmpty else {
            return question
        }
        return previous + " " + question
    }

    static func instructions(
        notebookTitle: String,
        sourceNames: [String],
        excerpts: String?,
        language: NLLanguage? = nil
    ) -> String {
        var parts = [StudyPromptBuilder.systemInstruction]
        parts.append("""
        You are tutoring the student in the notebook "\(notebookTitle)".
        Answer the student's questions directly and concisely, then add only the supporting detail that helps them learn. Prefer short paragraphs and bullets. Bold key terms.
        """)
        if sourceNames.isEmpty {
            parts.append("The student has not added any sources yet. Answer from general knowledge and say that adding sources will ground your answers.")
        } else {
            parts.append("Sources in this notebook:\n" + sourceNames.map { "- \($0)" }.joined(separator: "\n"))
            parts.append("""
            Base answers on the sources. If they don't cover something, say so in one sentence, then answer from general knowledge and label it as such.
            \(StudyPromptBuilder.citationInstruction)
            """)
        }
        if let excerpts {
            parts.append("SOURCE EXCERPTS\n\n" + excerpts)
        }
        parts.append(ResponseLanguage.instruction(for: language))
        return parts.joined(separator: "\n\n")
    }
}
