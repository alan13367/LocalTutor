//
//  LocalModelRunnerTests.swift
//  LocalTutorTests
//
//  Created by Codex on 28/05/2026.
//

import Testing
@testable import LocalTutor

struct LocalModelRunnerTests {
    @Test
    func runnerRefusesConcurrentRuns() async {
        let runner = LocalModelRunner()
        await runner.setRunningForTesting(true)

        do {
            _ = try await runner.run(
                profile: .gemma4E2B,
                prompt: "Hello",
                imageURL: nil,
                events: { _ in }
            )
            Issue.record("Expected busy error")
        } catch let error as LocalModelRunnerError {
            #expect(error.localizedDescription == LocalModelRunnerError.busy.localizedDescription)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
