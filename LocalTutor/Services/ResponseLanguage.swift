//
//  ResponseLanguage.swift
//  LocalTutor
//

import Foundation
import NaturalLanguage

enum ResponseLanguage {
    static let sampleCharacterLimit = 4_000

    static func detect(_ text: String, minimumLetters: Int = 12, minimumConfidence: Double = 0.6) -> NLLanguage? {
        let sample = String(text.prefix(sampleCharacterLimit))
        guard sample.unicodeScalars.filter(CharacterSet.letters.contains).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined,
              confidence >= minimumConfidence else {
            return nil
        }
        return language
    }

    static func resolve(question: String?, earlierQuestions: [String] = [], sourceText: String) -> NLLanguage? {
        if let question, let language = detect(question) {
            return language
        }
        for earlier in earlierQuestions.reversed() {
            if let language = detect(earlier) {
                return language
            }
        }
        return detect(sourceText, minimumLetters: 40, minimumConfidence: 0.5)
    }

    static func sourceSample(_ texts: [String]) -> String {
        var sample = ""
        for text in texts {
            guard sample.count < sampleCharacterLimit else { break }
            sample += text + "\n"
        }
        return sample
    }

    static func name(of language: NLLanguage) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    }

    static func instruction(for language: NLLanguage?) -> String {
        guard let language else {
            return "Answer language: reply in the same language as the student's question."
        }
        let name = name(of: language)
        return "Answer language: write all student-facing text in \(name), even though these instructions are in English."
    }
}
