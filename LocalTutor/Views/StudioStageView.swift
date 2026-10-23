//
//  StudioStageView.swift
//  LocalTutor
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared chrome

struct StageHeader<Title: View, Actions: View>: View {
    @Environment(AppModel.self) private var app
    let symbol: String
    let tint: Color
    let eyebrow: String
    var detail: String = ""
    var isWorking = false
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            StudioBadge(symbol: symbol, tint: tint, size: 44, isWorking: isWorking)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                    if !detail.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .font(.caption)
                title
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                actions
                Button {
                    app.showChat()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help("Back to chat (Esc)")
                .accessibilityLabel("Close and return to chat")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct StageIconButton: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct StageMoreMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }
}

struct StageWash: View {
    let tint: Color

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.16), tint.opacity(0.05), tint.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Studio item

struct StudioItemStage: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    let item: StudioItem

    @State private var copied = false
    @State private var savedToNotes = false

    private var live: LiveGeneration? { app.studio.liveGeneration(for: item.id) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top) {
                StageHeader(
                    symbol: item.kind.systemImage,
                    tint: item.kind.tint,
                    eyebrow: item.kind.title,
                    detail: detail,
                    isWorking: item.isRunning
                ) {
                    Text(item.title)
                } actions: {
                    actions
                }
            }
            .background { StageWash(tint: item.kind.tint) }
    }

    private var detail: String {
        if item.isRunning {
            return live?.statusMessage ?? item.statusMessage
        }
        switch item.status {
        case .failed: return "Didn't finish"
        case .cancelled: return "Stopped early"
        default: break
        }
        let sources = item.sourceIDs.isEmpty ? nil : "\(item.sourceIDs.count) source\(item.sourceIDs.count == 1 ? "" : "s")"
        return [item.payload?.itemCountDescription, sources, item.createdAt.formatted(.relative(presentation: .named))]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var hasContent: Bool {
        item.payload != nil || (item.kind.producesMarkdown && !item.markdown.isEmpty)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if item.isRunning {
            Button {
                app.studio.cancel(item.id)
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.glass)
            .help("Stop creating")
        } else {
            if hasContent {
                StageIconButton(
                    title: savedToNotes ? "Saved to Notes" : "Save to Notes",
                    systemImage: savedToNotes ? "checkmark" : "note.text.badge.plus",
                    action: saveToNotes
                )
                StageIconButton(
                    title: copied ? "Copied" : "Copy as Markdown",
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                    action: copy
                )
            }
            StageMoreMenu {
                if hasContent {
                    Button("Export as Markdown…", systemImage: "square.and.arrow.up", action: export)
                }
                Button("Create Again", systemImage: "arrow.clockwise") {
                    app.createStudioItem(item.kind, focus: item.focus, in: notebook.id)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    app.studio.delete(item.id, in: notebook.id)
                    app.showChat()
                }
            }
        }
    }

    private func saveToNotes() {
        app.saveToNote(title: item.title, markdown: StudioExport.markdown(for: item), citations: item.citations)
        flash($savedToNotes)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(StudioExport.markdown(for: item), forType: .string)
        flash($copied)
    }

    private func flash(_ flag: Binding<Bool>) {
        withAnimation(.snappy) { flag.wrappedValue = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { flag.wrappedValue = false }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(item.title).md"
        let markdown = StudioExport.markdown(for: item)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = item.status {
            unavailable(
                title: "Couldn't create this \(item.kind.title.lowercased())",
                systemImage: "exclamationmark.triangle",
                message: message
            )
        } else if item.kind.producesMarkdown {
            let markdown = live?.markdown ?? item.markdown
            if markdown.isEmpty {
                if item.isRunning {
                    creating
                } else {
                    stopped
                }
            } else {
                StudioDocumentView(
                    markdown: markdown,
                    isStreaming: item.isRunning,
                    citations: live?.citations ?? item.citations,
                    caption: item.status == .cancelled ? "Stopped before finishing" : item.statusMessage
                )
            }
        } else if item.isRunning {
            creating
        } else {
            switch item.payload {
            case .flashcards(let deck):
                ScrollView {
                    FlashcardPlayerView(cards: deck.cards, reviewStates: notebook.reviewStates) { cardID, grade in
                        app.store.recordReview(cardID: cardID, grade: grade, in: notebook.id)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            case .quiz(let quiz):
                ScrollView {
                    QuizPlayerView(quiz: quiz, tint: item.kind.tint)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 740)
                        .frame(maxWidth: .infinity)
                }
            case .mindMap(let root):
                MindMapView(root: root) { topic in
                    app.askInChat("Explain \"\(topic)\" using my sources.", in: notebook.id)
                }
            case .audioScript(let script):
                AudioOverviewView(script: script, itemID: item.id, tint: item.kind.tint)
            case nil:
                stopped
            }
        }
    }

    private var creating: some View {
        StudioCreatingView(
            kind: item.kind,
            status: live?.statusMessage ?? item.statusMessage,
            fraction: live?.prefillFraction,
            reasoning: live?.reasoning ?? "",
            sourceCount: item.sourceIDs.count
        )
    }

    private var stopped: some View {
        unavailable(
            title: "This \(item.kind.title.lowercased()) was stopped",
            systemImage: item.kind.systemImage,
            message: "It was stopped before anything was ready. Create it again whenever you like."
        )
    }

    private func unavailable(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 10) {
                Button("Back to Chat") { app.showChat() }
                    .buttonStyle(.glass)
                Button("Create Again") {
                    app.createStudioItem(item.kind, focus: item.focus, in: notebook.id)
                }
                .buttonStyle(.glassProminent)
                .tint(item.kind.tint)
            }
            .controlSize(.large)
        }
    }
}

