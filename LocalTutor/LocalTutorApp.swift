//
//  LocalTutorApp.swift
//  LocalTutor
//
//  Created by Alan on 28/05/2026.
//

import SwiftUI

@main
struct LocalTutorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    Task.detached {
                        try? await ManagedModelDownloadService.shared.ensureDownloaded(
                            profile: ModelCatalog.embeddingGemma300M,
                            progressHandler: { _ in }
                        )
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
    }
}
