//
//  LiveGeneration.swift
//  LocalTutor
//

import Foundation
import Observation

@MainActor
@Observable
final class LiveGeneration {
    var markdown = ""
    var reasoning = ""
    var statusMessage: String
    var prefillFraction: Double?
    var citations: [SourceCitation] = []

    @ObservationIgnored private(set) var receivedText = ""
    @ObservationIgnored private var pacer = RevealPacer()
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private let flushInterval: Duration = .milliseconds(40)
    @ObservationIgnored private let frameInterval: Duration = .milliseconds(16)

    init(statusMessage: String) {
        self.statusMessage = statusMessage
    }

    func appendText(_ chunk: String) {
        receivedText += chunk
        startRevealing()
    }

    func replaceText(_ text: String) {
        if !text.hasPrefix(markdown) {
            markdown = ""
            pacer = RevealPacer()
        }
        receivedText = text
        startRevealing()
    }

    func appendReasoning(_ chunk: String) {
        pendingReasoning += chunk
        scheduleFlush()
    }

    func drain() {
        revealTask?.cancel()
        revealTask = nil
        flushReasoning()
        if markdown != receivedText {
            markdown = receivedText
        }
    }

    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { [weak self, frameInterval] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: frameInterval)
                let now = ContinuousClock.now
                let elapsed = (now - last) / .seconds(1)
                last = now
                guard let self else { return }
                if !self.revealStep(elapsed: elapsed) {
                    self.revealTask = nil
                    return
                }
            }
        }
    }

    private func revealStep(elapsed: Double) -> Bool {
        let revealedBytes = markdown.utf8.count
        guard revealedBytes < receivedText.utf8.count else { return false }
        let start = receivedText.utf8.index(receivedText.startIndex, offsetBy: revealedBytes)
        let backlog = receivedText[start...]
        let count = pacer.charactersToReveal(backlog: backlog.count, elapsed: elapsed)
        if count > 0 {
            markdown += backlog.prefix(count)
        }
        return markdown.utf8.count < receivedText.utf8.count
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self, flushInterval] in
            try? await Task.sleep(for: flushInterval)
            self?.flushReasoning()
        }
    }

    private func flushReasoning() {
        flushScheduled = false
        guard !pendingReasoning.isEmpty else { return }
        reasoning += pendingReasoning
        pendingReasoning = ""
        if receivedText.isEmpty {
            statusMessage = "Thinking"
        }
    }
}

struct RevealPacer {
    static let smoothingSeconds = 0.12
    static let minimumCharactersPerSecond = 60.0

    private var carry = 0.0

    mutating func charactersToReveal(backlog: Int, elapsed: Double) -> Int {
        guard backlog > 0, elapsed > 0 else {
            carry = 0
            return 0
        }
        let smoothed = Double(backlog) * (1 - exp(-elapsed / Self.smoothingSeconds))
        carry += max(smoothed, Self.minimumCharactersPerSecond * elapsed)
        let count = min(backlog, Int(carry))
        carry -= Double(count)
        return count
    }
}
