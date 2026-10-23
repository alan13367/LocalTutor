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
    var tint: Color = .accentColor

    @State private var player = AudioOverviewPlayer()
    @State private var voices = AudioOverviewPlayer.availableVoices()
    @State private var exportError: String?
    @State private var showsVoiceSettings = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    playerCard
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(script.lines.enumerated()), id: \.element.id) { index, line in
                            AudioLineRow(
                                line: line,
                                tint: speakerTint(line.speaker),
                                isCurrent: player.currentLineIndex == index
                            )
                            .id(index)
                            .onTapGesture { player.play(script, from: index) }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
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
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
        .onAppear { isFocused = true }
        .onDisappear { player.stop() }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var isSpeaking: Bool {
        player.isPlaying && !player.isPaused
    }

    private func speakerTint(_ speaker: AudioLine.Speaker) -> Color {
        speaker == .hostA ? tint : .orange
    }

    // MARK: Player

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button(action: togglePlayback) {
                    Image(systemName: isSpeaking ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(tint)
                .help(isSpeaking ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(isSpeaking ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying)
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text("≈ \(script.estimatedMinutes) min · \(script.lines.count) lines · on-device voices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    StageIconButton(title: "Previous line", systemImage: "backward.fill") { player.skip(by: -1) }
                        .disabled(!player.isPlaying)
                    StageIconButton(title: "Next line", systemImage: "forward.fill") { player.skip(by: 1) }
                        .disabled(!player.isPlaying)
                    StageIconButton(title: "Voices and speed", systemImage: "slider.horizontal.3") {
                        showsVoiceSettings.toggle()
                    }
                    .popover(isPresented: $showsVoiceSettings, arrowEdge: .bottom) {
                        voiceSettings
                    }
                    exportButton
                }
            }

            AudioScrubber(
                lines: script.lines,
                currentIndex: player.currentLineIndex,
                tint: speakerTint
            ) { index in
                player.play(script, from: index)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 22))
    }

    private var nowPlaying: String {
        guard let index = player.currentLineIndex, script.lines.indices.contains(index) else {
            return "Two hosts talk through your sources"
        }
        let speaker = script.lines[index].speaker == .hostA ? "Host A" : "Host B"
        return player.isPaused ? "Paused · line \(index + 1)" : "\(speaker) is speaking · line \(index + 1)"
    }

    private var voiceSettings: some View {
        @Bindable var player = player
        return Form {
            Picker("Host A", selection: $player.voiceAID) {
                ForEach(voices) { Text($0.label).tag($0.id) }
            }
            Picker("Host B", selection: $player.voiceBID) {
                ForEach(voices) { Text($0.label).tag($0.id) }
            }
            Slider(value: $player.rate, in: 0.38...0.6) {
                Text("Speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise")
            } maximumValueLabel: {
                Image(systemName: "hare")
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }

    @ViewBuilder
    private var exportButton: some View {
        if player.isExporting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 40, height: 40)
        } else {
            StageIconButton(title: "Save as audio file", systemImage: "square.and.arrow.down", action: export)
        }
    }

    private func togglePlayback() {
        if player.isPlaying {
            player.togglePause()
        } else {
            player.play(script)
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

private struct AudioScrubber: View {
    let lines: [AudioLine]
    let currentIndex: Int?
    let tint: (AudioLine.Speaker) -> Color
    var onSelect: (Int) -> Void

    var body: some View {
        let longest = max(1, lines.map(\.text.count).max() ?? 1)
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let played = currentIndex.map { index <= $0 } ?? false
                Capsule()
                    .fill(tint(line.speaker).opacity(played ? 1 : 0.3))
                    .frame(height: 8 + 26 * CGFloat(line.text.count) / CGFloat(longest))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .scaleEffect(y: index == currentIndex ? 1.15 : 1)
                    .onTapGesture { onSelect(index) }
                    .help("Line \(index + 1)")
            }
        }
        .frame(height: 38)
        .animation(.easeOut(duration: 0.25), value: currentIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Script progress")
        .accessibilityValue(currentIndex.map { "Line \($0 + 1) of \(lines.count)" } ?? "Not playing")
    }
}

private struct AudioLineRow: View {
    let line: AudioLine
    let tint: Color
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(line.speaker == .hostA ? "A" : "B")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.gradient))
                .accessibilityLabel(line.speaker == .hostA ? "Host A" : "Host B")
            VStack(alignment: .leading, spacing: 3) {
                Text(line.speaker == .hostA ? "Host A" : "Host B")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? tint.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}
