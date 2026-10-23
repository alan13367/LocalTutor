//
//  AppModel.swift
//  LocalTutor
//

import Foundation
import MLX
import Observation
import SwiftUI

struct CitationPresentation: Identifiable, Equatable {
    var citation: SourceCitation
    var source: StudySource?

    var id: String { citation.id }
}

enum WorkspaceStage: Hashable {
    case chat
    case studioItem(UUID)
    case note(UUID)
    case flashcardReview

    var showsComposer: Bool {
        if case .note = self { return false }
        return true
    }

    func resolved(in notebook: Notebook) -> WorkspaceStage {
        switch self {
        case .chat:
            return .chat
        case .studioItem(let id):
            return notebook.studioItems.contains { $0.id == id } ? self : .chat
        case .note(let id):
            return notebook.notes.contains { $0.id == id } ? self : .chat
        case .flashcardReview:
            return notebook.allFlashcards.isEmpty ? .chat : self
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let store: NotebookStore
    let models: ModelManager
    let library: SourceLibrary
    let chat: ChatController
    let studio: StudioController

    var globalError: String?
    var memoryWarning: String?
    var presentedCitation: CitationPresentation?
    var stage: WorkspaceStage = .chat
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: AppStorageKeys.hasCompletedOnboarding) }
    }

    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        inferenceService: any InferenceService = LocalModelRunner(),
        store: NotebookStore? = nil,
        models: ModelManager? = nil
    ) {
        let store = store ?? NotebookStore()
        let models = models ?? ModelManager(inferenceService: inferenceService)
        self.store = store
        self.models = models
        library = SourceLibrary(store: store, models: models)
        chat = ChatController(store: store, models: models)
        studio = StudioController(store: store, models: models)
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
            || !store.notebooks.isEmpty

        let report: (String) -> Void = { [weak self] message in
            self?.globalError = message
        }
        models.onError = report
        library.onError = report
        chat.onError = report
        studio.onError = report
        models.isGenerationActive = { [weak self] in
            guard let self else { return false }
            return self.chat.isGenerating || self.studio.isGenerating
        }

        library.bootstrap()
        startMemoryPressureMonitor()
        #if DEBUG
        runDebugLaunchActions()
        #endif
    }

    #if DEBUG
    private func runDebugLaunchActions() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "LocalTutorDebugSeedSample"), store.notebooks.isEmpty {
            SampleNotebook.install(into: self)
        }
        if store.selectedNotebookID == nil, defaults.string(forKey: "LocalTutorDebugAsk") != nil || defaults.string(forKey: "LocalTutorDebugStudio") != nil {
            store.selectedNotebookID = store.notebooks.first?.id
        }
        if let question = defaults.string(forKey: "LocalTutorDebugAsk"), let notebookID = store.selectedNotebookID {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.chat.ask(question, in: notebookID)
            }
        }
        if defaults.bool(forKey: "LocalTutorDebugCancelDownload") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.models.cancelDownload()
            }
        }
        if let kind = defaults.string(forKey: "LocalTutorDebugStudio").flatMap(StudyResourceKind.init(rawValue:)),
           let notebookID = store.selectedNotebookID {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.createStudioItem(kind, in: notebookID)
            }
        }
    }
    #endif

    var isGenerating: Bool {
        chat.isGenerating || studio.isGenerating
    }

    var selectedNotebook: Notebook? {
        store.selectedNotebook
    }

    // MARK: - Notebook actions

    func createNotebook() {
        store.createNotebook()
    }

    func openNotebook(_ id: UUID) {
        stage = .chat
        store.selectedNotebookID = id
    }

    func showHome() {
        presentedCitation = nil
        stage = .chat
        store.selectedNotebookID = nil
    }

    // MARK: - Stage

    func stage(in notebook: Notebook) -> WorkspaceStage {
        stage.resolved(in: notebook)
    }

    func showChat() {
        stage = .chat
    }

    func openStudioItem(_ id: UUID?) {
        guard let id else { return }
        stage = .studioItem(id)
    }

    func createStudioItem(_ kind: StudyResourceKind, focus: String = "", in notebookID: UUID) {
        openStudioItem(studio.generate(kind, focus: focus, in: notebookID))
    }

    func askInChat(_ question: String, in notebookID: UUID) {
        stage = .chat
        chat.ask(question, in: notebookID)
    }

    func isGenerating(in notebook: Notebook) -> Bool {
        chat.running?.notebookID == notebook.id
            || notebook.studioItems.contains { studio.isRunning($0.id) }
    }

    func importSources(_ urls: [URL]) {
        let notebookID = store.selectedNotebookID ?? store.createNotebook().id
        library.importURLs(urls, into: notebookID, supportsVision: models.supportsVision)
    }

    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        let notebookID = store.selectedNotebookID ?? store.createNotebook().id
        return library.importFromDropProviders(providers, into: notebookID, supportsVision: models.supportsVision)
    }

    func openCitation(_ index: Int, in citations: [SourceCitation]) {
        guard let citation = citations.first(where: { $0.index == index }) else { return }
        let source = store.notebooks.lazy.flatMap(\.sources).first { $0.id == citation.sourceID }
            ?? store.allSources.first { $0.displayName == citation.sourceName }
        presentedCitation = CitationPresentation(citation: citation, source: source)
    }

    func saveToNote(title: String, markdown: String, citations: [SourceCitation]) {
        guard let notebookID = store.selectedNotebookID else { return }
        store.addNote(
            StudyNote(
                title: String(title.prefix(80)),
                markdown: ReasoningOutputFilter.sanitize(markdown),
                citations: citations
            ),
            to: notebookID
        )
    }

    func handleRefinement(_ suggestion: RefinementSuggestion, lastQuestion: String?) {
        guard let notebookID = store.selectedNotebookID else { return }
        if let kind = suggestion.newKind, kind != .ask {
            createStudioItem(kind, focus: lastQuestion ?? "", in: notebookID)
        } else {
            chat.refine(suggestion, in: notebookID)
        }
    }

    // MARK: - Memory pressure

    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            MainActor.assumeIsolated {
                self?.handleMemoryPressure(critical: event.contains(.critical))
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func handleMemoryPressure(critical: Bool) {
        let inference = models.inferenceService
        Task {
            await LocalEmbeddingRunner.shared.unload()
            await inference.releaseConversations()
            Memory.clearCache()
        }
        guard critical else { return }
        if isGenerating {
            memoryWarning = "Your Mac is very low on memory. LocalTutor freed its caches; close other apps or choose a smaller model if replies stall."
        } else {
            models.unloadModel()
            memoryWarning = "Your Mac ran low on memory, so LocalTutor unloaded its model. It will reload when you ask the next question."
        }
    }
}
