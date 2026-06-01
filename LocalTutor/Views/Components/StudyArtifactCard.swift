//
//  StudyArtifactCard.swift
//  LocalTutor
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudyArtifactCard: View {
    let turn: StudyTurn
    var onRegenerate: () -> Void
    var onCopy: () -> Void
    var onExport: () -> Void
    @State private var isThinkingExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            userBubble
            assistantCard
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if turn.user.isRefinement {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: turn.user.resourceKind.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(turn.user.resourceKind.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(turn.user.displayPrompt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                    )
                    .textSelection(.enabled)

                if !turn.user.sources.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                        Text(sourcesLabel)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourcesLabel: String {
        let names = turn.user.sources.prefix(2).map(\.displayName)
        let extra = turn.user.sources.count - names.count
        if extra > 0 {
            return names.joined(separator: ", ") + " + \(extra) more"
        }
        return names.joined(separator: ", ")
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if !thinkingText.isEmpty {
                thinkingPreview
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            bodyContent
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            if case .failed(let message) = turn.assistant.status {
                errorCallout(message)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            footer
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: turn.user.resourceKind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.user.resourceKind.title)
                    .font(.headline)
                Text(turn.assistant.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge
        }
    }

    private var thinkingText: String {
        turn.assistant.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var thinkingCollapsedPreview: String {
        let oneLine = thinkingText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        guard oneLine.count > 110 else { return oneLine }
        return String(oneLine.prefix(110)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private var thinkingPreview: some View {
        DisclosureGroup(isExpanded: $isThinkingExpanded) {
            ScrollView {
                Text(thinkingText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(turn.assistant.status == .streaming && turn.assistant.markdown.isEmpty ? "Thinking" : "Model thinking")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !isThinkingExpanded {
                    Text(thinkingCollapsedPreview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var bodyContent: some View {
        if turn.user.resourceKind.isInteractive {
            interactiveBody
        } else if turn.assistant.markdown.isEmpty && turn.assistant.status == .streaming {
            placeholder
        } else if turn.assistant.markdown.isEmpty && turn.assistant.status.isTerminal && !thinkingText.isEmpty {
            Text("The model produced thinking but no final answer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            MarkdownText(text: turn.assistant.markdown, isStreaming: turn.assistant.status == .streaming)
        }
    }

    @ViewBuilder
    private var interactiveBody: some View {
        switch turn.assistant.payload {
        case .quiz(let quiz):
            QuizPlayerView(quiz: quiz)
        case .flashcards(let deck):
            FlashcardPlayerView(deck: deck)
        case .none:
            if turn.assistant.status.isTerminal && !turn.assistant.markdown.isEmpty {
                fallbackParseFailure
            } else {
                interactivePlaceholder
            }
        }
    }

    private var interactivePlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(turn.assistant.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 14)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var fallbackParseFailure: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The model's response wasn't valid JSON. Tap Regenerate to try again.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            DisclosureGroup("Show raw output") {
                ScrollView {
                    Text(turn.assistant.markdown)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch turn.assistant.status {
        case .streaming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .scaleEffect(1)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15), value: turn.assistant.statusMessage)
            }
            Text(turn.assistant.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func errorCallout(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Spacer()
            if turn.assistant.status.isTerminal && !turn.assistant.markdown.isEmpty {
                if !turn.user.resourceKind.isInteractive {
                    CardActionButton(systemImage: "doc.on.doc", label: "Copy", action: onCopy)
                    CardActionButton(systemImage: "square.and.arrow.down", label: "Export", action: onExport)
                }
                CardActionButton(systemImage: "arrow.clockwise", label: "Regenerate", action: onRegenerate)
            }
        }
    }
}

private struct CardActionButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(label)
    }
}
