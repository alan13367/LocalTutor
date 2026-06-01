//
//  ManagedModelDownloadService.swift
//  LocalTutor
//

import Foundation

struct ModelDownloadJobsManifest: Codable, Sendable {
    var jobs: [ModelDownloadJob]

    init(jobs: [ModelDownloadJob] = []) {
        self.jobs = jobs
    }
}

struct ModelDownloadJob: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued
        case downloading
        case failed
    }

    let id: String
    let displayName: String
    let modelIdentifier: String
    let revision: String
    var createdAt: Date
    var updatedAt: Date
    var status: Status
    var lastErrorMessage: String?
    var files: [ModelDownloadFileState]
}

struct ModelDownloadFileState: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case queued
        case downloading
        case completed
        case failed
    }

    var id: String { relativePath }

    let relativePath: String
    let remoteURL: URL
    var expectedBytes: Int64?
    var writtenBytes: Int64
    var status: Status
    var lastErrorMessage: String?
}

struct ManagedModelDownloadResult: Sendable {
    var directory: URL
    var downloadSeconds: Double
}

enum ManagedModelDownloadError: LocalizedError {
    case invalidRepositoryID(String)
    case unableToListRepository(String)
    case emptyRepository(String)
    case badResponse(String)
    case corruptedDownload(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository id: \(id)."
        case .unableToListRepository(let name):
            return "Could not list files for \(name)."
        case .emptyRepository(let name):
            return "No model files were found for \(name)."
        case .badResponse(let path):
            return "Could not download \(path)."
        case .corruptedDownload(let name):
            return "\(name) finished downloading, but the model files are incomplete."
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let required = ByteCountFormatter.localTutorMemoryString(fromByteCount: requiredBytes)
            let available = ByteCountFormatter.localTutorMemoryString(fromByteCount: availableBytes)
            return "Not enough disk space. \(required) required, \(available) available."
        }
    }
}

