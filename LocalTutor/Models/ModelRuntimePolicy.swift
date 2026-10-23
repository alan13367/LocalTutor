//
//  ModelRuntimePolicy.swift
//  LocalTutor
//

import Foundation
import Metal

enum ContextPreference: String, CaseIterable, Identifiable, Sendable {
    case standard
    case extended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Balanced"
        case .extended: "Maximum"
        }
    }

    var detail: String {
        switch self {
        case .standard: "As much context as this Mac can read in about \(Int(ContextBudget.firstReplyTargetSeconds)) seconds, tuned from your own replies."
        case .extended: "As much context as fits in this Mac's memory, up to the model's limit. Large notebooks take longer on the first reply."
        }
    }

    static var current: ContextPreference {
        UserDefaults.standard.string(forKey: AppStorageKeys.contextPreference)
            .flatMap(ContextPreference.init(rawValue:)) ?? .standard
    }
}

enum SpeculativeDecodingPreference {
    static func isEnabled(for profile: ModelProfile, choices: [String: Bool], legacyChoice: Bool?) -> Bool {
        guard profile.supportsSpeculativeDecoding else { return false }
        if let choice = choices[profile.id] {
            return choice
        }
        if legacyChoice == false {
            return false
        }
        return profile.speculativeDecodingByDefault
    }

    static var storedChoices: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: AppStorageKeys.speculativeDecodingByModel) as? [String: Bool] ?? [:]
    }

    static var legacyChoice: Bool? {
        UserDefaults.standard.object(forKey: AppStorageKeys.useSpeculativeDecoding) as? Bool
    }

    static func current(for profile: ModelProfile) -> Bool {
        isEnabled(for: profile, choices: storedChoices, legacyChoice: legacyChoice)
    }
}

struct ModelRuntimePolicy: Equatable, Sendable {
    static let estimatedImageTokens = 640
    static let instructionReserve = 1_200

    var profileID: String
    var profileName: String
    var supportsVision: Bool
    var systemMemoryBytes: UInt64
    var minimumSystemMemoryBytes: UInt64
    var generationDefaults: ModelRuntimeDefaults
    var cacheLimitBytes: Int
    var contextTokens: Int

    var documentImageLimit: Int {
        supportsVision ? generationDefaults.documentImageLimit : 0
    }

    var extractionOptions: SourceExtractionOptions {
        extractionOptions(imageLimit: documentImageLimit)
    }

    func extractionOptions(imageLimit: Int) -> SourceExtractionOptions {
        SourceExtractionOptions(
            imageLimit: imageLimit,
            imageResize: generationDefaults.imageResize,
            minEmbeddedImageDimension: generationDefaults.minEmbeddedImageDimension
        )
    }

    func outputReserve(for resourceKind: StudyResourceKind) -> Int {
        min(generationDefaults.maxTokens, max(512, contextTokens / 4))
    }

    func historyReserve(for resourceKind: StudyResourceKind) -> Int {
        resourceKind == .ask ? min(4_096, contextTokens / 5) : 0
    }

    func sourceTokenBudget(for resourceKind: StudyResourceKind) -> Int {
        let imageReserve = documentImageLimit * Self.estimatedImageTokens
        let reserved = outputReserve(for: resourceKind)
            + Self.instructionReserve
            + historyReserve(for: resourceKind)
            + imageReserve
        return max(1_024, contextTokens - reserved)
    }
}

enum ContextBudget {
    static let minimumContextTokens = 4_096
    static let firstReplyTargetSeconds = 25.0
    static let assumedPrefillTokensPerSecond = 1_500.0
    private static let runtimeOverheadBytes: Double = 2.0 * 1_073_741_824
    private static let kvHeadroom = 0.9

    static let deviceWorkingSetBytes: UInt64 = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0

    static func workingSetBytes(forSystemMemory bytes: UInt64) -> UInt64 {
        if bytes == ProcessInfo.processInfo.physicalMemory, deviceWorkingSetBytes > 0 {
            return deviceWorkingSetBytes
        }
        let fraction = bytes >= 32 * 1_073_741_824 ? 0.75 : 0.67
        return UInt64(Double(bytes) * fraction)
    }

    static func memoryFit(
        for profile: ModelProfile,
        architecture: ModelArchitecture,
        workingSetBytes: UInt64,
        speculative: Bool? = nil
    ) -> Int {
        let speculative = speculative ?? (profile.supportsSpeculativeDecoding && profile.speculativeDecodingByDefault)
        let weights = Double(profile.downloadBytes + (speculative ? profile.drafterBytes : 0)) * 1.05
        let free = (Double(workingSetBytes) - weights - runtimeOverheadBytes - Double(architecture.fixedCacheBytes)) * kvHeadroom
        let bits = Double(speculative ? 16 : profile.defaults.kvBits ?? 16)
        let bytesPerToken = max(1, Double(architecture.kvBytesPerToken) * bits / 16)
        guard free > 0 else { return minimumContextTokens }
        return Int(min(free / bytesPerToken, Double(Int.max / 2)))
    }

    static func latencyFit(prefillTokensPerSecond: Double?) -> Int {
        Int((prefillTokensPerSecond ?? assumedPrefillTokensPerSecond) * firstReplyTargetSeconds)
    }

    static func contextTokens(
        for profile: ModelProfile,
        systemMemoryBytes: UInt64,
        preference: ContextPreference,
        architecture: ModelArchitecture? = nil,
        prefillTokensPerSecond: Double? = nil,
        speculative: Bool? = nil
    ) -> Int {
        let architecture = architecture ?? ModelArchitectureStore.architecture(for: profile)
        var candidates = [
            architecture.nativeContextTokens,
            memoryFit(
                for: profile,
                architecture: architecture,
                workingSetBytes: workingSetBytes(forSystemMemory: systemMemoryBytes),
                speculative: speculative
            )
        ]
        if preference == .standard {
            candidates.append(latencyFit(prefillTokensPerSecond: prefillTokensPerSecond ?? PrefillSpeedStore.tokensPerSecond(for: profile.id)))
        }
        let raw = candidates.min() ?? minimumContextTokens
        let rounded = (raw / 1_024) * 1_024
        return max(minimumContextTokens, rounded)
    }
}

enum ModelRuntimePolicyProvider {
    static func policy(
        for profile: ModelProfile,
        systemMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        preference: ContextPreference = .current,
        architecture: ModelArchitecture? = nil,
        prefillTokensPerSecond: Double? = nil,
        speculative: Bool? = nil
    ) -> ModelRuntimePolicy {
        let contextTokens = ContextBudget.contextTokens(
            for: profile,
            systemMemoryBytes: systemMemoryBytes,
            preference: preference,
            architecture: architecture,
            prefillTokensPerSecond: prefillTokensPerSecond,
            speculative: speculative ?? SpeculativeDecodingPreference.current(for: profile)
        )
        return ModelRuntimePolicy(
            profileID: profile.id,
            profileName: profile.name,
            supportsVision: profile.supportsVision,
            systemMemoryBytes: systemMemoryBytes,
            minimumSystemMemoryBytes: profile.minimumSystemMemoryBytes,
            generationDefaults: profile.defaults,
            cacheLimitBytes: cacheLimitBytes(forContextTokens: contextTokens),
            contextTokens: contextTokens
        )
    }

    private static func cacheLimitBytes(forContextTokens contextTokens: Int) -> Int {
        contextTokens <= 8_192
            ? 128 * 1024 * 1024
            : 256 * 1024 * 1024
    }
}
