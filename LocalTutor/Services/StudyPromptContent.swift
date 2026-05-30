//
//  StudyPromptContent.swift
//  LocalTutor
//

import Foundation

struct StudyPromptContent: Sendable {
    enum Block: Sendable {
        case text(String)
        case image(DocumentImage)
    }

    var systemInstruction: String
    var openingText: String
    var sourceBlocks: [Block]
    var closingText: String
    var includedImageCount: Int
    var omittedImageCount: Int
    var imageFilenames: [String]
    var warnings: [String]

    var benchmarkText: String {
        var parts: [String] = [
            systemInstruction,
            openingText
        ]

        for block in sourceBlocks {
            switch block {
            case .text(let text):
                parts.append(text)
            case .image(let image):
                parts.append("[Image: \(image.displayCaption)]")
            }
        }

        if !warnings.isEmpty {
            parts.append("Warnings:\n" + warnings.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append(closingText)

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

}
