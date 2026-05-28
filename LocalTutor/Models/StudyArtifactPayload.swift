//
//  StudyArtifactPayload.swift
//  LocalTutor
//
//  Strict JSON contracts for interactive study artifacts (quiz, flashcards),
//  plus a forgiving parser that extracts the JSON object from a model response.
//

import Foundation

enum StudyArtifactPayload: Equatable {
    case quiz(QuizArtifact)
    case flashcards(FlashcardDeck)
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

// MARK: - JSON schema instructions

extension StudyResourceKind {
    /// True when this resource kind produces an interactive payload rather than markdown.
    var isInteractive: Bool {
        switch self {
        case .quiz, .flashcards: true
        default: false
        }
    }

    /// JSON schema appended to the prompt for interactive kinds. Returns nil for
    /// markdown kinds.
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
                  "id": "q1",
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
            - Output must be valid JSON. Do not wrap it in ``` fences.
            """
        case .flashcards:
            return """
            Return ONLY a single JSON object, no markdown, no commentary, no code fences.
            Schema:
            {
              "title": "Short deck title",
              "cards": [
                { "id": "c1", "front": "Term, question, or cue.", "back": "Concise definition or answer." }
              ]
            }
            Rules:
            - Produce 8 to 14 cards.
            - Front should be short (a term, question, or prompt).
            - Back should be at most two short sentences.
            - Every card MUST be grounded in the provided source contents — never invent facts.
            - Output must be valid JSON. Do not wrap it in ``` fences.
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
            if let quiz = try? decoder.decode(QuizArtifact.self, from: data),
               !quiz.questions.isEmpty {
                return .quiz(quiz)
            }
        case .flashcards:
            if let deck = try? decoder.decode(FlashcardDeck.self, from: data),
               !deck.cards.isEmpty {
                return .flashcards(deck)
            }
        default:
            break
        }
        return nil
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
