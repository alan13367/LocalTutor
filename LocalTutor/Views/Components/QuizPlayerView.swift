//
//  QuizPlayerView.swift
//  LocalTutor
//
//  Interactive quiz session driven by a QuizArtifact.
//

import SwiftUI

struct QuizPlayerView: View {
    let quiz: QuizArtifact

    @State private var currentIndex = 0
    @State private var selectedAnswers: [String: String] = [:]
    @State private var revealed: Set<String> = []
    @State private var shortAnswerDrafts: [String: String] = [:]
    @State private var showResults = false

    private var question: QuizQuestion? {
        guard !quiz.questions.isEmpty, currentIndex < quiz.questions.count else { return nil }
        return quiz.questions[currentIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if showResults {
                resultsView
            } else if let question {
                questionBody(question)
                Spacer(minLength: 4)
                controls(question: question)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quiz.title ?? "Quiz")
                        .font(.headline)
                    if !showResults {
                        Text("Question \(min(currentIndex + 1, quiz.questions.count)) of \(quiz.questions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Final score")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                scoreBadge
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
    }

    private var progressFraction: Double {
        guard !quiz.questions.isEmpty else { return 0 }
        if showResults { return 1 }
        let completed = Double(revealed.count)
        return completed / Double(quiz.questions.count)
    }

    private var scoreBadge: some View {
        let correct = quiz.questions.filter { isCorrect(question: $0) && revealed.contains($0.id) }.count
        let answered = revealed.count
        return Text("\(correct)/\(quiz.questions.count)")
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(answered == 0 ? 0.08 : 0.16)))
            .foregroundStyle(Color.accentColor)
    }

    // MARK: Question

    @ViewBuilder
    private func questionBody(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            switch question.type {
            case .multipleChoice, .trueFalse:
                choiceList(question)
            case .shortAnswer:
                shortAnswerField(question)
            }

            if revealed.contains(question.id), let explanation = question.explanation, !explanation.isEmpty {
                explanationBox(explanation, correct: isCorrect(question: question))
            }
        }
    }

    private func choiceList(_ question: QuizQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { idx, choice in
                choiceRow(question: question, choice: choice, index: idx)
            }
        }
    }

    private func choiceRow(question: QuizQuestion, choice: String, index: Int) -> some View {
        let isSelected = selectedAnswers[question.id] == choice
        let isRevealed = revealed.contains(question.id)
        let isCorrectChoice = matches(choice, question.correctAnswer)
        let isWrongPick = isRevealed && isSelected && !isCorrectChoice

        return Button {
            guard !isRevealed else { return }
            selectedAnswers[question.id] = choice
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(letter(for: index))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06)))
                Text(choice)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRevealed && isCorrectChoice {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if isWrongPick {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(rowBackground(isSelected: isSelected, revealed: isRevealed, correct: isCorrectChoice, wrong: isWrongPick))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(rowStroke(isSelected: isSelected, revealed: isRevealed, correct: isCorrectChoice, wrong: isWrongPick), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isRevealed)
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, revealed: Bool, correct: Bool, wrong: Bool) -> some View {
        if revealed && correct {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green.opacity(0.12))
        } else if wrong {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.12))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.10))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04))
        }
    }

    private func rowStroke(isSelected: Bool, revealed: Bool, correct: Bool, wrong: Bool) -> Color {
        if revealed && correct { return Color.green.opacity(0.55) }
        if wrong { return Color.red.opacity(0.55) }
        if isSelected { return Color.accentColor.opacity(0.55) }
        return Color.primary.opacity(0.08)
    }

    private func shortAnswerField(_ question: QuizQuestion) -> some View {
        let revealed = revealed.contains(question.id)
        let draftBinding = Binding<String>(
            get: { shortAnswerDrafts[question.id] ?? "" },
            set: { shortAnswerDrafts[question.id] = $0 }
        )
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Type your answer", text: draftBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .disabled(revealed)

            if revealed {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text("Expected: \(question.correctAnswer)")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func explanationBox(_ explanation: String, correct: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: correct ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(correct ? Color.green : Color.accentColor)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: Controls

    private func controls(question: QuizQuestion) -> some View {
        HStack {
            Button {
                guard currentIndex > 0 else { return }
                currentIndex -= 1
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(currentIndex == 0)

            Spacer()

            if revealed.contains(question.id) {
                Button {
                    advance()
                } label: {
                    Label(isLast ? "See results" : "Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    submit(question: question)
                } label: {
                    Text("Check answer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit(question: question))
            }
        }
    }

    private var isLast: Bool {
        currentIndex == quiz.questions.count - 1
    }

    private func canSubmit(question: QuizQuestion) -> Bool {
        switch question.type {
        case .multipleChoice, .trueFalse:
            return selectedAnswers[question.id] != nil
        case .shortAnswer:
            return !(shortAnswerDrafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit(question: QuizQuestion) {
        revealed.insert(question.id)
    }

    private func advance() {
        if isLast {
            showResults = true
        } else {
            currentIndex += 1
        }
    }

    // MARK: Results

    private var resultsView: some View {
        let correct = quiz.questions.filter { isCorrect(question: $0) }.count
        let total = quiz.questions.count
        let percent = total > 0 ? Int(round(Double(correct) / Double(total) * 100)) : 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 56, height: 56)
                    Text("\(percent)%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nice work")
                        .font(.title3.weight(.semibold))
                    Text("\(correct) of \(total) correct")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    restart()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { idx, q in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isCorrect(question: q) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isCorrect(question: q) ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Q\(idx + 1). \(q.prompt)")
                                .font(.callout.weight(.medium))
                            Text("Answer: \(q.correctAnswer)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func restart() {
        selectedAnswers.removeAll()
        revealed.removeAll()
        shortAnswerDrafts.removeAll()
        showResults = false
        currentIndex = 0
    }

    // MARK: Helpers

    private func isCorrect(question: QuizQuestion) -> Bool {
        switch question.type {
        case .multipleChoice, .trueFalse:
            guard let answer = selectedAnswers[question.id] else { return false }
            return matches(answer, question.correctAnswer)
        case .shortAnswer:
            let draft = shortAnswerDrafts[question.id] ?? ""
            return matches(draft, question.correctAnswer)
        }
    }

    private func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    private func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private func letter(for index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "•" }
        return String(scalar)
    }
}
