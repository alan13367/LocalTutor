//
//  AudioOverviewView.swift
//  LocalTutor
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudioOverviewView: View {
    let script: AudioScript
    let itemID: UUID

    @State private var player = AudioOverviewPlayer()
    @State private var voices = AudioOverviewPlayer.availableVoices()
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(script.lines.enumerated()), id: \.element.id) { index, line in
                            AudioLineRow(line: line, isCurrent: player.currentLineIndex == index)
                                .id(index)
                                .onTapGesture { player.play(script, from: index) }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: player.currentLineIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .onDisappear { player.stop() }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var controls: some View {
        @Bindable var player = player
        return HStack(spacing: 14) {
            Button {
                player.skip(by: -1)
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.glass)
            .disabled(!player.isPlaying)
            .accessibilityLabel("Previous line")

            Button {
                if player.isPlaying {
                    player.togglePause()
                } else {
                    player.play(script)
                }
            } label: {
                Image(systemName: player.isPlaying && !player.isPaused ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying && !player.isPaused ? "Pause" : "Play")

            Button {
                player.skip(by: 1)
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.glass)
            .disabled(!player.isPlaying)
            .accessibilityLabel("Next line")

            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("≈ \(script.estimatedMinutes) min · \(script.lines.count) lines · on-device voices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Host A", selection: $player.voiceAID) {
                ForEach(voices) { Text($0.label).tag($0.id) }
            }
            .frame(maxWidth: 190)
            Picker("Host B", selection: $player.voiceBID) {
                ForEach(voices) { Text($0.label).tag($0.id) }
            }
            .frame(maxWidth: 190)

            Slider(value: $player.rate, in: 0.38...0.6) {
                Text("Speed")
            }
            .frame(width: 90)
            .help("Speaking rate")

            Button {
                export()
            } label: {
                if player.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .buttonStyle(.glass)
            .disabled(player.isExporting)
            .help("Save as audio file")
            .accessibilityLabel("Save as audio file")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "caf") ?? .audio]
        panel.nameFieldStringValue = "\(script.title).caf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await player.export(script, to: url)
                } catch {
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

private struct AudioLineRow: View {
    let line: AudioLine
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(line.speaker == .hostA ? "A" : "B")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(line.speaker == .hostA ? Color.accentColor : Color.purple))
                .accessibilityLabel(line.speaker == .hostA ? "Host A" : "Host B")
            Text(line.text)
                .font(.body)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}
