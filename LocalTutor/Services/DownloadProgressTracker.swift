//
//  DownloadProgressTracker.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation

struct DownloadProgressUpdate: Equatable, Sendable {
    var fraction: Double?
    var message: String
}

final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var firstProgressDate: Date?
    private var latestProgressDate: Date?
    private var latestFraction: Double?

    func start(message: String) -> DownloadProgressUpdate {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if firstProgressDate == nil {
            firstProgressDate = now
        }
        latestProgressDate = now

        return DownloadProgressUpdate(fraction: nil, message: message)
    }

    func update(_ progress: Progress) -> DownloadProgressUpdate {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if firstProgressDate == nil {
            firstProgressDate = now
        }
        latestProgressDate = now

        let fraction = determinateFraction(for: progress)
        if let fraction {
            latestFraction = max(latestFraction ?? 0, fraction)
        }

        let stableFraction = latestFraction
        return DownloadProgressUpdate(
            fraction: stableFraction,
            message: message(for: progress, fraction: stableFraction)
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

    private func determinateFraction(for progress: Progress) -> Double? {
        guard progress.totalUnitCount > 0 else {
            let fraction = progress.fractionCompleted
            return fraction.isFinite ? max(0, min(1, fraction)) : nil
        }

        let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
        return max(0, min(1, fraction))
    }

    private func message(for progress: Progress, fraction: Double?) -> String {
        guard let fraction else {
            return "Downloading model files"
        }

        if fraction >= 1 {
            return "Download complete"
        }

        let percent = Int((fraction * 100).rounded(.down))
        if progress.totalUnitCount > 1_000_000 {
            let completed = min(max(progress.completedUnitCount, 0), progress.totalUnitCount)
            let completedText = ByteCountFormatter.localTutorMemoryString(fromByteCount: completed)
            let totalText = ByteCountFormatter.localTutorMemoryString(fromByteCount: progress.totalUnitCount)
            return "Downloading \(percent)% · \(completedText) of \(totalText)"
        }

        return "Downloading \(percent)%"
    }
}
