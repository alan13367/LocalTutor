//
//  BenchmarkStore.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation

actor BenchmarkStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func save(_ record: BenchmarkRecord) throws -> URL {
        let directory = try benchmarksDirectory()
        let timestamp = DateFormatter.localTutorBenchmarkFilename(from: record.startedAt)
        let filename = "\(timestamp)-\(record.profileID)-\(record.id.uuidString.prefix(8)).json"
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder.localTutorBenchmark.encode(record)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func benchmarksDirectory() throws -> URL {
        try AppDirectories.benchmarks(fileManager: fileManager)
    }
}
