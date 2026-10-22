//
//  ChatPanel.swift
//  LocalTutor
//

import AppKit
import SwiftUI

struct ChatPanel: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    var onAddSources: () -> Void

    var body: some View {
        let chat = app.store.selectedChat(in: notebook.id)
        VStack(spacing: 0) {
            if let chat, !chat.turns.isEmpty {
                ChatTranscript(notebook: notebook, chat: chat)
                    .frame(maxHeight: .infinity)
            } else {
                ChatEmptyState(notebook: notebook, onAddSources: onAddSources)
                    .frame(maxHeight: .infinity)
            }
            ChatComposer(notebook: notebook)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .padding(.top, 6)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ChatThreadMenu(notebook: notebook, current: chat)
            }
        }
    }
}

// MARK: - Thread menu

private struct ChatThreadMenu: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    let current: NotebookChat?

    var body: some View {
        Menu {
            Button("New Chat", systemImage: "square.and.pencil") {
                app.store.newChat(in: notebook.id)
            }
            .disabled(app.chat.isGenerating)
            Divider()
            ForEach(notebook.chats.sorted { $0.updatedAt > $1.updatedAt }) { chat in
                Button {
                    app.store.selectedChatIDs[notebook.id] = chat.id
                } label: {
                    if chat.id == current?.id {
                        Label(chat.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(chat.displayTitle)
                    }
                }
            }
            if let current, notebook.chats.count > 1 || !current.turns.isEmpty {
                Divider()
                Button("Delete This Chat", systemImage: "trash", role: .destructive) {
                    app.store.deleteChat(current.id, in: notebook.id)
                }
                .disabled(app.chat.isRunning(chatID: current.id))
            }
        } label: {
            Label(current?.displayTitle ?? "Chat", systemImage: "bubble.left.and.text.bubble.right")
        }
        .help("Switch chats")
    }
}

// MARK: - Transcript

private struct ChatTranscript: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    let chat: NotebookChat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(chat.turns) { turn in
                        ChatTurnView(
                            turn: turn,
                            live: app.chat.liveGeneration(for: turn.id),
                            notebookID: notebook.id
                        )
                        .id(turn.id)
                    }
                    if let suggestions = refinementSuggestions {
                        RefinementChips(suggestions: suggestions) { suggestion in
                            app.handleRefinement(suggestion, lastQuestion: chat.turns.last?.user.focus)
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: chat.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: app.chat.live?.markdown.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.id) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var refinementSuggestions: [RefinementSuggestion]? {
        guard !app.chat.isGenerating, let last = chat.turns.last, last.assistant.status == .done else { return nil }
        return RefinementSuggestion.suggestions(for: .ask)
    }
}

struct ChatTurnView: View {
    @Environment(AppModel.self) private var app
    let turn: StudyTurn
    let live: LiveGeneration?
    let notebookID: UUID

