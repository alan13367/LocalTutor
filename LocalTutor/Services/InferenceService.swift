//
//  InferenceService.swift
//  LocalTutor
//

import Foundation

struct InferenceRequest: Sendable {
    var profile: ModelProfile
    var runtimePolicy: ModelRuntimePolicy
    var promptContent: StudyPromptContent
    var maxTokens: Int?
    var temperature: Float?

    init(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        promptContent: StudyPromptContent,
        maxTokens: Int? = nil,
        temperature: Float? = nil
    ) {
        self.profile = profile
        self.runtimePolicy = runtimePolicy
        self.promptContent = promptContent
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

protocol InferenceService: Sendable {
    func run(
        request: InferenceRequest,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord

    func preload(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws

    func unload() async

    func clearCache() async throws
}
