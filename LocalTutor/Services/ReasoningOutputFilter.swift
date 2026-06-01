//
//  ReasoningOutputFilter.swift
//  LocalTutor
//

import Foundation

struct ReasoningOutputFilter: Sendable {
    struct Chunk: Equatable, Sendable {
        var visible: String = ""
        var reasoning: String = ""
    }

    private static let openingTag = "<think>"
    private static let closingTag = "</think>"

    private var buffer = ""
    private var isInsideReasoning = false

    mutating func append(_ chunk: String) -> Chunk {
        guard !chunk.isEmpty else { return Chunk() }

        buffer += chunk
        var output = Chunk()

        while true {
            if isInsideReasoning {
                guard let closeRange = buffer.range(of: Self.closingTag, options: .caseInsensitive) else {
                    let retained = Self.retainedSuffix(in: buffer, matchingPrefixOf: Self.closingTag)
                    output.reasoning += String(buffer.dropLast(retained.count))
                    buffer = retained
                    return output
                }
                output.reasoning += String(buffer[..<closeRange.lowerBound])
                buffer = String(buffer[closeRange.upperBound...])
                isInsideReasoning = false
                continue
            }

            guard let openRange = buffer.range(of: Self.openingTag, options: .caseInsensitive) else {
                let retained = Self.retainedSuffix(in: buffer, matchingPrefixOf: Self.openingTag)
                output.visible += String(buffer.dropLast(retained.count))
                buffer = retained
                return output
            }

            output.visible += String(buffer[..<openRange.lowerBound])
            buffer = String(buffer[openRange.upperBound...])
            isInsideReasoning = true
        }
    }

    mutating func finish() -> Chunk {
        let output = isInsideReasoning
            ? Chunk(reasoning: buffer)
            : Chunk(visible: buffer)
        buffer = ""
        isInsideReasoning = false
        return output
    }

    static func sanitize(_ text: String) -> String {
        var filter = ReasoningOutputFilter()
        let first = filter.append(text)
        let second = filter.finish()
        return first.visible + second.visible
    }

    private static func retainedSuffix(in text: String, matchingPrefixOf token: String) -> String {
        let lowerText = text.lowercased()
        let lowerToken = token.lowercased()
        let maxLength = min(lowerText.count, max(lowerToken.count - 1, 0))
        guard maxLength > 0 else { return "" }

        for length in stride(from: maxLength, through: 1, by: -1) {
            if lowerText.suffix(length) == lowerToken.prefix(length) {
                return String(text.suffix(length))
            }
        }
        return ""
    }
}
