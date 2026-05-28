//
//  StudyPromptBuilder.swift
//  LocalTutor
//

import Foundation

enum StudyPromptBuilder {
    static func prompt(for user: StudyTurnUser, history: [StudyTurn], extracted: [ExtractedSource]) -> String {
        let trimmed = user.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmed.isEmpty ? "Help me study the attached sources." : trimmed
        let sourceList = user.sources.isEmpty
            ? "No files were attached."
            : user.sources.map { "- \($0.displayName) (\($0.kind.label))" }.joined(separator: "\n")
        let transcript = renderTranscript(history)
        let sourceContents = renderSourceContents(extracted, hasImage: user.sources.contains(where: \.isImage))
        let formatBlock = renderFormatBlock(for: user.resourceKind)

        return """
        You are LocalTutor, a private local study tutor running on the student's Mac.

        Resource to create:
        \(user.resourceKind.promptInstruction)
        \(transcript)
        Student goal:
        \(goal)

        Source files:
        \(sourceList)

        \(sourceContents)

        Base your answer strictly on the provided source contents and any attached image. If the sources do not cover something, say so briefly rather than guessing. Never ask the student to upload or paste a file that already appears above — it has already been provided.

        \(formatBlock)
        """
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

    private static func renderFormatBlock(for resourceKind: StudyResourceKind) -> String {
        if let schema = resourceKind.jsonSchemaInstruction {
            return """
            Output format (STRICT):
            \(schema)
            """
        }

        return "Format the answer for studying with short markdown headings, concrete bullets, and **bold** for key terms. No filler."
    }

    private static func renderSourceContents(_ extracted: [ExtractedSource], hasImage: Bool) -> String {
        if extracted.isEmpty {
            return hasImage
                ? "Source contents:\nAn image is attached as a separate input — analyze it directly."
                : "Source contents:\nNo text could be extracted from the attached files."
        }

        var budget = SourceExtractor.totalCharacterBudget
        var sections: [String] = []
        var truncatedAny = false

        for item in extracted {
            if let reason = item.failureReason, !item.hasContent {
                sections.append("""
                === \(item.source.displayName) ===
                (Could not read: \(reason))
                """)
                continue
            }

            let allowed = min(item.text.count, budget)
            let snippet = allowed > 0 ? String(item.text.prefix(allowed)) : ""
            budget -= allowed

            var section = """
            === \(item.source.displayName) ===
            \(snippet)
            """
            if allowed < item.text.count {
                section += "\n…[truncated — only the first portion fits the context window]"
                truncatedAny = true
            }
            sections.append(section)
            if budget <= 0 { break }
        }

        let truncationNote = truncatedAny
            ? "\nNote: Some excerpts above are truncated to fit the local model's context window. Base your answer on what is present and say 'the excerpt does not cover this' for anything that isn't.\n"
            : ""

        return """
        Source contents (verbatim excerpts the student attached):
        \(sections.joined(separator: "\n\n"))
        \(truncationNote)
        """
    }
}
