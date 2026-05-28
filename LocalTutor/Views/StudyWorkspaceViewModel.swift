//
//  StudyWorkspaceViewModel.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudyWorkspaceViewModel: ObservableObject {
    @Published var sources: [StudySource] = []
    @Published var selectedResource: StudyResourceKind = .summary
    @Published var studyGoal = ""
    @Published var output = ""
    @Published var statusMessage = "Ready"
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    @Published var isRunning = false
    @Published var errorMessage: String?

    private let runner: LocalModelRunner
    private var runTask: Task<Void, Never>?
    private var downloadPhaseHasEnded = false

    init(runner: LocalModelRunner = LocalModelRunner()) {
        self.runner = runner
    }

    var activeProfile: InferenceProfile {
        InferenceProfile.recommendedDefault
    }

    var preflight: MemoryPreflightResult {
        MemoryPreflight.evaluate(profile: activeProfile)
    }

    var selectedImageURL: URL? {
        sources.first(where: \.isImage)?.url
    }

    var canGenerate: Bool {
        !isRunning && (!studyGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sources.isEmpty)
    }

    var sourceSummary: String {
        if sources.isEmpty {
            return "No sources"
        }

        let sourceCount = sources.count
        let imageCount = sources.filter(\.isImage).count
        if imageCount > 0 {
            return "\(sourceCount) source\(sourceCount == 1 ? "" : "s"), \(imageCount) image\(imageCount == 1 ? "" : "s")"
        }
        return "\(sourceCount) source\(sourceCount == 1 ? "" : "s")"
    }

    func importURLs(_ urls: [URL]) {
        let existingURLs = Set(sources.map(\.url))
        let newSources = urls
            .filter { !existingURLs.contains($0) }
            .map(StudySource.init(url:))

        guard !newSources.isEmpty else {
            return
        }

        sources.append(contentsOf: newSources)
        statusMessage = "\(sources.count) source\(sources.count == 1 ? "" : "s") ready"
        errorMessage = nil
    }

    func importFromDropProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else {
            return false
        }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                if let error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else {
                    return
                }

                Task { @MainActor in
                    self?.importURLs([url])
                }
            }
        }

        return true
    }

    func removeSource(_ source: StudySource) {
        sources.removeAll { $0.id == source.id }
        statusMessage = sources.isEmpty ? "Ready" : "\(sources.count) source\(sources.count == 1 ? "" : "s") ready"
    }

    func clearSources() {
        sources.removeAll()
        statusMessage = "Ready"
        errorMessage = nil
    }

    func generate() {
        guard canGenerate else {
            return
        }

        let profile = activeProfile
        let preflight = MemoryPreflight.evaluate(profile: profile)

        guard preflight.canRun else {
            statusMessage = "Model unavailable"
            errorMessage = preflight.message
            return
        }

        let prompt = makePrompt()
        let imageURL = selectedImageURL

        output = ""
        errorMessage = nil
        downloadProgress = nil
        isDownloading = false
        downloadPhaseHasEnded = false
        isRunning = true
        statusMessage = "Starting \(profile.name)"

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                let record = try await runner.run(
                    profile: profile,
                    prompt: prompt,
                    imageURL: imageURL
                ) { [weak self] event in
                    await self?.handle(event)
                }

                await MainActor.run {
                    self.finish(record: record)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Could not run local model"
                    self.downloadProgress = nil
                    self.isDownloading = false
                    self.downloadPhaseHasEnded = true
                    self.isRunning = false
                }
            }
        }
    }

    func cancel() {
        guard isRunning else {
            return
        }

        statusMessage = "Cancelling"
        runTask?.cancel()
    }

    func unloadModel() {
        Task {
            await runner.unload()
            await MainActor.run {
                statusMessage = "Model unloaded"
                downloadProgress = nil
                isDownloading = false
                downloadPhaseHasEnded = true
            }
        }
    }

    private func handle(_ event: LocalModelRunnerEvent) {
        switch event {
        case .stage(let message):
            statusMessage = message
            if Self.stageEndsDownload(message) {
                isDownloading = false
                downloadProgress = nil
                downloadPhaseHasEnded = true
            }

        case .downloadProgress(let update):
            guard !downloadPhaseHasEnded else {
                return
            }
            isDownloading = true
            downloadProgress = update.fraction
            statusMessage = update.message

        case .outputChunk(let chunk):
            output += chunk
        }
    }

    private func finish(record: BenchmarkRecord) {
        if output.isEmpty {
            output = record.output
        }

        switch record.status {
        case .success:
            statusMessage = "Finished"
            errorMessage = nil
        case .cancelled:
            statusMessage = "Cancelled"
            errorMessage = nil
        case .failed:
            statusMessage = "Failed"
            errorMessage = record.errorMessage ?? "The local model run failed."
        case .skipped:
            statusMessage = "Skipped"
            errorMessage = record.errorMessage
        }

        downloadProgress = nil
        isDownloading = false
        downloadPhaseHasEnded = true
        isRunning = false
    }

    private static func stageEndsDownload(_ message: String) -> Bool {
        message.hasPrefix("Loaded")
            || message.hasPrefix("Using loaded")
            || message == "Preparing prompt"
            || message == "Generating"
    }

    private func makePrompt() -> String {
        let trimmedGoal = studyGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = trimmedGoal.isEmpty ? "Help me study the attached sources." : trimmedGoal
        let sourceList = sources.isEmpty
            ? "No files were attached."
            : sources.map { "- \($0.displayName) (\($0.kind.label))" }.joined(separator: "\n")

        return """
        You are LocalTutor, a private local study tutor running on the student's Mac.

        Resource to create:
        \(selectedResource.promptInstruction)

        Student goal:
        \(goal)

        Source files:
        \(sourceList)

        If an image is attached, analyze the image directly. If a non-image source only appears by filename, do not pretend you have read its contents; say what you can infer from the available context and ask for the relevant excerpt when needed.

        Format the answer for studying with short headings, concrete bullets, and no filler.
        """
    }
}
