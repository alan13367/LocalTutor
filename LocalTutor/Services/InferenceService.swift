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
    var thinking: Bool

    init(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        promptContent: StudyPromptContent,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        thinking: Bool = false
    ) {
        self.profile = profile
        self.runtimePolicy = runtimePolicy
        self.promptContent = promptContent
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinking = thinking
    }
}

struct ChatHistoryMessage: Sendable, Equatable {
    var question: String
    var answer: String
}

struct ChatInferenceRequest: Sendable {
    var profile: ModelProfile
    var runtimePolicy: ModelRuntimePolicy
    var conversationID: UUID
    var instructions: String
    var history: [ChatHistoryMessage]
    var message: String
    var images: [DocumentImage]
    var maxTokens: Int?
    var temperature: Float?
}

protocol InferenceService: Sendable {
    func run(
        request: InferenceRequest,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord

    func chat(
        request: ChatInferenceRequest,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord

    func generateStructured(
        request: InferenceRequest,
        jsonSchema: String,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws -> BenchmarkRecord

    func preload(
        profile: ModelProfile,
        runtimePolicy: ModelRuntimePolicy,
        events: @Sendable @escaping (LocalModelRunnerEvent) async -> Void
    ) async throws

    func unload() async

    func releaseConversations() async

    func setSpeculativeDecoding(_ enabled: Bool) async

    func clearCache() async throws
}
