//
//  AppDirectories.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation

enum AppDirectories {
    static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("LocalTutor", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func huggingFaceCache(fileManager: FileManager = .default) throws -> URL {
        let cache = try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("HuggingFaceHub", isDirectory: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }

    static func clearHuggingFaceCache(fileManager: FileManager = .default) throws {
        let cache = try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("HuggingFaceHub", isDirectory: true)
        if fileManager.fileExists(atPath: cache.path) {
            try fileManager.removeItem(at: cache)
        }
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    static func benchmarks(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Benchmarks", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
