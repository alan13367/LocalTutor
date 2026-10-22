//
//  NotebookPersistence.swift
//  LocalTutor
//

import Foundation

actor NotebookPersistence {
    private let directory: URL?

    init(directory: URL? = try? AppDirectories.notebooks()) {
        self.directory = directory
    }

    nonisolated static func loadAllSync(directory: URL? = try? AppDirectories.notebooks()) -> [Notebook] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else {
            return []
        }
        let decoder = makeDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Notebook.self, from: data)
            }
            .map(sanitize)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ notebook: Notebook) {
        guard let directory else { return }
        do {
            let data = try Self.makeEncoder().encode(notebook)
            try data.write(to: Self.fileURL(for: notebook.id, in: directory), options: .atomic)
        } catch {
            // Persistence is best-effort; a failed write should not disrupt studying.
        }
    }

    func delete(_ id: UUID) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: Self.fileURL(for: id, in: directory))
    }

    nonisolated static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Work that was mid-stream when the app quit can't keep streaming, so it is
    /// settled into a terminal state on load.
    nonisolated static func sanitize(_ notebook: Notebook) -> Notebook {
        var notebook = notebook
        for chatIndex in notebook.chats.indices {
            for turnIndex in notebook.chats[chatIndex].turns.indices {
                settle(&notebook.chats[chatIndex].turns[turnIndex].assistant)
            }
        }
        for index in notebook.studioItems.indices where !notebook.studioItems[index].status.isTerminal {
            if notebook.studioItems[index].markdown.isEmpty && notebook.studioItems[index].payload == nil {
                notebook.studioItems[index].status = .failed("This item was interrupted.")
                notebook.studioItems[index].statusMessage = "Interrupted"
            } else {
                notebook.studioItems[index].status = .done
                notebook.studioItems[index].statusMessage = "Ready"
            }
        }
        return notebook
    }

    nonisolated private static func settle(_ assistant: inout StudyTurnAssistant) {
        guard case .streaming = assistant.status else { return }
        if assistant.markdown.isEmpty {
            assistant.status = .failed("This response was interrupted.")
            assistant.statusMessage = "Interrupted"
        } else {
            assistant.status = .done
            assistant.statusMessage = "Ready"
        }
        assistant.isDownloading = false
        assistant.downloadProgress = nil
    }
}

enum LegacySessionMigration {
    static func migrateIfNeeded(
        legacyFile: URL? = try? AppDirectories.sessionsFile(),
        notebooksDirectory: URL? = try? AppDirectories.notebooks(),
        fileManager: FileManager = .default
    ) -> [Notebook] {
        guard let legacyFile,
              let notebooksDirectory,
              fileManager.fileExists(atPath: legacyFile.path),
              let data = try? Data(contentsOf: legacyFile),
              let sessions = try? NotebookPersistence.makeDecoder().decode([StudySession].self, from: data) else {
            return []
        }

        let notebooks = sessions
            .filter { !$0.isEmpty }
            .map(notebook(from:))
        let encoder = NotebookPersistence.makeEncoder()
        for notebook in notebooks {
            if let encoded = try? encoder.encode(notebook) {
                try? encoded.write(
                    to: NotebookPersistence.fileURL(for: notebook.id, in: notebooksDirectory),
                    options: .atomic
                )
            }
        }
        let migratedURL = legacyFile.deletingPathExtension().appendingPathExtension("migrated.json")
        try? fileManager.removeItem(at: migratedURL)
        try? fileManager.moveItem(at: legacyFile, to: migratedURL)
        return notebooks.map(NotebookPersistence.sanitize)
    }

    static func notebook(from session: StudySession) -> Notebook {
        var chatTurns: [StudyTurn] = []
        var studioItems: [StudioItem] = []
        for turn in session.turns {
            if turn.user.resourceKind == .ask || turn.user.isRefinement {
                var converted = turn
                converted.user.resourceKind = .ask
                chatTurns.append(converted)
                continue
            }
            var item = StudioItem(
                kind: turn.user.resourceKind,
                focus: turn.user.focus,
                createdAt: turn.assistant.startedAt,
                status: turn.assistant.status,
                statusMessage: turn.assistant.statusMessage,
                sourceIDs: turn.user.sources.map(\.id)
            )
            item.markdown = turn.assistant.markdown
            item.reasoning = turn.assistant.reasoning
            item.payload = turn.assistant.payload
            item.finishedAt = turn.assistant.finishedAt
            studioItems.append(item)
        }

        let chat = NotebookChat(
            title: session.titleIsCustom ? session.title : "New chat",
            titleIsCustom: session.titleIsCustom,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            turns: chatTurns
        )
        return Notebook(
            id: session.id,
            title: session.derivedTitle == "New session" ? "Untitled notebook" : session.derivedTitle,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            sources: session.sources,
            chats: [chat],
            studioItems: studioItems
        )
    }
}
