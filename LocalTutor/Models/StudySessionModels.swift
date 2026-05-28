//
//  StudySessionModels.swift
//  LocalTutor
//
//

import Foundation
import UniformTypeIdentifiers

enum StudyResourceKind: String, CaseIterable, Identifiable, Codable {
    case summary
    case beginnerExplanation
    case flashcards
    case quiz
    case cheatSheet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:
            "Summary"
        case .beginnerExplanation:
            "Explain"
        case .flashcards:
            "Flashcards"
        case .quiz:
            "Quiz"
        case .cheatSheet:
            "Cheat Sheet"
        }
    }

    var systemImage: String {
        switch self {
        case .summary:
            "doc.text"
        case .beginnerExplanation:
            "lightbulb"
        case .flashcards:
            "rectangle.stack"
        case .quiz:
            "checklist"
        case .cheatSheet:
            "doc.plaintext"
        }
    }

    var shortDescription: String {
        switch self {
        case .summary: "Main ideas, fast"
        case .beginnerExplanation: "Beginner walkthrough"
        case .flashcards: "Interactive deck"
        case .quiz: "Interactive test"
        case .cheatSheet: "Compact reference"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .summary: "Anything specific to focus on? Or just press send for a full summary."
        case .beginnerExplanation: "Add a topic to focus on, or send to explain the whole document."
        case .flashcards: "Add a topic, or send to build flashcards from the sources."
        case .quiz: "Add a topic, or send to generate a quiz from the sources."
        case .cheatSheet: "Add a focus, or send for a complete cheat sheet."
        }
    }

    var promptInstruction: String {
        switch self {
        case .summary:
            "Create a structured study summary with the main ideas, supporting details, and a short review checklist."
        case .beginnerExplanation:
            "Explain the material as if the student is new to the topic. Use simple language, analogies only when they clarify, and define important terms."
        case .flashcards:
            "Create flashcards with clear fronts and concise backs. Prioritize facts, definitions, commands, formulas, and distinctions likely to be tested."
        case .quiz:
            "Create a quiz with a mix of multiple choice and short-answer questions. Put the answer key after the questions."
        case .cheatSheet:
            "Create a compact exam cheat sheet with formulas, commands, definitions, pitfalls, and high-yield reminders."
        }
    }
}

enum StudySourceKind: String, Codable {
    case pdf
    case image
    case document
    case spreadsheet
    case presentation
    case text
    case other

    var label: String {
        switch self {
        case .pdf:
            "PDF"
        case .image:
            "Image"
        case .document:
            "Document"
        case .spreadsheet:
            "Spreadsheet"
        case .presentation:
            "Slides"
        case .text:
            "Text"
        case .other:
            "File"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf:
            "doc.richtext"
        case .image:
            "photo"
        case .document:
            "doc.text"
        case .spreadsheet:
            "tablecells"
        case .presentation:
            "rectangle.on.rectangle"
        case .text:
            "text.alignleft"
        case .other:
            "doc"
        }
    }
}

struct StudySource: Identifiable, Equatable, Hashable, Codable {
    var id = UUID()
    var url: URL
    var displayName: String
    var fileExtension: String
    var kind: StudySourceKind
    /// Security-scoped bookmark so the file stays readable after the app relaunches.
    var bookmarkData: Data?

    var isImage: Bool {
        kind == .image
    }

    init(url: URL) {
        self.url = url
        displayName = url.lastPathComponent
        fileExtension = url.pathExtension.lowercased()
        kind = StudySource.kind(for: url)
        bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves the bookmark to a current security-scoped URL when possible, so
    /// persisted sessions can re-read their files. Falls back to the stored URL.
    var accessibleURL: URL {
        guard let bookmarkData else { return url }
        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolved
        }
        return url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .text, .plainText, .rtf, .commaSeparatedText]
        let extensions = ["doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers", "md", "csv"]
        types.append(contentsOf: extensions.compactMap { UTType(filenameExtension: $0) })
        return Array(Set(types))
    }

    private static func kind(for url: URL) -> StudySourceKind {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else {
            return .other
        }

        if type.conforms(to: .image) {
            return .image
        }

        if type.conforms(to: .pdf) {
            return .pdf
        }

        if type.conforms(to: .plainText) || ["txt", "md", "csv"].contains(ext) {
            return .text
        }

        if ["xls", "xlsx", "numbers"].contains(ext) {
            return .spreadsheet
        }

        if ["ppt", "pptx", "key"].contains(ext) {
            return .presentation
        }

        if ["doc", "docx", "pages", "rtf"].contains(ext) {
            return .document
        }

        return .other
    }
}

enum StudyTurnStatus: Equatable, Codable {
    case streaming
    case done
    case cancelled
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .streaming: false
        default: true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, message
    }

    private enum Kind: String, Codable {
        case streaming, done, cancelled, failed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .streaming:
            try container.encode(Kind.streaming, forKey: .kind)
        case .done:
            try container.encode(Kind.done, forKey: .kind)
        case .cancelled:
            try container.encode(Kind.cancelled, forKey: .kind)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .streaming: self = .streaming
        case .done: self = .done
        case .cancelled: self = .cancelled
        case .failed:
            let message = (try? container.decode(String.self, forKey: .message)) ?? "The run failed."
            self = .failed(message)
        }
    }
}

struct StudyTurnUser: Identifiable, Equatable, Codable {
    var id = UUID()
    var focus: String
    var resourceKind: StudyResourceKind
    var sources: [StudySource]
    var isRefinement: Bool
    var displayPrompt: String {
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Create a \(resourceKind.title.lowercased()) from my sources"
    }
}

