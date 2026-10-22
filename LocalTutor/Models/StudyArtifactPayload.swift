//
//  StudyArtifactPayload.swift
//  LocalTutor
//
//  Strict JSON contracts for interactive study artifacts (quiz, flashcards),
//  plus a forgiving parser that extracts the JSON object from a model response.
//

import Foundation

enum StudyArtifactPayload: Equatable, Codable {
    case quiz(QuizArtifact)
    case flashcards(FlashcardDeck)
    case mindMap(MindMapNode)
    case audioScript(AudioScript)

    private enum CodingKeys: String, CodingKey {
        case kind, quiz, flashcards, mindMap, audioScript
    }

    private enum Kind: String, Codable {
        case quiz, flashcards, mindMap, audioScript
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quiz(let artifact):
            try container.encode(Kind.quiz, forKey: .kind)
            try container.encode(artifact, forKey: .quiz)
        case .flashcards(let deck):
            try container.encode(Kind.flashcards, forKey: .kind)
            try container.encode(deck, forKey: .flashcards)
        case .mindMap(let root):
            try container.encode(Kind.mindMap, forKey: .kind)
            try container.encode(root, forKey: .mindMap)
        case .audioScript(let script):
            try container.encode(Kind.audioScript, forKey: .kind)
            try container.encode(script, forKey: .audioScript)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .quiz:
            self = .quiz(try container.decode(QuizArtifact.self, forKey: .quiz))
        case .flashcards:
            self = .flashcards(try container.decode(FlashcardDeck.self, forKey: .flashcards))
        case .mindMap:
            self = .mindMap(try container.decode(MindMapNode.self, forKey: .mindMap))
        case .audioScript:
            self = .audioScript(try container.decode(AudioScript.self, forKey: .audioScript))
        }
    }

    var itemCountDescription: String {
        switch self {
        case .quiz(let quiz):
            "\(quiz.questions.count) question\(quiz.questions.count == 1 ? "" : "s")"
        case .flashcards(let deck):
            "\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")"
        case .mindMap(let root):
            "\(root.children.count) branch\(root.children.count == 1 ? "" : "es")"
        case .audioScript(let script):
            "≈ \(script.estimatedMinutes) min"
        }
    }
}

// MARK: - Mind map

struct MindMapNode: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var children: [MindMapNode]

    init(id: String = UUID().uuidString, title: String, children: [MindMapNode] = []) {
        self.id = id
        self.title = title
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        children = (try? c.decode([MindMapNode].self, forKey: .children)) ?? []
    }

    var nodeCount: Int {
        1 + children.reduce(0) { $0 + $1.nodeCount }
    }
}

// MARK: - Audio overview

struct AudioScript: Codable, Equatable, Sendable {
    var title: String
    var lines: [AudioLine]

    var estimatedMinutes: Int {
        let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        return max(1, Int((Double(words) / 155).rounded()))
    }
}

struct AudioLine: Codable, Equatable, Identifiable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case hostA = "A"
        case hostB = "B"
    }

    var id: String
    var speaker: Speaker
    var text: String

    init(id: String = UUID().uuidString, speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id, speaker, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let raw = (try? c.decode(String.self, forKey: .speaker)) ?? "A"
        speaker = raw.uppercased().hasPrefix("B") ? .hostB : .hostA
        text = try c.decode(String.self, forKey: .text)
    }
}

// MARK: - Quiz

struct QuizArtifact: Codable, Equatable {
    var title: String?
    var questions: [QuizQuestion]
}

struct QuizQuestion: Codable, Equatable, Identifiable {
    enum QuestionType: String, Codable {
        case multipleChoice
        case trueFalse
        case shortAnswer
    }

    let id: String
    var prompt: String
    var type: QuestionType
    var choices: [String]
    var correctAnswer: String
    var explanation: String?

    init(
        id: String = UUID().uuidString,
        prompt: String,
        type: QuestionType,
        choices: [String] = [],
        correctAnswer: String,
        explanation: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.type = type
        self.choices = choices
        self.correctAnswer = correctAnswer
        self.explanation = explanation
    }

