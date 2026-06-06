//
//  StudyPromptBuilder.swift
//  LocalTutor
//

import CoreImage
import Foundation

enum StudyPromptBuilder {
    static let systemInstruction = """
    You are LocalTutor, a private local study tutor running on the student's Mac. If this model emits a <think> block or a thought/analysis channel marker, keep internal thinking there, close or leave that channel, then always write the final student-facing answer after it. Never stop after hidden thinking, and do not mix hidden reasoning into the final answer. Use plain Markdown for study content. Do not wrap ordinary words, filenames, acronyms, checklist boxes, or citations in LaTeX/math delimiters. Use Unicode symbols such as ☐ instead of $\\square$; reserve LaTeX only for real equations.
    """

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        extracted: [ExtractedSource]
    ) -> StudyPromptContent {
        content(for: user, history: history, extracted: extracted, supportsVision: true)
    }

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        extracted: [ExtractedSource],
        supportsVision: Bool
    ) -> StudyPromptContent {
        let context = sourceContext(from: extracted, hasSources: !user.sources.isEmpty, supportsVision: supportsVision)
        return content(for: user, history: history, sourceContext: context, supportsVision: supportsVision)
    }

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        sourceContext: SourcePromptContext
    ) -> StudyPromptContent {
        content(for: user, history: history, sourceContext: sourceContext, supportsVision: true)
    }

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        sourceContext: SourcePromptContext,
        supportsVision: Bool
    ) -> StudyPromptContent {
        let trimmed = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmed.isEmpty ? "Help me study the attached sources." : trimmed
        let usableSources = supportsVision ? user.sources : user.sources.filter { !$0.isImage }
        let sourceList: String
        if usableSources.isEmpty {
            sourceList = user.sources.isEmpty
                ? "No files were attached."
                : "No usable text sources were attached for this text-only model."
        } else {
            sourceList = usableSources.map { "- \($0.displayName) (\($0.kind.label))" }.joined(separator: "\n")
        }
        let transcript = renderTranscript(history)
        let formatBlock = renderFormatBlock(for: user.resourceKind)
        let sourceInstruction = supportsVision
            ? "Source contents follow in reading order. Images are provided as separate vision inputs with captions naming their source and location."
            : "Source text follows in reading order. Images and scanned/image-only pages are not provided to this text-only model."

        let opening = """
        \(renderTaskBlock(for: user.resourceKind))
        \(transcript)
        Student \(user.resourceKind == .ask ? "question" : "goal"):
        \(goal)

        Source files:
        \(sourceList)

        Source selection:
        \(sourceContext.title)

        \(sourceInstruction)
        """

        var closingParts: [String] = [
            supportsVision
                ? "Base your answer strictly on the provided source contents and attached figures/pages. If the sources do not cover something, say so briefly rather than guessing. Never ask the student to upload or paste a file that already appears above - it has already been provided."
                : "Base your answer strictly on the provided source text. If the readable text does not cover something, say so briefly rather than guessing. Never ask the student to upload or paste a file that already appears above - it has already been provided."
        ]
        if sourceContext.omittedTextChunkCount > 0 {
            closingParts.append("Note: LocalTutor selected or distilled the most relevant source chunks that fit this model call. If the provided excerpts do not cover something, say so briefly.")
        }
        if sourceContext.omittedImageCount > 0 {
            let omittedNote: String
            if supportsVision {
                omittedNote = sourceContext.omittedImageCount == 1
                    ? "1 additional figure/page was omitted to fit the local model."
                    : "\(sourceContext.omittedImageCount) additional figures/pages were omitted to fit the local model."
            } else {
                omittedNote = sourceContext.omittedImageCount == 1
                    ? "1 image or scanned page was skipped because the selected model is text-only."
                    : "\(sourceContext.omittedImageCount) images or scanned pages were skipped because the selected model is text-only."
            }
            closingParts.append(omittedNote)
        }
        closingParts.append(formatBlock)

        return StudyPromptContent(
            systemInstruction: systemInstruction,
            openingText: opening,
            sourceBlocks: sourceContext.blocks,
            closingText: closingParts.joined(separator: "\n\n"),
            includedImageCount: sourceContext.includedImageCount,
            omittedImageCount: sourceContext.omittedImageCount,
            imageFilenames: sourceContext.imageFilenames,
            warnings: sourceContext.warnings
        )
    }

    static func prompt(for user: StudyTurnUser, history: [StudyTurn], extracted: [ExtractedSource]) -> String {
        content(for: user, history: history, extracted: extracted).benchmarkText
    }

    static func modelLabContent(prompt: String, imageURL: URL?) throws -> StudyPromptContent {
        guard let imageURL else {
            return modelLabContent(prompt: prompt, image: nil)
        }

        let granted = imageURL.startAccessingSecurityScopedResource()
        defer {
            if granted {
                imageURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true]) else {
            throw LocalModelRunnerError.imageRequired
        }

        let documentImage = DocumentImage(
            image: image,
            sourceName: imageURL.lastPathComponent,
            locator: nil,
            caption: nil,
            isStandalone: true,
            originalSize: image.extent.size
        )
        return modelLabContent(prompt: prompt, image: documentImage)
    }

    static func modelLabContent(prompt: String, image: DocumentImage?) -> StudyPromptContent {
        var blocks: [StudyPromptContent.Block] = [.text(prompt)]
        if let image {
            blocks.append(.image(image))
        }
        return StudyPromptContent(
            systemInstruction: systemInstruction,
            openingText: "Analyze the provided prompt and any attached image.",
            sourceBlocks: blocks,
            closingText: "",
            includedImageCount: image == nil ? 0 : 1,
            omittedImageCount: 0,
            imageFilenames: image.map { [$0.sourceName] } ?? [],
            warnings: []
        )
    }

    private static func renderTranscript(_ history: [StudyTurn]) -> String {
        guard !history.isEmpty else { return "" }

        let recent = history.suffix(4)
        return "\nPrevious turns (most recent last):\n" + recent.map { turn in
            let sanitizedMarkdown = ReasoningOutputFilter.sanitize(turn.assistant.markdown)
            let assistantText = sanitizedMarkdown.isEmpty ? "(no output)" : sanitizedMarkdown
            return """
            Student: \(turn.user.displayPrompt)
            Tutor: \(assistantText)
            """
        }.joined(separator: "\n---\n") + "\n"
    }

    private static func renderTaskBlock(for resourceKind: StudyResourceKind) -> String {
        switch resourceKind {
        case .ask:
            return """
            Task:
            \(resourceKind.promptInstruction)
            """
        default:
            return """
            Resource to create:
            \(resourceKind.promptInstruction)
            """
        }
    }

    private static func renderFormatBlock(for resourceKind: StudyResourceKind) -> String {
        if let schema = resourceKind.jsonSchemaInstruction {
            return """
            Output format (STRICT):
            \(schema)
            """
        }

        if resourceKind == .ask {
            return "Answer directly in concise markdown. Start with the answer, then add only the source-grounded details needed to support it. No filler."
        }

        return "Format the answer for studying with short markdown headings, concrete bullets, and **bold** for key terms. No filler."
    }

    private static func sourceContext(
        from extracted: [ExtractedSource],
        hasSources: Bool,
        supportsVision: Bool = true
    ) -> SourcePromptContext {
        let render = renderSourceBlocks(extracted, hasSources: hasSources, supportsVision: supportsVision)
        let includedImages = render.blocks.reduce(0) { count, block in
            if case .image = block { return count + 1 }
            return count
        }
        let omittedImages = extracted.reduce(0) { total, item in
            let includedButSkipped = supportsVision ? 0 : item.includedImageCount
            return total + item.omittedImageCount + includedButSkipped
        }
        let warnings = extracted.flatMap(\.warnings)
        return SourcePromptContext(
            title: "Full extracted source contents selected.",
            blocks: render.blocks,
            warnings: warnings,
            includedImageCount: includedImages,
            omittedImageCount: omittedImages,
            imageFilenames: uniqueImageNames(in: render.blocks),
            omittedTextChunkCount: 0
        )
    }

    private static func renderSourceBlocks(
        _ extracted: [ExtractedSource],
        hasSources: Bool,
        supportsVision: Bool
    ) -> (blocks: [StudyPromptContent.Block], truncatedAny: Bool) {
        if extracted.isEmpty {
            let message = hasSources
                ? "Source contents:\nNo text or figures could be extracted from the attached files."
                : "Source contents:\nNo files were attached."
            return ([.text(message)], false)
        }

        var blocks: [StudyPromptContent.Block] = [
            .text("Source contents (verbatim excerpts and figures/pages the student attached):")
        ]

        for item in extracted {
            if let reason = item.failureReason, !item.hasContent {
                blocks.append(.text("""
                === \(item.source.displayName) ===
                (Could not read: \(reason))
                """))
                continue
            }

            blocks.append(.text("=== \(item.source.displayName) ==="))
            for block in item.blocks {
                switch block {
                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.text(text))
                    }
                case .image(let image):
                    if supportsVision {
                        blocks.append(.image(image))
                    }
                }
            }
        }

        return (blocks, false)
    }

    private static func uniqueImageNames(in blocks: [StudyPromptContent.Block]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for block in blocks {
            guard case .image(let image) = block,
                  !seen.contains(image.sourceName) else {
                continue
            }
            seen.insert(image.sourceName)
            names.append(image.sourceName)
        }
        return names
    }
}
