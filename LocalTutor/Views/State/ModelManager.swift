//
//  ModelManager.swift
//  LocalTutor
//

import Foundation
import Observation

enum ModelDownloadPhase: Equatable {
    case checking
    case downloading
    case paused
    case loading
    case ready
    case failed

    var isTransferring: Bool {
        self == .checking || self == .downloading
    }
}

enum ModelManagerError: LocalizedError {
    case downloadPaused(String)

    var errorDescription: String? {
        switch self {
        case .downloadPaused(let name):
            "\(name) is paused. Resume the download to continue."
        }
    }
}

struct ModelDownloadStatus: Equatable {
    var profileID: String
    var profileName: String
    var message: String
    var fraction: Double?
    var phase: ModelDownloadPhase
}

@MainActor
@Observable
final class ModelManager {
    static let noSelectedProfileID = "__localtutor_no_selected_profile__"
    private static let cacheInfoRefreshMinimumInterval: TimeInterval = 5

    private(set) var storedProfileID: String {
        didSet { UserDefaults.standard.set(storedProfileID, forKey: AppStorageKeys.selectedProfileID) }
    }
    var contextPreference: ContextPreference {
        didSet {
            UserDefaults.standard.set(contextPreference.rawValue, forKey: AppStorageKeys.contextPreference)
            Task { await inferenceService.releaseConversations() }
        }
    }
    private(set) var downloadStatus: ModelDownloadStatus?
    private(set) var cacheInfoByProfileID: [String: ModelCacheInfo] = [:]
    private(set) var removingProfileIDs: Set<String> = []
    private(set) var loadedProfileID: String?
    var isGenerationActive: () -> Bool = { false }
    var onError: (String) -> Void = { _ in }

    var useSpeculativeDecoding: Bool {
        didSet {
            UserDefaults.standard.set(useSpeculativeDecoding, forKey: AppStorageKeys.useSpeculativeDecoding)
            let enabled = useSpeculativeDecoding
            Task { await inferenceService.setSpeculativeDecoding(enabled) }
        }
    }

    @ObservationIgnored let inferenceService: any InferenceService
    @ObservationIgnored private let downloadService: ManagedModelDownloadService?
    @ObservationIgnored private var pausingProfileID: String?
    @ObservationIgnored private let cacheInfoProvider: @Sendable ([ModelProfile]) async -> [String: ModelCacheInfo]
    @ObservationIgnored private let cachedModelRemover: @Sendable (ModelProfile) async throws -> ModelCacheRemovalResult
    @ObservationIgnored private var preloadTask: Task<Void, Error>?
    @ObservationIgnored private var preloadProfileID: String?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var cacheRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cacheInfoLoadedAt: Date?

    init(
        inferenceService: any InferenceService,
        cacheInfoProvider: @escaping @Sendable ([ModelProfile]) async -> [String: ModelCacheInfo] = { profiles in
            await Task.detached(priority: .utility) {
                ModelCacheStore.cacheInfoByProfileID(for: profiles)
            }.value
        },
        cachedModelRemover: @escaping @Sendable (ModelProfile) async throws -> ModelCacheRemovalResult = { profile in
            try await Task.detached(priority: .utility) {
                try ModelCacheStore.removeCachedModel(for: profile)
            }.value
        },
        downloadService: ManagedModelDownloadService? = .shared
    ) {
        self.inferenceService = inferenceService
        self.cacheInfoProvider = cacheInfoProvider
        self.cachedModelRemover = cachedModelRemover
        self.downloadService = downloadService
        storedProfileID = UserDefaults.standard.string(forKey: AppStorageKeys.selectedProfileID) ?? ""
        contextPreference = .current
        useSpeculativeDecoding = UserDefaults.standard.object(forKey: AppStorageKeys.useSpeculativeDecoding) as? Bool ?? true
        refreshCacheInfo(force: true)
        restorePausedDownload()
    }

    // MARK: - Selection

