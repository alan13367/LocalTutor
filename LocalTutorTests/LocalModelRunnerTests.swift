//
//  LocalModelRunnerTests.swift
//  LocalTutorTests
//
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LocalTutor

struct LocalModelRunnerTests {
    @MainActor
    @Test
    func firstTurnSourcePreviewOnlyShowsForEmptySessionsWithSources() {
        let viewModel = StudyWorkspaceViewModel()
        let sessionID = viewModel.currentSessionID
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTutorPreviewTest.md")
        try? "Preview test notes".write(to: sourceURL, atomically: true, encoding: .utf8)
        let source = StudySource(url: sourceURL)

        viewModel.currentSession = StudySession(id: sessionID, sources: [], turns: [])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == false)

        viewModel.currentSession = StudySession(id: sessionID, sources: [source], turns: [])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == true)

        let user = StudyTurnUser(
            focus: "What should I study?",
            resourceKind: .ask,
            sources: [source],
            isRefinement: false
        )
        viewModel.currentSession = StudySession(id: sessionID, sources: [source], turns: [StudyTurn(user: user)])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == false)
    }

    @MainActor
    @Test
    func textOnlyImportRejectsImagesButKeepsDocuments() throws {
        let viewModel = StudyWorkspaceViewModel()
        let sessionID = viewModel.currentSessionID
        viewModel.currentSession = StudySession(id: sessionID, sources: [], turns: [])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTutorImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notesURL = directory.appendingPathComponent("notes.md")
        let imageURL = directory.appendingPathComponent("figure.png")
        try "Readable notes".write(to: notesURL, atomically: true, encoding: .utf8)
        try Data().write(to: imageURL)

        viewModel.importURLs([notesURL, imageURL], supportsVision: false)

        #expect(viewModel.sources.map(\.displayName) == ["notes.md"])
        #expect(viewModel.globalError == "Images require a vision model.")
        #expect(StudySource.supportedContentTypes(supportsVision: false).contains(.image) == false)
        #expect(StudySource.supportedContentTypes(supportsVision: true).contains(.image))
    }

    @MainActor
    @Test
    func removingSelectedDownloadedModelClearsSelectionAndDisablesSend() {
        let previousProfileID = UserDefaults.standard.string(forKey: AppStorageKeys.selectedProfileID)
        defer {
            if let previousProfileID {
                UserDefaults.standard.set(previousProfileID, forKey: AppStorageKeys.selectedProfileID)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.selectedProfileID)
            }
        }

        UserDefaults.standard.removeObject(forKey: AppStorageKeys.selectedProfileID)
        let viewModel = StudyWorkspaceViewModel(
            inferenceService: NoopInferenceService(),
            cacheInfoProvider: { profiles in
                Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, ModelCacheInfo.empty) })
            },
            cachedModelRemover: { _ in
                ModelCacheRemovalResult(removedByteCount: 0)
            }
        )
        viewModel.setActiveProfile(.gemma4E2B)
        viewModel.composerText = "Summarize this"

        #expect(viewModel.selectedProfile?.id == ModelProfile.gemma4E2B.id)
        #expect(viewModel.canSend)

        viewModel.removeCachedModel(.gemma4E2B)

        #expect(viewModel.selectedProfile == nil)
        #expect(viewModel.canSend == false)
    }

    @Test
    func runnerRefusesConcurrentRuns() async {
        let runner = LocalModelRunner()
        await runner.setRunningForTesting(true)

        do {
            _ = try await runner.run(
                profile: .gemma4E2B,
                prompt: "Hello",
                imageURL: nil,
                events: { _ in }
            )
            Issue.record("Expected busy error")
        } catch let error as LocalModelRunnerError {
            #expect(error.localizedDescription == LocalModelRunnerError.busy.localizedDescription)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func downloadProgressTrackerSuppressesAlreadyCachedCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 100

        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerSuppressesCachedZeroThenCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)

        progress.completedUnitCount = 0
        #expect(tracker.update(progress) == nil)

        progress.completedUnitCount = 100
        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerReportsRealWorkBeforeCompletion() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 20

        let update = tracker.update(progress)

        #expect(update?.fraction == 0.2)
        #expect(update?.message == "Downloading 20%")
    }

    @Test
    func downloadProgressTrackerReportsVisibleSubPercentProgress() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 4_450_000_000)
        progress.completedUnitCount = 17_100_000

        let update = tracker.update(progress)

        #expect(DownloadProgressUpdate.percentText(for: 0.00384) == "0.4%")
        #expect(DownloadProgressUpdate.percentText(for: 0.0004) == "<0.1%")
        #expect(update?.message.hasPrefix("Downloading 0.4%") == true)
        #expect(update?.message.contains(" of ") == true)
    }

    @Test
    func downloadProgressTrackerUsesChildProgressFraction() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let parent = Progress(totalUnitCount: 1_000)
        let child = Progress(totalUnitCount: 1_000, parent: parent, pendingUnitCount: 1_000)
        child.completedUnitCount = 250

        let update = tracker.update(parent)

        #expect(update?.fraction == 0.25)
        #expect(update?.message == "Downloading 25%")
    }

    @Test
    func downloadProgressTrackerTreatsLowerFractionsAsNextFileProgress() {
        let tracker = DownloadProgressTracker(temporaryDirectory: nil)
        let progress = Progress(totalUnitCount: 1_000)

        progress.completedUnitCount = 400
        _ = tracker.update(progress)

        progress.completedUnitCount = 100
        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.46) < 0.0001)
        #expect(update?.message == "Downloading 46%")
    }

    @Test
    func downloadProgressTrackerUsesActiveTemporaryDownloadBytesWhenParentStalls() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorDownloadProgressTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let tracker = DownloadProgressTracker(temporaryDirectory: temporaryDirectory)
        let progress = Progress(totalUnitCount: 1_000_000_000)
        progress.completedUnitCount = 100_000_000
        _ = tracker.update(progress)

        let activeDownload = temporaryDirectory.appendingPathComponent("CFNetworkDownload_live.tmp")
        _ = fileManager.createFile(atPath: activeDownload.path, contents: nil)
        let handle = try FileHandle(forWritingTo: activeDownload)
        try handle.truncate(atOffset: 250_000_000)
        try handle.close()

        progress.completedUnitCount = 100_000_000
        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.35) < 0.0001)
        #expect(update?.message.hasPrefix("Downloading 35%") == true)

        let repeatedUpdate = tracker.update(progress)
        #expect(abs((repeatedUpdate?.fraction ?? 0) - 0.35) < 0.0001)

        let growHandle = try FileHandle(forWritingTo: activeDownload)
        try growHandle.truncate(atOffset: 300_000_000)
        try growHandle.close()

        Thread.sleep(forTimeInterval: 0.3)
        let grownUpdate = tracker.update(progress)
        #expect(abs((grownUpdate?.fraction ?? 0) - 0.4) < 0.0001)
        #expect(grownUpdate?.message.hasPrefix("Downloading 40%") == true)
    }

    @Test
    func downloadProgressTrackerDoesNotReportCompletionFromTemporaryBytesAlone() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorDownloadProgressTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let tracker = DownloadProgressTracker(temporaryDirectory: temporaryDirectory)
        let progress = Progress(totalUnitCount: 1_000_000_000)
        progress.completedUnitCount = 900_000_000
        _ = tracker.update(progress)

        let activeDownload = temporaryDirectory.appendingPathComponent("CFNetworkDownload_large.tmp")
        _ = fileManager.createFile(atPath: activeDownload.path, contents: nil)
        let handle = try FileHandle(forWritingTo: activeDownload)
        try handle.truncate(atOffset: 200_000_000)
        try handle.close()

        let update = tracker.update(progress)

        #expect(abs((update?.fraction ?? 0) - 0.999) < 0.0001)
        #expect(update?.message.hasPrefix("Downloading 99%") == true)
        #expect(update?.message != "Download complete")
    }

    @Test
    func reasoningOutputFilterRemovesThinkBlocks() {
        let raw = """
        <think>
        internal reasoning
        </think>
        # Final answer
        Study this.
        """

        #expect(ReasoningOutputFilter.sanitize(raw) == "\n# Final answer\nStudy this.")
    }

    @Test
    func reasoningOutputFilterBuffersSplitThinkTagsWhileStreaming() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<thi") == ReasoningOutputFilter.Chunk())
        #expect(filter.append("nk>hidden") == ReasoningOutputFilter.Chunk(reasoning: "hidden"))
        #expect(filter.append(" still hidden</thi") == ReasoningOutputFilter.Chunk(reasoning: " still hidden"))
        #expect(filter.append("nk>Visible") == ReasoningOutputFilter.Chunk(visible: "Visible"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterKeepsVisibleTextAroundThinkBlocks() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("Intro <think>hidden") == ReasoningOutputFilter.Chunk(visible: "Intro ", reasoning: "hidden"))
        #expect(filter.append("</think> final") == ReasoningOutputFilter.Chunk(visible: " final"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func reasoningOutputFilterFlushesUnclosedThinkingAsReasoning() {
        var filter = ReasoningOutputFilter()

        #expect(filter.append("<think>still thinking") == ReasoningOutputFilter.Chunk(reasoning: "still thinking"))
        #expect(filter.finish() == ReasoningOutputFilter.Chunk())
    }

    @Test
    func managedDownloaderDoesNotClampProgressToSmallerDelegateExpectedBytes() {
        let estimate = ManagedModelDownloadService.fileProgressEstimate(
            totalBytesWritten: 3_000,
            delegateExpectedBytes: 2_000,
            expectedFileBytes: 5_000
        )

        #expect(estimate.writtenBytes == 3_000)
        #expect(estimate.expectedBytes == 5_000)

        let completedEstimate = ManagedModelDownloadService.fileProgressEstimate(
            totalBytesWritten: 7_000,
            delegateExpectedBytes: 2_000,
            expectedFileBytes: 5_000
        )

        #expect(completedEstimate.writtenBytes == 5_000)
        #expect(completedEstimate.expectedBytes == 5_000)
    }

    @Test
    func managedModelStoreRequiresEveryIndexedWeightShard() throws {
        let fileManager = FileManager.default
        let modelDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelDirectory) }

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"model_type":"lfm2"}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"tokenizer_class":"PreTrainedTokenizerFast"}"#.write(
            to: modelDirectory.appendingPathComponent("tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
            .write(
                to: modelDirectory.appendingPathComponent("model.safetensors.index.json"),
                atomically: true,
                encoding: .utf8
            )
        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .lfm25A1B8B) == false)

        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model-00002-of-00002.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .lfm25A1B8B))
    }

    @Test
    func managedModelStoreRequiresVisionMetadataForVisionProfiles() throws {
        let fileManager = FileManager.default
        let modelDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedVisionStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelDirectory) }

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"model_type":"gemma"}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{}"#.write(
            to: modelDirectory.appendingPathComponent("tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 1, count: 8).write(
            to: modelDirectory.appendingPathComponent("model.safetensors")
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .gemma4E2B) == false)

        try #"{"model_type":"gemma","vision_config":{}}"#.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{}"#.write(
            to: modelDirectory.appendingPathComponent("processor_config.json"),
            atomically: true,
            encoding: .utf8
        )

        #expect(ManagedModelStore.isUsableModelDirectory(modelDirectory, for: .gemma4E2B))
    }

    @Test
    func modelCacheStoreRemovesOnlySelectedModel() throws {
        let fileManager = FileManager.default
        let cacheDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorModelCacheTests-\(UUID().uuidString)", isDirectory: true)
        let managedRepositoriesDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorManagedModelCacheTests-\(UUID().uuidString)", isDirectory: true)
        let jobsFileURL = fileManager.temporaryDirectory
            .appendingPathComponent("LocalTutorModelJobs-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: cacheDirectory) }
        defer { try? fileManager.removeItem(at: managedRepositoriesDirectory) }
        defer { try? fileManager.removeItem(at: jobsFileURL) }

        let lfmLocations = try ModelCacheStore.cacheLocations(
            for: ModelProfile.lfm25A1B8B.modelIdentifier,
            cacheDirectory: cacheDirectory
        )
        let gemmaLocations = try ModelCacheStore.cacheLocations(
            for: ModelProfile.gemma4E2B.modelIdentifier,
            cacheDirectory: cacheDirectory
        )

        try writeCacheFixture(
            repository: lfmLocations.repository,
            metadata: lfmLocations.metadata,
            locks: lfmLocations.locks,
            fileManager: fileManager
        )
        try writeCacheFixture(
            repository: gemmaLocations.repository,
            metadata: gemmaLocations.metadata,
            locks: gemmaLocations.locks,
            fileManager: fileManager
        )
        let lfmManagedRepository = ManagedModelStore.repositoryDirectory(
            for: ModelProfile.lfm25A1B8B.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory
        )
        let gemmaManagedRepository = ManagedModelStore.repositoryDirectory(
            for: ModelProfile.gemma4E2B.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory
        )
        try writeManagedRepositoryFixture(lfmManagedRepository, fileManager: fileManager)
        try writeManagedRepositoryFixture(gemmaManagedRepository, fileManager: fileManager)
        try writeJobsFixture(
            jobsFileURL,
            jobs: [
                makePersistedJob(for: .lfm25A1B8B),
                makePersistedJob(for: .gemma4E2B)
            ]
        )

        let before = try ModelCacheStore.cacheInfo(
            for: .lfm25A1B8B,
            cacheDirectory: cacheDirectory,
            managedRepositoriesDirectory: managedRepositoriesDirectory
        )
        let result = try ModelCacheStore.removeCachedModel(
            for: .lfm25A1B8B,
            cacheDirectory: cacheDirectory,
            managedRepositoriesDirectory: managedRepositoriesDirectory,
            jobsFileURL: jobsFileURL
        )

        #expect(before.isCached)
        #expect(before.hasManagedFiles)
        #expect(before.byteCount > 0)
        #expect(result.removedByteCount > 0)
        #expect(fileManager.fileExists(atPath: lfmLocations.repository.path) == false)
        #expect(fileManager.fileExists(atPath: lfmLocations.metadata.path) == false)
        #expect(fileManager.fileExists(atPath: lfmLocations.locks.path) == false)
        #expect(fileManager.fileExists(atPath: lfmManagedRepository.path) == false)
        #expect(fileManager.fileExists(atPath: gemmaLocations.repository.path))
        #expect(fileManager.fileExists(atPath: gemmaLocations.metadata.path))
        #expect(fileManager.fileExists(atPath: gemmaLocations.locks.path))
        #expect(fileManager.fileExists(atPath: gemmaManagedRepository.path))

        let jobsData = try Data(contentsOf: jobsFileURL)
        let manifest = try JSONDecoder().decode(ModelDownloadJobsManifest.self, from: jobsData)
        #expect(manifest.jobs.map(\.id) == [ModelProfile.gemma4E2B.id])
    }

    private func writeCacheFixture(
        repository: URL,
        metadata: URL,
        locks: URL,
        fileManager: FileManager
    ) throws {
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: blobs.appendingPathComponent("weights.safetensors"))

        try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "{}".write(to: metadata.appendingPathComponent("snapshot.json"), atomically: true, encoding: .utf8)

        try fileManager.createDirectory(at: locks, withIntermediateDirectories: true)
        try "lock".write(to: locks.appendingPathComponent("weights.lock"), atomically: true, encoding: .utf8)
    }

    private func writeManagedRepositoryFixture(_ repository: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 32).write(to: repository.appendingPathComponent("weights.safetensors"))
    }

    private func makePersistedJob(for profile: ModelProfile) -> ModelDownloadJob {
        ModelDownloadJob(
            id: profile.id,
            displayName: profile.name,
            modelIdentifier: profile.modelIdentifier,
            revision: "main",
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            lastErrorMessage: nil,
            files: [
                ModelDownloadFileState(
                    relativePath: "weights.safetensors",
                    remoteURL: URL(string: "https://huggingface.co/\(profile.modelIdentifier)/resolve/main/weights.safetensors")!,
                    expectedBytes: 32,
                    writtenBytes: 32,
                    status: .completed,
                    lastErrorMessage: nil
                )
            ]
        )
    }

    private func writeJobsFixture(_ url: URL, jobs: [ModelDownloadJob]) throws {
        let manifest = ModelDownloadJobsManifest(jobs: jobs)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }
}

private struct NoopInferenceService: InferenceService {
    func run(
        request _: InferenceRequest,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord {
        throw CancellationError()
    }

    func preload(
        profile _: ModelProfile,
        runtimePolicy _: ModelRuntimePolicy,
        events _: nonisolated(nonsending) @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws {}

    func unload() async {}

    func clearCache() async throws {}
}
