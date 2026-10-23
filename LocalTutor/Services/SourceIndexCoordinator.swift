import Combine
import Foundation

enum SourceIndexPhase: String, Sendable {
    case reading
    case chunking
    case downloading
    case embedding
    case lexicalOnly
    case ready
    case failed
}

struct SourceIndexProgress: Sendable {
    var phase: SourceIndexPhase
    var completed: Int
    var total: Int
    var fraction: Double?
    var message: String
}

@MainActor
final class SourceIndexStatusModel: ObservableObject {
    static let shared = SourceIndexStatusModel()

    @Published private(set) var latest: SourceIndexProgress?

    func update(_ progress: SourceIndexProgress) {
        latest = progress
    }
}

actor SourceIndexCoordinator {
    static let shared = SourceIndexCoordinator()

    private let repository: any SourceIndexRepository
    private let embeddingService: any EmbeddingService
    private let idleUnloadDelay: Duration
    private var tasks: [String: Task<Void, Never>] = [:]
    private var idleUnloadTask: Task<Void, Never>?
    private var tutorGenerationCount = 0

    init(
        repository: any SourceIndexRepository = SQLiteSourceIndexRepository.shared,
        embeddingService: any EmbeddingService = LocalEmbeddingRunner.shared,
        idleUnloadDelay: Duration = .seconds(180)
    ) {
        self.repository = repository
        self.embeddingService = embeddingService
        self.idleUnloadDelay = idleUnloadDelay
    }

    func cacheIndex(_ index: SourceIndex) async {
        try? await repository.store(index, state: .lexicalOnly)
    }

    func scheduleSemanticIndex(
        _ index: SourceIndex,
        progress: @escaping @Sendable (SourceIndexProgress) async -> Void
    ) {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard !ProcessInfo.processInfo.isRunningLocalTutorTests else { return }
        let key = index.fingerprint.cacheKey
        guard tasks[key] == nil else { return }
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.runSemanticIndex(index, progress: progress)
            await self.finishTask(key: key)
        }
    }

    func setTutorGenerationActive(_ active: Bool) async {
        tutorGenerationCount = max(0, tutorGenerationCount + (active ? 1 : -1))
        if !active, tutorGenerationCount == 0 {
            await Task.yield()
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        defer { scheduleIdleUnload() }
        try Task.checkCancellation()
        try await embeddingService.prepare { _ in }
        return try await embeddingService.embedQuery(text)
    }

    func prepareEmbeddingModel(
        events: @escaping @Sendable (EmbeddingServiceEvent) async -> Void
    ) async throws {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        defer { scheduleIdleUnload() }
        await waitUntilTutorIsIdle()
        try Task.checkCancellation()
        try await embeddingService.prepare(events: events)
    }

    func statistics() async -> SourceIndexStatistics {
        await repository.statistics()
    }

    func clear() async throws {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        await embeddingService.unload()
        try await repository.clear()
    }

    private func runSemanticIndex(
        _ index: SourceIndex,
        progress: @escaping @Sendable (SourceIndexProgress) async -> Void
    ) async {
        do {
            let existing = try await repository.vectorEntries(fingerprints: [index.fingerprint])
            if existing.count == index.chunks.count, !existing.isEmpty {
                await report(
                    SourceIndexProgress(
                        phase: .ready,
                        completed: existing.count,
                        total: index.chunks.count,
                        fraction: 1,
                        message: "Semantic search ready"
                    ),
                    progress
                )
                return
            }
            await waitUntilTutorIsIdle()
            try Task.checkCancellation()
            try await repository.updateState(.embedding, fingerprint: index.fingerprint)
            try await embeddingService.prepare { event in
                switch event {
                case .downloading(let update):
                    await self.report(
                        SourceIndexProgress(
                            phase: .downloading,
                            completed: 0,
                            total: index.chunks.count,
                            fraction: update.fraction,
                            message: "Preparing semantic search"
                        ),
                        progress
                    )
                case .ready:
                    break
                }
            }

            var stored: [String: [Float]] = [:]
            for start in stride(from: 0, to: index.chunks.count, by: LocalEmbeddingRunner.maximumBatchSize) {
                await waitUntilTutorIsIdle()
                try Task.checkCancellation()
                let end = min(index.chunks.count, start + LocalEmbeddingRunner.maximumBatchSize)
                let chunks = Array(index.chunks[start..<end])
                let vectors = try await embeddingService.embedDocuments(
                    chunks.map(EmbeddingDocument.init(chunk:))
                )
                for (chunk, vector) in zip(chunks, vectors) {
                    stored[chunk.id] = vector
                }
                await report(
                    SourceIndexProgress(
                        phase: .embedding,
                        completed: end,
                        total: index.chunks.count,
                        fraction: Double(end) / Double(max(1, index.chunks.count)),
                        message: "Indexing semantic context \(end) of \(index.chunks.count)"
                    ),
                    progress
                )
            }
            try await repository.storeVectors(stored, fingerprint: index.fingerprint)
            await report(
                SourceIndexProgress(
                    phase: .ready,
                    completed: index.chunks.count,
                    total: index.chunks.count,
                    fraction: 1,
                    message: "Semantic search ready"
                ),
                progress
            )
        } catch is CancellationError {
            return
        } catch {
            try? await repository.updateState(.failed, fingerprint: index.fingerprint)
            await report(
                SourceIndexProgress(
                    phase: .failed,
                    completed: 0,
                    total: index.chunks.count,
                    fraction: nil,
                    message: "Using lexical search while semantic indexing is unavailable"
                ),
                progress
            )
        }
    }

    private func waitUntilTutorIsIdle() async {
        while tutorGenerationCount > 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishTask(key: String) {
        tasks[key] = nil
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        guard tasks.isEmpty else { return }
        idleUnloadTask?.cancel()
        let delay = idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard tasks.isEmpty else { return }
        await embeddingService.unload()
        idleUnloadTask = nil
    }

    private func report(
        _ value: SourceIndexProgress,
        _ handler: @escaping @Sendable (SourceIndexProgress) async -> Void
    ) async {
        await SourceIndexStatusModel.shared.update(value)
        await handler(value)
    }
}
