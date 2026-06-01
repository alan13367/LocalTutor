//
//  DownloadProgressTracker.swift
//  LocalTutor
//
//

import Foundation

struct DownloadProgressUpdate: Equatable, Sendable {
    var fraction: Double?
    var message: String

    static func percentText(for fraction: Double) -> String {
        let percent = max(0, min(100, fraction * 100))
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        if percent > 0, percent < 1 {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded(.down)))%"
    }
}

final class DownloadProgressTracker: @unchecked Sendable {
    private static let temporaryScanInterval: TimeInterval = 0.25

    private let lock = NSLock()
    private let fileManager: FileManager
    private let temporaryDirectory: URL?
    private let ignoredTemporaryDownloadFiles: Set<String>
    private var firstProgressDate: Date?
    private var latestProgressDate: Date?
    private var latestFraction: Double?
    private var phaseBaselineFraction: Double?
    private var temporaryBaselineCompletedUnits: Double?
    private var temporaryObservedBytesByFile: [String: Int64] = [:]
    private var latestTemporaryScanDate: Date?
    private var latestTemporaryFiles: [String: Int64] = [:]
    private var hasReportedDownload = false

    init(
        temporaryDirectory: URL? = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
        self.ignoredTemporaryDownloadFiles = Self.temporaryDownloadFiles(
            in: temporaryDirectory,
            fileManager: fileManager
        )
    }

    func update(_ progress: Progress) -> DownloadProgressUpdate? {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let rawFraction = determinateFraction(for: progress)
        let fraction = adjustedFraction(for: progress, rawFraction: rawFraction, now: now)

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

    private func adjustedFraction(for progress: Progress, rawFraction: Double?, now: Date) -> Double? {
        let rawCompletedUnits = completedUnits(for: progress, rawFraction: rawFraction)
        let phaseAdjustedFraction = temporaryObservedBytesByFile.isEmpty
            ? phaseAdjustedFraction(rawFraction)
            : rawFraction
        let temporaryAdjustedFraction = temporaryAdjustedFraction(
            for: progress,
            rawFraction: rawFraction,
            rawCompletedUnits: rawCompletedUnits,
            now: now
        )

        return [phaseAdjustedFraction, temporaryAdjustedFraction]
            .compactMap(\.self)
            .max()
    }

    private func completedUnits(for progress: Progress, rawFraction: Double?) -> Double? {
        guard progress.totalUnitCount > 0 else {
            return nil
        }

        if let rawFraction {
            return Double(progress.totalUnitCount) * rawFraction
        }

        if progress.completedUnitCount > 0 {
            return Double(progress.completedUnitCount)
        }

        return nil
    }

    private func phaseAdjustedFraction(_ rawFraction: Double?) -> Double? {
        guard let rawFraction else {
            return nil
        }

        guard let latestFraction else {
            return rawFraction
        }

        if let phaseBaselineFraction {
            if rawFraction >= 0.999 {
                self.phaseBaselineFraction = nil
                return 1
            }

            return clampedFraction(phaseBaselineFraction + rawFraction * (1 - phaseBaselineFraction))
        }

        if rawFraction + 0.0001 < latestFraction, latestFraction < 0.98 {
            phaseBaselineFraction = latestFraction
            return clampedFraction(latestFraction + rawFraction * (1 - latestFraction))
        }

        return rawFraction
    }

    private func temporaryAdjustedFraction(
        for progress: Progress,
        rawFraction: Double?,
        rawCompletedUnits: Double?,
        now: Date
    ) -> Double? {
        guard progress.totalUnitCount > 1_000_000 else {
            return nil
        }

        let temporaryFiles = activeTemporaryDownloadFiles(now: now)
        guard !temporaryFiles.isEmpty else {
            return nil
        }

        let totalUnits = Double(progress.totalUnitCount)
        let rawCompletedUnits = rawCompletedUnits ?? 0
        let latestStableUnits = (latestFraction ?? rawFraction ?? 0) * totalUnits
        if temporaryBaselineCompletedUnits == nil {
            temporaryBaselineCompletedUnits = max(latestStableUnits, rawCompletedUnits)
        }

        for (fileName, byteCount) in temporaryFiles {
            temporaryObservedBytesByFile[fileName] = max(temporaryObservedBytesByFile[fileName] ?? 0, byteCount)
        }

        let temporaryDownloadedUnits = Double(temporaryObservedBytesByFile.values.reduce(Int64(0), +))
        let estimatedCompletedUnits = (temporaryBaselineCompletedUnits ?? 0) + temporaryDownloadedUnits
        var completedUnits = max(rawCompletedUnits, estimatedCompletedUnits)
        if rawFraction ?? 0 < 1 {
            completedUnits = min(completedUnits, totalUnits * 0.999)
        }

        return clampedFraction(completedUnits / totalUnits)
    }

    private func activeTemporaryDownloadFiles(now: Date) -> [String: Int64] {
        guard let temporaryDirectory else {
            return [:]
        }

        if !latestTemporaryFiles.isEmpty,
            let latestTemporaryScanDate,
            now.timeIntervalSince(latestTemporaryScanDate) < Self.temporaryScanInterval
        {
            return latestTemporaryFiles
        }

        latestTemporaryScanDate = now

        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            latestTemporaryFiles = [:]
            return [:]
        }

        latestTemporaryFiles = contents.reduce(into: [String: Int64]()) { partial, url in
            guard Self.isTemporaryDownloadFile(url),
                !ignoredTemporaryDownloadFiles.contains(url.lastPathComponent),
                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                resourceValues.isRegularFile == true
            else {
                return
            }

            partial[url.lastPathComponent] = Int64(resourceValues.fileSize ?? 0)
        }
        return latestTemporaryFiles
    }

    private static func temporaryDownloadFiles(
        in directory: URL?,
        fileManager: FileManager
    ) -> Set<String> {
        guard let directory,
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return Set(contents.filter(isTemporaryDownloadFile).map(\.lastPathComponent))
    }

    private static func isTemporaryDownloadFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("CFNetworkDownload_")
    }

    private func clampedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else {
            return 0
        }
        return max(0, min(1, fraction))
    }

    private func message(for progress: Progress, fraction: Double?) -> String {
        guard let fraction else {
            return "Downloading model files"
        }

        if fraction >= 1 {
            return "Download complete"
        }

        let percent = DownloadProgressUpdate.percentText(for: fraction)
        if progress.totalUnitCount > 1_000_000 {
            let completedUnits = max(
                Double(progress.completedUnitCount),
                Double(progress.totalUnitCount) * fraction
            )
            let completed = min(max(Int64(completedUnits), 0), progress.totalUnitCount)
            let completedText = ByteCountFormatter.localTutorMemoryString(fromByteCount: completed)
            let totalText = ByteCountFormatter.localTutorMemoryString(fromByteCount: progress.totalUnitCount)
            return "Downloading \(percent) · \(completedText) of \(totalText)"
        }

        return "Downloading \(percent)"
    }
}
