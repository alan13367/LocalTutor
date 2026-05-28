//
//  MemoryPreflightTests.swift
//  LocalTutorTests
//
//  Created by Codex on 28/05/2026.
//

import Testing
@testable import LocalTutor

struct MemoryPreflightTests {
    @Test
    func preflightPassesWhenAvailableMemoryMeetsProfileRequirement() {
        let profile = InferenceProfile.gemma4E2B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            availableBytes: profile.minimumAvailableMemoryBytes
        )

        #expect(result.canRun)
    }

    @Test
    func preflightSkipsWhenAvailableMemoryIsBelowProfileRequirement() {
        let profile = InferenceProfile.gemma4E4B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            availableBytes: profile.minimumAvailableMemoryBytes - 1
        )

        #expect(!result.canRun)
        #expect(result.message.contains("Not enough memory"))
    }
}
