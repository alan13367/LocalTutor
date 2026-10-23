//
//  StudySessionModels.swift
//  LocalTutor
//
//

import Foundation
import UniformTypeIdentifiers

enum StudyResourceKind: String, CaseIterable, Identifiable, Codable {
    case ask
    case studyGuide
    case briefing
    case summary
    case beginnerExplanation
    case flashcards
    case quiz
    case cheatSheet
    case mindMap
    case audioOverview

    var id: String { rawValue }

    static var studioKinds: [StudyResourceKind] {
        [.studyGuide, .briefing, .summary, .beginnerExplanation, .cheatSheet, .flashcards, .quiz, .mindMap, .audioOverview]
    }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .studyGuide: "Study Guide"
        case .briefing: "Briefing"
        case .summary: "Summary"
        case .beginnerExplanation: "Explainer"
        case .flashcards: "Flashcards"
        case .quiz: "Quiz"
        case .cheatSheet: "Cheat Sheet"
        case .mindMap: "Mind Map"
        case .audioOverview: "Audio Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "questionmark.bubble"
        case .studyGuide: "book.pages"
        case .briefing: "doc.richtext"
        case .summary: "doc.text"
        case .beginnerExplanation: "lightbulb"
        case .flashcards: "rectangle.stack"
        case .quiz: "checklist"
        case .cheatSheet: "doc.plaintext"
        case .mindMap: "point.3.connected.trianglepath.dotted"
        case .audioOverview: "waveform"
        }
    }

    var shortDescription: String {
        switch self {
        case .ask: "Source Q&A"
        case .studyGuide: "Key terms, questions, essay prompts"
        case .briefing: "Executive overview of every source"
        case .summary: "Main ideas, fast"
        case .beginnerExplanation: "Beginner walkthrough"
        case .flashcards: "Spaced-repetition deck"
        case .quiz: "Interactive test"
        case .cheatSheet: "Compact exam reference"
        case .mindMap: "Visual map of topics"
        case .audioOverview: "Two-host spoken recap"
        }
    }

    var composerPlaceholder: String {
        switch self {
        case .ask: "Ask anything about your sources."
        default: "Optional: focus on a topic or chapter."
        }
    }

    var promptInstruction: String {
        switch self {
        case .ask:
            "Answer the student's question directly using the provided sources. Do not turn the answer into a beginner explanation unless the student asks for that."
        case .studyGuide:
            "Create a complete study guide with these sections: Overview (2-3 sentences), Key Concepts (each with a one-line definition), Short-Answer Practice Questions (8-10, with brief answers at the end), Essay Prompts (3-4), and a Glossary of important terms."
        case .briefing:
            "Write a briefing document: an executive summary paragraph, then the most important themes and findings as headed sections with supporting facts, notable quotes or figures, and a closing list of open questions."
        case .summary:
            "Create a structured study summary of all the provided material. Give every major topic its own short section with 2-5 bullet points covering its key definitions and results, keep the sources' order, and do not go deep into any single topic so that nothing is left out. End with a short review checklist. Stay under about 900 words."
        case .beginnerExplanation:
            "Explain the material as if the student is new to the topic. Use simple language, analogies only when they clarify, and define important terms."
        case .flashcards:
            "Create flashcards with clear fronts and concise backs. Prioritize facts, definitions, commands, formulas, and distinctions likely to be tested."
        case .quiz:
            "Create a quiz with a mix of multiple choice, true/false, and short-answer questions that test understanding, not trivia."
        case .cheatSheet:
            "Create a compact exam cheat sheet with formulas, commands, definitions, pitfalls, and high-yield reminders."
        case .mindMap:
            "Create a hierarchical mind map of the material: one central topic, 4-7 main branches, and 2-5 short sub-points per branch."
        case .audioOverview:
            "Write a lively, accurate two-host podcast conversation that teaches the material. Host A guides the discussion and asks questions; Host B explains with examples. Open with a hook, cover the key ideas in a logical order, and close with a quick recap."
        }
    }

    var composerActionTitle: String {
        self == .ask ? "Ask" : "Create"
    }

    var allowsEmptyFocus: Bool {
        self != .ask
    }

    var producesMarkdown: Bool {
        switch self {
        case .flashcards, .quiz, .mindMap, .audioOverview: false
        default: true
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
    var isEnabled: Bool = true
    var addedAt: Date = Date()
    var guide: SourceGuide?

    var isImage: Bool {
        kind == .image
    }

    init(url: URL) {
        self.url = url
        displayName = url.lastPathComponent
        fileExtension = url.pathExtension.lowercased()
        kind = StudySource.kind(for: url)
        bookmarkData = StudySource.makeBookmark(for: url)
    }

    static func makeBookmark(for url: URL) -> Data? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, displayName, fileExtension, kind, bookmarkData, isEnabled, addedAt, guide
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? url.lastPathComponent
        fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? url.pathExtension.lowercased()
        kind = (try? container.decode(StudySourceKind.self, forKey: .kind)) ?? StudySource.kind(for: url)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        guide = try? container.decodeIfPresent(SourceGuide.self, forKey: .guide)
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
        supportedContentTypes(supportsVision: true)
    }

    static func supportedContentTypes(supportsVision: Bool) -> [UTType] {
        var types: [UTType] = [.pdf, .text, .plainText, .rtf, .commaSeparatedText]
        if supportsVision {
            types.append(.image)
        }
        let extensions = ["doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers", "md", "csv", "epub", "webarchive", "html", "json", "xml"]
        types.append(contentsOf: extensions.compactMap { UTType(filenameExtension: $0) })
        return Array(Set(types))
    }

    static func kind(for url: URL) -> StudySourceKind {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else {
            return .other
        }

        if type.conforms(to: .image) {
            return .image
        }

        if ["html", "htm", "xhtml", "webarchive", "epub"].contains(ext) {
            return .document
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
        if resourceKind == .ask {
            return "Ask about my sources"
        }
        return "Create a \(resourceKind.title.lowercased()) from my sources"
    }
}

struct StudyTurnAssistant: Equatable, Codable {
    var markdown: String = ""
    var reasoning: String = ""
    var status: StudyTurnStatus = .streaming
    var statusMessage: String = "Starting"
    var startedAt: Date = Date()
    var finishedAt: Date?
    var downloadProgress: Double?
    var isDownloading: Bool = false
    var payload: StudyArtifactPayload?
    var citations: [SourceCitation] = []
    var profileName: String?

    private enum CodingKeys: String, CodingKey {
        case markdown
        case reasoning
        case status
        case statusMessage
        case startedAt
        case finishedAt
        case downloadProgress
        case isDownloading
        case payload
        case citations
        case profileName
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markdown = (try? container.decode(String.self, forKey: .markdown)) ?? ""
        reasoning = (try? container.decode(String.self, forKey: .reasoning)) ?? ""
        status = (try? container.decode(StudyTurnStatus.self, forKey: .status)) ?? .done
        statusMessage = (try? container.decode(String.self, forKey: .statusMessage)) ?? "Ready"
        startedAt = (try? container.decode(Date.self, forKey: .startedAt)) ?? Date()
        finishedAt = try? container.decode(Date.self, forKey: .finishedAt)
        downloadProgress = try? container.decode(Double.self, forKey: .downloadProgress)
        isDownloading = (try? container.decode(Bool.self, forKey: .isDownloading)) ?? false
        payload = try? container.decode(StudyArtifactPayload.self, forKey: .payload)
        citations = (try? container.decode([SourceCitation].self, forKey: .citations)) ?? []
        profileName = try? container.decode(String.self, forKey: .profileName)
    }
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
        selectedResource: StudyResourceKind = .ask
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
    var id: String { label }
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
        case .ask:
            return universal + [
                RefinementSuggestion(label: "Make flashcards", systemImage: "rectangle.stack", instruction: "Turn the previous answer into focused flashcards.", newKind: .flashcards),
                RefinementSuggestion(label: "Quiz me", systemImage: "checklist", instruction: "Turn the previous answer into a short quiz.", newKind: .quiz)
            ]
        default:
            return universal
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
        StudyExamplePrompt(title: "Ask a question", subtitle: "Direct source Q&A", systemImage: "questionmark.bubble", focus: "What should I know first from these sources?", kind: .ask),
        StudyExamplePrompt(title: "Summarize my notes", subtitle: "Get the main ideas, fast", systemImage: "doc.text", focus: "Summarize the attached material into the most important ideas.", kind: .summary),
        StudyExamplePrompt(title: "Explain like I'm new", subtitle: "Beginner-friendly walkthrough", systemImage: "lightbulb", focus: "Explain the attached material as if I'm new to this topic.", kind: .beginnerExplanation),
        StudyExamplePrompt(title: "Make flashcards", subtitle: "Active recall, ready to drill", systemImage: "rectangle.stack", focus: "Create flashcards covering the most testable points in the attached material.", kind: .flashcards),
        StudyExamplePrompt(title: "Quiz me", subtitle: "Test what you know", systemImage: "checklist", focus: "Quiz me on the attached material with a mix of question types.", kind: .quiz)
    ]
}
