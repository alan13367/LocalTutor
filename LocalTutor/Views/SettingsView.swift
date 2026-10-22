//
//  SettingsView.swift
//  LocalTutor
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Models", systemImage: "cpu") {
                ModelsSettingsPane()
            }
            Tab("Helpers", systemImage: "sparkles") {
                HelpersSettingsPane()
            }
            Tab("Storage", systemImage: "internaldrive") {
                StorageSettingsPane()
            }
        }
        .frame(width: 720, height: 620)
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var pendingRemoval: ModelProfile?

    private var systemMemory: UInt64 { SystemMemory.totalBytes() }

    var body: some View {
        @Bindable var models = app.models
        Form {
            Section {
                LabeledContent("This Mac") {
                    Text("\(SystemInfo.chipName) · \(systemMemory.gibibytesDescription) · \(ModelTier.tier(forSystemMemory: systemMemory).label)")
                        .foregroundStyle(.secondary)
                }
                Picker("Context size", selection: $models.contextPreference) {
                    ForEach(ContextPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                if let policy = app.models.runtimePolicy {
                    Text("\(app.models.contextPreference.detail) \(policy.profileName) reads up to \(policy.contextTokens.formatted()) tokens (about \((policy.sourceTokenBudget(for: .ask) * 3 / 4).formatted()) words of sources) per question.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Faster generation (multi-token prediction)", isOn: $models.useSpeculativeDecoding)
                Text(speculativeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(ModelTier.allCases, id: \.self) { tier in
                let profiles = ModelProfile.studyCatalog.filter { $0.tier == tier }
                if !profiles.isEmpty {
                    Section(tier.label) {
                        ForEach(profiles) { profile in
                            ModelRow(profile: profile, onRemove: { pendingRemoval = profile })
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "model")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                if let pendingRemoval {
                    app.models.remove(pendingRemoval)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("This frees \(pendingRemoval.map { app.models.cacheInfo(for: $0).sizeDescription } ?? "disk space"). You can download it again later.")
        }
        .onAppear { app.models.refreshCacheInfo() }
    }

    private var speculativeDetail: String {
        guard let profile = app.models.selectedProfile else {
            return "Downloads a small drafter model that predicts several tokens at once for long study materials."
        }
        guard profile.supportsSpeculativeDecoding else {
            return "\(profile.name) has no multi-token prediction drafter yet."
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(profile.drafterBytes), countStyle: .file)
        return "Adds a \(size) drafter to \(profile.name) that predicts several tokens at once, so answers and study materials stream noticeably faster."
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var app
    let profile: ModelProfile
    var onRemove: () -> Void

    var body: some View {
        let canRun = MemoryPreflight.evaluate(profile: profile).canRun
        let isSelected = app.models.selectedProfile?.id == profile.id
        let isCached = app.models.cacheInfo(for: profile).isCached
        let status = app.models.downloadStatus?.profileID == profile.id ? app.models.downloadStatus : nil

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.headline)
                        if profile.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                                .foregroundStyle(.tint)
                        }
                        if profile.supportsVision {
                            Image(systemName: "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Reads images and scanned pages")
                                .accessibilityLabel("Vision capable")
                        }
                    }
                    Text(profile.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(profile.publisher) · \(profile.parameterScale) · \(profile.downloadSizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if !canRun {
                        Text("Needs \(profile.minimumSystemMemoryDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isSelected {
                        Text(isCached ? "In use" : "Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    } else {
                        Button(isCached ? "Use" : "Download") {
                            app.models.select(profile)
                        }
                        .buttonStyle(.glass)
                        .disabled(app.isGenerating)
                    }
                    if isCached {
                        Button("Remove…", role: .destructive, action: onRemove)
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(!app.models.canRemove(profile))
                    } else if isSelected, canRun, status == nil {
                        Button("Download") { app.models.startPreload(for: profile) }
                            .buttonStyle(.glass)
                    }
                }
            }
            if let status, status.phase != .ready {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.phase == .failed ? .orange : .secondary)
                    if status.phase != .failed {
                        DownloadProgressMeter(fraction: status.fraction)
                            .frame(height: 6)
                    }
                    DownloadControls(status: status)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
        .opacity(canRun ? 1 : 0.5)
    }
}

// MARK: - Helpers

private struct HelpersSettingsPane: View {
    @AppStorage(AppStorageKeys.useSystemModelForHelpers) private var useSystemModel = true
    @State private var embeddingStatus = "Installed automatically the first time semantic search is needed."
    @State private var embeddingProgress: Double?
    @State private var isPreparingEmbedding = false
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle("Use Apple Intelligence for quick tasks", isOn: $useSystemModel)
                    .disabled(!SystemModelHelper.availability.isAvailable)
                Text("Writes source guides and chat titles with Apple's built-in on-device model, so your tutor model stays free for answers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status") {
                    Text(SystemModelHelper.availability.explanation)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Apple Intelligence", systemImage: "apple.intelligence")
            }

            Section {
                LabeledContent(ModelCatalog.embeddingModel.name) {
                    if app.models.cacheInfo(for: ModelCatalog.embeddingModel).isCached {
                        Text("Installed").foregroundStyle(.secondary)
                    } else {
                        Button("Install Now", action: prepareEmbeddingModel)
                            .disabled(isPreparingEmbedding)
                    }
                }
                Text(embeddingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let embeddingProgress {
                    ProgressView(value: embeddingProgress)
                }
            } header: {
                Label("Semantic search", systemImage: "text.magnifyingglass")
            } footer: {
                Text("Finds passages by meaning, not just keywords, for large notebooks. It loads only while indexing or searching and unloads when idle.")
            }
        }
        .formStyle(.grouped)
    }

    private func prepareEmbeddingModel() {
        isPreparingEmbedding = true
        embeddingStatus = "Preparing semantic search…"
        Task {
            do {
                try await SourceIndexCoordinator.shared.prepareEmbeddingModel { event in
                    await MainActor.run {
                        switch event {
                        case .downloading(let update):
                            embeddingProgress = update.fraction
                            embeddingStatus = "Downloading semantic search model"
                        case .ready:
                            embeddingProgress = nil
                            embeddingStatus = "Ready for semantic search"
                        }
                    }
                }
                isPreparingEmbedding = false
                app.models.refreshCacheInfo(force: true)
            } catch {
                isPreparingEmbedding = false
                embeddingProgress = nil
                embeddingStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - Storage

private struct StorageSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var statistics = SourceIndexStatistics(documentCount: 0, chunkCount: 0, vectorCount: 0, diskBytes: 0)
    @State private var isClearing = false

    var body: some View {
        Form {
            Section("Source index") {
                LabeledContent("Documents", value: statistics.documentCount.formatted())
                LabeledContent("Passages", value: statistics.chunkCount.formatted())
                LabeledContent("Vectors", value: statistics.vectorCount.formatted())
                LabeledContent("Disk", value: ByteCountFormatter.localTutorMemoryString(fromByteCount: statistics.diskBytes))
                Button("Clear Index", role: .destructive) {
                    clearIndex()
                }
                .disabled(isClearing || statistics.documentCount == 0)
                Text("Sources are re-indexed automatically the next time they are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Models") {
                let cached = ModelProfile.studyCatalog.filter { app.models.cacheInfo(for: $0).isCached }
                if cached.isEmpty {
                    Text("No models downloaded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(cached) { profile in
                    LabeledContent(profile.name, value: app.models.cacheInfo(for: profile).sizeDescription)
                }
                Button("Show Data Folder in Finder") {
                    if let root = try? AppDirectories.applicationSupportRoot() {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                }
            }
            Section("About") {
                LabeledContent("LocalTutor", value: AppInfo.version)
                Text("Everything (models, sources, notebooks) stays on this Mac. No accounts, no telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func refresh() async {
        statistics = await SourceIndexCoordinator.shared.statistics()
    }

    private func clearIndex() {
        isClearing = true
        Task {
            try? await SourceIndexCoordinator.shared.clear()
            await SourceExtractionCache.shared.removeAll()
            await refresh()
            isClearing = false
        }
    }
}
