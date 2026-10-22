//
//  StudioPanel.swift
//  LocalTutor
//

import SwiftUI

struct StudioPanel: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook

    @State private var focus = ""
    @State private var editingNote: StudyNote?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generators
                if !dueCards.isEmpty || !notebook.allFlashcards.isEmpty {
                    reviewCard
                }
                outputs
                notes
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(item: $editingNote) { note in
            NoteEditorView(notebookID: notebook.id, note: note)
        }
    }

    private var dueCards: [Flashcard] {
        notebook.dueFlashcards()
    }

    // MARK: Generators

    private var generators: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Studio")
                .font(.headline)
            TextField("Focus (optional), e.g. \"Chapter 3\"", text: $focus)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("Focus topic for generated materials")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(StudyResourceKind.studioKinds) { kind in
                    Button {
                        generate(kind)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(height: 20)
                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    .disabled(!canGenerate)
                    .help(canGenerate ? "\(kind.title): \(kind.shortDescription)" : disabledReason)
                    .accessibilityLabel("Create \(kind.title)")
                    .accessibilityHint(kind.shortDescription)
                }
            }
        }
    }

    private var canGenerate: Bool {
        app.models.selectedProfile != nil && !notebook.enabledSources.isEmpty
    }

    private var disabledReason: String {
        app.models.selectedProfile == nil ? "Choose a model in Settings first" : "Add or select a source first"
    }

    private func generate(_ kind: StudyResourceKind) {
        if let id = app.studio.generate(kind, focus: focus, in: notebook.id) {
            if kind.isInteractive || kind == .studyGuide || kind == .briefing {
                app.openedStudioItemID = id
            }
        }
    }

    // MARK: Review

    private var reviewCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(dueCards.isEmpty ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(dueCards.isEmpty ? "All caught up" : "\(dueCards.count) card\(dueCards.count == 1 ? "" : "s") due")
                    .font(.callout.weight(.semibold))
                Text("Spaced repetition across \(notebook.allFlashcards.count) flashcards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") {
                app.isShowingFlashcardReview = true
            }
            .buttonStyle(.glassProminent)
            .disabled(dueCards.isEmpty)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: Outputs

    @ViewBuilder
    private var outputs: some View {
        if !notebook.studioItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Created")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(notebook.studioItems) { item in
                    StudioItemRow(item: item, live: app.studio.liveGeneration(for: item.id)) {
                        app.openedStudioItemID = item.id
                    } onCancel: {
                        app.studio.cancel(item.id)
                    } onDelete: {
                        app.studio.delete(item.id, in: notebook.id)
                    }
                }
            }
        }
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let note = StudyNote(title: "New note", markdown: "")
                    app.store.addNote(note, to: notebook.id)
                    editingNote = note
                } label: {
                    Label("New Note", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New note")
                .accessibilityLabel("New note")
            }
            if notebook.notes.isEmpty {
                Text("Save answers from the chat, or write your own notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(notebook.notes) { note in
                Button {
                    editingNote = note
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(note.markdown.isEmpty ? "Empty note" : note.markdown)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete Note", role: .destructive) {
                        app.store.deleteNote(note.id, in: notebook.id)
                    }
                }
            }
        }
    }
}

private struct StudioItemRow: View {
    let item: StudioItem
    let live: LiveGeneration?
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 4)
                if item.isRunning {
                    Button(action: onCancel) {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                    .accessibilityLabel("Stop generating \(item.title)")
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if item.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(live?.statusMessage ?? item.statusMessage)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if case .failed = item.status {
            Text("Failed · click for details")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("\(item.kind.title) · \(item.statusMessage) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let notebookID: UUID
    let note: StudyNote

    @State private var title = ""
    @State private var markdown = ""
    @State private var isPreviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Picker("Mode", selection: $isPreviewing) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(20)
            Divider()
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
                        .padding(20)
                }
            } else {
                TextEditor(text: $markdown)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(14)
            }
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    app.store.deleteNote(note.id, in: notebookID)
                    dismiss()
                }
                Spacer()
                Button("Done") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
            .padding(14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            title = note.title
            markdown = note.markdown
            isPreviewing = !note.markdown.isEmpty
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, trimmedTitle.isEmpty || trimmedTitle == "New note" {
            app.store.deleteNote(note.id, in: notebookID)
            return
        }
        guard title != note.title || markdown != note.markdown else { return }
        app.store.updateNote(note.id, in: notebookID) { stored in
            stored.title = title.isEmpty ? "Untitled note" : title
            stored.markdown = markdown
        }
    }
}
