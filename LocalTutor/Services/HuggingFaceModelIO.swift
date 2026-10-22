//
//  HuggingFaceModelIO.swift
//  LocalTutor
//
//

import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

struct HuggingFaceModelDownloader: Downloader {
    private let hubClient: HubClient

    init(hubClient: HubClient) {
        self.hubClient = hubClient
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repositoryID = Repo.ID(rawValue: id) else {
            throw HuggingFaceModelIOError.invalidRepositoryID(id)
        }

        do {
            return try await hubClient.downloadSnapshot(
                of: repositoryID,
                revision: revision ?? "main",
                matching: patterns,
                progressHandler: { @MainActor progress in
                    progressHandler(progress)
                }
            )
        } catch {
            throw HuggingFaceModelIOError.downloadFailed(id, error.localizedDescription)
        }
    }
}

struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        let template = ChatTemplatePatcher.stableHistoryTemplate(
            from: ChatTemplatePatcher.chatTemplate(in: directory)
        )
        return TransformersTokenizerBridge(upstream, noThinkingTemplate: template)
    }
}

enum ChatTemplatePatcher {
    static let historyReasoningCondition = "loop.index0 > ns.last_query_index"

    static func chatTemplate(in directory: URL) -> String? {
        if let template = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8) {
            return template
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return config["chat_template"] as? String
    }

    static func stableHistoryTemplate(from template: String?) -> String? {
        guard let template,
              template.contains("enable_thinking"),
              template.components(separatedBy: historyReasoningCondition).count == 2 else {
            return nil
        }
        return template.replacingOccurrences(of: historyReasoningCondition, with: "true")
    }

    static func disablesThinking(_ context: [String: any Sendable]?) -> Bool {
        (context?["enable_thinking"] as? Bool) == false
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    private let noThinkingTemplate: String?

    init(_ upstream: any Tokenizers.Tokenizer, noThinkingTemplate: String? = nil) {
        self.upstream = upstream
        self.noThinkingTemplate = noThinkingTemplate
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? {
        upstream.bosToken
    }

    var eosToken: String? {
        upstream.eosToken
    }

    var unknownToken: String? {
        upstream.unknownToken
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            if let noThinkingTemplate, ChatTemplatePatcher.disablesThinking(additionalContext) {
                return try upstream.applyChatTemplate(
                    messages: messages,
                    chatTemplate: .literal(noThinkingTemplate),
                    addGenerationPrompt: true,
                    truncation: false,
                    maxLength: nil,
                    tools: tools,
                    additionalContext: additionalContext
                )
            }
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum HuggingFaceModelIOError: LocalizedError {
    case invalidRepositoryID(String)
    case downloadFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            "Invalid Hugging Face repository id: \(id)."
        case .downloadFailed(let id, let reason):
            "Could not download \(id): \(reason)"
        }
    }
}
