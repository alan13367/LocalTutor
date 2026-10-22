//
//  ModelStatusButton.swift
//  LocalTutor
//

import SwiftUI

struct ModelStatusButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SettingsLink {
            HStack(spacing: 7) {
                statusIndicator
                Text(app.models.selectedProfile?.name ?? "Choose a model")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
        }
        .help(helpText)
        .accessibilityLabel("Model: \(app.models.selectedProfile?.name ?? "none"), \(statusLine)")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .busy:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .loaded:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(.secondary.opacity(0.6)).frame(width: 7, height: 7)
        case .attention:
            Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }

    private enum IndicatorState { case busy, loaded, idle, attention }

    private var state: IndicatorState {
        guard let profile = app.models.selectedProfile else { return .attention }
        if let status = app.models.downloadStatus, status.profileID == profile.id {
            switch status.phase {
            case .checking, .loading, .downloading: return .busy
            case .paused, .failed: return .attention
            case .ready: break
            }
        }
        if app.models.loadedProfileID == profile.id { return .loaded }
        return app.models.cacheInfo(for: profile).isCached ? .idle : .attention
    }

    private var helpText: String {
        "\(statusLine). Models and settings (⌘,)"
    }

    var statusLine: String {
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
