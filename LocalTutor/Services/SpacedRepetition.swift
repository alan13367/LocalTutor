//
//  SpacedRepetition.swift
//  LocalTutor
//

import Foundation

enum ReviewGrade: Int, CaseIterable, Identifiable, Sendable {
    case again = 1
    case hard = 3
    case good = 4
    case easy = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }

    var keyboardKey: Character {
        switch self {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }
}

enum SpacedRepetition {
    static let relearnInterval: TimeInterval = 10 * 60

    static func review(
        _ state: FlashcardReviewState,
        grade: ReviewGrade,
        now: Date = Date()
    ) -> FlashcardReviewState {
        var next = state
        next.lastReviewed = now

        let quality = Double(grade.rawValue)
        let easeDelta = 0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02)
        next.ease = max(1.3, state.ease + easeDelta)

        if grade == .again {
            next.repetitions = 0
            next.lapses += 1
            next.intervalDays = 0
            next.due = now.addingTimeInterval(relearnInterval)
            return next
        }

        next.repetitions += 1
        let interval: Double
        switch next.repetitions {
        case 1:
            interval = grade == .easy ? 3 : 1
        case 2:
            interval = grade == .hard ? 3 : 6
        default:
            let multiplier = grade == .hard ? 1.2 : (grade == .easy ? next.ease * 1.3 : next.ease)
            interval = max(state.intervalDays + 1, state.intervalDays * multiplier)
        }
        next.intervalDays = interval.rounded()
        next.due = now.addingTimeInterval(next.intervalDays * 86_400)
        return next
    }

    static func intervalDescription(for state: FlashcardReviewState, grade: ReviewGrade, now: Date = Date()) -> String {
        let next = review(state, grade: grade, now: now)
        let seconds = next.due.timeIntervalSince(now)
        if seconds < 3_600 {
            return "\(max(1, Int(seconds / 60)))m"
        }
        let days = Int((seconds / 86_400).rounded())
        if days < 30 {
            return "\(days)d"
        }
        return "\(Int((Double(days) / 30).rounded()))mo"
    }
}