    var selectedProfile: ModelProfile? {
        if storedProfileID == Self.noSelectedProfileID {
            return nil
        }
        if let profile = ModelProfile.profile(withID: storedProfileID),
           MemoryPreflight.evaluate(profile: profile).canRun {
            return profile
        }
        if storedProfileID.isEmpty {
            let defaultProfile = ModelProfile.recommendedDefault
            return MemoryPreflight.evaluate(profile: defaultProfile).canRun ? defaultProfile : nil
        }
        return nil
    }

    var activeProfile: ModelProfile {
        selectedProfile ?? ModelProfile.recommendedDefault
    }

    var runtimePolicy: ModelRuntimePolicy? {
        selectedProfile.map { ModelRuntimePolicyProvider.policy(for: $0, preference: contextPreference) }
    }

    var supportsVision: Bool {
        selectedProfile?.supportsVision ?? false
    }

    var isSelectedModelDownloaded: Bool {
        guard let selectedProfile else { return false }
        return cacheInfo(for: selectedProfile).isCached
    }

    var preflight: MemoryPreflightResult {
        guard let selectedProfile else {
            return MemoryPreflightResult(
                canRun: false,
                systemMemoryBytes: SystemMemory.totalBytes(),
                requiredBytes: 0,
                message: "Choose a model before studying."
            )
        }
        return MemoryPreflight.evaluate(profile: selectedProfile)
    }

    func select(_ profile: ModelProfile, preload: Bool = true) {
        storedProfileID = profile.id
        if preload {
            startPreload(for: profile)
        }
    }

    func clearSelection() {
        storedProfileID = Self.noSelectedProfileID
    }

    // MARK: - Cache info

    func refreshCacheInfo(force: Bool = false) {
        if !force,
           let cacheInfoLoadedAt,
           Date().timeIntervalSince(cacheInfoLoadedAt) < Self.cacheInfoRefreshMinimumInterval {
            return
        }
        if !force, cacheRefreshTask != nil {
            return
        }
        cacheRefreshTask?.cancel()
        let profiles = ModelProfile.studyCatalog + [ModelCatalog.embeddingModel]
        let provider = cacheInfoProvider
        cacheRefreshTask = Task { [weak self] in
            let info = await provider(profiles)
            guard !Task.isCancelled else { return }
            self?.cacheInfoByProfileID = info
            self?.cacheInfoLoadedAt = Date()
            self?.cacheRefreshTask = nil
        }
    }

    func cacheInfo(for profile: ModelProfile) -> ModelCacheInfo {
        cacheInfoByProfileID[profile.id] ?? .empty
    }

    var hasAnyDownloadedModel: Bool {
        ModelProfile.studyCatalog.contains { cacheInfo(for: $0).isCached }
    }

    func isRemoving(_ profile: ModelProfile) -> Bool {
        removingProfileIDs.contains(profile.id)
    }

    func canRemove(_ profile: ModelProfile) -> Bool {
        cacheInfo(for: profile).isCached && !removingProfileIDs.contains(profile.id) && !isGenerationActive()
    }

    func remove(_ profile: ModelProfile) {
        guard !removingProfileIDs.contains(profile.id) else { return }
        guard !isGenerationActive() else {
            onError("Stop the current response before removing model files.")
            return
        }
        if selectedProfile?.id == profile.id {
            storedProfileID = Self.noSelectedProfileID
        }
        let preloadToCancel = preloadProfileID == profile.id ? preloadTask : nil
        preloadToCancel?.cancel()
        if preloadProfileID == profile.id {
            preloadProfileID = nil
            preloadTask = nil
        }

        dismissTask?.cancel()
        removingProfileIDs.insert(profile.id)
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "Removing downloaded files",
            fraction: nil,
            phase: .checking
        )

