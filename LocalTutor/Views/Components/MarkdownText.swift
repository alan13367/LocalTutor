//
//  MarkdownText.swift
//  LocalTutor
//
//  Streaming-safe markdown renderer using native AttributedString.
//  Splits the text into block elements (headings, paragraphs, lists,
//  fenced code blocks) and only re-parses at safe boundaries while
//  the model is still streaming.
//

import SwiftUI

struct MarkdownText: View {
    let text: String
    var isStreaming: Bool = false

    @State private var blocks: [MarkdownBlock] = []
    @State private var lastParsedLength: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
            if isStreaming {
                StreamingCaret()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { rebuild(force: true) }
        .onChange(of: text) { _, _ in
            maybeRebuild()
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { rebuild(force: true) }
        }
    }

    private func maybeRebuild() {
        if !isStreaming {
            rebuild(force: true)
            return
        }
        // Only re-parse at safe boundaries to keep streaming smooth.
        let suffix = text.suffix(6)
        let atBoundary = suffix.contains("\n") || text.hasSuffix(". ") || text.hasSuffix("```\n") || text.hasSuffix("? ") || text.hasSuffix("! ")
        let grewALot = text.count - lastParsedLength > 220
        guard atBoundary || grewALot else { return }
        rebuild(force: false)
    }

    private func rebuild(force: Bool) {
        if !force && text.count == lastParsedLength { return }
        blocks = MarkdownParser.parse(text)
        lastParsedLength = text.count
    }
}

// MARK: - Block model

enum MarkdownBlock: Identifiable, Equatable {
    case heading(level: Int, text: String, id: UUID = UUID())
    case paragraph(AttributedString, id: UUID = UUID())
    case bulletList(items: [AttributedString], id: UUID = UUID())
    case numberedList(items: [AttributedString], id: UUID = UUID())
    case codeBlock(language: String?, code: String, id: UUID = UUID())
    case quote(AttributedString, id: UUID = UUID())
    case divider(id: UUID = UUID())

    var id: UUID {
        switch self {
        case .heading(_, _, let id),
             .paragraph(_, let id),
             .bulletList(_, let id),
             .numberedList(_, let id),
             .codeBlock(_, _, let id),
             .quote(_, let id),
             .divider(let id):
            return id
        }
    }
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        guard !raw.isEmpty else { return [] }
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
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

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider())
                i += 1
                continue
            }

            // Headings
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Block quote
            if trimmed.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") {
                        quoteLines.append(String(t.dropFirst(2)))
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.quote(inlineAttributed(quoteLines.joined(separator: " "))))
                continue
            }

            // Bullet list
            if isBullet(trimmed) {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isBullet(t) {
                        items.append(inlineAttributed(stripBullet(t)))
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            // Numbered list
            if isNumbered(trimmed) {
                var items: [AttributedString] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if isNumbered(t) {
                        items.append(inlineAttributed(stripNumber(t)))
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.numberedList(items: items))
                continue
            }

            // Paragraph: join consecutive non-blank, non-special lines
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") || isBullet(t) || isNumbered(t) || parseHeading(t) != nil || t.hasPrefix("> ") {
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

    private static func inlineAttributed(_ text: String) -> AttributedString {
        // Try full inline markdown first (handles **bold**, *italic*, `code`, [links])
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

// MARK: - Block rendering

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text, _):
            Text(text)
                .font(headingFont(for: level))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 4 : 0)
                .textSelection(.enabled)

        case .paragraph(let attr, _):
            Text(attr)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bulletList(let items, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

        case .numberedList(let items, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .font(.body.monospacedDigit())
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

        case .codeBlock(let language, let code, _):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

        case .quote(let attr, _):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(attr)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .divider:
            Divider()
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

private struct StreamingCaret: View {
    @State private var on: Bool = true

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(on ? 0.9 : 0.2))
            .frame(width: 8, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                    on.toggle()
                }
            }
    }
}
