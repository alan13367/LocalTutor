//
//  MarkdownParser.swift
//  LocalTutor
//

import Foundation

enum MarkdownBlock: Identifiable, Equatable {
    case heading(level: Int, text: String, id: UUID = UUID())
    case paragraph(AttributedString, id: UUID = UUID())
    case bulletList(items: [AttributedString], id: UUID = UUID())
    case numberedList(items: [AttributedString], id: UUID = UUID())
    case table(headers: [AttributedString], rows: [[AttributedString]], id: UUID = UUID())
    case codeBlock(language: String?, code: String, id: UUID = UUID())
    case quote(AttributedString, id: UUID = UUID())
    case divider(id: UUID = UUID())

    var id: UUID {
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

enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        guard !raw.isEmpty else { return [] }
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")

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
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider())
                i += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
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

                blocks.append(.table(headers: headers, rows: rows))
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
                blocks.append(.quote(inlineAttributed(quoteLines.joined(separator: " "))))
                continue
            }

            if isBullet(trimmed) {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isBullet(t) {
                        items.append(inlineAttributed(stripBullet(t)))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            if isNumbered(trimmed) {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isNumbered(t) {
                        items.append(inlineAttributed(stripNumber(t)))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.numberedList(items: items))
                continue
            }

            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") || isBullet(t) || isNumbered(t) || parseHeading(t) != nil || t.hasPrefix("> ") || isTableRow(t) {
                    break
                }
                paragraphLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(inlineAttributed(paragraphLines.joined(separator: " "))))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    private static func isNumbered(_ line: String) -> Bool {
        let pattern = #"^\d+\.\s"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func stripNumber(_ line: String) -> String {
        guard let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    private static func isTableRow(_ line: String) -> Bool {
        tableCells(from: line).count >= 2
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let cells = tableCells(from: line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
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
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attr
        }
        return AttributedString(text)
    }
}
