//
//  NotebookWorkspaceView.swift
//  LocalTutor
//

import SwiftUI

struct NotebookWorkspaceView: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook
    var onAddSources: () -> Void

    @AppStorage("showsStudio") private var showsStudio = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pendingDeletion = false
    @State private var isRenaming = false
    @State private var renameDraft = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SourcesPanel(notebook: notebook, onAdd: onAddSources)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            ChatPanel(notebook: notebook, onAddSources: onAddSources)
                .inspector(isPresented: $showsStudio) {
                    StudioPanel(notebook: notebook)
                        .inspectorColumnWidth(min: 290, ideal: 320, max: 420)
                }
        }
        .navigationTitle(notebook.title)
        .navigationSubtitle(notebook.subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.showHome()
                } label: {
                    Label("Notebooks", systemImage: "chevron.left")
                }
                .help("All notebooks (⌘[)")
                .keyboardShortcut("[", modifiers: .command)
            }
            ToolbarItem(placement: .navigation) {
                notebookMenu
            }
            ToolbarItem(placement: .navigation) {
                ChatThreadMenu(notebook: notebook, current: app.store.selectedChat(in: notebook.id))
            }
            ToolbarItem(placement: .primaryAction) {
                ModelStatusButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsStudio.toggle()
                } label: {
                    Label("Studio", systemImage: "sidebar.trailing")
                }
                .help(showsStudio ? "Hide Studio" : "Show Studio")
            }
        }
        .alert("Rename Notebook", isPresented: $isRenaming) {
            TextField("Name", text: $renameDraft)
            Button("Save") { app.store.renameNotebook(notebook.id, to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(notebook.title)\"?",
            isPresented: $pendingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Notebook", role: .destructive) {
                app.store.deleteNotebook(notebook.id)
            }
        } message: {
            Text("Its chats, notes and study materials will be removed. Your original files are not touched.")
        }
        .sheet(item: $app.presentedCitation) { presentation in
            CitationSourceView(presentation: presentation)
        }
        .sheet(item: openedStudioItemBinding) { item in
            StudioItemDetailView(notebookID: notebook.id, itemID: item.id)
        }
        .sheet(isPresented: $app.isShowingFlashcardReview) {
            FlashcardReviewSheet(notebookID: notebook.id)
        }
    }

    private var notebookMenu: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") {
                renameDraft = notebook.title
                isRenaming = true
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
            Button("Delete Notebook…", systemImage: "trash", role: .destructive) {
                pendingDeletion = true
            }
            .disabled(app.isGenerating(in: notebook))
        } label: {
            Label("Notebook", systemImage: notebook.symbol)
        }
        .help("Rename, change icon or delete this notebook")
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
