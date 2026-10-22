//
//  ContentView.swift
//  LocalTutor
//
//  Created by Alan on 28/05/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if !app.hasCompletedOnboarding {
                OnboardingView()
            } else if let notebook = app.selectedNotebook {
                NotebookWorkspaceView(notebook: notebook, onAddSources: { isImporting = true })
                    .transition(.opacity)
            } else {
                NavigationStack {
                    HomeView(onAddSources: { isImporting = true })
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.store.selectedNotebookID)
        .frame(minWidth: 1080, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
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
            guard app.hasCompletedOnboarding else { return false }
            return app.importDrop(providers)
        }
        .overlay(FullWindowDropOverlay(isActive: isDropTargeted && app.hasCompletedOnboarding))
        .onReceive(NotificationCenter.default.publisher(for: .localTutorAddSources)) { _ in
            if app.hasCompletedOnboarding { isImporting = true }
        }
        .overlay(alignment: .top) {
            BannerStack()
                .padding(.top, 12)
                .padding(.horizontal, 24)
        }
        .overlay(alignment: .bottomTrailing) {
            if let status = app.models.downloadStatus, app.hasCompletedOnboarding, status.phase != .loading, status.phase != .checking {
                ModelDownloadToast(status: status) {
                    app.models.dismissDownloadStatus()
                }
                .padding(24)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.models.downloadStatus?.phase)
        .animation(.easeOut(duration: 0.2), value: app.globalError)
    }
}

private struct BannerStack: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            if let error = app.globalError {
                Banner(message: error, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    app.globalError = nil
                }
            }
            if let warning = app.memoryWarning {
                Banner(message: warning, systemImage: "memorychip", tint: .red) {
                    app.memoryWarning = nil
                }
            }
        }
        .frame(maxWidth: 640)
    }
}

struct Banner: View {
    let message: String
    let systemImage: String
    let tint: Color
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