actor ManagedModelDownloadService {
    static let shared = ManagedModelDownloadService()

    private static let defaultRevision = "main"
    private static let defaultModelFileGlobs = [
        "*.safetensors",
        "*.json",
        "*.jinja",
        "*.txt",
        "*.model",
        "*.tiktoken"
    ]
    private static let minimumFreeSpaceMultiplier = 1.15
    private static let progressHeartbeatNanoseconds: UInt64 = 350_000_000

    typealias ProgressHandler = @Sendable (DownloadProgressUpdate) -> Void

    private let fileManager: FileManager
    private let repositoriesDirectory: URL
    private let stagingDirectory: URL
    private let jobsFileURL: URL
    private let hostURL: URL
    private let metadataSession: URLSession
    private var jobsByProfileID: [String: ModelDownloadJob]

    init(
        repositoriesDirectory: URL? = nil,
        stagingDirectory: URL? = nil,
        jobsFileURL: URL? = nil,
        metadataSession: URLSession? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.repositoriesDirectory = repositoriesDirectory
            ?? (try? AppDirectories.managedModelRepositories(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("LocalTutorModelRepositories", isDirectory: true)
        self.stagingDirectory = stagingDirectory
            ?? (try? AppDirectories.modelDownloadStaging(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("LocalTutorModelDownloadStaging", isDirectory: true)
        self.jobsFileURL = jobsFileURL
            ?? (try? AppDirectories.modelDownloadJobsFile(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("localtutor-model-download-jobs.json")
        self.hostURL = URL(string: "https://huggingface.co")!

        if let metadataSession {
            self.metadataSession = metadataSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60
            self.metadataSession = URLSession(configuration: configuration)
        }

        try? fileManager.createDirectory(at: self.repositoriesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.stagingDirectory, withIntermediateDirectories: true)
        Self.cleanupStagingDirectory(fileManager: fileManager, stagingDirectory: self.stagingDirectory)
        self.jobsByProfileID = Self.loadPersistedJobs(from: self.jobsFileURL)
    }

    func ensureDownloaded(
        profile: ModelProfile,
        revision requestedRevision: String? = nil,
        matching requestedGlobs: [String]? = nil,
        progressHandler: @escaping ProgressHandler
    ) async throws -> ManagedModelDownloadResult {
        let revision = requestedRevision ?? Self.defaultRevision
        let directory = ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: repositoriesDirectory
        )

        if jobsByProfileID[profile.id] == nil,
            ManagedModelStore.isUsableModelDirectory(directory, for: profile, fileManager: fileManager)
        {
            jobsByProfileID.removeValue(forKey: profile.id)
            savePersistedJobs()
            return ManagedModelDownloadResult(directory: directory, downloadSeconds: 0)
        }

        let startedAt = Date()
        var job = try await buildJob(
            for: profile,
            revision: revision,
            requestedGlobs: requestedGlobs ?? Self.defaultModelFileGlobs
        )
        if let existing = jobsByProfileID[profile.id] {
            job = merge(job, withExistingJob: existing)
        }

        try checkAvailableDiskSpace(for: job)
        jobsByProfileID[profile.id] = job
        savePersistedJobs()
        emitProgress(for: job, progressHandler: progressHandler)

        do {
            for relativePath in job.files.map(\.relativePath) {
                try Task.checkCancellation()
                try await downloadFileIfNeeded(
                    relativePath: relativePath,
                    modelID: profile.id,
                    progressHandler: progressHandler
                )
            }

            try Task.checkCancellation()
            guard ManagedModelStore.isUsableModelDirectory(directory, for: profile, fileManager: fileManager) else {
                throw ManagedModelDownloadError.corruptedDownload(profile.name)
            }

            if var finishedJob = jobsByProfileID[profile.id] {
                for index in finishedJob.files.indices {
                    finishedJob.files[index].status = .completed
                    let destination = directory.appending(path: finishedJob.files[index].relativePath)
                    let size = fileSizeIfExists(at: destination)
                    finishedJob.files[index].writtenBytes = size
                    finishedJob.files[index].expectedBytes = max(finishedJob.files[index].expectedBytes ?? 0, size)
                }
            }

            jobsByProfileID.removeValue(forKey: profile.id)
            savePersistedJobs()
            Self.emitProgress(
                completedBytes: totalBytesExpected(for: job) ?? totalBytesWritten(for: job),
                totalBytes: totalBytesExpected(for: job),
                isFinal: true,
                progressHandler: progressHandler
            )
            return ManagedModelDownloadResult(directory: directory, downloadSeconds: Date().timeIntervalSince(startedAt))
        } catch is CancellationError {
            markQueuedAfterCancellation(modelID: profile.id)
            throw CancellationError()
        } catch {
            failJob(modelID: profile.id, error: error)
            throw error
        }
    }

    func isDownloaded(profile: ModelProfile) -> Bool {
        let directory = ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: repositoriesDirectory
        )
        return ManagedModelStore.isUsableModelDirectory(directory, for: profile, fileManager: fileManager)
    }

    func localDirectory(for profile: ModelProfile) -> URL {
        ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: repositoriesDirectory
        )
    }

    private func buildJob(
        for profile: ModelProfile,
        revision: String,
        requestedGlobs: [String]
    ) async throws -> ModelDownloadJob {
        let filenames = try await fetchRepositoryFilenames(
            modelIdentifier: profile.modelIdentifier,
            displayName: profile.name,
            globs: Self.effectiveGlobs(requestedGlobs)
        )
        guard !filenames.isEmpty else {
            throw ManagedModelDownloadError.emptyRepository(profile.name)
        }

        let expectedBytesByFile = await fetchExpectedBytes(
            for: filenames,
            modelIdentifier: profile.modelIdentifier,
            revision: revision
        )
        let repositoryDirectory = ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: repositoriesDirectory
        )
        var files: [ModelDownloadFileState] = []

        for filename in filenames {
            let destination = repositoryDirectory.appending(path: filename)
            let existingBytes = fileSizeIfExists(at: destination)
            let expectedBytes = expectedBytesByFile[filename] ?? nil
            let isComplete = isCompleteFile(existingBytes: existingBytes, expectedBytes: expectedBytes)

            files.append(
                ModelDownloadFileState(
                    relativePath: filename,
                    remoteURL: remoteFileURL(
                        for: profile.modelIdentifier,
                        revision: revision,
                        relativePath: filename
                    ),
                    expectedBytes: expectedBytes,
                    writtenBytes: isComplete ? existingBytes : 0,
                    status: isComplete ? .completed : .pending,
                    lastErrorMessage: nil
                )
            )
        }

        return ModelDownloadJob(
            id: profile.id,
            displayName: profile.name,
            modelIdentifier: profile.modelIdentifier,
            revision: revision,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            lastErrorMessage: nil,
            files: files
        )
    }

    private func fetchRepositoryFilenames(
        modelIdentifier: String,
        displayName: String,
        globs: [String]
    ) async throws -> [String] {
        let requestURL = hostURL
            .appending(path: "api")
            .appending(path: "models")
            .appending(path: modelIdentifier)
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await metadataSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode)
            else {
                throw ManagedModelDownloadError.unableToListRepository(displayName)
            }

            let repository = try JSONDecoder().decode(HuggingFaceRepositoryResponse.self, from: data)
            return repository.siblings
                .map(\.rfilename)
                .filter { ManagedModelStore.matchesAnyGlob($0, globs: globs) }
                .sorted()
        } catch let error as ManagedModelDownloadError {
            throw error
        } catch {
            throw ManagedModelDownloadError.unableToListRepository(displayName)
        }
    }

    private func fetchExpectedBytes(
        for filenames: [String],
        modelIdentifier: String,
        revision: String
    ) async -> [String: Int64?] {
        var result: [String: Int64?] = [:]
        for filename in filenames {
            result[filename] = await fetchExpectedBytes(
                for: filename,
                modelIdentifier: modelIdentifier,
                revision: revision
            )
        }
        return result
    }

    private func fetchExpectedBytes(
        for relativePath: String,
        modelIdentifier: String,
        revision: String
    ) async -> Int64? {
        var request = URLRequest(url: remoteFileURL(for: modelIdentifier, revision: revision, relativePath: relativePath))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await metadataSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200 ..< 300).contains(httpResponse.statusCode)
            else {
                return nil
            }
            if let headerValue = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                let fileSize = Int64(headerValue)
            {
                return fileSize
            }
            return response.expectedContentLength > 0 ? response.expectedContentLength : nil
        } catch {
            return nil
        }
    }

    private func downloadFileIfNeeded(
        relativePath: String,
        modelID: String,
        progressHandler: @escaping ProgressHandler
    ) async throws {
        guard var job = jobsByProfileID[modelID],
            let index = job.files.firstIndex(where: { $0.relativePath == relativePath })
        else {
            return
        }

        let file = job.files[index]
        let repositoryDirectory = ManagedModelStore.repositoryDirectory(
            for: job.modelIdentifier,
            repositoriesDirectory: repositoriesDirectory
        )
        let destination = repositoryDirectory.appending(path: file.relativePath)
        let existingBytes = fileSizeIfExists(at: destination)
        if isCompleteFile(existingBytes: existingBytes, expectedBytes: file.expectedBytes) {
            job.files[index].writtenBytes = existingBytes
            job.files[index].status = .completed
            job.files[index].lastErrorMessage = nil
            job.updatedAt = Date()
            jobsByProfileID[modelID] = job
            savePersistedJobs()
            emitProgress(for: job, progressHandler: progressHandler)
            return
        }

        job.status = .downloading
        job.files[index].status = .downloading
        job.files[index].writtenBytes = 0
        job.files[index].lastErrorMessage = nil
        job.updatedAt = Date()
        jobsByProfileID[modelID] = job
        savePersistedJobs()
        emitProgress(for: job, progressHandler: progressHandler)

        let completedBefore = totalBytesWritten(for: job, excluding: relativePath)
        let totalExpected = totalBytesExpected(for: job)
        let temporaryBaseline = Self.temporaryDownloadFiles(fileManager: fileManager)
        let reportProgress: @Sendable (Int64, Int64) -> Void = { [progressHandler] totalBytesWritten, totalBytesExpected in
            let estimate = Self.fileProgressEstimate(
                totalBytesWritten: totalBytesWritten,
                delegateExpectedBytes: totalBytesExpected,
                expectedFileBytes: file.expectedBytes
            )
            let progressTotal = max(totalExpected ?? 0, completedBefore + (estimate.expectedBytes ?? 0))
            let boundedWritten = estimate.writtenBytes
            Self.emitProgress(
                completedBytes: max(0, completedBefore + boundedWritten),
                totalBytes: progressTotal > 0 ? progressTotal : nil,
                isFinal: false,
                progressHandler: progressHandler
            )
        }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedURL = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.removeItem(at: stagedURL)
        _ = fileManager.createFile(atPath: stagedURL.path, contents: nil)

        let delegate = try ModelFileDownloadDelegate(stagedFileURL: stagedURL, onProgress: reportProgress)
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60 * 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        defer {
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: file.remoteURL)
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60 * 60

        let response: URLResponse
        let heartbeatTask = Task {
            await Self.emitHeartbeatProgress(
                for: session,
                temporaryBaseline: temporaryBaseline,
                fileManager: fileManager,
                reportProgress: reportProgress
            )
        }
        defer {
            heartbeatTask.cancel()
        }
        do {
            response = try await delegate.download(request: request, session: session)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse,
            (200 ..< 300).contains(httpResponse.statusCode)
        else {
            try? fileManager.removeItem(at: stagedURL)
            throw ManagedModelDownloadError.badResponse(file.relativePath)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: stagedURL, to: destination)

        let finalSize = fileSizeIfExists(at: destination)
        guard isCompleteFile(existingBytes: finalSize, expectedBytes: file.expectedBytes) else {
            throw ManagedModelDownloadError.badResponse(file.relativePath)
        }

        guard var updatedJob = jobsByProfileID[modelID],
            let updatedIndex = updatedJob.files.firstIndex(where: { $0.relativePath == relativePath })
        else {
            return
        }
        updatedJob.files[updatedIndex].writtenBytes = finalSize
        updatedJob.files[updatedIndex].expectedBytes = max(updatedJob.files[updatedIndex].expectedBytes ?? 0, finalSize)
        updatedJob.files[updatedIndex].status = .completed
        updatedJob.files[updatedIndex].lastErrorMessage = nil
        updatedJob.status = updatedJob.files.allSatisfy { $0.status == .completed } ? .queued : .downloading
        updatedJob.updatedAt = Date()
        jobsByProfileID[modelID] = updatedJob
        savePersistedJobs()
        emitProgress(for: updatedJob, progressHandler: progressHandler)
    }

    private func merge(_ freshJob: ModelDownloadJob, withExistingJob existingJob: ModelDownloadJob) -> ModelDownloadJob {
        var merged = freshJob
        merged.createdAt = existingJob.createdAt
        merged.lastErrorMessage = existingJob.lastErrorMessage

        for index in merged.files.indices {
            let relativePath = merged.files[index].relativePath
            if let existingFile = existingJob.files.first(where: { $0.relativePath == relativePath }) {
                merged.files[index].expectedBytes = merged.files[index].expectedBytes ?? existingFile.expectedBytes
                if merged.files[index].status != .completed {
                    merged.files[index].status = .pending
                    merged.files[index].writtenBytes = 0
                } else {
                    merged.files[index].writtenBytes = max(merged.files[index].writtenBytes, existingFile.writtenBytes)
                }
            }
        }

        merged.status = existingJob.status == .failed ? .failed : .queued
        merged.updatedAt = Date()
        return merged
    }

    private func failJob(modelID: String, error: Error) {
        guard var job = jobsByProfileID[modelID] else { return }
        let message = error.localizedDescription
        job.status = .failed
        job.lastErrorMessage = message
        job.updatedAt = Date()
        for index in job.files.indices where job.files[index].status != .completed {
            job.files[index].status = .failed
            job.files[index].lastErrorMessage = message
        }
        jobsByProfileID[modelID] = job
        savePersistedJobs()
    }

    private func markQueuedAfterCancellation(modelID: String) {
        guard var job = jobsByProfileID[modelID] else { return }
        for index in job.files.indices where job.files[index].status == .downloading || job.files[index].status == .queued {
            job.files[index].status = .pending
            job.files[index].writtenBytes = 0
        }
        job.status = .queued
        job.updatedAt = Date()
        jobsByProfileID[modelID] = job
        savePersistedJobs()
    }

    private func checkAvailableDiskSpace(for job: ModelDownloadJob) throws {
        let totalExpected = totalBytesExpected(for: job) ?? 0
        guard totalExpected > 0 else { return }

        let alreadyWritten = totalBytesWritten(for: job)
        let remaining = max(totalExpected - alreadyWritten, 0)
        let required = Int64(Double(remaining) * Self.minimumFreeSpaceMultiplier)
        let available = try availableDiskSpace()
        guard available > required else {
            throw ManagedModelDownloadError.insufficientStorage(requiredBytes: required, availableBytes: available)
        }
    }

    private func emitProgress(for job: ModelDownloadJob, progressHandler: ProgressHandler) {
        if let totalExpected = totalBytesExpected(for: job), totalExpected > 0 {
            Self.emitProgress(
                completedBytes: totalBytesWritten(for: job),
                totalBytes: totalExpected,
                isFinal: false,
                progressHandler: progressHandler
            )
            return
        }

        let totalFiles = max(Int64(job.files.count), 1)
        Self.emitProgress(
            completedBytes: Int64(job.files.filter { $0.status == .completed }.count),
            totalBytes: totalFiles,
            isFinal: false,
            progressHandler: progressHandler
        )
    }

    private func totalBytesExpected(for job: ModelDownloadJob) -> Int64? {
        let values = job.files.compactMap(\.expectedBytes)
        guard values.count == job.files.count else { return nil }
        return values.reduce(0, +)
    }

    private func totalBytesWritten(for job: ModelDownloadJob, excluding relativePath: String? = nil) -> Int64 {
        job.files.reduce(Int64(0)) { partial, file in
            guard file.relativePath != relativePath else { return partial }
            return partial + min(file.writtenBytes, file.expectedBytes ?? file.writtenBytes)
        }
    }

    private func remoteFileURL(for modelIdentifier: String, revision: String, relativePath: String) -> URL {
        hostURL
            .appending(path: modelIdentifier)
            .appending(path: "resolve")
            .appending(component: revision)
            .appending(path: relativePath)
    }

    private func fileSizeIfExists(at url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func isCompleteFile(existingBytes: Int64, expectedBytes: Int64?) -> Bool {
        guard existingBytes > 0 else { return false }
        guard let expectedBytes, expectedBytes > 0 else { return true }
        return existingBytes >= expectedBytes
    }

    private func availableDiskSpace() throws -> Int64 {
        let attributes = try fileManager.attributesOfFileSystem(forPath: repositoriesDirectory.path)
        guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return freeSize.int64Value
    }

    private func savePersistedJobs() {
        let manifest = ModelDownloadJobsManifest(jobs: jobsByProfileID.values.sorted { $0.createdAt < $1.createdAt })
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: jobsFileURL, options: [.atomic])
        }
    }

    private static func loadPersistedJobs(from jobsFileURL: URL) -> [String: ModelDownloadJob] {
        guard let data = try? Data(contentsOf: jobsFileURL),
            let manifest = try? JSONDecoder().decode(ModelDownloadJobsManifest.self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: manifest.jobs.map { ($0.id, $0) })
    }

    private static func cleanupStagingDirectory(fileManager: FileManager, stagingDirectory: URL) {
        let entries = (try? fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func effectiveGlobs(_ requestedGlobs: [String]) -> [String] {
        Array(Set(requestedGlobs + defaultModelFileGlobs)).sorted()
    }

    private static func emitProgress(
        completedBytes: Int64,
        totalBytes: Int64?,
        isFinal: Bool,
        progressHandler: ProgressHandler
    ) {
        let fraction: Double?
        let message: String

        if isFinal {
            fraction = 1
            message = "Download complete"
        } else if let totalBytes, totalBytes > 0 {
            let rawFraction = Double(max(completedBytes, 0)) / Double(totalBytes)
            let clampedFraction = min(max(rawFraction, 0), 0.999)
            fraction = clampedFraction
            let percent = DownloadProgressUpdate.percentText(for: clampedFraction)
            if totalBytes > 1_000_000 {
                let boundedCompleted = min(max(completedBytes, 0), totalBytes)
                let completedText = ByteCountFormatter.localTutorMemoryString(fromByteCount: boundedCompleted)
                let totalText = ByteCountFormatter.localTutorMemoryString(fromByteCount: totalBytes)
                message = clampedFraction >= 0.999
                    ? "Finalizing downloaded files"
                    : "Downloading \(percent) · \(completedText) of \(totalText)"
            } else {
                message = clampedFraction >= 0.999 ? "Finalizing downloaded files" : "Downloading \(percent)"
            }
        } else {
            fraction = nil
            message = "Downloading model files"
        }

        progressHandler(DownloadProgressUpdate(fraction: fraction, message: message))
    }

    private static func emitHeartbeatProgress(
        for session: URLSession,
        temporaryBaseline: [String: Int64],
        fileManager: FileManager,
        reportProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: progressHeartbeatNanoseconds)
            } catch {
                return
            }

            let taskProgress = await activeTaskProgress(for: session)
            let temporaryBytes = activeTemporaryDownloadBytes(
                excluding: Set(temporaryBaseline.keys),
                fileManager: fileManager
            )
            let writtenBytes = max(taskProgress.writtenBytes, temporaryBytes)
            guard writtenBytes > 0 else { continue }
            reportProgress(writtenBytes, taskProgress.expectedBytes)
        }
    }

    private static func activeTaskProgress(for session: URLSession) async -> (writtenBytes: Int64, expectedBytes: Int64) {
        let tasks = await allTasks(for: session)
        return tasks.reduce((writtenBytes: Int64(0), expectedBytes: Int64(0))) { partial, task in
            (
                writtenBytes: max(partial.writtenBytes, task.countOfBytesReceived),
                expectedBytes: max(partial.expectedBytes, task.countOfBytesExpectedToReceive)
            )
        }
    }

    private static func allTasks(for session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private static func activeTemporaryDownloadBytes(
        excluding ignoredFiles: Set<String>,
        fileManager: FileManager
    ) -> Int64 {
        temporaryDownloadFiles(fileManager: fileManager)
            .filter { !ignoredFiles.contains($0.key) }
            .values
            .max() ?? 0
    }

    private static func temporaryDownloadFiles(fileManager: FileManager) -> [String: Int64] {
        let directory = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        return contents.reduce(into: [String: Int64]()) { partial, url in
            guard url.lastPathComponent.hasPrefix("CFNetworkDownload_"),
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                resourceValues.isRegularFile == true
            else {
                return
            }
            partial[url.lastPathComponent] = Int64(resourceValues.fileSize ?? 0)
        }
    }

    static func fileProgressEstimate(
        totalBytesWritten: Int64,
        delegateExpectedBytes: Int64,
        expectedFileBytes: Int64?
    ) -> (writtenBytes: Int64, expectedBytes: Int64?) {
        let expectedValues = [delegateExpectedBytes > 0 ? delegateExpectedBytes : nil, expectedFileBytes]
            .compactMap(\.self)
            .filter { $0 > 0 }
        let expectedBytes = expectedValues.max()
        let writtenBytes = max(0, totalBytesWritten)
        if let expectedBytes {
            return (min(writtenBytes, expectedBytes), expectedBytes)
        }
        return (writtenBytes, nil)
    }
}

