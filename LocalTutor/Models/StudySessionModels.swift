//
//  StudySessionModels.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import UniformTypeIdentifiers

enum StudyResourceKind: String, CaseIterable, Identifiable {
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

enum StudySourceKind: String {
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

struct StudySource: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var displayName: String
    var fileExtension: String
    var kind: StudySourceKind

    var isImage: Bool {
        kind == .image
    }

    init(url: URL) {
        self.url = url
        displayName = url.lastPathComponent
        fileExtension = url.pathExtension.lowercased()
        kind = StudySource.kind(for: url)
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
