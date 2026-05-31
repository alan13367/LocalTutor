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
        let profile = ModelProfile.gemma4E2B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            systemMemoryBytes: profile.minimumSystemMemoryBytes
        )

        #expect(result.canRun)
        #expect(result.message.contains("System memory"))
    }

    @Test
    func preflightSkipsWhenSystemMemoryIsBelowProfileRequirement() {
        let profile = ModelProfile.gemma4E4B
        let result = MemoryPreflight.evaluate(
            profile: profile,
            systemMemoryBytes: profile.minimumSystemMemoryBytes - 1
        )

        #expect(!result.canRun)
        #expect(result.message.contains("Not enough system memory"))
    }

    @Test
    func policyPreflightMatchesProfilePreflight() {
        let profile = ModelProfile.gemma4E4B
        let memory = profile.minimumSystemMemoryBytes
        let policy = ModelRuntimePolicyProvider.policy(for: profile, systemMemoryBytes: memory)

        let profileResult = MemoryPreflight.evaluate(profile: profile, systemMemoryBytes: memory)
        let policyResult = MemoryPreflight.evaluate(policy: policy)

        #expect(profileResult == policyResult)
    }
}
