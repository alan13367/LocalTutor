//
//  LocalModelRunnerTests.swift
//  LocalTutorTests
//
//

import Foundation
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

    @Test
    func downloadProgressTrackerSuppressesAlreadyCachedCompletion() {
        let tracker = DownloadProgressTracker()
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 100

        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerSuppressesCachedZeroThenCompletion() {
        let tracker = DownloadProgressTracker()
        let progress = Progress(totalUnitCount: 100)

        progress.completedUnitCount = 0
        #expect(tracker.update(progress) == nil)

        progress.completedUnitCount = 100
        #expect(tracker.update(progress) == nil)
        #expect(tracker.downloadSeconds == 0)
    }

    @Test
    func downloadProgressTrackerReportsRealWorkBeforeCompletion() {
        let tracker = DownloadProgressTracker()
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 20

        let update = tracker.update(progress)

        #expect(update?.fraction == 0.2)
        #expect(update?.message == "Downloading 20%")
    }
}
