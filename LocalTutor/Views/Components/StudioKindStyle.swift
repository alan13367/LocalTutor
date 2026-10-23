//
//  StudioKindStyle.swift
//  LocalTutor
//

import SwiftUI

extension StudyResourceKind {
    var tint: Color {
        switch self {
        case .ask: .accentColor
        case .studyGuide: .blue
        case .briefing: .indigo
        case .summary: .teal
        case .beginnerExplanation: .orange
        case .cheatSheet: .red
        case .flashcards: .pink
        case .quiz: .green
        case .mindMap: .cyan
        case .audioOverview: .purple
        }
    }
}

enum StudioStyle {
    static let noteTint = Color.brown
    static let noteSymbol = "note.text"
    static let reviewTint = StudyResourceKind.flashcards.tint
    static let reviewSymbol = "calendar.badge.clock"
}

struct StudioBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28
    var isWorking = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(tint.gradient)
                    .shadow(color: tint.opacity(size > 36 ? 0.35 : 0), radius: 8, y: 3)
            )
            .accessibilityHidden(true)
    }
}