struct StudyTurnAssistant: Equatable, Codable {
    var markdown: String = ""
    var status: StudyTurnStatus = .streaming
    var statusMessage: String = "Starting"
    var startedAt: Date = Date()
    var finishedAt: Date?
    var downloadProgress: Double?
    var isDownloading: Bool = false
    var payload: StudyArtifactPayload?
}

struct StudyTurn: Identifiable, Equatable, Codable {
    var id = UUID()
    var user: StudyTurnUser
    var assistant: StudyTurnAssistant = StudyTurnAssistant()
}

/// A persisted study session: its own sources, transcript, and default resource kind.
struct StudySession: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    /// When true, the history list shows `title` instead of auto-deriving from the first turn.
    var titleIsCustom: Bool
    var createdAt: Date
    var updatedAt: Date
    var sources: [StudySource]
    var turns: [StudyTurn]
    var selectedResource: StudyResourceKind

    init(
        id: UUID = UUID(),
        title: String = "New session",
        titleIsCustom: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sources: [StudySource] = [],
        turns: [StudyTurn] = [],
        selectedResource: StudyResourceKind = .summary
    ) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sources = sources
        self.turns = turns
        self.selectedResource = selectedResource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        titleIsCustom = try container.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sources = try container.decode([StudySource].self, forKey: .sources)
        turns = try container.decode([StudyTurn].self, forKey: .turns)
        selectedResource = try container.decode(StudyResourceKind.self, forKey: .selectedResource)
    }

    var isEmpty: Bool {
        turns.isEmpty && sources.isEmpty
    }

    /// A short, human title for the history list (custom name or first-turn prompt).
    var derivedTitle: String {
        if titleIsCustom {
            return title
        }
        if let first = turns.first {
            let prompt = first.user.displayPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                return String(prompt.prefix(60))
            }
        }
        return title
    }

    var subtitle: String {
        let count = turns.count
        if count == 0 {
            return sources.isEmpty ? "Empty" : "\(sources.count) source\(sources.count == 1 ? "" : "s")"
        }
        return "\(count) turn\(count == 1 ? "" : "s")"
    }
}

struct RefinementSuggestion: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var systemImage: String
    var instruction: String
    var newKind: StudyResourceKind?

    static func suggestions(for kind: StudyResourceKind) -> [RefinementSuggestion] {
        let universal: [RefinementSuggestion] = [
            RefinementSuggestion(
                label: "Shorter",
                systemImage: "rectangle.compress.vertical",
                instruction: "Make the previous answer significantly shorter while preserving the essential points."
            ),
            RefinementSuggestion(
                label: "Simpler",
                systemImage: "sparkles",
                instruction: "Explain the previous answer in simpler language, assuming the student is new to the topic."
            ),
            RefinementSuggestion(
                label: "Add examples",
                systemImage: "lightbulb",
                instruction: "Add concrete examples to the previous answer to make the ideas easier to grasp."
            )
        ]
        switch kind {
        case .summary:
            return universal + [
                RefinementSuggestion(label: "Make flashcards", systemImage: "rectangle.stack", instruction: "Turn the previous answer into focused flashcards.", newKind: .flashcards),
                RefinementSuggestion(label: "Quiz me", systemImage: "checklist", instruction: "Turn the previous answer into a short quiz.", newKind: .quiz)
            ]
        case .beginnerExplanation:
            return universal + [
                RefinementSuggestion(label: "Cheat sheet", systemImage: "doc.plaintext", instruction: "Condense the previous answer into a compact cheat sheet.", newKind: .cheatSheet)
            ]
        case .flashcards:
            return universal + [
                RefinementSuggestion(label: "Quiz me", systemImage: "checklist", instruction: "Turn the previous flashcards into a quiz.", newKind: .quiz)
            ]
        case .quiz:
            return universal + [
                RefinementSuggestion(label: "Harder", systemImage: "flame", instruction: "Make the previous quiz noticeably harder, with trickier distractors."),
                RefinementSuggestion(label: "Show answers", systemImage: "checkmark.seal", instruction: "Provide a detailed answer key with explanations for the previous quiz.")
            ]
        case .cheatSheet:
            return universal + [
                RefinementSuggestion(label: "Quiz me", systemImage: "checklist", instruction: "Turn the previous cheat sheet into a quiz.", newKind: .quiz)
            ]
        }
    }
}

struct StudyExamplePrompt: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var systemImage: String
    var focus: String
    var kind: StudyResourceKind

    static let starter: [StudyExamplePrompt] = [
        StudyExamplePrompt(title: "Summarize my notes", subtitle: "Get the main ideas, fast", systemImage: "doc.text", focus: "Summarize the attached material into the most important ideas.", kind: .summary),
        StudyExamplePrompt(title: "Explain like I'm new", subtitle: "Beginner-friendly walkthrough", systemImage: "lightbulb", focus: "Explain the attached material as if I'm new to this topic.", kind: .beginnerExplanation),
        StudyExamplePrompt(title: "Make flashcards", subtitle: "Active recall, ready to drill", systemImage: "rectangle.stack", focus: "Create flashcards covering the most testable points in the attached material.", kind: .flashcards),
        StudyExamplePrompt(title: "Quiz me", subtitle: "Test what you know", systemImage: "checklist", focus: "Quiz me on the attached material with a mix of question types.", kind: .quiz)
    ]
}
