//
//  ModelArchitecture.swift
//  LocalTutor
//

import Foundation
import Synchronization

struct ModelArchitecture: Equatable, Sendable {
    var nativeContextTokens: Int
    var kvBytesPerToken: Int
    var fixedCacheBytes: Int

    static func parse(configData: Data) -> ModelArchitecture? {
        guard let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else { return nil }
        let text = root["text_config"] as? [String: Any] ?? root
        func int(_ key: String) -> Int? {
            (text[key] as? NSNumber)?.intValue ?? (root[key] as? NSNumber)?.intValue
        }
        guard let layerCount = int("num_hidden_layers"), layerCount > 0,
              let nativeContext = int("max_position_embeddings"), nativeContext > 0 else {
            return nil
        }
        let attentionHeads = int("num_attention_heads") ?? 1
        let headDim = int("head_dim") ?? (int("hidden_size") ?? 0) / max(1, attentionHeads)
        let kvHeads = int("num_key_value_heads") ?? attentionHeads
        let globalHeadDim = int("global_head_dim") ?? headDim
        let globalKVHeads = int("num_global_key_value_heads") ?? kvHeads
        let slidingWindow = int("sliding_window") ?? nativeContext
        let ownedLayers = layerCount - (int("num_kv_shared_layers") ?? 0)

        let layerTypes = (text["layer_types"] as? [String])
            ?? (0..<layerCount).map { index in
                guard let pattern = int("sliding_window_pattern"), pattern > 1 else { return "full_attention" }
                return (index + 1) % pattern == 0 ? "full_attention" : "sliding_attention"
            }

        var perToken = 0
        var fixed = 0
        for type in layerTypes.prefix(max(0, ownedLayers)) {
            let kind = type.lowercased()
            if kind.contains("sliding") || kind.contains("local") {
                fixed += min(slidingWindow, nativeContext) * 2 * kvHeads * headDim * 2
            } else if kind.contains("full") || kind.contains("global") || kind == "attention" {
                perToken += 2 * globalKVHeads * globalHeadDim * 2
            }
        }
        return ModelArchitecture(nativeContextTokens: nativeContext, kvBytesPerToken: perToken, fixedCacheBytes: fixed)
    }

    static func catalogEstimate(for profile: ModelProfile) -> ModelArchitecture {
        ModelArchitecture(
            nativeContextTokens: profile.defaults.maxContextTokens,
            kvBytesPerToken: profile.kvBytesPerToken,
            fixedCacheBytes: 0
        )
    }
}

enum ModelArchitectureStore {
    private static let cache = Mutex<[String: ModelArchitecture]>([:])

    static func architecture(for profile: ModelProfile) -> ModelArchitecture {
        if let cached = cache.withLock({ $0[profile.id] }) {
            return cached
        }
        let configURL = ManagedModelStore.repositoryDirectory(for: profile.modelIdentifier)
            .appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              let parsed = ModelArchitecture.parse(configData: data) else {
            return .catalogEstimate(for: profile)
        }
        cache.withLock { $0[profile.id] = parsed }
        return parsed
    }

    static func invalidate(_ profile: ModelProfile) {
        _ = cache.withLock { $0.removeValue(forKey: profile.id) }
    }
}
