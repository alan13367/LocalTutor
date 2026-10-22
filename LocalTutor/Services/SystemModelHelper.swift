//
//  SystemModelHelper.swift
//  LocalTutor
//

import Foundation
import FoundationModels

@Generable
struct GeneratedSourceGuide {
    @Guide(description: "A plain-language overview of the source in two or three sentences.")
    var summary: String

    @Guide(description: "Key topics covered by the source, each one to four words.", .count(3...6))
    var topics: [String]

    @Guide(description: "Study questions a student could answer using only this source.", .count(3))
    var questions: [String]
}

@Generable
struct GeneratedChatTitle {
    @Guide(description: "A short title of at most six words, without quotes or trailing punctuation.")
    var title: String
}

enum SystemModelAvailability: Equatable, Sendable {
    case available
    case notEnabled
    case notEligible
    case modelNotReady
    case unavailable

    var isAvailable: Bool { self == .available }

    var explanation: String {
        switch self {
        case .available:
            "Apple Intelligence is ready."
        case .notEnabled:
            "Turn on Apple Intelligence in System Settings to use it for quick helper tasks."
        case .notEligible:
            "This Mac does not support Apple Intelligence."
        case .modelNotReady:
            "Apple Intelligence is still downloading."
        case .unavailable:
            "Apple Intelligence is unavailable."
        }
    }
}

enum SystemModelHelper {
    static func inputCharacterBudget() -> Int {
        let tokens = max(1_024, SystemLanguageModel.default.contextSize - 1_400)
        return tokens * 3
    }

    static var availability: SystemModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .deviceNotEligible: return .notEligible
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
    }

    static var isEnabledByUser: Bool {
        UserDefaults.standard.object(forKey: AppStorageKeys.useSystemModelForHelpers) as? Bool ?? true
    }

    static var canRun: Bool {
        isEnabledByUser && availability.isAvailable
    }

    static let displayName = "Apple Intelligence"

    static func chatPolicy() -> ModelRuntimePolicy {
        let contextTokens = SystemLanguageModel.default.contextSize
        return ModelRuntimePolicy(
            profileID: "apple-intelligence",
            profileName: displayName,
            supportsVision: false,
            systemMemoryBytes: SystemMemory.totalBytes(),
            minimumSystemMemoryBytes: 0,
            generationDefaults: ModelRuntimeDefaults.text.withMaxTokens(1_024),
            cacheLimitBytes: 0,
            contextTokens: contextTokens
        )
    }

    static func streamAnswer(
        instructions: String,
        history: [ChatHistoryMessage],
        message: String,
        onUpdate: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let recap = history.suffix(2).map { turn in
            "Student: \(turn.question.prefix(300))\nTutor: \(turn.answer.prefix(600))"
        }
        let prompt = recap.isEmpty ? message : "Earlier in this conversation:\n\(recap.joined(separator: "\n\n"))\n\n\(message)"
        var latest = ""
        for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3)) {
            latest = snapshot.content
            await onUpdate(latest)
        }
        return latest
    }

    static func sourceGuide(sourceName: String, text: String) async throws -> SourceGuide {
        let excerpt = String(text.prefix(inputCharacterBudget()))
        let session = LanguageModelSession(
            instructions: "You help students study. Describe study material accurately and only use facts from the provided text."
        )
        let response = try await session.respond(
            to: "Source: \(sourceName)\n\n\(excerpt)",
            generating: GeneratedSourceGuide.self,
            options: GenerationOptions(temperature: 0.2)
        )
        let guide = response.content
        return SourceGuide(
            summary: guide.summary,
            topics: guide.topics,
            questions: guide.questions,
            generatedAt: Date(),
            generatorName: "Apple Intelligence"
        )
    }

    static func chatTitle(question: String, answer: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: "Write concise titles for study conversations."
        )
        let prompt = "Question: \(question.prefix(600))\n\nAnswer: \(answer.prefix(1_200))"
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedChatTitle.self,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content.title
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