    enum CodingKeys: String, CodingKey {
        case id, prompt, type, choices, correctAnswer, explanation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        prompt = try c.decode(String.self, forKey: .prompt)
        let rawType = (try? c.decode(String.self, forKey: .type)) ?? "multipleChoice"
        type = QuestionType(rawValue: rawType) ?? .multipleChoice
        choices = (try? c.decode([String].self, forKey: .choices)) ?? []
        correctAnswer = (try? c.decode(String.self, forKey: .correctAnswer)) ?? ""
        explanation = try? c.decode(String.self, forKey: .explanation)
    }
}

// MARK: - Flashcards

struct FlashcardDeck: Codable, Equatable {
    var title: String?
    var cards: [Flashcard]
}

struct Flashcard: Codable, Equatable, Identifiable {
    let id: String
    var front: String
    var back: String

    init(id: String = UUID().uuidString, front: String, back: String) {
        self.id = id
        self.front = front
        self.back = back
    }

    enum CodingKeys: String, CodingKey {
        case id, front, back
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        front = try c.decode(String.self, forKey: .front)
        back = try c.decode(String.self, forKey: .back)
    }
}

// MARK: - Structured output contracts

extension StudyResourceKind {
    /// True when this resource kind produces an interactive payload rather than markdown.
    var isInteractive: Bool {
        !producesMarkdown
    }

    var jsonSchema: String? {
        switch self {
        case .quiz:
            return #"{"type":"object","properties":{"title":{"type":"string"},"questions":{"type":"array","minItems":5,"maxItems":10,"items":{"type":"object","properties":{"prompt":{"type":"string"},"type":{"type":"string","enum":["multipleChoice","trueFalse","shortAnswer"]},"choices":{"type":"array","items":{"type":"string"},"maxItems":4},"correctAnswer":{"type":"string"},"explanation":{"type":"string"}},"required":["prompt","type","choices","correctAnswer","explanation"]}}},"required":["title","questions"]}"#
        case .flashcards:
            return #"{"type":"object","properties":{"title":{"type":"string"},"cards":{"type":"array","minItems":6,"maxItems":20,"items":{"type":"object","properties":{"front":{"type":"string"},"back":{"type":"string"}},"required":["front","back"]}}},"required":["title","cards"]}"#
        case .mindMap:
            return #"{"type":"object","properties":{"title":{"type":"string"},"children":{"type":"array","minItems":3,"maxItems":8,"items":{"type":"object","properties":{"title":{"type":"string"},"children":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}}},"required":["title","children"]}}},"required":["title","children"]}"#
        case .audioOverview:
            return #"{"type":"object","properties":{"title":{"type":"string"},"lines":{"type":"array","minItems":10,"maxItems":40,"items":{"type":"object","properties":{"speaker":{"type":"string","enum":["A","B"]},"text":{"type":"string"}},"required":["speaker","text"]}}},"required":["title","lines"]}"#
        default:
            return nil
        }
    }

