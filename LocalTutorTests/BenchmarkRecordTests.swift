//
//  BenchmarkRecordTests.swift
//  LocalTutorTests
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import Testing
@testable import LocalTutor

struct BenchmarkRecordTests {
    @Test
    func benchmarkRecordRoundTripsAsSchemaVersionOne() throws {
        let profile = InferenceProfile.gemma4E2B
        let record = BenchmarkRecord.skipped(
            profile: profile,
            prompt: "Explain subnet masks.",
            imageFilename: nil,
            reason: "Unit test"
        )

        let data = try JSONEncoder.localTutorBenchmark.encode(record)
        let decoded = try JSONDecoder.localTutorBenchmark.decode(BenchmarkRecord.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.profileID == profile.id)
        #expect(decoded.modelID == profile.modelIdentifier)
        #expect(decoded.status == .skipped)
        #expect(decoded.prompt == "Explain subnet masks.")
    }
}
