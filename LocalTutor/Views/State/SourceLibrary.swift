//
//  SourceLibrary.swift
//  LocalTutor
//

import Foundation
import Observation
import UniformTypeIdentifiers

enum SourceIngestState: Equatable {
    case pending
    case indexing
    case ready(chunks: Int, tokens: Int)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .pending, .indexing: true
        default: false
        }
    }
}

@MainActor
@Observable
final class SourceLibrary {
    nonisolated private static let guideSchema = #"{"type":"object","properties":{"summary":{"type":"string"},"topics":{"type":"array","minItems":3,"maxItems":6,"items":{"type":"string"}},"questions":{"type":"array","minItems":3,"maxItems":3,"items":{"type":"string"}}},"required":["summary","topics","questions"]}"#
    nonisolated private static let guideInputTokens = 2_400

    private(set) var indexStates: [UUID: SourceIngestState] = [:]
    private(set) var generatingGuideIDs: Set<UUID> = []

    @ObservationIgnored private let store: NotebookStore
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    @ObservationIgnored private var indexingQueue: [(source: StudySource, notebookID: UUID)] = []
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var guideTasks: [UUID: Task<Void, Never>] = [:]

    init(store: NotebookStore, models: ModelManager) {
        self.store = store
        self.models = models
    }

    func bootstrap() {
        guard !ProcessInfo.processInfo.isRunningLocalTutorTests else { return }
        for notebook in store.notebooks {
            for source in notebook.sources {
                enqueueIndexing(source, notebookID: notebook.id)
            }
        }
    }

    func state(for source: StudySource) -> SourceIngestState {
        if source.isImage {
            return .ready(chunks: 0, tokens: ModelRuntimePolicy.estimatedImageTokens)
        }
        return indexStates[source.id] ?? .pending
    }

    func supportedContentTypes(supportsVision: Bool) -> [UTType] {
        StudySource.supportedContentTypes(supportsVision: supportsVision)
    }

    // MARK: - Import

    @discardableResult
    func importURLs(_ urls: [URL], into notebookID: UUID, supportsVision: Bool) -> [StudySource] {
        guard let notebook = store.notebook(notebookID) else { return [] }
        let existing = Set(notebook.sources.map(\.url))
        let candidates = urls
            .filter { !existing.contains($0) }
            .map(StudySource.init(url:))
        let rejected = supportsVision ? [] : candidates.filter(\.isImage)
        let accepted = candidates.filter { supportsVision || !$0.isImage }

        if !accepted.isEmpty {
            store.update(notebookID) { notebook in
                notebook.sources.append(contentsOf: accepted)
                if notebook.title == "Untitled notebook", let first = accepted.first {
                    notebook.title = Self.title(fromFilename: first.displayName)
                }
            }
            for source in accepted {
                enqueueIndexing(source, notebookID: notebookID)
            }
        }
        if !rejected.isEmpty {
            onError(rejected.count == 1
                ? "Images need a vision model. Choose one in Settings to add pictures."
                : "\(rejected.count) images need a vision model. Choose one in Settings to add pictures.")
        }
        return accepted
    }

