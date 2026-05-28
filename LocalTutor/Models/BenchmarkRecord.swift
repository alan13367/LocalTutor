//
//  BenchmarkRecord.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum BenchmarkStatus: String, Codable, CaseIterable {
    case success
    case cancelled
    case failed
    case skipped
}

struct DeviceSnapshot: Codable, Equatable, Sendable {
    var macOSVersion: String
    var architecture: String
    var physicalMemoryBytes: UInt64

    static var current: DeviceSnapshot {
        DeviceSnapshot(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: SystemInfo.architecture,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}

struct MLXMemorySnapshotRecord: Codable, Equatable, Sendable {
    var activeBytes: UInt64
    var cacheBytes: UInt64
    var peakBytes: UInt64
}

struct BenchmarkTiming: Codable, Equatable, Sendable {
    var downloadSeconds: Double
    var loadSeconds: Double
    var firstTokenSeconds: Double?
    var wallSeconds: Double
}

struct BenchmarkTokenMetrics: Codable, Equatable, Sendable {
    var promptTokens: Int?
    var generatedTokens: Int?
    var promptTimeSeconds: Double?
    var generationTimeSeconds: Double?
    var tokensPerSecond: Double?
    var stopReason: String?
}

struct BenchmarkRecord: Codable, Identifiable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var appVersion: String
    var device: DeviceSnapshot
    var profileID: String
    var profileName: String
    var modelID: String
    var kind: String
    var tier: String
    var prompt: String
    var imageFilename: String?
    var timing: BenchmarkTiming
    var tokenMetrics: BenchmarkTokenMetrics
    var mlxMemoryBefore: MLXMemorySnapshotRecord?
    var mlxMemoryAfter: MLXMemorySnapshotRecord?
    var processPeakPhysicalFootprintBytes: UInt64?
    var status: BenchmarkStatus
    var errorMessage: String?
    var output: String

    static func skipped(profile: InferenceProfile, prompt: String, imageFilename: String?, reason: String) -> BenchmarkRecord {
        let now = Date()
        return BenchmarkRecord(
            schemaVersion: schemaVersion,
            id: UUID(),
            startedAt: now,
            endedAt: now,
            appVersion: AppInfo.version,
            device: .current,
            profileID: profile.id,
            profileName: profile.name,
            modelID: profile.modelIdentifier,
            kind: profile.kind.rawValue,
            tier: profile.tier.rawValue,
            prompt: prompt,
            imageFilename: imageFilename,
            timing: BenchmarkTiming(downloadSeconds: 0, loadSeconds: 0, firstTokenSeconds: nil, wallSeconds: 0),
            tokenMetrics: BenchmarkTokenMetrics(
                promptTokens: nil,
                generatedTokens: nil,
                promptTimeSeconds: nil,
                generationTimeSeconds: nil,
                tokensPerSecond: nil,
                stopReason: nil
            ),
            mlxMemoryBefore: nil,
            mlxMemoryAfter: nil,
            processPeakPhysicalFootprintBytes: nil,
            status: .skipped,
            errorMessage: reason,
            output: ""
        )
    }
}

struct BenchmarkExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(record: BenchmarkRecord) {
        data = (try? JSONEncoder.localTutorBenchmark.encode(record)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
