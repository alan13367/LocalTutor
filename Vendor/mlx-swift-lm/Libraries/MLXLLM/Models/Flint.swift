//
//  Flint.swift
//  LLM
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// port of mlx_lm/models/flint.py from https://github.com/ml-explore/mlx-lm/pull/1998
// (Recursive Flint: sliding-window + NoPE full attention with learned sinks,
// sigmoid-routed experts plus one shared expert, leading dense layers)

public struct FlintConfiguration: Codable, Sendable {
    var modelType: String = "flint"
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var kvHeads: Int
    var headDim: Int
    var numExperts: Int
    var numExpertsPerToken: Int
    var moeIntermediateSize: Int
    var sharedExpertIntermediateSize: Int
    var mlpOnlyLayers: [Int]
    var layerTypes: [String]
    var slidingWindow: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var ropeTheta: Float = 10_000
    var tieWordEmbeddings: Bool = false

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case numExperts = "num_experts"
        case numExpertsPerToken = "num_experts_per_tok"
        case moeIntermediateSize = "moe_intermediate_size"
        case sharedExpertIntermediateSize = "shared_expert_intermediate_size"
        case mlpOnlyLayers = "mlp_only_layers"
        case layerTypes = "layer_types"
        case slidingWindow = "sliding_window"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case ropeTheta = "rope_theta"
        case ropeParameters = "rope_parameters"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "flint"
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
        kvHeads = try container.decode(Int.self, forKey: .kvHeads)
        headDim = try container.decode(Int.self, forKey: .headDim)
        numExperts = try container.decode(Int.self, forKey: .numExperts)
        numExpertsPerToken = try container.decode(Int.self, forKey: .numExpertsPerToken)
        moeIntermediateSize = try container.decode(Int.self, forKey: .moeIntermediateSize)
        sharedExpertIntermediateSize = try container.decode(
            Int.self, forKey: .sharedExpertIntermediateSize)
        mlpOnlyLayers = try container.decodeIfPresent([Int].self, forKey: .mlpOnlyLayers) ?? []
        layerTypes = try container.decode([String].self, forKey: .layerTypes)
        slidingWindow = try container.decode(Int.self, forKey: .slidingWindow)
        rmsNormEps = try container.decode(Float.self, forKey: .rmsNormEps)
        vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
        tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        let ropeParameters = try container.decodeIfPresent(
            [String: StringOrNumber].self, forKey: .ropeParameters)
        if let theta = ropeParameters?["rope_theta"]?.asFloat() {
            ropeTheta = theta
        } else {
            ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 10_000
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(hiddenSize, forKey: .hiddenSize)
        try container.encode(hiddenLayers, forKey: .hiddenLayers)
        try container.encode(intermediateSize, forKey: .intermediateSize)
        try container.encode(attentionHeads, forKey: .attentionHeads)
        try container.encode(kvHeads, forKey: .kvHeads)
        try container.encode(headDim, forKey: .headDim)
        try container.encode(numExperts, forKey: .numExperts)
        try container.encode(numExpertsPerToken, forKey: .numExpertsPerToken)
        try container.encode(moeIntermediateSize, forKey: .moeIntermediateSize)
        try container.encode(sharedExpertIntermediateSize, forKey: .sharedExpertIntermediateSize)
        try container.encode(mlpOnlyLayers, forKey: .mlpOnlyLayers)
        try container.encode(layerTypes, forKey: .layerTypes)
        try container.encode(slidingWindow, forKey: .slidingWindow)
        try container.encode(rmsNormEps, forKey: .rmsNormEps)
        try container.encode(vocabularySize, forKey: .vocabularySize)
        try container.encode(ropeTheta, forKey: .ropeTheta)
        try container.encode(tieWordEmbeddings, forKey: .tieWordEmbeddings)
    }

    func usesSlidingWindow(layer: Int) -> Bool {
        layerTypes[layer] == "sliding_attention"
    }
}

class FlintAttention: Module {
    let heads: Int
    let kvHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    @ParameterInfo(key: "softmax_offset") var softmaxOffset: MLXArray

    let rope: RoPE?

