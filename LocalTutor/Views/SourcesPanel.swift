//
//  SourcesPanel.swift
//  LocalTutor
//

import SwiftUI

struct SourcesPanel: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    var onAdd: () -> Void

    @State private var expandedSourceIDs: Set<UUID> = []
    @State private var locatingSource: StudySource?
    @State private var isLocating = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)

            if notebook.sources.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(notebook.sources) { source in
                            SourceRow(
                                source: source,
                                state: app.library.state(for: source),
                                isExpanded: expandedSourceIDs.contains(source.id),
                                isGeneratingGuide: app.library.generatingGuideIDs.contains(source.id),
                                canUseSource: app.models.supportsVision || !source.isImage,
                                onToggleExpanded: { toggleExpanded(source) },
                                onToggleEnabled: { app.library.setEnabled($0, source: source, in: notebook.id) },
                                onGenerateGuide: { app.library.generateGuide(for: source, in: notebook.id) },
                                onAsk: { question in app.chat.ask(question, in: notebook.id) },
                                onLocate: {
                                    locatingSource = source
                                    isLocating = true
                                },
                                onRemove: { app.library.remove(source, from: notebook.id) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("\(notebook.enabledSources.count) of \(notebook.sources.count) selected")
                            Spacer()
                            Button(allEnabled ? "Deselect all" : "Select all") {
                                app.library.setAllEnabled(!allEnabled, in: notebook.id)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.sidebar)

                ContextBudgetMeter(notebook: notebook)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
            }
        }
        .fileImporter(
            isPresented: $isLocating,
            allowedContentTypes: app.library.supportedContentTypes(supportsVision: true)
        ) { result in
            if case .success(let url) = result, let locatingSource {
                app.library.relink(locatingSource, to: url, in: notebook.id)
            }
            locatingSource = nil
        }
        .fileDialogDefaultDirectory(locatingSource?.url.deletingLastPathComponent())
    }

    private var allEnabled: Bool {
        notebook.sources.allSatisfy(\.isEnabled)
    }

    private var header: some View {
        HStack {
            Text("Sources")
                .font(.headline)
            Spacer()
            Button(action: onAdd) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Add PDFs, documents, slides, images or web pages (⌘O)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Add your study material")
                .font(.headline)
            Text("PDFs, Word, Pages, slides, spreadsheets, EPUBs, web pages and images. Drop files anywhere in the window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Add Sources…", action: onAdd)
                .buttonStyle(.glassProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleExpanded(_ source: StudySource) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedSourceIDs.contains(source.id) {
                expandedSourceIDs.remove(source.id)
            } else {
                expandedSourceIDs.insert(source.id)
            }
        }
    }
}

// MARK: - Source row

private struct SourceRow: View {
    let source: StudySource
    let state: SourceIngestState
    let isExpanded: Bool
    let isGeneratingGuide: Bool
    let canUseSource: Bool
    var onToggleExpanded: () -> Void
    var onToggleEnabled: (Bool) -> Void
    var onGenerateGuide: () -> Void
    var onAsk: (String) -> Void
    var onLocate: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("Use \(source.displayName) in answers", isOn: Binding(get: { source.isEnabled }, set: { onToggleEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canUseSource)

                Image(systemName: source.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source.displayName)
                    statusText
                    if source.bookmarkData == nil {
                        Button(action: onLocate) {
                            Label("Restore file access…", systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .help("LocalTutor lost permission to read this file after relaunching. Locate it once to show pages and re-index.")
                    }
                }

                Spacer(minLength: 4)

                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide source guide" : "Show source guide")
            }

            if isExpanded {
                guideSection
                    .padding(.leading, 30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 3)
        .opacity(source.isEnabled ? 1 : 0.55)
        .contextMenu {
            Button(source.isEnabled ? "Exclude from Answers" : "Include in Answers") {
                onToggleEnabled(!source.isEnabled)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([source.accessibleURL])
            }
            Button("Locate File…", action: onLocate)
            Button(source.guide == nil ? "Generate Source Guide" : "Regenerate Source Guide", action: onGenerateGuide)
                .disabled(isGeneratingGuide || source.isImage)
            Divider()
            Button("Remove Source", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .pending, .indexing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(state == .pending ? "Waiting to index" : "Indexing…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .ready(let chunks, let tokens):
            Text(source.isImage ? "Image · read by vision models" : "\(source.kind.label) · \(TokenCountLabel.text(tokens)) · \(chunks) passages")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var guideSection: some View {
        if let guide = source.guide {
            VStack(alignment: .leading, spacing: 8) {
                Text(guide.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                FlowLayout(spacing: 6) {
                    ForEach(guide.topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(guide.questions, id: \.self) { question in
                        Button {
                            onAsk(question)
                        } label: {
                            Label(question, systemImage: "questionmark.bubble")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help("Ask this question")
                    }
                }
                Text("Guide by \(guide.generatorName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if isGeneratingGuide {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if source.isImage {
            Text("Images are read directly by vision models when you ask a question.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Generate source guide", systemImage: "sparkles", action: onGenerateGuide)
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!state.isReady)
        }
    }
}

private extension SourceIngestState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Context budget

private struct ContextBudgetMeter: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook

    var body: some View {
        if let policy = app.models.runtimePolicy {
            let used = app.library.notebookTokenEstimate(notebook)
            let budget = policy.sourceTokenBudget(for: .ask)
            let fits = used <= budget
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: fits ? "checkmark.circle.fill" : "magnifyingglass.circle.fill")
                        .foregroundStyle(fits ? .green : .blue)
                        .accessibilityHidden(true)
                    Text(fits ? "Whole notebook in context" : "Answers use search")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("\(TokenCountLabel.short(used)) / \(TokenCountLabel.short(budget))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DownloadProgressMeter(fraction: min(1, Double(used) / Double(max(1, budget))), label: "Context used")
                    .tint(fits ? .green : .blue)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .help(fits
                  ? "\(TokenCountLabel.text(used)) of \(TokenCountLabel.text(budget)). Follow-up questions reuse the already-read sources, so they start much faster."
                  : "\(TokenCountLabel.text(used)) exceeds the \(TokenCountLabel.text(budget)) budget for \(policy.profileName). Each question retrieves the most relevant passages.")
            .accessibilityElement(children: .combine)
        }
    }
}

enum TokenCountLabel {
    static func text(_ tokens: Int) -> String {
        tokens >= 1_000 ? String(format: "%.1fK tokens", Double(tokens) / 1_000) : "\(tokens) tokens"
    }

    static func short(_ tokens: Int) -> String {
        tokens >= 1_000 ? String(format: "%.0fK", Double(tokens) / 1_000) : "\(tokens)"
    }
}
