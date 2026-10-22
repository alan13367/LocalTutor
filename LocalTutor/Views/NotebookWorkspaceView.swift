//
//  NotebookWorkspaceView.swift
//  LocalTutor
//

import SwiftUI
import UniformTypeIdentifiers

struct NotebookWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var showsStudio = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NotebookSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } content: {
            Group {
                if let notebook = app.selectedNotebook {
                    SourcesPanel(notebook: notebook, onAdd: { isImporting = true })
                } else {
                    ContentUnavailableView("No notebook", systemImage: "books.vertical", description: Text("Create a notebook to get started."))
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            Group {
                if let notebook = app.selectedNotebook {
                    ChatPanel(notebook: notebook, onAddSources: { isImporting = true })
                } else {
                    WelcomeEmptyState(onAddSources: { isImporting = true })
                }
            }
            .inspector(isPresented: $showsStudio) {
                if let notebook = app.selectedNotebook {
                    StudioPanel(notebook: notebook)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                } else {
                    Color.clear
                }
            }
        }
        .navigationTitle(app.selectedNotebook?.title ?? "LocalTutor")
        .navigationSubtitle(app.selectedNotebook?.subtitle ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isImporting = true
                } label: {
                    Label("Add Sources", systemImage: "plus.rectangle.on.folder")
                }
                .help("Add sources (⌘O)")

                Button {
                    showsStudio.toggle()
                } label: {
                    Label("Studio", systemImage: "sidebar.trailing")
                }
                .help(showsStudio ? "Hide Studio" : "Show Studio")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: app.library.supportedContentTypes(supportsVision: app.models.supportsVision),
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                app.importSources(urls)
            case .failure(let error):
                app.globalError = error.localizedDescription
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            app.importDrop(providers)
        }
        .overlay(FullWindowDropOverlay(isActive: isDropTargeted))
        .onReceive(NotificationCenter.default.publisher(for: .localTutorAddSources)) { _ in
            isImporting = true
        }
        .sheet(item: $app.presentedCitation) { presentation in
            CitationSourceView(presentation: presentation)
        }
        .sheet(item: openedStudioItemBinding) { item in
            if let notebook = app.selectedNotebook {
                StudioItemDetailView(notebookID: notebook.id, itemID: item.id)
            }
        }
        .sheet(isPresented: $app.isShowingFlashcardReview) {
            if let notebook = app.selectedNotebook {
                FlashcardReviewSheet(notebookID: notebook.id)
            }
        }
    }

    private var openedStudioItemBinding: Binding<IdentifiedUUID?> {
        Binding(
            get: { app.openedStudioItemID.map(IdentifiedUUID.init) },
            set: { app.openedStudioItemID = $0?.id }
        )
    }
}

struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}

private struct WelcomeEmptyState: View {
    @Environment(AppModel.self) private var app
    var onAddSources: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Create your first notebook", systemImage: "books.vertical")
        } description: {
            Text("A notebook holds the sources for one subject. Ask questions, and LocalTutor answers with citations, all on your Mac.")
        } actions: {
            Button("New Notebook") {
                app.createNotebook()
                onAddSources()
            }
            .buttonStyle(.glassProminent)
        }
    }
}

// MARK: - Sidebar

private struct NotebookSidebar: View {
    @Environment(AppModel.self) private var app
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var pendingDeletion: Notebook?

    var body: some View {
        @Bindable var store = app.store
        List(selection: $store.selectedNotebookID) {
            Section("Notebooks") {
                ForEach(app.store.notebooks) { notebook in
                    NotebookRow(notebook: notebook, isGenerating: isGenerating(in: notebook))
                        .tag(notebook.id)
                        .contextMenu {
                            Button("Rename…") {
                                renameDraft = notebook.title
                                renamingID = notebook.id
                            }
                            Menu("Icon") {
                                ForEach(Self.symbols, id: \.self) { symbol in
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
                            .disabled(isGenerating(in: notebook))
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    app.createNotebook()
                } label: {
                    Label("New Notebook", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                ModelFooterButton()
            }
            .padding(10)
        }
        .alert("Rename Notebook", isPresented: renameBinding) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let renamingID {
                    app.store.renameNotebook(renamingID, to: renameDraft)
                }
                renamingID = nil
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
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

    static let symbols = [
        "book.closed", "graduationcap", "function", "atom", "flask", "leaf",
        "globe.europe.africa", "building.columns", "chart.line.uptrend.xyaxis",
        "cpu", "music.note", "paintpalette", "heart.text.square", "scalemass", "brain.head.profile"
    ]

    private func isGenerating(in notebook: Notebook) -> Bool {
        app.chat.running?.notebookID == notebook.id
            || notebook.studioItems.contains { app.studio.isRunning($0.id) }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }
}

private struct NotebookRow: View {
    let notebook: Notebook
    let isGenerating: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notebook.symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(notebook.title)
                    .lineLimit(1)
                Text(notebook.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isGenerating ? "Generating" : "")
    }
}

private struct ModelFooterButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsLink {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.models.selectedProfile?.name ?? "Choose a model")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .help("Models and settings (⌘,)")
    }

    private var statusLine: String {
        guard let profile = app.models.selectedProfile else { return "Open Settings to pick one" }
        if let status = app.models.downloadStatus, status.profileID == profile.id {
            switch status.phase {
            case .checking, .loading: return "Loading…"
            case .downloading: return "Downloading · \(status.fraction.map { DownloadProgressUpdate.percentText(for: $0) } ?? "…")"
            case .paused: return "Download paused"
            case .failed: return "Couldn’t load · open Settings"
            case .ready: break
            }
        }
        if app.models.loadedProfileID == profile.id {
            return "Loaded · \(contextLabel)"
        }
        if !app.models.cacheInfo(for: profile).isCached {
            return "Not downloaded · \(profile.downloadSizeDescription)"
        }
        return "Ready · \(contextLabel)"
    }

    private var contextLabel: String {
        guard let policy = app.models.runtimePolicy else { return "" }
        return "\(policy.contextTokens / 1_024)K context"
    }
}