    init(_ args: FlintConfiguration, layerIdx: Int) {
        let dim = args.hiddenSize
        heads = args.attentionHeads
        kvHeads = args.kvHeads
        scale = pow(Float(args.headDim), -0.5)

        _wq.wrappedValue = Linear(dim, heads * args.headDim, bias: false)
        _wk.wrappedValue = Linear(dim, kvHeads * args.headDim, bias: false)
        _wv.wrappedValue = Linear(dim, kvHeads * args.headDim, bias: false)
        _wo.wrappedValue = Linear(heads * args.headDim, dim, bias: false)

        _qNorm.wrappedValue = RMSNorm(dimensions: args.headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: args.headDim, eps: args.rmsNormEps)
        _softmaxOffset.wrappedValue = MLXArray.zeros([heads])

        rope =
            args.usesSlidingWindow(layer: layerIdx)
            ? RoPE(dimensions: args.headDim, traditional: false, base: args.ropeTheta)
            : nil
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = qNorm(wq(x).reshaped(B, L, heads, -1)).transposed(0, 2, 1, 3)
        var keys = kNorm(wk(x).reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        var values = wv(x).reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)

        if let rope {
            let offset = cache?.ropeOffset
            queries = applyRotaryPosition(rope, to: queries, offset: offset)
            keys = applyRotaryPosition(rope, to: keys, offset: offset)
        }

        if let quantizedCache = cache as? QuantizedKVCacheProtocol {
            // Quantized attention has no sink term; LocalTutor keeps Flint's KV cache unquantized.
            let (quantizedKeys, quantizedValues) = quantizedCache.updateQuantized(
                keys: keys, values: values)
            let output = quantizedScaledDotProductAttention(
                queries: queries,
                quantizedKeys: quantizedKeys,
                quantizedValues: quantizedValues,
                scale: scale,
                mask: mask,
                groupSize: quantizedCache.groupSize,
                bits: quantizedCache.bits,
                mode: quantizedCache.mode
            )
            return wo(output.transposed(0, 2, 1, 3).reshaped(B, L, -1))
        }

        if let cache {
            (keys, values) = cache.update(keys: keys, values: values)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values,
            scale: scale,
            mask: mask,
            sinks: softmaxOffset)
        return wo(output.transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

class FlintMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

class FlintSparseMoeBlock: Module, UnaryLayer {
    let topK: Int

    @ModuleInfo(key: "gate") var gate: Linear
    @ModuleInfo(key: "switch_mlp") var switchMLP: SwitchGLU
    @ModuleInfo(key: "shared_expert") var sharedExpert: FlintMLP

    init(_ args: FlintConfiguration) {
        topK = args.numExpertsPerToken
        _gate.wrappedValue = Linear(args.hiddenSize, args.numExperts, bias: false)
        _switchMLP.wrappedValue = SwitchGLU(
            inputDims: args.hiddenSize, hiddenDims: args.moeIntermediateSize,
            numExperts: args.numExperts)
        _sharedExpert.wrappedValue = FlintMLP(
            dimensions: args.hiddenSize, hiddenDimensions: args.sharedExpertIntermediateSize)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let logits = gate(x.asType(.float32))
        let scores = sigmoid(logits)

        let inds: MLXArray
        let weights: MLXArray
        if supportsFusedRouterTopK(logits, k: topK) {
            (inds, weights) = fusedRouterTopK(
                selection: logits, values: scores, k: topK, normalize: true, order: .descending)
        } else {
            inds = MLX.argPartition(-scores, kth: topK - 1, axis: -1)[.ellipsis, ..<topK]
            let selected = MLX.takeAlong(scores, inds, axis: -1)
            weights = selected / MLX.sum(selected, axis: -1, keepDims: true)
        }

        let y = switchMLP(x, inds)
        let routed = weightedExpertSum(y, weights).asType(y.dtype)
        return routed + sharedExpert(x)
    }
}

class FlintDecoderLayer: Module {
    let usesSlidingWindow: Bool

    @ModuleInfo(key: "self_attn") var selfAttn: FlintAttention
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    fileprivate let mlp: UnaryLayer

    init(_ args: FlintConfiguration, layerIdx: Int) {
        usesSlidingWindow = args.usesSlidingWindow(layer: layerIdx)
        _selfAttn.wrappedValue = FlintAttention(args, layerIdx: layerIdx)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        if args.mlpOnlyLayers.contains(layerIdx) {
            mlp = FlintMLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        } else {
            mlp = FlintSparseMoeBlock(args)
        }
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let h = x + selfAttn(inputLayerNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionLayerNorm(h))
    }
}

public class FlintModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "norm") var norm: RMSNorm

    fileprivate let layers: [FlintDecoderLayer]
    let slidingWindow: Int
    let fullAttentionIndex: Int?
    let slidingAttentionIndex: Int?

    init(_ args: FlintConfiguration) {
        precondition(args.vocabularySize > 0)
        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        _norm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        layers = (0 ..< args.hiddenLayers).map { FlintDecoderLayer(args, layerIdx: $0) }
        slidingWindow = args.slidingWindow
        fullAttentionIndex = args.layerTypes.firstIndex(of: "full_attention")
        slidingAttentionIndex = args.layerTypes.firstIndex(of: "sliding_attention")
    }

    func callAsFunction(
        _ inputs: MLXArray, cache: [KVCache]? = nil, inputEmbeddings: MLXArray? = nil
    ) -> MLXArray {
        var h = inputEmbeddings ?? embedTokens(inputs)
        let n = h.dim(1)

        let fullMask = makeAttentionMask(
            n: n, cache: fullAttentionIndex.flatMap { cache?[$0] }, windowSize: nil)
        let slidingMask = makeAttentionMask(
            n: n, cache: slidingAttentionIndex.flatMap { cache?[$0] }, windowSize: slidingWindow)

        for (i, layer) in layers.enumerated() {
            h = layer(
                h, mask: layer.usesSlidingWindow ? slidingMask : fullMask, cache: cache?[i])
        }

        return norm(h)
    }
}

public class FlintModel: Module, LLMModel, KVCacheDimensionProvider {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    public let model: FlintModelInner
    let configuration: FlintConfiguration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ args: FlintConfiguration) {
        configuration = args
        vocabularySize = args.vocabularySize
        kvHeads = Array(repeating: args.kvHeads, count: args.hiddenLayers)
        model = FlintModelInner(args)
        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let out = model(inputs, cache: cache)
        if let lmHead {
            return lmHead(out)
        }
        return model.embedTokens.asLinear(out)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = filterLMHeadWeights(
            from: weights, tiedWordEmbeddings: configuration.tieWordEmbeddings)
        for layer in 0 ..< configuration.hiddenLayers
        where !configuration.mlpOnlyLayers.contains(layer) {
            let prefix = "model.layers.\(layer).mlp"
            for name in ["up_proj", "down_proj", "gate_proj"]
            where weights["\(prefix).experts.0.\(name).weight"] != nil {
                let experts = (0 ..< configuration.numExperts).map { expert in
                    weights.removeValue(forKey: "\(prefix).experts.\(expert).\(name).weight")!
                }
                weights["\(prefix).switch_mlp.\(name).weight"] = MLX.stacked(experts)
            }
        }
        return weights
    }

    public func newCache(parameters: GenerateParameters?) throws -> [any KVCache] {
        try (0 ..< configuration.hiddenLayers).map { layer in
            try makeHybridAttentionKVCache(
                parameters: parameters,
                slidingWindow: configuration.slidingWindow,
                usesSlidingWindow: configuration.usesSlidingWindow(layer: layer))
        }
    }
}

extension FlintModel: LoRAModel {
    public var loraLayers: [Module] {
        model.layers
    }
}

/// Registers the `flint` model type with ``LLMTypeRegistry/shared``. Call once before loading a
/// Flint checkpoint; re-registration is idempotent.
public enum FlintRegistration {
    public static func register() async {
        await LLMTypeRegistry.shared.registerModelType("flint") { data in
            FlintModel(try JSONDecoder.json5().decode(FlintConfiguration.self, from: data))
        }
    }
}
