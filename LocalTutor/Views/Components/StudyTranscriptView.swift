//
//  StudyTranscriptView.swift
//  LocalTutor
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudyTranscriptView: View {
    @ObservedObject var viewModel: StudyWorkspaceViewModel
    var onAttach: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if viewModel.turns.isEmpty {
                        EmptyStateHero(viewModel: viewModel, onAttach: onAttach)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ForEach(viewModel.turns) { turn in
                            StudyArtifactCard(
                                turn: turn,
                                onRegenerate: { viewModel.regenerate(turn: turn) },
                                onCopy: { copy(turn.assistant.markdown) },
                                onExport: { export(turn) }
                            )
                            .id(turn.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if !viewModel.refinementSuggestions.isEmpty {
                            RefinementChips(suggestions: viewModel.refinementSuggestions) { suggestion in
                                viewModel.refine(with: suggestion)
                            }
                            .padding(.top, 4)
                            .id("refinements")
                        }
                    }

                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: viewModel.turns.last?.assistant.markdown) { _, _ in
                // Streaming updates arrive coalesced (~25 fps); scroll without an
                // animation so we don't queue an animation per frame and jank.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.currentSessionID) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func export(_ turn: StudyTurn) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "LocalTutor-\(turn.user.resourceKind.title).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? turn.assistant.markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct EmptyStateHero: View {
    @ObservedObject var viewModel: StudyWorkspaceViewModel
    var onAttach: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 84, height: 84)
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text("Study with your own resources")
                    .font(.title.weight(.semibold))
                Text("Drop files anywhere, or pick a starting point below.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(StudyExamplePrompt.starter) { example in
                    Button {
                        viewModel.applyExample(example)
                    } label: {
                        ExampleTile(example: example)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                Text("Drop study files anywhere in this window")
                Button("Browse files…", action: onAttach)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(
                Capsule().fill(Color.primary.opacity(0.04))
            )
        }
        .padding(.horizontal, 12)
    }
}

private struct ExampleTile: View {
    let example: StudyExamplePrompt

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: example.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(example.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(example.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
