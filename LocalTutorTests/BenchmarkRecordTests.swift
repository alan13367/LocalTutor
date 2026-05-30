//
//  BenchmarkRecordTests.swift
//  LocalTutorTests
//
//

import Foundation
import Testing
@testable import LocalTutor

struct BenchmarkRecordTests {
    @Test
    func benchmarkRecordRoundTripsAsSchemaVersionTwo() throws {
        let profile = InferenceProfile.gemma4E2B
        let record = BenchmarkRecord.skipped(
            profile: profile,
            prompt: "Explain subnet masks.",
            imageFilename: nil,
            reason: "Unit test"
        )

        let data = try JSONEncoder.localTutorBenchmark.encode(record)
        let decoded = try JSONDecoder.localTutorBenchmark.decode(BenchmarkRecord.self, from: data)

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.profileID == profile.id)
        #expect(decoded.modelID == profile.modelIdentifier)
        #expect(decoded.status == .skipped)
        #expect(decoded.prompt == "Explain subnet masks.")
        #expect(decoded.imageFilenames.isEmpty)
    }

    @Test
    func benchmarkRecordDecodesLegacyImageFilename() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(UUID().uuidString)",
          "startedAt": "2026-05-28T12:00:00Z",
          "endedAt": "2026-05-28T12:00:01Z",
          "appVersion": "1.0",
          "device": {
            "macOSVersion": "Version 26.5",
            "architecture": "arm64",
            "physicalMemoryBytes": 8589934592
          },
          "profileID": "gemma4E2B",
          "profileName": "Gemma 4 E2B",
          "modelID": "mlx-community/gemma-4-e2b-it-4bit",
          "kind": "vision",
          "tier": "eightGB",
          "prompt": "Explain this.",
          "imageFilename": "figure.png",
          "timing": {
            "downloadSeconds": 0,
            "loadSeconds": 0,
            "wallSeconds": 1
          },
          "tokenMetrics": {},
          "status": "success",
          "output": "Done"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.localTutorBenchmark.decode(BenchmarkRecord.self, from: json)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.imageFilename == "figure.png")
        #expect(decoded.imageFilenames == ["figure.png"])
        #expect(decoded.includedImageCount == 1)
    }
}
