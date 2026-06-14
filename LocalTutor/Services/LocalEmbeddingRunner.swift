//
//  LocalEmbeddingRunner.swift
//  LocalTutor
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

actor LocalEmbeddingRunner {
    static let shared = LocalEmbeddingRunner()
    private let modelDownloadService: ManagedModelDownloadService
    private var activeContainer: ModelContainer?
    
    init(modelDownloadService: ManagedModelDownloadService = .shared) {
        self.modelDownloadService = modelDownloadService
    }
    
    func embed(text: String) async throws -> [Float] {
        let profile = ModelCatalog.embeddingGemma300M
        let container = try await loadContainerIfNeeded(profile: profile)
        
        return try await container.perform { context in
            let tokenizer = context.tokenizer
            let tokens = tokenizer.encode(text: text)
            let inputArray = MLXArray(tokens).expandedDimensions(axis: 0)
            
            // Generate embeddings
            let modelOutput = context.model(inputArray, cache: nil)
            
            // The output is [batch, sequence_length, hidden_dimension]
            // We apply mean pooling across the sequence length (axis 1)
            let pooled = modelOutput.mean(axes: [1]).squeezed()
            
            // Convert the MLXArray to a standard Swift array of floats
            let floats = pooled.asArray(Float.self)
            
            return floats
        }
    }
    
    private func loadContainerIfNeeded(profile: ModelProfile) async throws -> ModelContainer {
        if let activeContainer {
            return activeContainer
        }
        
        Memory.clearCache()
        let tokenizerLoader = TransformersTokenizerLoader()
        
        let downloadResult = try await modelDownloadService.ensureDownloaded(
            profile: profile,
            progressHandler: { _ in }
        )
        
        let container: ModelContainer
        switch profile.configuration {
        case .llm(let configuration):
            var localConfiguration = configuration
            localConfiguration.id = .directory(downloadResult.directory)
            container = try await LLMModelFactory.shared.loadContainer(
                from: LocalDirectoryOnlyDownloader(),
                using: tokenizerLoader,
                configuration: localConfiguration
            )
        default:
            throw LocalModelRunnerError.unsupportedProfile(profile.id)
        }
        
        self.activeContainer = container
        return container
    }
}