    func importFromDropProviders(_ providers: [NSItemProvider], into notebookID: UUID, supportsVision: Bool) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let message {
                        self?.onError(message)
                    } else if let url {
                        self?.importURLs([url], into: notebookID, supportsVision: supportsVision)
                    }
                }
            }
        }
        return true
    }

    func remove(_ source: StudySource, from notebookID: UUID) {
        guideTasks[source.id]?.cancel()
        store.update(notebookID) { $0.sources.removeAll { $0.id == source.id } }
        indexStates[source.id] = nil
    }

    func setEnabled(_ enabled: Bool, source: StudySource, in notebookID: UUID) {
        store.updateSource(source.id, in: notebookID) { $0.isEnabled = enabled }
    }

    func setAllEnabled(_ enabled: Bool, in notebookID: UUID) {
        store.update(notebookID) { notebook in
            for index in notebook.sources.indices {
                notebook.sources[index].isEnabled = enabled
            }
        }
    }

    nonisolated static func title(fromFilename name: String) -> String {
        let base = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.hasPrefix(".") else { return "Untitled notebook" }
        return String(base.prefix(60))
    }

    // MARK: - Indexing

    private func enqueueIndexing(_ source: StudySource, notebookID: UUID) {
        guard !source.isImage, !ProcessInfo.processInfo.isRunningLocalTutorTests else { return }
        if case .ready = indexStates[source.id] { return }
        indexStates[source.id] = .pending
        indexingQueue.append((source, notebookID))
        startIndexingIfNeeded()
    }

    private func startIndexingIfNeeded() {
        guard indexingTask == nil else { return }
        indexingTask = Task { [weak self] in
            while let self, !self.indexingQueue.isEmpty {
                let next = self.indexingQueue.removeFirst()
                await self.index(next.source, notebookID: next.notebookID)
            }
            self?.indexingTask = nil
        }
    }

    private func index(_ source: StudySource, notebookID: UUID) async {
        indexStates[source.id] = .indexing
        let result: SourceIndex? = await Task.detached(priority: .utility) {
            if let cached = await SourceIndexStore.shared.cachedIndex(for: source) {
                return cached.rebased(to: source)
            }
            let extracted = await SourceExtractor.extract([source], options: .defaults(for: .text)).first
            guard let extracted, extracted.hasContent else { return nil }
            let index = await SourceIndexBuilder.build(from: extracted)
            await SourceIndexCoordinator.shared.cacheIndex(index)
            await SourceIndexCoordinator.shared.scheduleSemanticIndex(index) { _ in }
            return index
        }.value

        guard let result, !result.chunks.isEmpty else {
            indexStates[source.id] = .failed("No readable text was found.")
            return
        }
        let tokens = result.chunks.reduce(0) { $0 + $1.estimatedTokenCount }
        indexStates[source.id] = .ready(chunks: result.chunks.count, tokens: tokens)

        let current = store.notebook(notebookID)?.sources.first { $0.id == source.id }
        if current?.guide == nil, SystemModelHelper.canRun {
            generateGuide(for: source, in: notebookID, index: result)
        }
    }

    func notebookTokenEstimate(_ notebook: Notebook) -> Int {
        notebook.enabledSources.reduce(0) { total, source in
            if case .ready(_, let tokens) = state(for: source) {
                return total + tokens
            }
            return total
        }
    }

    // MARK: - Source guides

    func generateGuide(for source: StudySource, in notebookID: UUID, index: SourceIndex? = nil) {
        guard guideTasks[source.id] == nil else { return }
        generatingGuideIDs.insert(source.id)
        let profile = models.selectedProfile
        let policy = models.runtimePolicy
        let inference = models.inferenceService
        guideTasks[source.id] = Task { [weak self] in
            defer {
                self?.guideTasks[source.id] = nil
                self?.generatingGuideIDs.remove(source.id)
            }
            var resolvedIndex = index
            if resolvedIndex == nil {
                resolvedIndex = await SourceIndexStore.shared.cachedIndex(for: source)
            }
            guard let resolvedIndex else {
                self?.onError("Index \(source.displayName) before generating a guide.")
                return
            }
            let text = Self.guideText(from: resolvedIndex)
            do {
                let guide: SourceGuide
                if SystemModelHelper.canRun {
                    guide = try await SystemModelHelper.sourceGuide(sourceName: source.displayName, text: text)
                } else if let profile, let policy {
                    guide = try await Self.modelGuide(
                        source: source,
                        text: text,
                        profile: profile,
                        policy: policy,
                        inference: inference
                    )
                } else {
                    self?.onError("Choose a model to generate source guides.")
                    return
                }
                guard !Task.isCancelled else { return }
                self?.store.updateSource(source.id, in: notebookID) { $0.guide = guide }
            } catch is CancellationError {
                return
            } catch {
                self?.onError("Couldn't summarize \(source.displayName): \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func guideText(from index: SourceIndex) -> String {
        var remaining = guideInputTokens
        var parts: [String] = []
        for chunk in index.chunks {
            guard remaining > 0 else { break }
            let text = chunk.estimatedTokenCount <= remaining
                ? chunk.text
                : String(chunk.text.prefix(PromptTokenEstimator.characterLimit(forTokenBudget: remaining)))
            parts.append(text)
            remaining -= chunk.estimatedTokenCount
        }
        return parts.joined(separator: "\n\n")
    }

    private nonisolated static func modelGuide(
        source: StudySource,
        text: String,
        profile: ModelProfile,
        policy: ModelRuntimePolicy,
        inference: any InferenceService
    ) async throws -> SourceGuide {
        let content = StudyPromptContent(
            systemInstruction: StudyPromptBuilder.systemInstruction,
            openingText: "Write a source guide for \"\(source.displayName)\": a two or three sentence overview, 3-6 key topics (1-4 words each), and exactly 3 study questions answerable from the text.",
            sourceBlocks: [.text(text)],
            closingText: "Return JSON with keys summary, topics, questions.",
            includedImageCount: 0,
            omittedImageCount: 0,
            imageFilenames: [],
            warnings: []
        )
        let request = InferenceRequest(
            profile: profile,
            runtimePolicy: policy,
            promptContent: content,
            maxTokens: 400,
            temperature: 0.2
        )
        let record = try await inference.generateStructured(request: request, jsonSchema: guideSchema) { _ in }
        guard record.status == .success,
              let data = StudyArtifactParser.extractJSONData(from: record.output),
              let decoded = try? JSONDecoder().decode(GuidePayload.self, from: data) else {
            throw LocalModelRunnerError.structuredOutputFailed(record.errorMessage ?? "Invalid guide")
        }
        return SourceGuide(
            summary: decoded.summary,
            topics: decoded.topics,
            questions: decoded.questions,
            generatedAt: Date(),
            generatorName: profile.name
        )
    }

    private struct GuidePayload: Decodable {
        var summary: String
        var topics: [String]
        var questions: [String]
    }
}
