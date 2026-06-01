//
//  LocalModelRunnerTests.swift
//  LocalTutorTests
//
//

import Foundation
import Testing
@testable import LocalTutor

struct LocalModelRunnerTests {
    @MainActor
    @Test
    func firstTurnSourcePreviewOnlyShowsForEmptySessionsWithSources() {
        let viewModel = StudyWorkspaceViewModel()
        let sessionID = viewModel.currentSessionID
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTutorPreviewTest.md")
        try? "Preview test notes".write(to: sourceURL, atomically: true, encoding: .utf8)
        let source = StudySource(url: sourceURL)

        viewModel.currentSession = StudySession(id: sessionID, sources: [], turns: [])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == false)

        viewModel.currentSession = StudySession(id: sessionID, sources: [source], turns: [])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == true)

        let user = StudyTurnUser(
            focus: "What should I study?",
            resourceKind: .ask,
            sources: [source],
            isRefinement: false
        )
        viewModel.currentSession = StudySession(id: sessionID, sources: [source], turns: [StudyTurn(user: user)])
        #expect(viewModel.shouldShowFirstTurnSourcePreview == false)
    }

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

    @Test
    func downloadProgressTrackerUsesChildProgressFraction() {
        let tracker = DownloadProgressTracker()
        let parent = Progress(totalUnitCount: 1_000)
        let child = Progress(totalUnitCount: 1_000, parent: parent, pendingUnitCount: 1_000)
        child.completedUnitCount = 250

        let update = tracker.update(parent)

        #expect(update?.fraction == 0.25)
        #expect(update?.message == "Downloading 25%")
    }
}