private struct StudioCreatingView: View {
    let kind: StudyResourceKind
    let status: String
    let fraction: Double?
    let reasoning: String
    let sourceCount: Int

    var body: some View {
        VStack(spacing: 20) {
            ripple
            VStack(spacing: 6) {
                Text("Creating your \(kind.title.lowercased())")
                    .font(.title2.weight(.semibold))
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: status)
            }
            if let fraction {
                DownloadProgressMeter(fraction: fraction, label: "Reading sources")
                    .frame(width: 240)
                    .tint(kind.tint)
            }
            if !thought.isEmpty {
                Text(thought)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: 460)
                    .accessibilityHidden(true)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ripple: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (time / 2.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(kind.tint.opacity(0.45 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: 84 + 96 * phase, height: 84 + 96 * phase)
                }
                StudioBadge(symbol: kind.systemImage, tint: kind.tint, size: 76)
            }
        }
        .frame(width: 190, height: 190)
        .accessibilityHidden(true)
    }

    private var thought: String {
        let line = reasoning.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let cleaned = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned.count > 160 ? "…" + cleaned.suffix(160) : cleaned
    }

    private var footnote: String {
        let keepsGoing = "Keeps going if you return to chat"
        guard sourceCount > 0 else { return keepsGoing }
        return "From \(sourceCount) source\(sourceCount == 1 ? "" : "s") · \(keepsGoing.lowercased())"
    }
}

