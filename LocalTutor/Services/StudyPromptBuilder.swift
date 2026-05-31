//
//  StudyPromptBuilder.swift
//  LocalTutor
//

import CoreImage
import Foundation

enum StudyPromptBuilder {
    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        extracted: [ExtractedSource]
    ) -> StudyPromptContent {
        let context = sourceContext(from: extracted, hasSources: !user.sources.isEmpty)
        return content(for: user, history: history, sourceContext: context)
    }

    static func content(
        for user: StudyTurnUser,
        history: [StudyTurn],
        sourceContext: SourcePromptContext
    ) -> StudyPromptContent {
        let trimmed = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmed.isEmpty ? "Help me study the attached sources." : trimmed
        let sourceList = user.sources.isEmpty
            ? "No files were attached."
            : user.sources.map { "- \($0.displayName) (\($0.kind.label))" }.joined(separator: "\n")
        let transcript = renderTranscript(history)
        let formatBlock = renderFormatBlock(for: user.resourceKind)

        let opening = """
        \(renderTaskBlock(for: user.resourceKind))
        \(transcript)
        Student \(user.resourceKind == .ask ? "question" : "goal"):
        \(goal)

        Source files:
        \(sourceList)

        Source selection:
        \(sourceContext.title)

        Source contents follow in reading order. Images are provided as separate vision inputs with captions naming their source and location.
        """

        var closingParts: [String] = [
            "Base your answer strictly on the provided source contents and attached figures/pages. If the sources do not cover something, say so briefly rather than guessing. Never ask the student to upload or paste a file that already appears above - it has already been provided."
        ]
        if sourceContext.omittedTextChunkCount > 0 {
            closingParts.append("Note: LocalTutor selected or distilled the most relevant source chunks that fit this model call. If the provided excerpts do not cover something, say so briefly.")
        }
        if sourceContext.omittedImageCount > 0 {
            let omittedNote = sourceContext.omittedImageCount == 1
                ? "1 additional figure/page was omitted to fit the local model."
                : "\(sourceContext.omittedImageCount) additional figures/pages were omitted to fit the local model."
            closingParts.append(omittedNote)
        }
        closingParts.append(formatBlock)

        return StudyPromptContent(
            systemInstruction: "You are LocalTutor, a private local study tutor running on the student's Mac.",
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
            systemInstruction: "You are LocalTutor, a private local study tutor running on the student's Mac.",
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
            let assistantText = turn.assistant.markdown.isEmpty ? "(no output)" : turn.assistant.markdown
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
        hasSources: Bool
    ) -> SourcePromptContext {
        let render = renderSourceBlocks(extracted, hasSources: hasSources)
        let includedImages = render.blocks.reduce(0) { count, block in
            if case .image = block { return count + 1 }
            return count
        }
        let omittedImages = extracted.reduce(0) { $0 + $1.omittedImageCount }
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
        hasSources: Bool
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
                    blocks.append(.image(image))
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
