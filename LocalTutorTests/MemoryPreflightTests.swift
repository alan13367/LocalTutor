//
//  MemoryPreflightTests.swift
//  LocalTutorTests
//
//

import Testing
@testable import LocalTutor

struct MemoryPreflightTests {
    @Test
    func preflightPassesWhenSystemMemoryMeetsProfileRequirement() {
        let profile = InferenceProfile.gemma4E2B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            systemMemoryBytes: profile.minimumSystemMemoryBytes
        )

        #expect(result.canRun)
        #expect(result.message.contains("System memory"))
    }

    @Test
    func preflightSkipsWhenSystemMemoryIsBelowProfileRequirement() {
        let profile = InferenceProfile.gemma4E4B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            systemMemoryBytes: profile.minimumSystemMemoryBytes - 1
        )

        #expect(!result.canRun)
        #expect(result.message.contains("Not enough system memory"))
    }
}