        let inferenceService = inferenceService
        let remover = cachedModelRemover
        Task { [weak self] in
            do {
                if let preloadToCancel {
                    _ = await preloadToCancel.result
                }
                await inferenceService.unload()
                if case .embedder = profile.configuration {
                    await LocalEmbeddingRunner.shared.unload()
                }
                let result = try await remover(profile)
                self?.completeRemoval(profile, result: result)
            } catch {
                self?.failRemoval(profile, error: error)
            }
        }
    }

    // MARK: - Loading

    func startPreload(for profile: ModelProfile) {
        if pausingProfileID == profile.id {
            pausingProfileID = nil
        }
        let policy = ModelRuntimePolicyProvider.policy(for: profile, preference: contextPreference)
        guard MemoryPreflight.evaluate(policy: policy).canRun else { return }
        if preloadProfileID == profile.id, preloadTask != nil { return }

        preloadTask?.cancel()
        dismissTask?.cancel()
        preloadProfileID = profile.id
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "Preparing \(profile.name)",
            fraction: nil,
            phase: .checking
        )

        let inferenceService = inferenceService
        preloadTask = Task { [weak self] in
            do {
                try await inferenceService.preload(profile: profile, runtimePolicy: policy) { [weak self] event in
                    await self?.handleLoadEvent(event, profile: profile)
                }
                self?.completePreload(profile)
            } catch is CancellationError {
                self?.clearPreloadIfCurrent(profile)
                throw CancellationError()
            } catch where self?.pausingProfileID == profile.id {
                self?.clearPreloadIfCurrent(profile)
                throw CancellationError()
            } catch {
                self?.failPreload(profile, error: error)
                throw error
            }
        }
    }

    func waitForPreloadIfNeeded(profile: ModelProfile) async throws {
        guard preloadProfileID == profile.id, let task = preloadTask else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(200))
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    var isPaused: Bool {
        downloadStatus?.phase == .paused
    }

    func ensureLoaded(_ profile: ModelProfile) async throws {
        if loadedProfileID == profile.id, preloadTask == nil { return }
        if downloadStatus?.profileID == profile.id, downloadStatus?.phase == .paused {
            throw ModelManagerError.downloadPaused(profile.name)
        }
        startPreload(for: profile)
        do {
            try await waitForPreloadIfNeeded(profile: profile)
        } catch is CancellationError {
            if downloadStatus?.phase == .paused {
                throw ModelManagerError.downloadPaused(profile.name)
            }
            throw CancellationError()
        }
    }

    // MARK: - Pause / resume

    var isDownloadActive: Bool {
        guard let status = downloadStatus else { return false }
        return status.phase.isTransferring && preloadTask != nil
    }

    func pauseDownload() {
        guard let status = downloadStatus, preloadTask != nil, status.phase.isTransferring else { return }
        pausingProfileID = status.profileID
        preloadTask?.cancel()
        downloadStatus = ModelDownloadStatus(
            profileID: status.profileID,
            profileName: status.profileName,
            message: Self.pausedMessage(fraction: status.fraction),
            fraction: status.fraction,
            phase: .paused
        )
    }

    func resumeDownload() {
        guard let status = downloadStatus, status.phase == .paused || status.phase == .failed,
              let profile = ModelProfile.profile(withID: status.profileID) else { return }
        pausingProfileID = nil
        startPreload(for: profile)
    }

    func cancelDownload() {
        guard let status = downloadStatus,
              let profile = ModelProfile.profile(withID: status.profileID) else { return }
        pausingProfileID = status.profileID
        let task = preloadProfileID == profile.id ? preloadTask : nil
        task?.cancel()
        downloadStatus = nil
        let service = downloadService
        Task { [weak self] in
            _ = await task?.result
            await service?.discardDownload(profile: profile)
            self?.pausingProfileID = nil
            self?.refreshCacheInfo(force: true)
        }
    }

    nonisolated static func pausedMessage(fraction: Double?) -> String {
        guard let fraction else { return "Download paused" }
        return "Paused at \(DownloadProgressUpdate.percentText(for: fraction))"
    }

    private func restorePausedDownload() {
        guard let downloadService else { return }
        Task { [weak self] in
            let pending = await downloadService.pendingDownloads()
            guard let self, self.downloadStatus == nil else { return }
            let preferred = pending.first { $0.profileID == self.selectedProfile?.id } ?? pending.first
            guard let preferred,
                  let profile = ModelProfile.profile(withID: preferred.profileID),
                  preferred.writtenBytes > 0 else { return }
            self.downloadStatus = ModelDownloadStatus(
                profileID: profile.id,
                profileName: profile.name,
                message: Self.pausedMessage(fraction: preferred.fraction),
                fraction: preferred.fraction,
                phase: .paused
            )
        }
    }

    func handleLoadEvent(_ event: LocalModelRunnerEvent, profile: ModelProfile) {
        if pausingProfileID == profile.id { return }
        switch event {
        case .stage(let message):
            if message == LocalModelRunnerStage.checkingModelCache() {
                updateStatus(for: profile, message: message, fraction: nil, phase: .checking)
            } else if message.hasPrefix("Loading") {
                updateStatus(for: profile, message: message, fraction: nil, phase: .loading)
            } else if LocalModelRunnerStage.endsDownloadPhase(message) {
                loadedProfileID = profile.id
                guard downloadStatus?.profileID == profile.id || preloadProfileID == profile.id else { return }
                markReady(profile)
            }
        case .downloadProgress(let update):
            updateStatus(for: profile, message: update.message, fraction: update.fraction, phase: .downloading)
        case .prefillProgress, .reasoningChunk, .outputChunk:
            break
        }
    }

    func dismissDownloadStatus() {
        dismissTask?.cancel()
        dismissTask = nil
        downloadStatus = nil
    }

    func unloadModel() {
        loadedProfileID = nil
        Task { await inferenceService.unload() }
    }

    private func updateStatus(for profile: ModelProfile, message: String, fraction: Double?, phase: ModelDownloadPhase) {
        dismissTask?.cancel()
        dismissTask = nil
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: message,
            fraction: fraction,
            phase: phase
        )
    }

    private func completePreload(_ profile: ModelProfile) {
        loadedProfileID = profile.id
        markReady(profile)
        clearPreloadIfCurrent(profile)
    }

    private func markReady(_ profile: ModelProfile) {
        guard downloadStatus?.profileID == profile.id || preloadProfileID == profile.id else { return }
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "\(profile.name) is ready",
            fraction: 1,
            phase: .ready
        )
        refreshCacheInfo(force: true)
        scheduleDismiss()
    }

    private func completeRemoval(_ profile: ModelProfile, result: ModelCacheRemovalResult) {
        removingProfileIDs.remove(profile.id)
        ModelArchitectureStore.invalidate(profile)
        cacheInfoByProfileID[profile.id] = .empty
        cacheInfoLoadedAt = Date()
        if loadedProfileID == profile.id {
            loadedProfileID = nil
        }
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: "Removed \(result.sizeDescription)",
            fraction: 1,
            phase: .ready
        )
        scheduleDismiss()
    }

    private func failRemoval(_ profile: ModelProfile, error: Error) {
        removingProfileIDs.remove(profile.id)
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: error.localizedDescription,
            fraction: nil,
            phase: .failed
        )
        refreshCacheInfo(force: true)
    }

    private func failPreload(_ profile: ModelProfile, error: Error) {
        clearPreloadIfCurrent(profile)
        downloadStatus = ModelDownloadStatus(
            profileID: profile.id,
            profileName: profile.name,
            message: error.localizedDescription,
            fraction: nil,
            phase: .failed
        )
    }

    private func clearPreloadIfCurrent(_ profile: ModelProfile) {
        guard preloadProfileID == profile.id else { return }
        preloadProfileID = nil
        preloadTask = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, self?.downloadStatus?.phase == .ready else { return }
            self?.downloadStatus = nil
            self?.dismissTask = nil
        }
    }
}
