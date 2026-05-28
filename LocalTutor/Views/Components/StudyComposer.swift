//
//  StudyComposer.swift
//  LocalTutor
//

import SwiftUI

struct StudyComposer: View {
    @ObservedObject var viewModel: StudyWorkspaceViewModel
    var onAttach: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kindPicker
            mainBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
    }

    private var kindPicker: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Create")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Text(viewModel.selectedResource.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(StudyResourceKind.allCases) { kind in
                        KindPill(
                            kind: kind,
                            isSelected: viewModel.selectedResource == kind
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                viewModel.selectedResource = kind
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 1)
            }
        }
    }

    private var mainBar: some View {
        HStack(alignment: .center, spacing: 10) {
            attachButton

            TextField(viewModel.selectedResource.composerPlaceholder, text: $viewModel.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isFocused)
                .onSubmit { submit() }
                .onAppear { isFocused = true }
                .frame(minHeight: 34)

            sendButton
        }
    }

    private var attachButton: some View {
        Button(action: onAttach) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                if !viewModel.sources.isEmpty {
                    Text("\(viewModel.sources.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(viewModel.sources.isEmpty ? "Attach files" : "\(viewModel.sources.count) attached — manage in the sidebar")
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isRunning {
            Button {
                viewModel.cancel()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(Color.red.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop")
        } else {
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(viewModel.canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canSend)
            .help("Send (⌘↩)")
        }
    }

    private func submit() {
        guard viewModel.canSend else { return }
        viewModel.send()
    }
}

private struct KindPill: View {
    let kind: StudyResourceKind
    let isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.title)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background)
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.2 : 0.5)
            )
            .foregroundStyle(foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Create a \(kind.title.lowercased())")
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var background: some View {
        Capsule().fill(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.08 : 0.05))
        )
    }

    private var borderColor: Color {
        isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07)
    }

    private var foregroundColor: Color {
        isSelected ? Color.accentColor : Color.primary
    }
}
