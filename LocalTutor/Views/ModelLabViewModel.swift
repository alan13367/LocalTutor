//
//  ModelLabViewModel.swift
//  LocalTutor
//
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class ModelLabViewModel: ObservableObject {
    @Published var profiles = ModelProfile.v0Catalog
    @Published var selectedProfileID = ModelProfile.recommendedDefault.id
    @Published var prompt = """
    You are LocalTutor. Explain the attached material or prompt like a careful tutor, then list the most important facts a student should remember.
    """
    @Published var selectedImageURL: URL?
    @Published var output = ""
    @Published var statusMessage = "Ready"
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    @Published var isRunning = false
    @Published var latestRecord: BenchmarkRecord?
    @Published var latestRecordURL: URL?
    @Published var errorMessage: String?

    private let inferenceService: any InferenceService
    private let store: BenchmarkStore
    private var runTask: Task<Void, Never>?
    private var downloadPhaseHasEnded = false

    init(inferenceService: any InferenceService = LocalModelRunner(), store: BenchmarkStore = BenchmarkStore()) {
        self.inferenceService = inferenceService
        self.store = store
    }

    convenience init(runner: LocalModelRunner, store: BenchmarkStore = BenchmarkStore()) {
        self.init(inferenceService: runner, store: store)
    }

    var selectedProfile: ModelProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    var currentPreflight: MemoryPreflightResult {
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: selectedProfile)
        return MemoryPreflight.evaluate(policy: runtimePolicy)
    }

    var canRun: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var exportFilename: String {
        guard let latestRecord else {
            return "localtutor-benchmark.json"
        }

        let timestamp = DateFormatter.localTutorBenchmarkFilename(from: latestRecord.startedAt)
        return "\(timestamp)-\(latestRecord.profileID).json"
    }

    func runSelectedProfile() {
        guard canRun else {
            return
        }

        let profile = selectedProfile
        let runtimePolicy = ModelRuntimePolicyProvider.policy(for: profile)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageURL = selectedImageURL
        let preflight = MemoryPreflight.evaluate(policy: runtimePolicy)

        output = ""
        latestRecord = nil
        latestRecordURL = nil
        errorMessage = nil
        downloadProgress = nil
        isDownloading = false
        downloadPhaseHasEnded = false

        guard preflight.canRun else {
            let record = BenchmarkRecord.skipped(
                profile: profile,
                prompt: prompt,
                imageFilename: imageURL?.lastPathComponent,
                reason: preflight.message
            )
            Task {
                await finish(record: record, status: preflight.message)
            }
            return
        }

        isRunning = true
        statusMessage = "Starting \(profile.name)"

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                let promptContent = try StudyPromptBuilder.modelLabContent(
                    prompt: prompt,
                    imageURL: imageURL
                )
                let request = InferenceRequest(
                    profile: profile,
                    runtimePolicy: runtimePolicy,
                    promptContent: promptContent
                )
                let record = try await inferenceService.run(request: request) { [weak self] event in
                    await self?.handle(event)
                }
                await finish(record: record, status: statusMessage(for: record))
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    statusMessage = error.localizedDescription
                    isDownloading = false
                    downloadPhaseHasEnded = true
                    isRunning = false
                }
            }
        }
    }

    func cancelRun() {
        statusMessage = "Cancelling"
        runTask?.cancel()
    }

    func unloadModel() {
        Task {
            await inferenceService.unload()
            await MainActor.run {
                statusMessage = "Model unloaded"
                downloadProgress = nil
                isDownloading = false
                downloadPhaseHasEnded = true
            }
        }
    }

    func clearCache() {
        Task {
            do {
                try await inferenceService.clearCache()
                await MainActor.run {
                    statusMessage = "Model cache cleared"
                    downloadProgress = nil
                    isDownloading = false
                    downloadPhaseHasEnded = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    statusMessage = "Could not clear cache"
                }
            }
        }
    }

    func setImageURL(_ url: URL?) {
        selectedImageURL = url
    }

    private func handle(_ event: LocalModelRunnerEvent) {
        switch event {
        case .stage(let message):
            statusMessage = message
            if LocalModelRunnerStage.endsDownloadPhase(message) {
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

    private func finish(record: BenchmarkRecord, status: String) async {
        let savedURL: URL?
        do {
            savedURL = try await store.save(record)
        } catch {
            savedURL = nil
            errorMessage = "Benchmark finished but could not be saved: \(error.localizedDescription)"
        }

        latestRecord = record
        latestRecordURL = savedURL
        if output.isEmpty {
            output = record.output
        }
        statusMessage = status
        downloadProgress = nil
        isDownloading = false
        downloadPhaseHasEnded = true
        isRunning = false
    }

    private func statusMessage(for record: BenchmarkRecord) -> String {
        switch record.status {
        case .success:
            "Finished \(record.profileName)"
        case .cancelled:
            "Cancelled"
        case .failed:
            record.errorMessage ?? "Failed"
        case .skipped:
            record.errorMessage ?? "Skipped"
        }
    }

}
