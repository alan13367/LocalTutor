//
//  ModelCacheStore.swift
//  LocalTutor
//

import Foundation
import HuggingFace

struct ModelCacheInfo: Equatable, Sendable {
    var byteCount: Int64
    var hasRepositoryFiles: Bool
    var hasMetadataFiles: Bool
    var hasLockFiles: Bool
    var hasManagedFiles: Bool

    var isCached: Bool {
        hasRepositoryFiles || hasMetadataFiles || hasLockFiles || hasManagedFiles
    }

    var sizeDescription: String {
        guard byteCount > 0 else {
            return "No local files"
        }
        return ByteCountFormatter.localTutorMemoryString(fromByteCount: byteCount)
    }

    static let empty = ModelCacheInfo(
        byteCount: 0,
        hasRepositoryFiles: false,
        hasMetadataFiles: false,
        hasLockFiles: false,
        hasManagedFiles: false
    )
}

struct ModelCacheRemovalResult: Equatable, Sendable {
    var removedByteCount: Int64

    var sizeDescription: String {
        guard removedByteCount > 0 else {
            return "local files"
        }
        return ByteCountFormatter.localTutorMemoryString(fromByteCount: removedByteCount)
    }
}

enum ModelCacheStoreError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            "Invalid Hugging Face repository id: \(id)."
        }
    }
}

enum ModelCacheStore {
    static func cacheInfo(
        for profile: ModelProfile,
        cacheDirectory: URL? = nil,
        managedRepositoriesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ModelCacheInfo {
        let locations = try cacheLocations(
            for: profile.modelIdentifier,
            cacheDirectory: cacheDirectory,
            fileManager: fileManager
        )
        let managedRepository = ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory,
            fileManager: fileManager
        )
        let repositoryByteCount = try byteCount(at: locations.repository, fileManager: fileManager)
        let metadataByteCount = try byteCount(at: locations.metadata, fileManager: fileManager)
        let lockByteCount = try byteCount(at: locations.locks, fileManager: fileManager)
        let managedByteCount = try byteCount(at: managedRepository, fileManager: fileManager)

        return ModelCacheInfo(
            byteCount: repositoryByteCount + metadataByteCount + lockByteCount + managedByteCount,
            hasRepositoryFiles: fileManager.fileExists(atPath: locations.repository.path),
            hasMetadataFiles: fileManager.fileExists(atPath: locations.metadata.path),
            hasLockFiles: fileManager.fileExists(atPath: locations.locks.path),
            hasManagedFiles: fileManager.fileExists(atPath: managedRepository.path)
        )
    }

    static func cacheInfoByProfileID(
        for profiles: [ModelProfile] = ModelProfile.studyCatalog,
        cacheDirectory: URL? = nil,
        managedRepositoriesDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String: ModelCacheInfo] {
        var result: [String: ModelCacheInfo] = [:]
        for profile in profiles {
            result[profile.id] = (try? cacheInfo(
                for: profile,
                cacheDirectory: cacheDirectory,
                managedRepositoriesDirectory: managedRepositoriesDirectory,
                fileManager: fileManager
            )) ?? .empty
        }
        return result
    }

    @discardableResult
    static func removeCachedModel(
        for profile: ModelProfile,
        cacheDirectory: URL? = nil,
        managedRepositoriesDirectory: URL? = nil,
        jobsFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ModelCacheRemovalResult {
        let locations = try cacheLocations(
            for: profile.modelIdentifier,
            cacheDirectory: cacheDirectory,
            fileManager: fileManager
        )
        let managedRepository = ManagedModelStore.repositoryDirectory(
            for: profile.modelIdentifier,
            repositoriesDirectory: managedRepositoriesDirectory,
            fileManager: fileManager
        )
        let removedByteCount = try [locations.repository, locations.metadata, locations.locks, managedRepository]
            .reduce(Int64(0)) { partial, url in
                partial + (try byteCount(at: url, fileManager: fileManager))
            }

        for url in [locations.repository, locations.metadata, locations.locks, managedRepository]
            where fileManager.fileExists(atPath: url.path)
        {
            try fileManager.removeItem(at: url)
        }
        ManagedModelStore.removePersistedJob(for: profile.id, jobsFileURL: jobsFileURL, fileManager: fileManager)

        return ModelCacheRemovalResult(removedByteCount: removedByteCount)
    }

    static func cacheLocations(
        for modelIdentifier: String,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> (repository: URL, metadata: URL, locks: URL) {
        guard let repositoryID = Repo.ID(rawValue: modelIdentifier) else {
            throw ModelCacheStoreError.invalidRepositoryID(modelIdentifier)
        }

        let root = try cacheDirectory ?? AppDirectories.huggingFaceCache(fileManager: fileManager)
        let cache = HubCache(cacheDirectory: root)
        let repository = cache.repoDirectory(repo: repositoryID, kind: .model)

        return (
            repository: repository,
            metadata: cache.metadataDirectory(repo: repositoryID, kind: .model),
            locks: cache.lockPath(for: repository)
        )
    }

    private static func byteCount(at url: URL, fileManager: FileManager) throws -> Int64 {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return try fileByteCount(at: url)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey
            ])
            guard values.isDirectory != true, values.isSymbolicLink != true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}
