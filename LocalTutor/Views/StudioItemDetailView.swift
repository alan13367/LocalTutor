//
//  StudioItemDetailView.swift
//  LocalTutor
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let notebookID: UUID
    let itemID: UUID

    var body: some View {
        let notebook = app.store.notebook(notebookID)
        VStack(spacing: 0) {
            if let notebook, let item = notebook.studioItems.first(where: { $0.id == itemID }) {
                header(item)
                Divider()
                content(item, notebook: notebook)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("This item was deleted", systemImage: "trash")
                Button("Close") { dismiss() }
                    .padding()
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 600, idealHeight: 760)
        .onChange(of: app.store.notebook(notebookID)?.studioItems.contains { $0.id == itemID }) { _, exists in
            if exists != true { dismiss() }
        }
    }

    private func header(_ item: StudioItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(item.kind.title) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isRunning {
                Button("Stop") { app.studio.cancel(item.id) }
                    .buttonStyle(.glass)
            } else {
                Menu {
                    Button("Copy as Markdown", systemImage: "doc.on.doc") { copy(item) }
                    Button("Export…", systemImage: "square.and.arrow.up") { export(item) }
                    Button("Save to Notes", systemImage: "note.text.badge.plus") {
                        app.saveToNote(title: item.title, markdown: StudioExport.markdown(for: item), citations: item.citations)
                    }
                    Divider()
                    Button("Create Again", systemImage: "arrow.clockwise") {
                        if let id = app.studio.generate(item.kind, focus: item.focus, in: notebookID) {
                            app.openedStudioItemID = id
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        app.studio.delete(item.id, in: notebookID)
                        dismiss()
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glassProminent)
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(_ item: StudioItem, notebook: Notebook) -> some View {
        let live = app.studio.liveGeneration(for: item.id)
        if item.isRunning {
            RunningStudioItemView(item: item, live: live)
        } else if case .failed(let message) = item.status {
            ContentUnavailableView {
                Label("Couldn't create this \(item.kind.title.lowercased())", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    if let id = app.studio.generate(item.kind, focus: item.focus, in: notebookID) {
                        app.openedStudioItemID = id
                    }
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            switch item.payload {
            case .flashcards(let deck):
                ScrollView {
                    FlashcardPlayerView(
                        title: deck.title ?? item.title,
                        cards: deck.cards,
                        reviewStates: notebook.reviewStates
                    ) { cardID, grade in
                        app.store.recordReview(cardID: cardID, grade: grade, in: notebookID)
                    }
                    .padding(24)
                }
            case .quiz(let quiz):
                ScrollView {
                    QuizPlayerView(quiz: quiz)
                        .padding(24)
                }
            case .mindMap(let root):
                MindMapView(root: root) { topic in
                    app.chat.ask("Explain \"\(topic)\" using my sources.", in: notebookID)
                    dismiss()
                }
            case .audioScript(let script):
                AudioOverviewView(script: script, itemID: item.id)
            case nil:
                ScrollView {
                    MarkdownText(text: item.markdown, citationCount: item.citations.count)
                        .environment(\.openURL, OpenURLAction { url in
                            if let index = CitationLinker.citationIndex(from: url) {
                                app.openCitation(index, in: item.citations)
                                return .handled
                            }
                            return .systemAction
                        })
                        .padding(28)
                        .frame(maxWidth: 780)
                        .frame(maxWidth: .infinity)
                    CitedSourcesRow(markdown: item.markdown, citations: item.citations) { index in
                        app.openCitation(index, in: item.citations)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func copy(_ item: StudioItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(StudioExport.markdown(for: item), forType: .string)
    }

    private func export(_ item: StudioItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(item.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? StudioExport.markdown(for: item).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct RunningStudioItemView: View {
    let item: StudioItem
    let live: LiveGeneration?

    var body: some View {
        VStack(spacing: 18) {
            StreamingStatusView(message: live?.statusMessage ?? item.statusMessage, fraction: live?.prefillFraction)
            if let live, item.kind.producesMarkdown, !live.markdown.isEmpty {
                ScrollView {
                    MarkdownText(text: live.markdown, isStreaming: true)
                        .padding(28)
                        .frame(maxWidth: 780)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Spacer()
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
                Text("Creating your \(item.kind.title.lowercased()) from \(item.sourceIDs.count) source\(item.sourceIDs.count == 1 ? "" : "s")…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.top, 20)
    }
}

enum StudioExport {
    static func markdown(for item: StudioItem) -> String {
        switch item.payload {
        case .flashcards(let deck):
            let cards = deck.cards.map { "- **\($0.front)** — \($0.back)" }.joined(separator: "\n")
            return "# \(deck.title ?? item.title)\n\n\(cards)\n"
        case .quiz(let quiz):
            let questions = quiz.questions.enumerated().map { index, question in
                var lines = ["\(index + 1). \(question.prompt)"]
                for choice in question.choices {
                    lines.append("   - \(choice)")
                }
                lines.append("   - **Answer:** \(question.correctAnswer)")
                if let explanation = question.explanation, !explanation.isEmpty {
                    lines.append("   - _\(explanation)_")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
            return "# \(quiz.title ?? item.title)\n\n\(questions)\n"
        case .mindMap(let root):
            return "# \(root.title)\n\n" + outline(root.children, depth: 0)
        case .audioScript(let script):
            let lines = script.lines.map { "**\($0.speaker == .hostA ? "Host A" : "Host B"):** \($0.text)" }
            return "# \(script.title)\n\n" + lines.joined(separator: "\n\n") + "\n"
        case nil:
            return ReasoningOutputFilter.sanitize(item.markdown)
        }
    }

    private static func outline(_ nodes: [MindMapNode], depth: Int) -> String {
        nodes.map { node in
            String(repeating: "  ", count: depth) + "- \(node.title)\n" + outline(node.children, depth: depth + 1)
        }.joined()
    }
}

// MARK: - Flashcard review

struct FlashcardReviewSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let notebookID: UUID
    @State private var sessionCards: [Flashcard] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(16)
            Divider()
            if sessionCards.isEmpty {
                ContentUnavailableView("Nothing due", systemImage: "checkmark.seal", description: Text("Come back later. New cards appear when you create flashcards."))
            } else if let notebook = app.store.notebook(notebookID) {
                ScrollView {
                    FlashcardPlayerView(
                        title: "Due today",
                        cards: sessionCards,
                        reviewStates: notebook.reviewStates
                    ) { cardID, grade in
                        app.store.recordReview(cardID: cardID, grade: grade, in: notebookID)
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear {
            sessionCards = app.store.notebook(notebookID)?.dueFlashcards() ?? []
        }
    }
}
