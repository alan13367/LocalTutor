//
//  NotebookModels.swift
//  LocalTutor
//

import Foundation

struct Notebook: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var symbol: String
    var createdAt: Date
    var updatedAt: Date
    var sources: [StudySource]
    var chats: [NotebookChat]
    var studioItems: [StudioItem]
    var notes: [StudyNote]
    var reviewStates: [String: FlashcardReviewState]

    init(
        id: UUID = UUID(),
        title: String = "Untitled notebook",
        symbol: String = "book.closed",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sources: [StudySource] = [],
        chats: [NotebookChat] = [NotebookChat()],
        studioItems: [StudioItem] = [],
        notes: [StudyNote] = [],
        reviewStates: [String: FlashcardReviewState] = [:]
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sources = sources
        self.chats = chats.isEmpty ? [NotebookChat()] : chats
        self.studioItems = studioItems
        self.notes = notes
        self.reviewStates = reviewStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled notebook"
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "book.closed"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sources = try container.decodeIfPresent([StudySource].self, forKey: .sources) ?? []
        let decodedChats = try container.decodeIfPresent([NotebookChat].self, forKey: .chats) ?? []
        chats = decodedChats.isEmpty ? [NotebookChat()] : decodedChats
        studioItems = try container.decodeIfPresent([StudioItem].self, forKey: .studioItems) ?? []
        notes = try container.decodeIfPresent([StudyNote].self, forKey: .notes) ?? []
        reviewStates = try container.decodeIfPresent([String: FlashcardReviewState].self, forKey: .reviewStates) ?? [:]
    }

    var enabledSources: [StudySource] {
        sources.filter(\.isEnabled)
    }

    var isEmpty: Bool {
        sources.isEmpty && notes.isEmpty && studioItems.isEmpty && chats.allSatisfy(\.turns.isEmpty)
    }

    var subtitle: String {
        let count = sources.count
        return count == 0 ? "No sources" : "\(count) source\(count == 1 ? "" : "s")"
    }

    var allFlashcards: [Flashcard] {
        studioItems.flatMap { item -> [Flashcard] in
            guard case .flashcards(let deck) = item.payload else { return [] }
            return deck.cards
        }
    }

    func dueFlashcards(now: Date = Date()) -> [Flashcard] {
        allFlashcards.filter { card in
            guard let state = reviewStates[card.id] else { return true }
            return state.due <= now
        }
    }

    func runningStudioItem(of kind: StudyResourceKind) -> StudioItem? {
        studioItems.first { $0.isRunning && $0.kind == kind }
    }
}

struct NotebookChat: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var titleIsCustom: Bool
    var createdAt: Date
    var updatedAt: Date
    var turns: [StudyTurn]

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        titleIsCustom: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [StudyTurn] = []
    ) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
    }

    var displayTitle: String {
        if titleIsCustom || title != "New chat" {
            return title
        }
        if let first = turns.first?.user.displayPrompt, !first.isEmpty {
            return String(first.prefix(48))
        }
        return title
    }
}

struct StudioItem: Identifiable, Equatable, Codable {
    var id: UUID
    var kind: StudyResourceKind
    var title: String
    var focus: String
    var createdAt: Date
    var finishedAt: Date?
    var status: StudyTurnStatus
    var statusMessage: String
    var markdown: String
    var reasoning: String
    var payload: StudyArtifactPayload?
    var citations: [SourceCitation]
    var sourceIDs: [UUID]

    init(
        id: UUID = UUID(),
        kind: StudyResourceKind,
        title: String? = nil,
        focus: String = "",
        createdAt: Date = Date(),
        status: StudyTurnStatus = .streaming,
        statusMessage: String = "Queued",
        sourceIDs: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.title
        self.focus = focus
        self.createdAt = createdAt
        self.finishedAt = nil
        self.status = status
        self.statusMessage = statusMessage
        self.markdown = ""
        self.reasoning = ""
        self.payload = nil
        self.citations = []
        self.sourceIDs = sourceIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(StudyResourceKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? kind.title
        focus = try container.decodeIfPresent(String.self, forKey: .focus) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = (try? container.decode(StudyTurnStatus.self, forKey: .status)) ?? .done
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? "Ready"
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        payload = try? container.decodeIfPresent(StudyArtifactPayload.self, forKey: .payload)
        citations = try container.decodeIfPresent([SourceCitation].self, forKey: .citations) ?? []
        sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
    }

    var isRunning: Bool {
        !status.isTerminal
    }
}

struct StudyNote: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var markdown: String
    var createdAt: Date
    var updatedAt: Date
    var citations: [SourceCitation]

    init(
        id: UUID = UUID(),
        title: String,
        markdown: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        citations: [SourceCitation] = []
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.citations = citations
    }
}

struct SourceCitation: Identifiable, Equatable, Hashable, Codable, Sendable {
    var index: Int
    var chunkID: String
    var sourceID: UUID
    var sourceName: String
    var locator: String?
    var page: Int?
    var headingPath: [String]
    var excerpt: String

    var id: String { "\(index)-\(chunkID)" }

    var shortLabel: String {
        var parts = [sourceName]
        if let page {
            parts.append("p. \(page)")
        } else if let heading = headingPath.last?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), !heading.isEmpty {
            parts.append(String(heading.prefix(40)))
        } else if let locator, !locator.isEmpty {
            parts.append(locator)
        }
        return parts.joined(separator: " · ")
    }

    init(index: Int, chunk: SourceChunk) {
        self.index = index
        chunkID = chunk.id
        sourceID = chunk.sourceID
        sourceName = chunk.sourceName
        locator = chunk.locator
        page = chunk.locatorRange.startPage
        headingPath = chunk.headingPath
        excerpt = String(chunk.text.prefix(1_200))
    }

    init(
        index: Int,
        chunkID: String,
        sourceID: UUID,
        sourceName: String,
        locator: String?,
        page: Int?,
        headingPath: [String],
        excerpt: String
    ) {
        self.index = index
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.locator = locator
        self.page = page
        self.headingPath = headingPath
        self.excerpt = excerpt
    }
}

struct SourceGuide: Equatable, Codable, Sendable {
    var summary: String
    var topics: [String]
    var questions: [String]
    var generatedAt: Date
    var generatorName: String
}

struct FlashcardReviewState: Equatable, Codable, Sendable {
    var cardID: String
    var ease: Double
    var intervalDays: Double
    var repetitions: Int
    var lapses: Int
    var due: Date
    var lastReviewed: Date?

    static func new(cardID: String, now: Date = Date()) -> FlashcardReviewState {
        FlashcardReviewState(
            cardID: cardID,
            ease: 2.5,
            intervalDays: 0,
            repetitions: 0,
            lapses: 0,
            due: now,
            lastReviewed: nil
        )
    }
}
