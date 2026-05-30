//
//  DownloadProgressTracker.swift
//  LocalTutor
//
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
    private var hasReportedDownload = false

    func update(_ progress: Progress) -> DownloadProgressUpdate? {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let fraction = determinateFraction(for: progress)

        if !hasReportedDownload {
            if let fraction, fraction <= 0 || fraction >= 1 {
                return nil
            }

            hasReportedDownload = true
            firstProgressDate = now
        }

        latestProgressDate = now

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
        let progressFraction = progress.fractionCompleted
        if progressFraction.isFinite, progressFraction > 0, progressFraction < 1 {
            return max(0, min(1, progressFraction))
        }

        guard progress.totalUnitCount > 0 else {
            if progressFraction.isFinite, progressFraction >= 1 {
                return 1
            }
            return nil
        }

        let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
        return fraction.isFinite ? max(0, min(1, fraction)) : nil
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
            let completedUnits = progress.completedUnitCount > 0
                ? Double(progress.completedUnitCount)
                : Double(progress.totalUnitCount) * fraction
            let completed = min(max(Int64(completedUnits), 0), progress.totalUnitCount)
            let completedText = ByteCountFormatter.localTutorMemoryString(fromByteCount: completed)
            let totalText = ByteCountFormatter.localTutorMemoryString(fromByteCount: progress.totalUnitCount)
            return "Downloading \(percent)% · \(completedText) of \(totalText)"
        }

        return "Downloading \(percent)%"
    }
}
