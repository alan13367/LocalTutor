//
//  StreamingMarkdown.swift
//  LocalTutor
//

import Foundation

final class MarkdownStreamRenderer {
    private var stableSource: Substring = ""
    private var stableBlocks: [MarkdownBlock] = []
    private var finalSource: String?
    private var finalBlocks: [MarkdownBlock] = []
    private var citationCount = -1

    func blocks(for text: String, isStreaming: Bool, citationCount: Int) -> [MarkdownBlock] {
        if citationCount != self.citationCount {
            self.citationCount = citationCount
            stableSource = ""
            stableBlocks = []
            finalSource = nil
        }

        guard isStreaming else {
            if finalSource != text {
                finalSource = text
                finalBlocks = MarkdownParser.parse(linkified(text))
            }
            return finalBlocks
        }

        let boundary = Self.stableBoundary(in: text)
        let stable = text[..<boundary]
        if stable != stableSource {
            stableSource = stable
            stableBlocks = MarkdownParser.parse(linkified(String(stable)))
        }
        let tail = MarkdownStreamHealer.heal(String(text[boundary...]))
        return stableBlocks + MarkdownParser.parse(linkified(tail), startingOrdinal: stableBlocks.count)
    }

    static func stableBoundary(in text: String) -> String.Index {
        var boundary = text.startIndex
        var insideFence = false
        var lineStart = text.startIndex
        while let newline = text[lineStart...].firstIndex(of: "\n") {
            let line = text[lineStart..<newline].trimmingCharacters(in: .whitespaces)
            lineStart = text.index(after: newline)
            if line.hasPrefix("```") {
                insideFence.toggle()
            } else if line.isEmpty, !insideFence {
                boundary = lineStart
            }
        }
        return boundary
    }

    private func linkified(_ text: String) -> String {
        citationCount > 0 ? CitationLinker.linkify(text, validRange: 1...citationCount) : text
    }
}

enum MarkdownStreamHealer {
    static func heal(_ tail: String) -> String {
        var lines = tail.components(separatedBy: "\n")
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            return tail
        }

        let pending = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
        if pending.hasPrefix("|") || isBareBlockMarker(pending) {
            lines[lines.count - 1] = ""
        }
        let complete = lines.dropLast()
        if complete.reversed().prefix(while: isTableLine).count == 1 {
            lines.remove(at: complete.count - 1)
        }

        guard var last = lines.popLast() else { return "" }
        last = closingInlineMarkers(trimmingOpenMath(trimmingOpenLink(last)))
        return (lines + [last]).joined(separator: "\n")
    }

    private static func isBareBlockMarker(_ line: String) -> Bool {
        line.range(of: #"^(#{1,6}|[-*+]|\d+\.?|>|`{1,2})$"#, options: .regularExpression) != nil
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.count > 1
    }

    private static func trimmingOpenLink(_ text: String) -> String {
        guard let open = text.lastIndex(of: "[") else { return text }
        guard let close = text[open...].firstIndex(of: "]") else {
            return String(text[..<open])
        }
        let rest = text[text.index(after: close)...]
        if rest.hasPrefix("("), !rest.contains(")") {
            return String(text[..<open])
        }
        return text
    }

    private static func trimmingOpenMath(_ text: String) -> String {
        var openIndex: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if text[index] == "$" {
                openIndex = openIndex == nil ? index : nil
            }
            index = text.index(after: index)
        }
        return openIndex.map { String(text[..<$0]) } ?? text
    }

    private static func closingInlineMarkers(_ line: String) -> String {
        var text = line
        while text.last?.isWhitespace == true {
            text.removeLast()
        }

        var stack: [String] = []
        var openedAtEnd = false
        var index = text.startIndex
        var atLineStart = true
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if atLineStart, "*-+".contains(character), next < text.endIndex, text[next] == " " {
                index = next
                atLineStart = false
                continue
            }
            if character.isWhitespace {
                index = next
                continue
            }
            atLineStart = false

            let marker: String
            if character == "`" {
                marker = "`"
            } else if character == "*", stack.last != "`" {
                marker = next < text.endIndex && text[next] == "*" ? "**" : "*"
            } else {
                index = next
                continue
            }

            let end = text.index(index, offsetBy: marker.count)
            let precededBySpace = index == text.startIndex || text[text.index(before: index)].isWhitespace
            let followedBySpace = end < text.endIndex && text[end].isWhitespace
            openedAtEnd = false
            if let position = stack.lastIndex(of: marker), marker == "`" || !precededBySpace {
                stack.remove(at: position)
            } else if marker == "`" || !followedBySpace {
                stack.append(marker)
                openedAtEnd = end == text.endIndex
            }
            index = end
        }

        if openedAtEnd, let marker = stack.popLast() {
            text.removeLast(marker.count)
            while text.last?.isWhitespace == true {
                text.removeLast()
            }
        }
        return text + stack.reversed().joined()
    }
}
