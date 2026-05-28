//
//  InferenceProfileTests.swift
//  LocalTutorTests
//
//

import Testing
@testable import LocalTutor

struct InferenceProfileTests {
    @Test
    func v0CatalogContainsGemma4BaseProfiles() {
        let profiles = InferenceProfile.v0Catalog

        #expect(profiles.map(\.id) == ["gemma4E2B", "gemma4E4B"])
        #expect(profiles.allSatisfy { $0.kind == .vision })
        #expect(profiles.map(\.modelIdentifier) == [
            "mlx-community/gemma-4-e2b-it-4bit",
            "mlx-community/gemma-4-e4b-it-4bit"
        ])
        #expect(profiles.map(\.minimumSystemMemoryBytes) == [
            8.gibibytes,
            16.gibibytes
        ])
    }

    @Test
    func studyCatalogContainsOnlyReliableStructuredOutputProfiles() {
        let profiles = InferenceProfile.studyCatalog

        #expect(profiles.map(\.id) == ["gemma4E2B", "gemma4E4B", "qwen3VL4B"])
    }
}