    /// JSON contract appended to the prompt for structured kinds.
    var jsonSchemaInstruction: String? {
        switch self {
        case .quiz:
            return """
            Return ONLY a single JSON object, no markdown, no commentary, no code fences.
            Schema:
            {
              "title": "Short quiz title",
              "questions": [
                {
                  "prompt": "Question text",
                  "type": "multipleChoice" | "trueFalse" | "shortAnswer",
                  "choices": ["A", "B", "C", "D"],
                  "correctAnswer": "Exact string that matches one of the choices, or the canonical short answer.",
                  "explanation": "One short sentence saying why the correct answer is right."
                }
              ]
            }
            Rules:
            - Produce 5 to 8 questions, mixing types.
            - For "multipleChoice" provide exactly 4 unique choices and set correctAnswer to the exact text of one of them.
            - For "trueFalse" set choices to ["True","False"] and correctAnswer to "True" or "False".
            - For "shortAnswer" set choices to [] and correctAnswer to the expected one- or two-word answer.
            - Every question MUST come directly from the provided source contents — never invent facts.
            """
        case .flashcards:
            return """
            Return ONLY a single JSON object, no markdown, no commentary, no code fences.
            Schema:
            {
              "title": "Short deck title",
              "cards": [
                { "front": "Term, question, or cue.", "back": "Concise definition or answer." }
              ]
            }
            Rules:
            - Produce 8 to 14 cards.
            - Front should be short (a term, question, or prompt).
            - Back should be at most two short sentences.
            - Every card MUST be grounded in the provided source contents — never invent facts.
            """
        case .mindMap:
            return """
            Return ONLY a single JSON object, no markdown, no commentary, no code fences.
            Schema:
            {
              "title": "Central topic (2-5 words)",
              "children": [
                { "title": "Main branch (1-4 words)", "children": [ { "title": "Sub-point (2-8 words)" } ] }
              ]
            }
            Rules:
            - 4 to 7 main branches, each with 2 to 5 sub-points.
            - Keep every label short; no full sentences.
            - Use only ideas from the provided sources.
            """
        case .audioOverview:
            return """
            Return ONLY a single JSON object, no markdown, no commentary, no code fences.
            Schema:
            {
              "title": "Episode title",
              "lines": [ { "speaker": "A" | "B", "text": "What this host says." } ]
            }
            Rules:
            - 16 to 30 lines, alternating speakers naturally. Host A guides and asks; Host B explains.
            - Spoken style: short sentences, no markdown, no bullet points, no URLs, no LaTeX.
            - Every fact must come from the provided sources.
            """
        default:
            return nil
        }
    }
}

// MARK: - Parser

enum StudyArtifactParser {
    static func parse(_ raw: String, kind: StudyResourceKind) -> StudyArtifactPayload? {
        guard let data = extractJSONData(from: raw) else { return nil }
        let decoder = JSONDecoder()
        switch kind {
        case .quiz:
            if var quiz = try? decoder.decode(QuizArtifact.self, from: data),
               !quiz.questions.isEmpty {
                quiz.questions = quiz.questions.map(normalized)
                return .quiz(quiz)
            }
        case .flashcards:
            if let deck = try? decoder.decode(FlashcardDeck.self, from: data),
               !deck.cards.isEmpty {
                return .flashcards(deck)
            }
        case .mindMap:
            if let root = try? decoder.decode(MindMapNode.self, from: data),
               !root.children.isEmpty {
                return .mindMap(root)
            }
        case .audioOverview:
            if let script = try? decoder.decode(AudioScript.self, from: data),
               !script.lines.isEmpty {
                return .audioScript(script)
            }
        default:
            break
        }
        return nil
    }

    private static func normalized(_ question: QuizQuestion) -> QuizQuestion {
        var question = question
        switch question.type {
        case .trueFalse:
            question.choices = ["True", "False"]
            let answer = question.correctAnswer.lowercased()
            question.correctAnswer = answer.hasPrefix("t") ? "True" : "False"
        case .multipleChoice:
            if question.choices.isEmpty {
                question.type = .shortAnswer
            } else if !question.choices.contains(question.correctAnswer),
                      let match = question.choices.first(where: {
                          $0.localizedCaseInsensitiveCompare(question.correctAnswer) == .orderedSame
                      }) {
                question.correctAnswer = match
            }
        case .shortAnswer:
            question.choices = []
        }
        return question
    }

    /// Pulls the outermost balanced `{...}` JSON object out of a string, tolerating
    /// leading prose, code fences, or trailing junk.
    static func extractJSONData(from raw: String) -> Data? {
        let trimmed = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startIdx = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var endIdx: String.Index?

        var idx = startIdx
        while idx < trimmed.endIndex {
            let c = trimmed[idx]
            if escape {
                escape = false
            } else if c == "\\" && inString {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIdx = idx
                        break
                    }
                }
            }
            idx = trimmed.index(after: idx)
        }

        guard let end = endIdx else { return nil }
        let jsonString = String(trimmed[startIdx...end])
        return jsonString.data(using: .utf8)
    }
}
