//
//  AudioOverviewPlayer.swift
//  LocalTutor
//

import AVFoundation
import Foundation
import Observation

struct AudioVoiceOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var quality: AVSpeechSynthesisVoiceQuality
    var language: String

    var label: String {
        switch quality {
        case .premium: "\(name) (Premium)"
        case .enhanced: "\(name) (Enhanced)"
        default: name
        }
    }
}

@MainActor
@Observable
final class AudioOverviewPlayer: NSObject {
    private(set) var currentLineIndex: Int?
    private(set) var isPlaying = false
    private(set) var isPaused = false
    private(set) var isExporting = false
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voiceAID: String
    var voiceBID: String

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var script: AudioScript?
    @ObservationIgnored private var utteranceLines: [ObjectIdentifier: Int] = [:]

    static func availableVoices() -> [AudioVoiceOption] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
        let pool = voices.isEmpty ? AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") } : voices
        return pool
            .map { AudioVoiceOption(id: $0.identifier, name: $0.name, quality: $0.quality, language: $0.language) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    override init() {
        let voices = Self.availableVoices()
        let storedA = UserDefaults.standard.string(forKey: AppStorageKeys.audioVoiceA)
        let storedB = UserDefaults.standard.string(forKey: AppStorageKeys.audioVoiceB)
        voiceAID = storedA ?? voices.first?.id ?? ""
        voiceBID = storedB ?? voices.dropFirst().first(where: { $0.name != voices.first?.name })?.id ?? voices.first?.id ?? ""
        super.init()
        synthesizer.delegate = self
    }

    func play(_ script: AudioScript, from index: Int = 0) {
        stop()
        self.script = script
        UserDefaults.standard.set(voiceAID, forKey: AppStorageKeys.audioVoiceA)
        UserDefaults.standard.set(voiceBID, forKey: AppStorageKeys.audioVoiceB)
        isPlaying = true
        isPaused = false
        for (offset, line) in script.lines.enumerated() where offset >= index {
            let utterance = makeUtterance(for: line)
            utteranceLines[ObjectIdentifier(utterance)] = offset
            synthesizer.speak(utterance)
        }
    }

    func togglePause() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else if isPlaying {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        utteranceLines.removeAll()
        isPlaying = false
        isPaused = false
        currentLineIndex = nil
    }

    func skip(by delta: Int) {
        guard let script else { return }
        let target = min(max(0, (currentLineIndex ?? 0) + delta), script.lines.count - 1)
        play(script, from: target)
    }

    private func makeUtterance(for line: AudioLine) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: line.text)
        let voiceID = line.speaker == .hostA ? voiceAID : voiceBID
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.18
        utterance.pitchMultiplier = line.speaker == .hostA ? 1.0 : 0.94
        return utterance
    }

    // MARK: - Export

    func export(_ script: AudioScript, to url: URL) async throws {
        isExporting = true
        defer { isExporting = false }
        let utterances = script.lines.map(makeUtterance(for:))
        try await AudioOverviewRenderer.render(utterances: utterances, to: url)
    }
}

extension AudioOverviewPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let index = self.utteranceLines[key] {
                self.currentLineIndex = index
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceLines[key] = nil
            if self.utteranceLines.isEmpty {
                self.isPlaying = false
                self.isPaused = false
                self.currentLineIndex = nil
            }
        }
    }
}

enum AudioOverviewRenderer {
    @MainActor
    static func render(utterances: [AVSpeechUtterance], to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        var file: AVAudioFile?
        for utterance in utterances {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                synthesizer.write(utterance) { buffer in
                    guard !finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        finished = true
                        continuation.resume()
                        return
                    }
                    do {
                        if file == nil {
                            file = try AVAudioFile(
                                forWriting: url,
                                settings: pcm.format.settings,
                                commonFormat: pcm.format.commonFormat,
                                interleaved: pcm.format.isInterleaved
                            )
                        }
                        try file?.write(from: pcm)
                    } catch {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
