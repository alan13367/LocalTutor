//
//  NotebookStore.swift
//  LocalTutor
//

import Foundation
import Observation

@MainActor
@Observable
final class NotebookStore {
    private static let saveDelay: Duration = .milliseconds(700)

    private(set) var notebooks: [Notebook] = []
    var selectedNotebookID: UUID?
    var selectedChatIDs: [UUID: UUID] = [:]

    @ObservationIgnored private let persistence: NotebookPersistence?
    @ObservationIgnored private var dirtyIDs: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(persistence: NotebookPersistence? = NotebookPersistence(), initial: [Notebook]? = nil) {
        self.persistence = persistence
        if let initial {
            notebooks = initial
        } else {
            var loaded = NotebookPersistence.loadAllSync()
            if loaded.isEmpty {
                loaded = LegacySessionMigration.migrateIfNeeded()
            }
            notebooks = loaded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: - Lookup

    var selectedNotebook: Notebook? {
        guard let selectedNotebookID else { return nil }
        return notebook(selectedNotebookID)
    }

    func notebook(_ id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    func selectedChatID(in notebookID: UUID) -> UUID? {
        guard let notebook = notebook(notebookID) else { return nil }
        if let id = selectedChatIDs[notebookID], notebook.chats.contains(where: { $0.id == id }) {
            return id
        }
        return notebook.chats.max { $0.updatedAt < $1.updatedAt }?.id
    }

    func selectedChat(in notebookID: UUID) -> NotebookChat? {
        guard let notebook = notebook(notebookID), let chatID = selectedChatID(in: notebookID) else { return nil }
        return notebook.chats.first { $0.id == chatID }
    }

    var allSources: [StudySource] {
        notebooks.flatMap(\.sources)
    }

    // MARK: - Notebook lifecycle

    @discardableResult
    func createNotebook(title: String = "Untitled notebook") -> Notebook {
        let notebook = Notebook(title: title)
        notebooks.insert(notebook, at: 0)
        selectedNotebookID = notebook.id
        markDirty(notebook.id)
        return notebook
    }

    func deleteNotebook(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        selectedChatIDs[id] = nil
        dirtyIDs.remove(id)
        if selectedNotebookID == id {
            selectedNotebookID = nil
        }
        Task { [persistence] in await persistence?.delete(id) }
    }

    func renameNotebook(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func setSymbol(_ symbol: String, for id: UUID) {
        update(id) { $0.symbol = symbol }
    }

    func update(_ id: UUID, touch: Bool = true, _ body: (inout Notebook) -> Void) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        body(&notebooks[index])
        if touch {
            notebooks[index].updatedAt = Date()
        }
        markDirty(id)
    }

    // MARK: - Chats

    @discardableResult
    func newChat(in notebookID: UUID) -> UUID? {
        guard let notebook = notebook(notebookID) else { return nil }
        if let empty = notebook.chats.first(where: { $0.turns.isEmpty }) {
            selectedChatIDs[notebookID] = empty.id
            return empty.id
        }
        let chat = NotebookChat()
        update(notebookID) { $0.chats.insert(chat, at: 0) }
        selectedChatIDs[notebookID] = chat.id
        return chat.id
    }

    func deleteChat(_ chatID: UUID, in notebookID: UUID) {
        update(notebookID) { notebook in
            notebook.chats.removeAll { $0.id == chatID }
            if notebook.chats.isEmpty {
                notebook.chats = [NotebookChat()]
            }
        }
        if selectedChatIDs[notebookID] == chatID {
            selectedChatIDs[notebookID] = nil
        }
    }

    func renameChat(_ chatID: UUID, in notebookID: UUID, to title: String, isCustom: Bool = true) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateChat(chatID, in: notebookID) { chat in
            chat.title = trimmed
            chat.titleIsCustom = isCustom
        }
    }

    func updateChat(_ chatID: UUID, in notebookID: UUID, _ body: (inout NotebookChat) -> Void) {
        update(notebookID) { notebook in
            guard let index = notebook.chats.firstIndex(where: { $0.id == chatID }) else { return }
            body(&notebook.chats[index])
            notebook.chats[index].updatedAt = Date()
        }
    }

    func updateTurn(_ turnID: UUID, chatID: UUID, notebookID: UUID, _ body: (inout StudyTurn) -> Void) {
        updateChat(chatID, in: notebookID) { chat in
            guard let index = chat.turns.firstIndex(where: { $0.id == turnID }) else { return }
            body(&chat.turns[index])
        }
    }

    // MARK: - Studio & notes

    func updateStudioItem(_ itemID: UUID, in notebookID: UUID, _ body: (inout StudioItem) -> Void) {
        update(notebookID) { notebook in
            guard let index = notebook.studioItems.firstIndex(where: { $0.id == itemID }) else { return }
            body(&notebook.studioItems[index])
        }
    }

    func deleteStudioItem(_ itemID: UUID, in notebookID: UUID) {
        update(notebookID) { $0.studioItems.removeAll { $0.id == itemID } }
    }

    func addNote(_ note: StudyNote, to notebookID: UUID) {
        update(notebookID) { $0.notes.insert(note, at: 0) }
    }

    func updateNote(_ noteID: UUID, in notebookID: UUID, _ body: (inout StudyNote) -> Void) {
        update(notebookID) { notebook in
            guard let index = notebook.notes.firstIndex(where: { $0.id == noteID }) else { return }
            body(&notebook.notes[index])
            notebook.notes[index].updatedAt = Date()
        }
    }

    func deleteNote(_ noteID: UUID, in notebookID: UUID) {
        update(notebookID) { $0.notes.removeAll { $0.id == noteID } }
    }

    func recordReview(cardID: String, grade: ReviewGrade, in notebookID: UUID) {
        update(notebookID, touch: false) { notebook in
            let current = notebook.reviewStates[cardID] ?? .new(cardID: cardID)
            notebook.reviewStates[cardID] = SpacedRepetition.review(current, grade: grade)
        }
    }

    // MARK: - Sources

    func updateSource(_ sourceID: UUID, in notebookID: UUID, _ body: (inout StudySource) -> Void) {
        update(notebookID) { notebook in
            guard let index = notebook.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            body(&notebook.sources[index])
        }
    }

    // MARK: - Persistence

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await persistDirty()
    }

    private func markDirty(_ id: UUID) {
        guard persistence != nil else { return }
        dirtyIDs.insert(id)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            await self?.persistDirty()
        }
    }

    private func persistDirty() async {
        guard let persistence else { return }
        let ids = dirtyIDs
        dirtyIDs.removeAll()
        for id in ids {
            guard let snapshot = notebook(id) else { continue }
            await persistence.save(snapshot)
        }
    }
}
