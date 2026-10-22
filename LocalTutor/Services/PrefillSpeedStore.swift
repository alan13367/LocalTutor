//
//  PrefillSpeedStore.swift
//  LocalTutor
//

import Foundation

enum PrefillSpeedStore {
    static let minimumSampleTokens = 1_024
    private static let smoothing = 0.3

    static func tokensPerSecond(for profileID: String, defaults: UserDefaults = .standard) -> Double? {
        let value = defaults.double(forKey: key(profileID))
        return value > 0 ? value : nil
    }

    static func record(promptTokens: Int, seconds: Double, for profileID: String, defaults: UserDefaults = .standard) {
        guard promptTokens >= minimumSampleTokens, seconds > 0 else { return }
        let sample = Double(promptTokens) / seconds
        let updated = tokensPerSecond(for: profileID, defaults: defaults)
            .map { $0 + smoothing * (sample - $0) } ?? sample
        defaults.set(updated, forKey: key(profileID))
    }

    static func record(_ metrics: BenchmarkTokenMetrics, for profileID: String) {
        guard let promptTokens = metrics.promptTokens, let seconds = metrics.promptTimeSeconds else { return }
        record(promptTokens: promptTokens, seconds: seconds, for: profileID)
    }

    private static func key(_ profileID: String) -> String {
        "prefillTokensPerSecond.\(profileID)"
    }
}
