//
//  MarkdownParser.swift
//  LocalTutor
//

import Foundation

enum MarkdownBlock: Identifiable, Equatable {
    case heading(level: Int, text: String, id: String = UUID().uuidString)
    case paragraph(AttributedString, id: String = UUID().uuidString)
    case bulletList(items: [MarkdownListItem], id: String = UUID().uuidString)
    case numberedList(items: [MarkdownListItem], id: String = UUID().uuidString)
    case table(headers: [AttributedString], rows: [[AttributedString]], id: String = UUID().uuidString)
    case codeBlock(language: String?, code: String, id: String = UUID().uuidString)
    case quote(AttributedString, id: String = UUID().uuidString)
    case divider(id: String = UUID().uuidString)

    var id: String {
        switch self {
        case .heading(_, _, let id),
             .paragraph(_, let id),
             .bulletList(_, let id),
             .numberedList(_, let id),
             .table(_, _, let id),
             .codeBlock(_, _, let id),
             .quote(_, let id),
             .divider(let id):
            return id
        }
    }
}

struct MarkdownListItem: Equatable {
    var text: AttributedString
    var level: Int
}

enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        guard !raw.isEmpty else { return [] }
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var ordinal = 0

        func nextID(_ kind: String) -> String {
            defer { ordinal += 1 }
            return "\(kind)-\(ordinal)"
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if inner.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    code.append(inner)
                    i += 1
                }
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n"), id: nextID("code")))
                continue
            }

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider(id: nextID("divider")))
                i += 1
                continue
            }

            if let headingParts = parseHeading(trimmed) {
                blocks.append(.heading(level: headingParts.level, text: headingParts.text, id: nextID("heading")))
                i += 1
                continue
            }

            if let strongHeading = parseStrongHeading(trimmed) {
                blocks.append(.heading(level: 2, text: strongHeading, id: nextID("heading")))
                i += 1
                continue
            }

            if i + 1 < lines.count,
               isTableRow(trimmed),
               isTableSeparatorLine(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = tableCells(from: trimmed).map(inlineAttributed)
                i += 2

                var rows: [[AttributedString]] = []
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(row), !isTableSeparatorLine(row) else { break }
                    rows.append(tableCells(from: row).map(inlineAttributed))
                    i += 1
                }

                blocks.append(.table(headers: headers, rows: rows, id: nextID("table")))
                continue
            }

            if trimmed.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quoteLines.append(String(t.dropFirst(2)))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.quote(inlineAttributed(quoteLines.joined(separator: " ")), id: nextID("quote")))
                continue
            }

            if parseBulletItem(line) != nil {
                var items: [MarkdownListItem] = []
                while i < lines.count {
                    if let item = parseBulletItem(lines[i]) {
                        items.append(item)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items, id: nextID("bullet")))
                continue
            }

            if parseNumberedItem(line) != nil {
                var items: [MarkdownListItem] = []
                while i < lines.count {
                    if let item = parseNumberedItem(lines[i]) {
                        items.append(item)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.numberedList(items: items, id: nextID("numbered")))
                continue
            }

            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") || isBullet(t) || isNumbered(t) || parseHeading(t) != nil || parseStrongHeading(t) != nil || t.hasPrefix("> ") || isTableRow(t) {
                    break
                }
                paragraphLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(inlineAttributed(paragraphLines.joined(separator: " ")), id: nextID("paragraph")))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = readableInlineText(String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
        return (level, text)
    }

    private static func parseStrongHeading(_ line: String) -> String? {
        strongHeadingText(in: line, delimiter: "**")
            ?? strongHeadingText(in: line, delimiter: "__")
    }

    private static func strongHeadingText(in line: String, delimiter: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(delimiter), trimmed.count > delimiter.count * 2 else {
            return nil
        }
        let suffix = "\(delimiter):"
        let content: Substring
        if trimmed.hasSuffix(delimiter) {
            content = trimmed.dropFirst(delimiter.count).dropLast(delimiter.count)
        } else if trimmed.hasSuffix(suffix) {
            content = trimmed.dropFirst(delimiter.count).dropLast(suffix.count)
        } else {
            return nil
        }
        let text = readableInlineText(content.trimmingCharacters(in: .whitespacesAndNewlines))
        return text.isEmpty ? nil : text
    }

    private static func parseBulletItem(_ line: String) -> MarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard isBullet(trimmed) else { return nil }
        return MarkdownListItem(text: inlineAttributed(stripBullet(trimmed)), level: indentationLevel(in: line))
    }

    private static func parseNumberedItem(_ line: String) -> MarkdownListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard isNumbered(trimmed) else { return nil }
        return MarkdownListItem(text: inlineAttributed(stripNumber(trimmed)), level: indentationLevel(in: line))
    }

    private static func indentationLevel(in line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        if columns >= 4 {
            return min(columns / 4, 4)
        }
        if columns >= 2 {
            return 1
        }
        return 0
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isNumbered(_ line: String) -> Bool {
        guard let numberedPrefixRegex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return numberedPrefixRegex.firstMatch(in: line, range: range) != nil
    }

    private static func stripNumber(_ line: String) -> String {
        guard let numberedPrefixRegex else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = numberedPrefixRegex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range, in: line) else {
            return line
        }
        return String(line[swiftRange.upperBound...])
    }

    private static func isTableRow(_ line: String) -> Bool {
        tableCells(from: line).count >= 2
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let cells = tableCells(from: line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            guard let tableSeparatorCellRegex else { return false }
            let range = NSRange(cell.startIndex..<cell.endIndex, in: cell)
            return tableSeparatorCellRegex.firstMatch(in: cell, range: range) != nil
        }
    }

    private static func tableCells(from line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }

        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func inlineAttributed(_ text: String) -> AttributedString {
        let readable = readableInlineText(text)
        if let attr = try? AttributedString(
            markdown: readable,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(readable)
    }

    private static func readableInlineText(_ text: String) -> String {
        InlineLatexRenderer.render(text)
    }

    private static let numberedPrefixRegex = try? NSRegularExpression(pattern: #"^\d+\.\s"#)
    private static let tableSeparatorCellRegex = try? NSRegularExpression(pattern: #"^:?-{3,}:?$"#)
}