enum ManagedModelStore {
    static func repositoryDirectory(
        for modelIdentifier: String,
        repositoriesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let root = repositoriesDirectory
            ?? (try? AppDirectories.managedModelRepositories(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("LocalTutorModelRepositories", isDirectory: true)
        return root.appendingPathComponent(repositoryDirectoryName(for: modelIdentifier), isDirectory: true)
    }

    static func repositoryDirectoryName(for modelIdentifier: String) -> String {
        "models--" + modelIdentifier.replacingOccurrences(of: "/", with: "--")
    }

    static func isUsableModelDirectory(
        _ directory: URL,
        for profile: ModelProfile,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }

        let configURL = directory.appendingPathComponent("config.json", isDirectory: false)
        guard let configData = try? Data(contentsOf: configURL), !configData.isEmpty,
            let configObject = try? JSONSerialization.jsonObject(with: configData),
            let config = configObject as? [String: Any]
        else {
            return false
        }

        let expectedWeights = expectedSafetensorsFilenames(in: directory, fileManager: fileManager)
        if expectedWeights.isEmpty {
            guard containsFile(withExtension: "safetensors", in: directory, fileManager: fileManager) else {
                return false
            }
        } else {
            guard expectedWeights.allSatisfy({
                let weightURL = directory.appendingPathComponent($0, isDirectory: false)
                return fileManager.fileExists(atPath: weightURL.path) && fileSize(at: weightURL) > 0
            }) else {
                return false
            }
        }

        guard hasTokenizerFiles(in: directory, fileManager: fileManager) else {
            return false
        }

        if profile.supportsVision {
            guard config["vision_config"] != nil || config["vision_config_dict"] != nil else {
                return false
            }
            let hasProcessor = fileManager.fileExists(
                atPath: directory.appendingPathComponent("processor_config.json").path
            )
            let hasPreprocessor = fileManager.fileExists(
                atPath: directory.appendingPathComponent("preprocessor_config.json").path
            )
            guard hasProcessor || hasPreprocessor else {
                return false
            }
        }

        return true
    }

    static func removePersistedJob(
        for profileID: String,
        jobsFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let url = jobsFileURL
            ?? (try? AppDirectories.modelDownloadJobsFile(fileManager: fileManager))
            ?? fileManager.temporaryDirectory.appendingPathComponent("localtutor-model-download-jobs.json")
        guard let data = try? Data(contentsOf: url),
            var manifest = try? JSONDecoder().decode(ModelDownloadJobsManifest.self, from: data)
        else {
            return
        }
        manifest.jobs.removeAll { $0.id == profileID }
        if let encoded = try? JSONEncoder().encode(manifest) {
            try? encoded.write(to: url, options: [.atomic])
        }
    }

    static func matchesAnyGlob(_ value: String, globs: [String]) -> Bool {
        globs.contains { glob in
            let escaped = NSRegularExpression.escapedPattern(for: glob)
            let pattern = "^" + escaped
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".") + "$"
            return value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func containsFile(
        withExtension pathExtension: String,
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            return true
        }
        return false
    }

    private static func expectedSafetensorsFilenames(in directory: URL, fileManager: FileManager) -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var filenames: Set<String> = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".safetensors.index.json") {
            guard let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                let weightMap = dictionary["weight_map"] as? [String: String]
            else {
                continue
            }
            filenames.formUnion(weightMap.values)
        }
        return filenames
    }

    private static func hasTokenizerFiles(in directory: URL, fileManager: FileManager) -> Bool {
        let acceptedFilenames = [
            "tokenizer.json",
            "tokenizer.model",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt"
        ]
        return acceptedFilenames.contains { filename in
            fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private struct HuggingFaceRepositoryResponse: Decodable, Sendable {
    let siblings: [Sibling]

    struct Sibling: Decodable, Sendable {
        let rfilename: String
    }
}

private final class ModelFileDownloadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let stagedFileURL: URL
    private let lock = NSLock()
    private var completion: ((Result<URLResponse, Error>) -> Void)?
    private var dataTask: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: URLResponse?
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    private var hasCompleted = false

    init(stagedFileURL: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        self.stagedFileURL = stagedFileURL
        self.onProgress = onProgress
        self.fileHandle = try FileHandle(forWritingTo: stagedFileURL)
    }

    func download(request: URLRequest, session: URLSession) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                dataTask = task
                completion = { result in
                    continuation.resume(with: result)
                }
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        if response.expectedContentLength > 0 {
            expectedBytes = response.expectedContentLength
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let writtenBytes: Int64
        let totalExpectedBytes: Int64
        do {
            lock.lock()
            try fileHandle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            writtenBytes = receivedBytes
            totalExpectedBytes = max(expectedBytes, dataTask.countOfBytesExpectedToReceive)
            lock.unlock()
        } catch {
            lock.unlock()
            dataTask.cancel()
            complete(.failure(error))
            return
        }

        onProgress(writtenBytes, totalExpectedBytes)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
            return
        }

        lock.lock()
        let response = response ?? task.response
        lock.unlock()

        guard let response else {
            complete(.failure(ManagedModelDownloadError.badResponse(stagedFileURL.lastPathComponent)))
            return
        }
        complete(.success(response))
    }

    private func cancel() {
        lock.lock()
        let task = dataTask
        lock.unlock()
        task?.cancel()
    }

    private func complete(_ result: Result<URLResponse, Error>) {
        let completion: ((Result<URLResponse, Error>) -> Void)?
        lock.lock()
        if hasCompleted {
            lock.unlock()
            return
        }
        hasCompleted = true
        completion = self.completion
        self.completion = nil
        dataTask = nil
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()

        completion?(result)
    }
}
