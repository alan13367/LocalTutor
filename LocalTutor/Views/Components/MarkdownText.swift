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
                        Text(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 22)
                }
            }

        case .numberedList(let items, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .foregroundStyle(.secondary)
                            .font(.body.monospacedDigit())
                        Text(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 22)
                }
            }

        case .table(let headers, let rows, _):
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            MarkdownTableCell(text: headers[column], isHeader: true)
                        }
                    }

                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(headers.indices, id: \.self) { column in
                                MarkdownTableCell(
                                    text: cellText(in: rows[row], column: column),
                                    isHeader: false
                                )
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                )
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

    private func cellText(in row: [AttributedString], column: Int) -> AttributedString {
        guard column < row.count else {
            return AttributedString("")
        }

        return row[column]
    }
}

private struct MarkdownTableCell: View {
    let text: AttributedString
    let isHeader: Bool

    var body: some View {
        Text(text)
            .font(isHeader ? .callout.weight(.semibold) : .callout)
            .foregroundStyle(.primary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHeader ? Color.primary.opacity(0.07) : Color.primary.opacity(0.025))
            .border(Color.primary.opacity(0.10), width: 0.5)
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
