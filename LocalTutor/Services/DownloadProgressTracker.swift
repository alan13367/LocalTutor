//
//  DownloadProgressTracker.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation

final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var firstProgressDate: Date?
    private var latestProgressDate: Date?
    private var latestFraction: Double = 0

    func update(_ progress: Progress) -> (fraction: Double, description: String) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if firstProgressDate == nil {
            firstProgressDate = now
        }
        latestProgressDate = now
        latestFraction = max(0, min(1, progress.fractionCompleted))

        return (
            latestFraction,
            progress.localizedDescription.isEmpty
                ? "\(Int(latestFraction * 100))%"
                : progress.localizedDescription
        )
    }

    var downloadSeconds: Double {
        lock.lock()
        defer { lock.unlock() }

        guard let firstProgressDate, let latestProgressDate else {
            return 0
        }
        return latestProgressDate.timeIntervalSince(firstProgressDate)
    }
}
