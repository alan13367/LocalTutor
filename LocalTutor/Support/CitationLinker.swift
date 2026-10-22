//
//  CitationLinker.swift
//  LocalTutor
//

import Foundation
import SwiftUI

enum CitationLinker {
    static let scheme = "cite"

    private static let markerRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,3}(?:\s*[,;]\s*\d{1,3})*)\](?!\()"#
    )

    static func linkify(_ markdown: String, validRange: ClosedRange<Int>?) -> String {
        guard let validRange, let regex = markerRegex, markdown.contains("[") else {
            return markdown
        }
        var result = ""
        var cursor = markdown.startIndex
        let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        for match in matches {
            guard let whole = Range(match.range, in: markdown),
                  let body = Range(match.range(at: 1), in: markdown) else { continue }
            let numbers = markdown[body]
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !numbers.isEmpty, numbers.allSatisfy(validRange.contains) else { continue }
            result += markdown[cursor..<whole.lowerBound]
            result += numbers.map { "[\($0)](\(scheme):\($0))" }.joined()
            cursor = whole.upperBound
        }
        result += markdown[cursor...]
        return result
    }

    static func citationIndex(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }

    static func referencedIndexes(in markdown: String) -> [Int] {
        guard let regex = markerRegex else { return [] }
        var seen: [Int] = []
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let body = Range(match.range(at: 1), in: markdown) else { continue }
            for value in markdown[body].split(whereSeparator: { $0 == "," || $0 == ";" }) {
                if let index = Int(value.trimmingCharacters(in: .whitespaces)), !seen.contains(index) {
                    seen.append(index)
                }
            }
        }
        return seen
    }

    static func styled(_ attributed: AttributedString) -> AttributedString {
        var copy = attributed
        for run in copy.runs {
            guard let link = run.link, link.scheme == scheme else { continue }
            let range = run.range
            let label = String(copy[range].characters)
            var badge = AttributedString(label)
            badge.link = link
            badge.font = .caption2.weight(.bold)
            badge.foregroundColor = .accentColor
            badge.baselineOffset = 5
            copy.replaceSubrange(range, with: badge)
        }
        return copy
    }
}