private struct StudioDocumentView: View {
    @Environment(AppModel.self) private var app
    let markdown: String
    let isStreaming: Bool
    let citations: [SourceCitation]
    let caption: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MarkdownText(text: markdown, isStreaming: isStreaming, citationCount: citations.count)
                    .environment(\.openURL, OpenURLAction { url in
                        if let index = CitationLinker.citationIndex(from: url) {
                            app.openCitation(index, in: citations)
                            return .handled
                        }
                        return .systemAction
                    })
                if !isStreaming {
                    CitedSourcesRow(markdown: markdown, citations: citations) { index in
                        app.openCitation(index, in: citations)
                    }
                    if !caption.isEmpty, caption != "Ready" {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Flashcard review

struct FlashcardReviewStage: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    @State private var sessionCards: [Flashcard]

    init(notebook: Notebook) {
        self.notebook = notebook
        _sessionCards = State(initialValue: notebook.dueFlashcards())
    }

    var body: some View {
        Group {
            if sessionCards.isEmpty {
                ContentUnavailableView(
                    "Nothing due",
                    systemImage: "checkmark.seal",
                    description: Text("Come back later. New cards appear when you create flashcards.")
                )
            } else {
                ScrollView {
                    FlashcardPlayerView(cards: sessionCards, reviewStates: notebook.reviewStates) { cardID, grade in
                        app.store.recordReview(cardID: cardID, grade: grade, in: notebook.id)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            StageHeader(
                symbol: StudioStyle.reviewSymbol,
                tint: StudioStyle.reviewTint,
                eyebrow: "Review",
                detail: "\(sessionCards.count) due of \(notebook.allFlashcards.count) cards"
            ) {
                Text("Spaced repetition")
            } actions: {
                EmptyView()
            }
        }
        .background { StageWash(tint: StudioStyle.reviewTint) }
    }
}

// MARK: - Note

struct NoteStage: View {
    @Environment(AppModel.self) private var app
    let notebookID: UUID
    let note: StudyNote

    @State private var title: String
    @State private var markdown: String
    @State private var isPreviewing: Bool
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field {
        case title
        case body
    }

    init(notebookID: UUID, note: StudyNote) {
        self.notebookID = notebookID
        self.note = note
        let isBlank = note.markdown.isEmpty && note.title == "New note"
        _title = State(initialValue: isBlank ? "" : note.title)
        _markdown = State(initialValue: note.markdown)
        _isPreviewing = State(initialValue: !note.markdown.isEmpty)
    }

    var body: some View {
        Group {
            if isPreviewing {
                ScrollView {
                    MarkdownText(text: markdown, citationCount: note.citations.count)
                        .environment(\.openURL, OpenURLAction { url in
                            if let index = CitationLinker.citationIndex(from: url) {
                                app.openCitation(index, in: note.citations)
                                return .handled
                            }
                            return .systemAction
                        })
                        .padding(.horizontal, 36)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                        .frame(maxWidth: 800, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            } else {
                TextEditor(text: $markdown)
                    .font(.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.horizontal, 31)
                    .padding(.top, 8)
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) { header }
        .background { StageWash(tint: StudioStyle.noteTint) }
        .onAppear {
            if !isPreviewing {
                focus = title.isEmpty ? .title : .body
            }
        }
        .onChange(of: title) { scheduleSave() }
        .onChange(of: markdown) { scheduleSave() }
        .onDisappear(perform: finish)
    }

    private var header: some View {
        StageHeader(
            symbol: StudioStyle.noteSymbol,
            tint: StudioStyle.noteTint,
            eyebrow: "Note",
            detail: "Edited \(note.updatedAt.formatted(.relative(presentation: .named)))"
        ) {
            TextField("Untitled note", text: $title)
                .textFieldStyle(.plain)
                .focused($focus, equals: .title)
                .onSubmit {
                    isPreviewing = false
                    focus = .body
                }
        } actions: {
            Picker("Mode", selection: $isPreviewing) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            StageMoreMenu {
                Button("Copy as Markdown", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(markdown, forType: .string)
                }
                Divider()
                Button("Delete Note", systemImage: "trash", role: .destructive) {
                    saveTask?.cancel()
                    app.store.deleteNote(note.id, in: notebookID)
                    app.showChat()
                }
            }
        }
    }

    private var storedNote: StudyNote? {
        app.store.notebook(notebookID)?.notes.first { $0.id == note.id }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        guard let stored = storedNote else { return }
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled note" : title
        guard resolvedTitle != stored.title || markdown != stored.markdown else { return }
        app.store.updateNote(note.id, in: notebookID) { note in
            note.title = resolvedTitle
            note.markdown = markdown
        }
    }

    private func finish() {
        saveTask?.cancel()
        guard storedNote != nil else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, trimmedTitle.isEmpty || trimmedTitle == "New note" {
            app.store.deleteNote(note.id, in: notebookID)
            return
        }
        persist()
    }
}

// MARK: - Export

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
