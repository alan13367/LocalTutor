//
//  FlashcardPlayerView.swift
//  LocalTutor
//
//  Interactive flashcard deck powered by a FlashcardDeck payload.
//

import SwiftUI

struct FlashcardPlayerView: View {
    let deck: FlashcardDeck

    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var known: Set<String> = []
    @State private var againPile: [String] = []
    @State private var sessionFinished = false

    private var orderedCards: [Flashcard] { deck.cards }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if sessionFinished {
                resultsView
            } else if !orderedCards.isEmpty {
                cardView
                controls
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deck.title ?? "Flashcards")
                        .font(.headline)
                    if !sessionFinished {
                        Text("Card \(min(currentIndex + 1, orderedCards.count)) of \(orderedCards.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Label("\(known.count)", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                    Label("\(againPile.count)", systemImage: "arrow.uturn.left")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
    }

    private var progressFraction: Double {
        guard !orderedCards.isEmpty else { return 0 }
        if sessionFinished { return 1 }
        return Double(known.count + againPile.count) / Double(orderedCards.count)
    }

    private var card: Flashcard? {
        guard !orderedCards.isEmpty, currentIndex < orderedCards.count else { return nil }
        return orderedCards[currentIndex]
    }

    @ViewBuilder
    private var cardView: some View {
        if let card {
            FlashcardFace(card: card, isFlipped: isFlipped)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 220)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        isFlipped.toggle()
                    }
                }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if !isFlipped {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        isFlipped = true
                    }
                } label: {
                    Label("Show answer", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    grade(known: false)
                } label: {
                    Label("Again", systemImage: "arrow.uturn.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button {
                    grade(known: true)
                } label: {
                    Label("Got it", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 56, height: 56)
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session complete")
                        .font(.title3.weight(.semibold))
                    Text("\(known.count) of \(orderedCards.count) marked as known")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    restart(onlyAgain: false)
                } label: {
                    Label("Restart deck", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                if !againPile.isEmpty {
                    Button {
                        restart(onlyAgain: true)
                    } label: {
                        Label("Drill missed (\(againPile.count))", systemImage: "flame")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Actions

    private func grade(known isKnown: Bool) {
        guard let card else { return }
        if isKnown {
            known.insert(card.id)
            againPile.removeAll { $0 == card.id }
        } else {
            if !againPile.contains(card.id) { againPile.append(card.id) }
        }
        advance()
    }

    private func advance() {
        if currentIndex >= orderedCards.count - 1 {
            sessionFinished = true
        } else {
            currentIndex += 1
            withAnimation(.easeInOut(duration: 0.18)) {
                isFlipped = false
            }
        }
    }

    private func restart(onlyAgain: Bool) {
        if onlyAgain {
            let drillIDs = Set(againPile)
            // Move the again pile to the front of the iteration order.
            let drillCards = deck.cards.filter { drillIDs.contains($0.id) }
            // We just iterate them directly by resetting state to start over.
            // Replace order by simulating a "filtered deck" via known seeding.
            known = Set(deck.cards.map(\.id)).subtracting(drillIDs)
            againPile = []
            currentIndex = deck.cards.firstIndex(where: { drillIDs.contains($0.id) }) ?? 0
            // Walk to first drill card that isn't known.
            while currentIndex < deck.cards.count, known.contains(deck.cards[currentIndex].id) {
                currentIndex += 1
            }
            sessionFinished = drillCards.isEmpty
        } else {
            known.removeAll()
            againPile.removeAll()
            currentIndex = 0
            sessionFinished = false
        }
        isFlipped = false
    }
}

private struct FlashcardFace: View {
    let card: Flashcard
    let isFlipped: Bool

    var body: some View {
        ZStack {
            face(text: card.front, kind: "Front", visible: !isFlipped)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 0 : 1)
            face(text: card.back, kind: "Back", visible: isFlipped)
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isFlipped)
    }

    private func face(text: String, kind: String, visible _: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 0)
            Text(text)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text("Tap to flip")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}
