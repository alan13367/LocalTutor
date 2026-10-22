//
//  HomeView.swift
//  LocalTutor
//

import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    var onAddSources: () -> Void

    @State private var searchText = ""
    @State private var renaming: Notebook?
    @State private var renameDraft = ""
    @State private var pendingDeletion: Notebook?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)]

    var body: some View {
        Group {
            if app.store.notebooks.isEmpty {
                emptyState
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("LocalTutor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelStatusButton()
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search notebooks")
        .alert("Rename Notebook", isPresented: renameBinding) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let renaming {
                    app.store.renameNotebook(renaming.id, to: renameDraft)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete \"\(pendingDeletion?.title ?? "")\"?",
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                if let pendingDeletion {
                    app.store.deleteNotebook(pendingDeletion.id)
                }
                pendingDeletion = nil
            }
        } message: {
            Text("Its chats, notes and study materials will be removed. Your original files are not touched.")
        }
    }

    // MARK: Gallery

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    if searchText.isEmpty {
                        NewNotebookCard {
                            app.createNotebook()
                        }
                    }
                    ForEach(filteredNotebooks) { notebook in
                        NotebookCard(
                            notebook: notebook,
                            isGenerating: app.isGenerating(in: notebook)
                        ) {
                            app.openNotebook(notebook.id)
                        }
                        .contextMenu { menu(for: notebook) }
                    }
                }
                if filteredNotebooks.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your notebooks")
                .font(.largeTitle.weight(.bold))
            Text(headerSubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        let due = app.store.notebooks.reduce(0) { $0 + $1.dueFlashcards().count }
        if due > 0 {
            return "\(due) flashcard\(due == 1 ? "" : "s") due for review today."
        }
        return "One notebook per subject. Everything stays on this Mac."
    }

    private var filteredNotebooks: [Notebook] {
        let sorted = app.store.notebooks.sorted { $0.updatedAt > $1.updatedAt }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { notebook in
            notebook.title.localizedCaseInsensitiveContains(query)
                || notebook.sources.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private func menu(for notebook: Notebook) -> some View {
        Button("Open") { app.openNotebook(notebook.id) }
        Button("Rename…") {
            renameDraft = notebook.title
            renaming = notebook
        }
        Menu("Icon") {
            ForEach(NotebookSymbols.all, id: \.self) { symbol in
                Button {
                    app.store.setSymbol(symbol, for: notebook.id)
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        }
        Divider()
        Button("Delete Notebook…", role: .destructive) {
            pendingDeletion = notebook
        }
        .disabled(app.isGenerating(in: notebook))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)), in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Create your first notebook")
                    .font(.largeTitle.weight(.bold))
                Text("A notebook holds the sources for one subject. Ask questions and LocalTutor answers with citations, all on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 12) {
                Button("Add Sources…", systemImage: "plus") {
                    onAddSources()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Try the Sample") {
                    SampleNotebook.install(into: app)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            Text("Or drop PDFs, slides and notes anywhere in this window.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }
}

enum NotebookSymbols {
    static let all = [
        "book.closed", "graduationcap", "function", "atom", "flask", "leaf",
        "globe.europe.africa", "building.columns", "chart.line.uptrend.xyaxis",
        "cpu", "music.note", "paintpalette", "heart.text.square", "scalemass", "brain.head.profile",
        "stethoscope", "lungs", "cross.case", "hammer", "lock.shield"
    ]
}

// MARK: - Cards

private struct NotebookCard: View {
    let notebook: Notebook
    let isGenerating: Bool
    var onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: notebook.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                        .accessibilityHidden(true)
                    Spacer()
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else if dueCount > 0 {
                        Label("\(dueCount) due", systemImage: "rectangle.stack")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 14)
                Text(notebook.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(height: 150)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notebook.title)
        .accessibilityValue([detailLine, isGenerating ? "Generating" : nil, dueCount > 0 ? "\(dueCount) cards due" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private var dueCount: Int {
        notebook.dueFlashcards().count
    }

    private var detailLine: String {
        "\(notebook.subtitle) · \(notebook.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

private struct NewNotebookCard: View {
    var onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                Text("New Notebook")
                    .font(.headline)
                Text("⌘N")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Notebook")
    }
}
