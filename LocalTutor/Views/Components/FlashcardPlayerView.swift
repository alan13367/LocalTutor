//
//  FlashcardPlayerView.swift
//  LocalTutor
//

import SwiftUI

struct FlashcardPlayerView: View {
    let title: String
    let cards: [Flashcard]
    let reviewStates: [String: FlashcardReviewState]
    var onGrade: (String, ReviewGrade) -> Void

    @State private var queue: [Flashcard] = []
    @State private var isFlipped = false
    @State private var reviewed = 0
    @State private var gradeCounts: [ReviewGrade: Int] = [:]
    @State private var started = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let card = queue.first {
                FlashcardFace(card: card, isFlipped: isFlipped)
                    .frame(minHeight: 240)
                    .contentShape(Rectangle())
                    .onTapGesture { flip() }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(isFlipped ? "Grade this card" : "Flip to see the answer")
                controls(for: card)
            } else if started {
                results
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            flip()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard isFlipped, let card = queue.first,
                  let grade = ReviewGrade.allCases.first(where: { String($0.keyboardKey) == press.characters }) else {
                return .ignored
            }
            record(card, grade)
            return .handled
        }
        .onAppear {
            if !started {
                queue = cards
                started = true
            }
            isFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(queue.isEmpty ? "Session complete" : "\(queue.count) left · \(reviewed) reviewed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Space to flip · 1–4 to grade")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: Double(reviewed), total: Double(max(1, reviewed + queue.count)))
                .tint(Color.accentColor)
        }
    }

    @ViewBuilder
    private func controls(for card: Flashcard) -> some View {
        if isFlipped {
            let state = reviewStates[card.id] ?? .new(cardID: card.id)
            HStack(spacing: 8) {
                ForEach(ReviewGrade.allCases) { grade in
                    Button {
                        record(card, grade)
                    } label: {
                        VStack(spacing: 2) {
                            Text(grade.title)
                                .font(.callout.weight(.semibold))
                            Text(SpacedRepetition.intervalDescription(for: state, grade: grade))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .tint(tint(for: grade))
                    .accessibilityLabel("\(grade.title), next review in \(SpacedRepetition.intervalDescription(for: state, grade: grade))")
                }
            }
        } else {
            Button {
                flip()
            } label: {
                Text("Show Answer")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var results: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Nice work: \(reviewed) review\(reviewed == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
            HStack(spacing: 14) {
                ForEach(ReviewGrade.allCases) { grade in
                    Label("\(gradeCounts[grade, default: 0]) \(grade.title)", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(tint(for: grade))
                }
            }
            Text("Cards are scheduled for future review automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Practice Again") {
                queue = cards
                reviewed = 0
                gradeCounts = [:]
                isFlipped = false
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func flip() {
        guard !queue.isEmpty else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            isFlipped.toggle()
        }
    }

    private func record(_ card: Flashcard, _ grade: ReviewGrade) {
        onGrade(card.id, grade)
        reviewed += 1
        gradeCounts[grade, default: 0] += 1
        queue.removeFirst()
        if grade == .again {
            queue.append(card)
        }
        isFlipped = false
    }

    private func tint(for grade: ReviewGrade) -> Color {
        switch grade {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}

private struct FlashcardFace: View {
    let card: Flashcard
    let isFlipped: Bool

    var body: some View {
        ZStack {
            face(text: card.front, kind: "Question")
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 0 : 1)
            face(text: card.back, kind: "Answer")
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
    }

    private func face(text: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 0)
            Text(InlineLatexRenderer.render(text))
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.08)), in: .rect(cornerRadius: 20))
    }
}
