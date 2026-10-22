//
//  NotebookTests.swift
//  LocalTutorTests
//

import Foundation
import Testing
@testable import LocalTutor

struct NotebookTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTutorNotebookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(named name: String) throws -> StudySource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try "Notes about \(name)".write(to: url, atomically: true, encoding: .utf8)
        return StudySource(url: url)
    }

    @Test
    func legacySessionsMigrateIntoNotebooksWithChatsAndStudioItems() throws {
        let directory = try temporaryDirectory()
        let legacy = directory.appendingPathComponent("study-sessions.json")
        let notebooksDirectory = directory.appendingPathComponent("Notebooks", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooksDirectory, withIntermediateDirectories: true)

        let notes = try source(named: "biology.md")
        var ask = StudyTurn(user: StudyTurnUser(focus: "What is ATP?", resourceKind: .ask, sources: [notes], isRefinement: false))
        ask.assistant.markdown = "Energy currency."
        ask.assistant.status = .done
        var quiz = StudyTurn(user: StudyTurnUser(focus: "", resourceKind: .quiz, sources: [notes], isRefinement: false))
        quiz.assistant.status = .done
        quiz.assistant.payload = .quiz(QuizArtifact(title: "Cells", questions: [
            QuizQuestion(prompt: "Powerhouse?", type: .shortAnswer, correctAnswer: "Mitochondria")
        ]))
        let session = StudySession(title: "Biology", titleIsCustom: true, sources: [notes], turns: [ask, quiz])
        let empty = StudySession()
        let encoder = NotebookPersistence.makeEncoder()
        try encoder.encode([session, empty]).write(to: legacy)

        let migrated = LegacySessionMigration.migrateIfNeeded(legacyFile: legacy, notebooksDirectory: notebooksDirectory)

        #expect(migrated.count == 1)
        let notebook = try #require(migrated.first)
        #expect(notebook.id == session.id)
        #expect(notebook.title == "Biology")
        #expect(notebook.sources.map(\.displayName) == ["biology.md"])
        #expect(notebook.chats.first?.turns.map(\.user.focus) == ["What is ATP?"])
        #expect(notebook.studioItems.map(\.kind) == [.quiz])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("study-sessions.migrated.json").path))
        #expect(NotebookPersistence.loadAllSync(directory: notebooksDirectory).map(\.id) == [session.id])
    }

    @Test
    func persistenceRoundTripsAndSettlesInterruptedWork() async throws {
        let directory = try temporaryDirectory()
        var turn = StudyTurn(user: StudyTurnUser(focus: "Q", resourceKind: .ask, sources: [], isRefinement: false))
        turn.assistant.markdown = "Partial"
        var item = StudioItem(kind: .summary)
        item.status = .streaming
        let notebook = Notebook(title: "Physics", chats: [NotebookChat(turns: [turn])], studioItems: [item])

        await NotebookPersistence(directory: directory).save(notebook)
        let loaded = try #require(NotebookPersistence.loadAllSync(directory: directory).first)

        #expect(loaded.title == "Physics")
        #expect(loaded.chats.first?.turns.first?.assistant.status == .done)
        if case .failed = loaded.studioItems.first?.status {
            #expect(true)
        } else {
            Issue.record("Empty interrupted studio items should be marked failed")
        }
    }

    @Test
    func sourcesDecodedFromOlderFilesDefaultToEnabled() throws {
        let json = #"{"id":"2F1F0C1E-6C7E-4D51-9C3A-0D6E0F5E5B11","url":"file:///tmp/a.pdf","displayName":"a.pdf","fileExtension":"pdf","kind":"pdf"}"#
        let source = try JSONDecoder().decode(StudySource.self, from: Data(json.utf8))

        #expect(source.isEnabled)
        #expect(source.guide == nil)
        #expect(source.kind == .pdf)
    }

    @MainActor
    @Test
    func newChatReusesAnEmptyThread() throws {
        let notebook = Notebook(title: "History")
        let store = NotebookStore(persistence: nil, initial: [notebook])

        let first = store.newChat(in: notebook.id)
        let second = store.newChat(in: notebook.id)

        #expect(first == second)
        #expect(store.notebook(notebook.id)?.chats.count == 1)
    }

    @MainActor
    @Test
    func reviewsScheduleCardsAndDueListShrinks() throws {
        let deck = FlashcardDeck(title: "Deck", cards: [
            Flashcard(id: "c1", front: "A", back: "1"),
            Flashcard(id: "c2", front: "B", back: "2")
        ])
        var item = StudioItem(kind: .flashcards, status: .done)
        item.payload = .flashcards(deck)
        let notebook = Notebook(studioItems: [item])
        let store = NotebookStore(persistence: nil, initial: [notebook])

        #expect(store.notebook(notebook.id)?.dueFlashcards().count == 2)
        store.recordReview(cardID: "c1", grade: .good, in: notebook.id)
        #expect(store.notebook(notebook.id)?.dueFlashcards().map(\.id) == ["c2"])
    }

    @Test
    func spacedRepetitionGrowsIntervalsAndResetsOnLapse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var state = FlashcardReviewState.new(cardID: "x", now: now)

        state = SpacedRepetition.review(state, grade: .good, now: now)
        #expect(state.intervalDays == 1)
        state = SpacedRepetition.review(state, grade: .good, now: now)
        #expect(state.intervalDays == 6)
        state = SpacedRepetition.review(state, grade: .good, now: now)
        #expect(state.intervalDays >= 14)

        let lapsed = SpacedRepetition.review(state, grade: .again, now: now)
        #expect(lapsed.repetitions == 0)
        #expect(lapsed.lapses == 1)
        #expect(lapsed.due == now.addingTimeInterval(SpacedRepetition.relearnInterval))
        #expect(lapsed.ease < state.ease)
    }

    @Test
    func citationMarkersBecomeLinksOnlyWhenValid() {
        let text = "Plants make sugar [1]. Water splits [2, 3]. Ignore [9] and [a](https://x.y)."
        let linked = CitationLinker.linkify(text, validRange: 1...3)

        #expect(linked.contains("[1](cite:1)"))
        #expect(linked.contains("[2](cite:2)\u{2009}[3](cite:3)"))
        #expect(linked.contains("[9]"))
        #expect(!linked.contains("cite:9"))
        #expect(linked.contains("[a](https://x.y)"))
        #expect(CitationLinker.referencedIndexes(in: text) == [1, 2, 3, 9])
        #expect(CitationLinker.citationIndex(from: URL(string: "cite:12")!) == 12)
    }

    @Test
    func sanitizeTidiesTitlesAndDropsEmptyCancelledItems() {
        var kept = StudioItem(kind: .summary, status: .cancelled)
        kept.markdown = "Partial summary"
        let notebook = Notebook(
            title: "Material  de   estudio ",
            studioItems: [StudioItem(kind: .beginnerExplanation, status: .cancelled), kept, StudioItem(kind: .quiz, status: .done)]
        )

        let sanitized = NotebookPersistence.sanitize(notebook)

        #expect(sanitized.title == "Material de estudio")
        #expect(sanitized.studioItems.map(\.kind) == [.summary, .quiz])
    }

    @Test
    func citationRangesBecomeSingleLinks() {
        let text = "Gas exchange [2–4]. Cells [5-6; 1]. Out of range [3–9]."
        let linked = CitationLinker.linkify(text, validRange: 1...6)

        #expect(linked.contains("[2–4](cite:2)"))
        #expect(linked.contains("[5–6](cite:5)\u{2009}[1](cite:1)"))
        #expect(linked.contains("[3–9]."))
        #expect(CitationLinker.referencedIndexes(in: "[2–4] [1]") == [2, 3, 4, 1])
    }

    @Test
    func retrievalQueryCarriesContextForShortFollowUps() {
        let previous = StudyTurn(user: StudyTurnUser(focus: "Explain the Calvin cycle", resourceKind: .ask, sources: [], isRefinement: false))

        #expect(ChatContextPlanner.retrievalQuery(question: "why?", history: [previous]) == "Explain the Calvin cycle why?")
        #expect(ChatContextPlanner.retrievalQuery(question: "How does RuBisCO bind oxygen during photorespiration?", history: [previous])
            == "How does RuBisCO bind oxygen during photorespiration?")
    }

    @Test
    func chatInstructionsEmbedExcerptsOnlyInFullNotebookMode() {
        let full = ChatContextPlanner.instructions(notebookTitle: "Bio", sourceNames: ["a.pdf"], excerpts: "[1] a.pdf\nText")
        let retrieval = ChatContextPlanner.instructions(notebookTitle: "Bio", sourceNames: ["a.pdf"], excerpts: nil)

        #expect(full.contains("SOURCE EXCERPTS"))
        #expect(!retrieval.contains("SOURCE EXCERPTS"))
        #expect(retrieval.contains(StudyPromptBuilder.citationInstruction))
    }

    @Test
    func responseLanguageFollowsQuestionThenHistoryThenSources() {
        let spanishSources = "Los pulmones son los órganos principales del sistema respiratorio. Se encuentran en la cavidad torácica y permiten el intercambio de gases entre el aire y la sangre."

        #expect(ResponseLanguage.resolve(question: "Cual es la funcion de los pulmones¿?", sourceText: "") == .spanish)
        #expect(ResponseLanguage.resolve(question: "What do the lungs do in the body?", sourceText: spanishSources) == .english)
        #expect(ResponseLanguage.resolve(question: nil, earlierQuestions: ["Cual es la funcion de los pulmones?"], sourceText: "") == .spanish)
        #expect(ResponseLanguage.resolve(question: "ok", sourceText: spanishSources) == .spanish)
        #expect(ResponseLanguage.instruction(for: .spanish).contains("Spanish"))
    }

    @Test
    func chatInstructionsEndWithAnswerLanguage() {
        let instructions = ChatContextPlanner.instructions(notebookTitle: "Bio", sourceNames: ["a.pdf"], excerpts: "[1] a.pdf\nText", language: .spanish)

        #expect(instructions.hasSuffix(ResponseLanguage.instruction(for: .spanish)))
    }

    @Test
    func structuredPayloadsParseForEveryStudioKind() {
        let mindMap = #"{"title":"Photosynthesis","children":[{"title":"Light reactions","children":[{"title":"Photolysis"}]}]}"#
        let audio = #"{"title":"Episode","lines":[{"speaker":"A","text":"Hi"},{"speaker":"b","text":"Hello"}]}"#
        let quiz = #"{"title":"Q","questions":[{"prompt":"Sky blue?","type":"trueFalse","choices":[],"correctAnswer":"true","explanation":"Rayleigh"}]}"#

        if case .mindMap(let root) = StudyArtifactParser.parse(mindMap, kind: .mindMap) {
            #expect(root.children.first?.children.first?.title == "Photolysis")
            #expect(root.nodeCount == 3)
        } else {
            Issue.record("Mind map should parse")
        }
        if case .audioScript(let script) = StudyArtifactParser.parse(audio, kind: .audioOverview) {
            #expect(script.lines.map(\.speaker) == [.hostA, .hostB])
        } else {
            Issue.record("Audio script should parse")
        }
        if case .quiz(let parsed) = StudyArtifactParser.parse(quiz, kind: .quiz) {
            #expect(parsed.questions.first?.choices == ["True", "False"])
            #expect(parsed.questions.first?.correctAnswer == "True")
        } else {
            Issue.record("Quiz should parse")
        }
    }

    @Test
    func everyStructuredKindHasAValidJSONSchema() throws {
        for kind in StudyResourceKind.allCases where kind.isInteractive {
            let schema = try #require(kind.jsonSchema)
            let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            #expect(object?["type"] as? String == "object")
        }
        #expect(StudyResourceKind.summary.jsonSchema == nil)
    }

    @Test
    func mindMapLayoutCentersParentsOverChildren() {
        let root = MindMapNode(id: "r", title: "Root", children: [
            MindMapNode(id: "a", title: "A", children: [MindMapNode(id: "a1", title: "A1"), MindMapNode(id: "a2", title: "A2")]),
            MindMapNode(id: "b", title: "B")
        ])

        let layout = MindMapLayout(root: root, collapsed: [])
        let rows = Dictionary(uniqueKeysWithValues: layout.placed.map { ($0.node.id, $0.row) })

        #expect(layout.rows == 3)
        #expect(layout.depth == 2)
        #expect(rows["a"] == 0.5)
        #expect(layout.edges.count == 4)

        let collapsed = MindMapLayout(root: root, collapsed: ["a"])
        #expect(collapsed.rows == 2)
    }

    @Test
    func htmlExtractionKeepsHeadingsAndDropsScripts() {
        let html = """
        <html><head><title>x</title><style>p{}</style></head><body>
        <h1>Cells</h1><p>The cell is the unit&nbsp;of life &amp; growth.</p>
        <script>alert(1)</script><ul><li>Nucleus</li><li>Mitochondria</li></ul>
        </body></html>
        """

        let text = MarkupTextExtractor.plainText(fromHTML: html)

        #expect(text.contains("# Cells"))
        #expect(text.contains("The cell is the unit of life & growth."))
        #expect(text.contains("- Nucleus"))
        #expect(!text.contains("alert"))
        #expect(!text.contains("<"))
    }

    @Test
    func sourceTitlesComeFromFilenames() {
        #expect(SourceLibrary.title(fromFilename: "intro_to-economics.pdf") == "intro to economics")
        #expect(SourceLibrary.title(fromFilename: ".pdf") == "Untitled notebook")
        #expect(SourceLibrary.title(fromFilename: "Material - Examen  Final.pdf") == "Material – Examen Final")
    }

    @Test
    func studioExportRendersStructuredItemsAsMarkdown() {
        var item = StudioItem(kind: .flashcards, status: .done)
        item.payload = .flashcards(FlashcardDeck(title: "Deck", cards: [Flashcard(front: "ATP", back: "Energy")]))

        #expect(StudioExport.markdown(for: item) == "# Deck\n\n- **ATP** — Energy\n")
    }

    @Test
    func thinkingTemplatesRenderHistoryLikeTheGenerationPrompt() {
        let template = "{%- if enable_thinking is defined %}{%- endif %}{%- if loop.index0 > ns.last_query_index %}think{%- else %}plain{%- endif %}"

        let patched = ChatTemplatePatcher.stableHistoryTemplate(from: template)

        #expect(patched?.contains("{%- if true %}") == true)
        #expect(ChatTemplatePatcher.stableHistoryTemplate(from: "{{ messages }}") == nil)
        #expect(ChatTemplatePatcher.disablesThinking(["enable_thinking": false]))
        #expect(!ChatTemplatePatcher.disablesThinking(nil))
    }
}
