//
//  CitationSourceView.swift
//  LocalTutor
//

import AppKit
import PDFKit
import SwiftUI

struct CitationSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: CitationPresentation

    @State private var context: CitationContext?

    private var citation: SourceCitation { presentation.citation }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let source = presentation.source, source.kind == .pdf, citation.page != nil {
                CitationPDFView(url: source.accessibleURL, page: citation.page ?? 1, excerpt: citation.excerpt)
            } else {
                textContext
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 720)
        .task {
            context = await CitationContext.load(for: citation, source: presentation.source)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(citation.index)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
                .accessibilityLabel("Citation \(citation.index)")
            VStack(alignment: .leading, spacing: 2) {
                Text(citation.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                Text(locationLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let source = presentation.source {
                Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                    let url = source.accessibleURL
                    let granted = url.startAccessingSecurityScopedResource()
                    NSWorkspace.shared.open(url)
                    if granted { url.stopAccessingSecurityScopedResource() }
                }
                .buttonStyle(.glass)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glassProminent)
        }
        .padding(16)
    }

    private var locationLine: String {
        var parts: [String] = []
        if let page = citation.page {
            parts.append("Page \(page)")
        } else if let locator = citation.locator, !locator.isEmpty {
            parts.append(locator.capitalized)
        }
        if !citation.headingPath.isEmpty {
            parts.append(citation.headingPath.joined(separator: " › "))
        }
        return parts.isEmpty ? "Cited passage" : parts.joined(separator: " · ")
    }

    private var textContext: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let before = context?.before, !before.isEmpty {
                    Text(before)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(context?.passage ?? citation.excerpt)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.yellow.opacity(0.18))
                    )
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.yellow)
                            .frame(width: 4)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cited passage: \(context?.passage ?? citation.excerpt)")
                if let after = context?.after, !after.isEmpty {
                    Text(after)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }
}

struct CitationContext: Sendable {
    var before: String
    var passage: String
    var after: String

    static func load(for citation: SourceCitation, source: StudySource?) async -> CitationContext? {
        guard let source, let index = await SourceIndexStore.shared.cachedIndex(for: source) else { return nil }
        let chunks = index.chunks.sorted { $0.ordinal < $1.ordinal }
        guard let position = chunks.firstIndex(where: { $0.id == citation.chunkID })
                ?? chunks.firstIndex(where: { citation.excerpt.hasPrefix(String($0.text.prefix(80))) }) else {
            return nil
        }
        let before = position > 0 ? String(chunks[position - 1].text.suffix(600)) : ""
        let after = position + 1 < chunks.count ? String(chunks[position + 1].text.prefix(600)) : ""
        return CitationContext(before: before, passage: chunks[position].text, after: after)
    }
}

private struct CitationPDFView: NSViewRepresentable {
    let url: URL
    let page: Int
    let excerpt: String

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        load(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    private func load(into view: PDFView) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { return }
        view.document = document
        guard let target = document.page(at: max(0, page - 1)) else { return }
        view.go(to: target)

        let needle = Self.searchNeedle(from: excerpt)
        guard !needle.isEmpty else { return }
        let matches = document.findString(needle, withOptions: [.caseInsensitive])
        if let match = matches.first(where: { $0.pages.contains(target) }) ?? matches.first {
            match.color = NSColor.systemYellow.withAlphaComponent(0.5)
            view.highlightedSelections = [match]
            view.go(to: match)
        }
    }

    static func searchNeedle(from excerpt: String) -> String {
        let lines = excerpt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 24 && !$0.hasPrefix("===") && !$0.hasPrefix("#") }
        guard let line = lines.first else { return "" }
        return String(line.prefix(60))
    }
}
