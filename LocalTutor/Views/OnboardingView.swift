//
//  OnboardingView.swift
//  LocalTutor
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var chosenProfileID: String?
    @State private var startedDownload = false
    @State private var showsAllModels = false

    private var systemMemory: UInt64 { SystemMemory.totalBytes() }
    private var recommended: ModelProfile { ModelCatalog.recommended(forSystemMemory: systemMemory) }
    private var chosen: ModelProfile {
        chosenProfileID.flatMap(ModelProfile.profile(withID:)) ?? recommended
    }
    private var options: [ModelProfile] {
        let runnable = ModelProfile.studyCatalog.filter { MemoryPreflight.evaluate(profile: $0).canRun }
        let others = runnable.filter { $0.id != recommended.id }.sorted { $0.tier > $1.tier }
        guard showsAllModels else {
            return chosen.id == recommended.id ? [recommended] : [recommended, chosen]
        }
        return [recommended] + others
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                machineCard
                modelChoice
                actions
                privacyNote
            }
            .padding(40)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        )
        .onChange(of: app.models.downloadStatus == nil) { _, cleared in
            guard cleared else { return }
            if startedDownload, app.models.loadedProfileID == chosen.id {
                finish(withSample: false)
            } else if !app.models.cacheInfo(for: chosen).isCached {
                startedDownload = false
            }
        }
        .onChange(of: app.models.downloadStatus?.phase) { _, phase in
            if startedDownload, phase == .ready, app.models.cacheInfo(for: chosen).isCached || app.models.loadedProfileID == chosen.id {
                finish(withSample: false)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: .circle)
                .accessibilityHidden(true)
            Text("Welcome to LocalTutor")
                .font(.largeTitle.weight(.bold))
            Text("Your private study partner. Add your notes and textbooks, ask questions, and get answers with citations, all running on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var machineCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(SystemInfo.chipName) · \(systemMemory.gibibytesDescription) memory")
                    .font(.headline)
                Text("LocalTutor picked the best model for this Mac. You can change it anytime in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var modelChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tutor model")
                .font(.headline)
            ForEach(options) { profile in
                Button {
                    chosenProfileID = profile.id
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: chosen.id == profile.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen.id == profile.id ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .font(.callout.weight(.semibold))
                                if profile.id == recommended.id {
                                    Text("Recommended")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(profile.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(app.models.cacheInfo(for: profile).isCached ? "Downloaded" : profile.downloadSizeDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(chosen.id == profile.id ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                )
                .accessibilityAddTraits(chosen.id == profile.id ? .isSelected : [])
            }
            Button(showsAllModels ? "Show fewer models" : "Choose a different model…") {
                withAnimation(.snappy) { showsAllModels.toggle() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .disabled(startedDownload)
    }

    @ViewBuilder
    private var actions: some View {
        if startedDownload, let status = app.models.downloadStatus, status.profileID == chosen.id {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(status.message)
                        .font(.callout)
                    Spacer()
                    DownloadControls(status: status)
                }
                DownloadProgressMeter(fraction: status.fraction)
                    .frame(height: 8)
                Text("You can pause anytime and pick up where you left off, even after quitting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            VStack(spacing: 10) {
                Button {
                    startDownload()
                } label: {
                    Text(app.models.cacheInfo(for: chosen).isCached ? "Continue with \(chosen.name)" : "Download \(chosen.name) (\(chosen.downloadSizeDescription))")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)

                HStack(spacing: 16) {
                    Button("Try the sample notebook") {
                        app.models.select(chosen, preload: false)
                        finish(withSample: true)
                    }
                    Button("Skip for now") {
                        app.models.select(chosen, preload: false)
                        finish(withSample: false)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var privacyNote: some View {
        VStack(spacing: 6) {
            Label("No accounts, no cloud, no telemetry. Models download once from Hugging Face.", systemImage: "lock.shield")
            if SystemModelHelper.availability.isAvailable {
                Label("Apple Intelligence will write quick source summaries and chat titles.", systemImage: "apple.intelligence")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func startDownload() {
        startedDownload = true
        app.models.select(chosen, preload: true)
        if app.models.cacheInfo(for: chosen).isCached {
            finish(withSample: false)
        }
    }

    private func finish(withSample: Bool) {
        if withSample {
            SampleNotebook.install(into: app)
        } else if app.store.notebooks.isEmpty {
            app.createNotebook()
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            app.hasCompletedOnboarding = true
        }
    }
}

enum SampleNotebook {
    @MainActor
    static func install(into app: AppModel) {
        guard let bundled = Bundle.main.url(forResource: "SampleNotebook", withExtension: "md"),
              let directory = try? AppDirectories.applicationSupportRoot().appendingPathComponent("Samples", isDirectory: true) else {
            app.createNotebook()
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Photosynthesis – Sample Notes.md")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.copyItem(at: bundled, to: destination)
        }
        let notebook = app.store.createNotebook(title: "Sample: Photosynthesis")
        app.store.setSymbol("leaf", for: notebook.id)
        app.library.importURLs([destination], into: notebook.id, supportsVision: app.models.supportsVision)
    }
}
