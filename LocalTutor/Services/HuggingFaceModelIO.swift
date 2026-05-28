//
//  HuggingFaceModelIO.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
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
        return TransformersTokenizerBridge(upstream)
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
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
