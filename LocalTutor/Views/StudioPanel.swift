//
//  StudioPanel.swift
//  LocalTutor
//

import SwiftUI

struct StudioPanel: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook

    @State private var focus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
    }

    private var stage: WorkspaceStage {
        app.stage(in: notebook)
    }

    private var dueCards: [Flashcard] {
        notebook.dueFlashcards()
    }

    // MARK: Generators

    private var generators: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Studio")
                    .font(.title3.weight(.semibold))
                Spacer()
                if runningCount > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("\(runningCount) creating")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            focusField
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(StudyResourceKind.studioKinds) { kind in
                    let isCreating = notebook.runningStudioItem(of: kind) != nil
                    Button {
                        app.createStudioItem(kind, focus: focus, in: notebook.id)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(kind.tint)
                                .symbolEffect(.pulse, options: .repeating, isActive: isCreating)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(kind.tint.opacity(0.14)))
                                .overlay(Circle().strokeBorder(kind.tint.opacity(isCreating ? 0.6 : 0), lineWidth: 1.5))
                            Text(kind.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                    .disabled(!canGenerate && !isCreating)
                    .help(isCreating ? "\(kind.title) is being created. Click to open it." : (canGenerate ? "\(kind.title): \(kind.shortDescription)" : disabledReason))
                    .accessibilityLabel(isCreating ? "Open \(kind.title) being created" : "Create \(kind.title)")
                    .accessibilityHint(kind.shortDescription)
                }
            }
        }
    }

    private var focusField: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focus.isEmpty ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            TextField("Focus on a topic (optional)", text: $focus)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Focus topic for generated materials")
            if !focus.isEmpty {
                Button {
                    focus = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear focus")
                .accessibilityLabel("Clear focus")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .help("Created items concentrate on this topic, e.g. \"Chapter 3\"")
    }

    private var runningCount: Int {
        notebook.studioItems.filter(\.isRunning).count
    }

    private var canGenerate: Bool {
        app.models.selectedProfile != nil && !notebook.enabledSources.isEmpty
    }

    private var disabledReason: String {
        app.models.selectedProfile == nil ? "Choose a model in Settings first" : "Add or select a source first"
    }

    // MARK: Review

    private var reviewCard: some View {
        Button {
            app.stage = .flashcardReview
        } label: {
            HStack(spacing: 12) {
                StudioBadge(symbol: StudioStyle.reviewSymbol, tint: dueCards.isEmpty ? .secondary : StudioStyle.reviewTint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dueCards.isEmpty ? "All caught up" : "\(dueCards.count) card\(dueCards.count == 1 ? "" : "s") due")
                        .font(.callout.weight(.semibold))
                    Text("Spaced repetition · \(notebook.allFlashcards.count) cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !dueCards.isEmpty {
                    Text("Review")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(StudioStyle.reviewTint)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(stage == .flashcardReview ? StudioStyle.reviewTint.opacity(0.2) : .clear).interactive(), in: .rect(cornerRadius: 14))
        .disabled(dueCards.isEmpty)
        .accessibilityLabel(dueCards.isEmpty ? "All flashcards caught up" : "Review \(dueCards.count) due flashcards")
    }

    // MARK: Outputs

    @ViewBuilder
    private var outputs: some View {
        if !notebook.studioItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Created")
                ForEach(notebook.studioItems) { item in
                    StudioItemRow(
                        item: item,
                        live: app.studio.liveGeneration(for: item.id),
                        isSelected: stage == .studioItem(item.id)
                    ) {
                        app.openStudioItem(item.id)
                    } onCancel: {
                        app.studio.cancel(item.id)
                    } onDelete: {
                        app.studio.delete(item.id, in: notebook.id)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Notes")
                Spacer()
                Button {
                    let note = StudyNote(title: "New note", markdown: "")
                    app.store.addNote(note, to: notebook.id)
                    app.stage = .note(note.id)
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
                let isSelected = stage == .note(note.id)
                Button {
                    app.stage = .note(note.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        StudioBadge(symbol: StudioStyle.noteSymbol, tint: StudioStyle.noteTint, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(note.markdown.isEmpty ? "Empty note" : note.markdown)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(StudioRowBackground(tint: StudioStyle.noteTint, isSelected: isSelected))
                .contextMenu {
                    Button("Delete Note", role: .destructive) {
                        app.store.deleteNote(note.id, in: notebook.id)
                    }
                }
            }
        }
    }
}

private struct StudioRowBackground: View {
    let tint: Color
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? tint.opacity(0.16) : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.45) : .clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct StudioItemRow: View {
    let item: StudioItem
    let live: LiveGeneration?
    let isSelected: Bool
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                StudioBadge(symbol: item.kind.systemImage, tint: item.kind.tint, size: 28, isWorking: item.isRunning)
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
        .background(StudioRowBackground(tint: item.kind.tint, isSelected: isSelected))
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if item.isRunning {
            Text(live?.statusMessage ?? item.statusMessage)
                .font(.caption2)
                .foregroundStyle(item.kind.tint)
                .lineLimit(1)
        } else if case .failed = item.status {
            Text("Failed · click for details")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var caption: String {
        [item.kind.title, item.payload?.itemCountDescription, item.createdAt.formatted(.relative(presentation: .named))]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
