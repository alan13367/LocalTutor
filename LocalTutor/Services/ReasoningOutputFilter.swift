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

    private static let openingTags = [
        "<think>",
        "<|channel>thought",
        "<|channel|>thought",
        "<channel|>thought",
        "<|channel>analysis",
        "<|channel|>analysis",
        "<channel|>analysis"
    ]
    private static let closingTags = [
        "</think>",
        "<channel|>",
        "<|channel>final",
        "<|channel|>final",
        "<channel|>final",
        "<|channel>answer",
        "<|channel|>answer",
        "<channel|>answer"
    ]

    private var buffer = ""
    private var isInsideReasoning = false

    mutating func append(_ chunk: String) -> Chunk {
        guard !chunk.isEmpty else { return Chunk() }

        buffer += chunk
        var output = Chunk()

        while true {
            if isInsideReasoning {
                guard let closeRange = Self.firstRange(in: buffer, matchingAnyOf: Self.closingTags) else {
                    let retained = Self.retainedSuffix(in: buffer, matchingPrefixOfAny: Self.closingTags)
                    output.reasoning += String(buffer.dropLast(retained.count))
                    buffer = retained
                    return output
                }
                output.reasoning += String(buffer[..<closeRange.lowerBound])
                buffer = String(buffer[closeRange.upperBound...])
                isInsideReasoning = false
                continue
            }

            guard let openRange = Self.firstRange(in: buffer, matchingAnyOf: Self.openingTags) else {
                let retained = Self.retainedSuffix(in: buffer, matchingPrefixOfAny: Self.openingTags)
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

    private static func firstRange(in text: String, matchingAnyOf tokens: [String]) -> Range<String.Index>? {
        tokens
            .compactMap { text.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func retainedSuffix(in text: String, matchingPrefixOfAny tokens: [String]) -> String {
        tokens
            .map { retainedSuffix(in: text, matchingPrefixOf: $0) }
            .max { $0.count < $1.count } ?? ""
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
