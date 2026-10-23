//
//  LocalTutorApp.swift
//  LocalTutor
//
//  Created by Alan on 28/05/2026.
//

import SwiftUI

@main
struct LocalTutorApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            LocalTutorCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }

        #if DEBUG
        Window("Model Lab", id: "model-lab") {
            ModelLabView()
        }
        .defaultSize(width: 960, height: 720)
        #endif
    }
}

struct LocalTutorCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") {
                app.createNotebook()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Chat") {
                if let id = app.store.selectedNotebookID {
                    app.store.newChat(in: id)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(app.store.selectedNotebookID == nil)

            Divider()

            Button("Add Sources…") {
                NotificationCenter.default.post(name: .localTutorAddSources, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Study") {
            ForEach(StudyResourceKind.studioKinds) { kind in
                Button("Create \(kind.title)") {
                    guard let id = app.store.selectedNotebookID else { return }
                    app.createStudioItem(kind, in: id)
                }
                .disabled(app.store.selectedNotebook?.enabledSources.isEmpty ?? true)
            }
            Divider()
            Button("Review Due Flashcards") {
                app.stage = .flashcardReview
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled((app.store.selectedNotebook?.dueFlashcards().isEmpty) ?? true)
            Divider()
            Button("Stop Generating") {
                app.chat.cancel()
                app.studio.cancelAll()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!app.isGenerating)
        }
    }
}

extension Notification.Name {
    static let localTutorAddSources = Notification.Name("LocalTutorAddSources")
}
