//
//  BenchmarkRecord.swift
//  LocalTutor
//
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
    static let schemaVersion = 2

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
    var imageFilenames: [String]
    var includedImageCount: Int
    var omittedImageCount: Int
    var timing: BenchmarkTiming
    var tokenMetrics: BenchmarkTokenMetrics
    var mlxMemoryBefore: MLXMemorySnapshotRecord?
    var mlxMemoryAfter: MLXMemorySnapshotRecord?
    var processPeakPhysicalFootprintBytes: UInt64?
    var status: BenchmarkStatus
    var errorMessage: String?
    var output: String

    init(
        schemaVersion: Int,
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        appVersion: String,
        device: DeviceSnapshot,
        profileID: String,
        profileName: String,
        modelID: String,
        kind: String,
        tier: String,
        prompt: String,
        imageFilename: String?,
        imageFilenames: [String] = [],
        includedImageCount: Int = 0,
        omittedImageCount: Int = 0,
        timing: BenchmarkTiming,
        tokenMetrics: BenchmarkTokenMetrics,
        mlxMemoryBefore: MLXMemorySnapshotRecord?,
        mlxMemoryAfter: MLXMemorySnapshotRecord?,
        processPeakPhysicalFootprintBytes: UInt64?,
        status: BenchmarkStatus,
        errorMessage: String?,
        output: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appVersion = appVersion
        self.device = device
        self.profileID = profileID
        self.profileName = profileName
        self.modelID = modelID
        self.kind = kind
        self.tier = tier
        self.prompt = prompt
        self.imageFilename = imageFilename
        self.imageFilenames = imageFilenames.isEmpty ? imageFilename.map { [$0] } ?? [] : imageFilenames
        self.includedImageCount = includedImageCount
        self.omittedImageCount = omittedImageCount
        self.timing = timing
        self.tokenMetrics = tokenMetrics
        self.mlxMemoryBefore = mlxMemoryBefore
        self.mlxMemoryAfter = mlxMemoryAfter
        self.processPeakPhysicalFootprintBytes = processPeakPhysicalFootprintBytes
        self.status = status
        self.errorMessage = errorMessage
        self.output = output
    }

    static func skipped(profile: ModelProfile, prompt: String, imageFilename: String?, reason: String) -> BenchmarkRecord {
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
            imageFilenames: imageFilename.map { [$0] } ?? [],
            includedImageCount: 0,
            omittedImageCount: 0,
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case startedAt
        case endedAt
        case appVersion
        case device
        case profileID
        case profileName
        case modelID
        case kind
        case tier
        case prompt
        case imageFilename
        case imageFilenames
        case includedImageCount
        case omittedImageCount
        case timing
        case tokenMetrics
        case mlxMemoryBefore
        case mlxMemoryAfter
        case processPeakPhysicalFootprintBytes
        case status
        case errorMessage
        case output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        device = try container.decode(DeviceSnapshot.self, forKey: .device)
        profileID = try container.decode(String.self, forKey: .profileID)
        profileName = try container.decode(String.self, forKey: .profileName)
        modelID = try container.decode(String.self, forKey: .modelID)
        kind = try container.decode(String.self, forKey: .kind)
        tier = try container.decode(String.self, forKey: .tier)
        prompt = try container.decode(String.self, forKey: .prompt)
        imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        imageFilenames = try container.decodeIfPresent([String].self, forKey: .imageFilenames)
            ?? imageFilename.map { [$0] }
            ?? []
        includedImageCount = try container.decodeIfPresent(Int.self, forKey: .includedImageCount)
            ?? imageFilenames.count
        omittedImageCount = try container.decodeIfPresent(Int.self, forKey: .omittedImageCount) ?? 0
        timing = try container.decode(BenchmarkTiming.self, forKey: .timing)
        tokenMetrics = try container.decode(BenchmarkTokenMetrics.self, forKey: .tokenMetrics)
        mlxMemoryBefore = try container.decodeIfPresent(MLXMemorySnapshotRecord.self, forKey: .mlxMemoryBefore)
        mlxMemoryAfter = try container.decodeIfPresent(MLXMemorySnapshotRecord.self, forKey: .mlxMemoryAfter)
        processPeakPhysicalFootprintBytes = try container.decodeIfPresent(UInt64.self, forKey: .processPeakPhysicalFootprintBytes)
        status = try container.decode(BenchmarkStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        output = try container.decode(String.self, forKey: .output)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(device, forKey: .device)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(profileName, forKey: .profileName)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(kind, forKey: .kind)
        try container.encode(tier, forKey: .tier)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(imageFilename, forKey: .imageFilename)
        try container.encode(imageFilenames, forKey: .imageFilenames)
        try container.encode(includedImageCount, forKey: .includedImageCount)
        try container.encode(omittedImageCount, forKey: .omittedImageCount)
        try container.encode(timing, forKey: .timing)
        try container.encode(tokenMetrics, forKey: .tokenMetrics)
        try container.encodeIfPresent(mlxMemoryBefore, forKey: .mlxMemoryBefore)
        try container.encodeIfPresent(mlxMemoryAfter, forKey: .mlxMemoryAfter)
        try container.encodeIfPresent(processPeakPhysicalFootprintBytes, forKey: .processPeakPhysicalFootprintBytes)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(output, forKey: .output)
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
