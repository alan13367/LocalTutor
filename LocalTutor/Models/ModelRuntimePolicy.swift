//
//  ModelRuntimePolicy.swift
//  LocalTutor
//

import Foundation

struct ModelRuntimePolicy: Equatable, Sendable {
    var profileID: String
    var profileName: String
    var supportsVision: Bool
    var systemMemoryBytes: UInt64
    var minimumSystemMemoryBytes: UInt64
    var generationDefaults: ModelRuntimeDefaults
    var cacheLimitBytes: Int

    var documentImageLimit: Int {
        supportsVision ? generationDefaults.documentImageLimit : 0
    }

    var extractionOptions: SourceExtractionOptions {
        SourceExtractionOptions(
            imageLimit: documentImageLimit,
            imageResize: generationDefaults.imageResize,
            minEmbeddedImageDimension: generationDefaults.minEmbeddedImageDimension
        )
    }

    func extractionOptions(imageLimit: Int) -> SourceExtractionOptions {
        SourceExtractionOptions(
            imageLimit: imageLimit,
            imageResize: generationDefaults.imageResize,
            minEmbeddedImageDimension: generationDefaults.minEmbeddedImageDimension
        )
    }

    func sourceTokenBudget(for resourceKind: StudyResourceKind) -> Int {
        let outputReserve = min(
            resourceKind.isInteractive ? 1_024 : generationDefaults.maxTokens,
            max(256, generationDefaults.maxKVSize / 3)
        )
        let instructionReserve = min(900, max(500, generationDefaults.maxKVSize / 4))
        let rawBudget = generationDefaults.maxKVSize - outputReserve - instructionReserve
        let sourceBudgetCap = max(256, generationDefaults.maxKVSize / 3)
        return max(256, min(rawBudget, sourceBudgetCap))
    }
}

enum ModelRuntimePolicyProvider {
    static func policy(
        for profile: ModelProfile,
        systemMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelRuntimePolicy {
        ModelRuntimePolicy(
            profileID: profile.id,
            profileName: profile.name,
            supportsVision: profile.supportsVision,
            systemMemoryBytes: systemMemoryBytes,
            minimumSystemMemoryBytes: profile.minimumSystemMemoryBytes,
            generationDefaults: profile.defaults,
            cacheLimitBytes: cacheLimitBytes(for: profile.defaults)
        )
    }

    private static func cacheLimitBytes(for defaults: ModelRuntimeDefaults) -> Int {
        defaults.maxKVSize <= 2_048
            ? 64 * 1024 * 1024
            : 128 * 1024 * 1024
    }
}
