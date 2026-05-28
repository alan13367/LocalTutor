//
//  SessionStore.swift
//  LocalTutor
//
//  Persists study sessions (sources + transcripts) to a JSON file in
//  Application Support so the student can leave and continue later.
//

import Foundation

/// Serial, off-main persistence for the study session history. Writes are
/// debounced by the caller; this actor only does the encode + atomic write.
actor SessionStore {
    /// Synchronous load used once at launch to seed the view model. The sessions
    /// file is small, so reading it on the main thread at startup is fine.
    nonisolated static func loadSync() -> [StudySession] {
        guard let fileURL = try? AppDirectories.sessionsFile(),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sessions = try decoder.decode([StudySession].self, from: data)
            return sessions.map(sanitize)
        } catch {
            return []
        }
    }

    func save(_ sessions: [StudySession]) {
        guard let fileURL = try? AppDirectories.sessionsFile() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort; a failed write should not disrupt studying.
        }
    }

    /// A turn that was mid-stream when the app quit can't keep streaming, so we
    /// settle it into a terminal state on load.
    nonisolated private static func sanitize(_ session: StudySession) -> StudySession {
        var session = session
        for index in session.turns.indices {
            if case .streaming = session.turns[index].assistant.status {
                if session.turns[index].assistant.markdown.isEmpty {
                    session.turns[index].assistant.status = .failed("This response was interrupted.")
                    session.turns[index].assistant.statusMessage = "Interrupted"
                } else {
                    session.turns[index].assistant.status = .done
                    session.turns[index].assistant.statusMessage = "Ready"
                }
                session.turns[index].assistant.isDownloading = false
                session.turns[index].assistant.downloadProgress = nil
            }
        }
        return session
    }
}