    @State private var showsReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            userBubble
            assistantBody
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
            Text(turn.user.displayPrompt)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
                .accessibilityLabel("You asked: \(turn.user.displayPrompt)")
        }
    }

    private var markdown: String { live?.markdown ?? turn.assistant.markdown }
    private var reasoning: String { live?.reasoning ?? turn.assistant.reasoning }
    private var citations: [SourceCitation] { live?.citations ?? turn.assistant.citations }
    private var isStreaming: Bool { turn.assistant.status == .streaming }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isStreaming, markdown.isEmpty {
                StreamingStatusView(
                    message: live?.statusMessage ?? turn.assistant.statusMessage,
                    fraction: live?.prefillFraction
                )
            }

            if !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showsReasoning) {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(isStreaming && markdown.isEmpty ? "Thinking…" : "Reasoning", systemImage: "brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if !markdown.isEmpty {
                MarkdownText(text: markdown, isStreaming: isStreaming, citationCount: citations.count)
                    .environment(\.openURL, OpenURLAction { url in
                        if let index = CitationLinker.citationIndex(from: url) {
                            app.openCitation(index, in: citations)
                            return .handled
                        }
                        return .systemAction
                    })
            }

            if case .failed(let message) = turn.assistant.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isStreaming {
                CitedSourcesRow(markdown: markdown, citations: citations) { index in
                    app.openCitation(index, in: citations)
                }
                footer
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(markdown, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy answer")
            .accessibilityLabel("Copy answer")

            Button {
                app.saveToNote(title: turn.user.displayPrompt, markdown: markdown, citations: citations)
            } label: {
                Image(systemName: "note.text.badge.plus")
            }
            .help("Save to notes")
            .accessibilityLabel("Save to notes")
            .disabled(markdown.isEmpty)

            Button {
                app.chat.regenerate(turn, in: notebookID)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Regenerate")
            .accessibilityLabel("Regenerate answer")
            .disabled(app.chat.isGenerating)

            Spacer()

            Text(footerCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var footerCaption: String {
        [turn.assistant.profileName, turn.assistant.statusMessage]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "Ready" }
            .joined(separator: " · ")
    }
}

struct StreamingStatusView: View {
    let message: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Reading sources")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CitedSourcesRow: View {
    let markdown: String
    let citations: [SourceCitation]
    var onOpen: (Int) -> Void

    var body: some View {
        let referenced = CitationLinker.referencedIndexes(in: markdown)
            .compactMap { index in citations.first { $0.index == index } }
        if !referenced.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(referenced.prefix(12)) { citation in
                    Button {
                        onOpen(citation.index)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(citation.index)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Circle().fill(Color.accentColor))
                            Text(citation.shortLabel)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(String(citation.excerpt.prefix(240)) + (citation.excerpt.count > 240 ? "…" : ""))
                }
            }
        }
    }
}

// MARK: - Empty state

private struct ChatEmptyState: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    var onAddSources: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                Image(systemName: notebook.symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 84, height: 84)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .circle)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(notebook.sources.isEmpty ? "Start with your sources" : "Ask about \(notebook.title)")
                        .font(.title.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if notebook.sources.isEmpty {
                    Button("Add Sources…", action: onAddSources)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                } else {
                    suggestions
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        if notebook.sources.isEmpty {
            return "Add lecture slides, textbooks or notes. Everything stays on this Mac."
        }
        return "Answers cite your sources. Click a citation to see the passage."
    }

    private var suggestedQuestions: [String] {
        let fromGuides = notebook.enabledSources.compactMap(\.guide).flatMap(\.questions)
        if !fromGuides.isEmpty {
            return Array(fromGuides.prefix(4))
        }
        return [
            "What are the most important ideas in these sources?",
            "Explain the hardest concept here in simple terms.",
            "What would likely come up on an exam about this?",
            "Summarize each source in two sentences."
        ]
    }

    private var suggestions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(suggestedQuestions, id: \.self) { question in
                Button {
                    app.chat.ask(question, in: notebook.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(question)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                .disabled(app.models.selectedProfile == nil || app.chat.isGenerating)
            }
        }
    }
}

// MARK: - Composer

private struct ChatComposer: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var chat = app.chat
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $chat.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.vertical, 8)
                .padding(.leading, 6)
                .accessibilityLabel("Ask a question")

            if app.chat.isRunning(chatID: app.store.selectedChatID(in: notebook.id) ?? UUID()) {
                Button {
                    app.chat.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .disabled(!app.chat.canSend(in: notebook))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (↩)")
                .accessibilityLabel("Send question")
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onAppear { isFocused = true }
    }

    private var placeholder: String {
        if app.models.selectedProfile == nil {
            return "Choose a model in Settings to start"
        }
        if app.chat.willAnswerWithSystemModel {
            return "Ask now: Apple Intelligence answers until your model is downloaded"
        }
        if notebook.enabledSources.isEmpty {
            return "Ask anything, or add sources to ground answers"
        }
        return "Ask about \(notebook.enabledSources.count) source\(notebook.enabledSources.count == 1 ? "" : "s")…"
    }

    private func send() {
        app.chat.send(in: notebook.id)
    }
}
