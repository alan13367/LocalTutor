//
//  SourceExtractor.swift
//  LocalTutor
//
//  Reads text out of attached study sources (PDF, Word, RTF, plain text,
//  CSV, markdown). Images are handled separately by the model as inputs.
//

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct ExtractedSource: Sendable {
    var source: StudySource
    /// Plain-text representation of the document's contents. Empty when extraction
    /// is unsupported or the file was empty.
    var text: String
    /// Nil on success, otherwise a short reason the contents could not be read.
    var failureReason: String?

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SourceExtractor {
    /// Maximum characters of extracted text to include per source. Keeps the
    /// prompt within the local model's context window and away from Metal's
    /// per-buffer allocation cap on Apple Silicon GPUs.
    /// Roughly 4 chars per token → 1.5k tokens per source.
    static let perSourceCharacterLimit = 6_000
    /// Cumulative cap across all sources for a single turn. Keeps the entire
    /// prompt under ~3k tokens so the model has plenty of room to answer
    /// within the 6k KV cache.
    static let totalCharacterBudget = 12_000

    static func extract(_ sources: [StudySource]) async -> [ExtractedSource] {
        // Skip images — those go through the vision pipeline.
        let textSources = sources.filter { !$0.isImage }
        guard !textSources.isEmpty else { return [] }

        return await withTaskGroup(of: ExtractedSource.self) { group in
            for source in textSources {
                group.addTask {
                    if let cached = await SourceExtractionCache.shared.cached(for: source) {
                        return cached
                    }
                    let extracted = await extractOne(source)
                    await SourceExtractionCache.shared.store(extracted, for: source)
                    return extracted
                }
            }
            var results: [ExtractedSource] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { lhs, rhs in
                lhs.source.displayName.localizedCaseInsensitiveCompare(rhs.source.displayName) == .orderedAscending
            }
        }
    }

    private static func extractOne(_ source: StudySource) async -> ExtractedSource {
        let url = source.accessibleURL
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let raw = try readText(at: url, kind: source.kind, fileExtension: source.fileExtension)
            let cleaned = clean(raw)
            let trimmed = String(cleaned.prefix(perSourceCharacterLimit))
            return ExtractedSource(source: source, text: trimmed, failureReason: nil)
        } catch let error as SourceExtractorError {
            return ExtractedSource(source: source, text: "", failureReason: error.description)
        } catch {
            return ExtractedSource(source: source, text: "", failureReason: error.localizedDescription)
        }
    }

    private static func readText(at url: URL, kind: StudySourceKind, fileExtension: String) throws -> String {
        switch kind {
        case .pdf:
            return try readPDF(url)
        case .text:
            return try readPlainText(url)
        case .document:
            return try readAttributed(url, fileExtension: fileExtension)
        case .spreadsheet:
            return try readSpreadsheet(url, fileExtension: fileExtension)
        case .presentation:
            throw SourceExtractorError.unsupported("Slide decks are not yet readable as text. Export the slides to PDF for now.")
        case .image:
            return ""
        case .other:
            // Fall back to plain text if it decodes.
            if let text = try? readPlainText(url) { return text }
            throw SourceExtractorError.unsupported("This file type is not yet supported.")
        }
    }

    private static func readPDF(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw SourceExtractorError.unreadable("Could not open the PDF.")
        }
        var parts: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.isEmpty {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SourceExtractorError.unreadable("This PDF appears to be scanned. No selectable text was found.")
        }
        return joined
    }

    private static func readPlainText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw SourceExtractorError.unreadable("Could not decode the text file.")
    }

    private static func readAttributed(_ url: URL, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]

        switch ext {
        case "docx":
            options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc":
            options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf":
            options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd":
            options[.documentType] = NSAttributedString.DocumentType.rtfd
        default:
            break
        }

        do {
            let data = try Data(contentsOf: url)
            let attributed = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return attributed.string
        } catch {
            // Pages, Numbers, Keynote files are zip bundles — NSAttributedString can't read them.
            if ["pages", "key", "numbers"].contains(ext) {
                throw SourceExtractorError.unsupported("\(ext.uppercased()) files aren't directly readable. Export to PDF or .docx for now.")
            }
            throw SourceExtractorError.unreadable(error.localizedDescription)
        }
    }

    private static func readSpreadsheet(_ url: URL, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        if ext == "csv" {
            return try readPlainText(url)
        }
        throw SourceExtractorError.unsupported("Spreadsheets in this format aren't readable yet. Export to CSV for now.")
    }

    private static func clean(_ text: String) -> String {
        // Collapse runs of >2 blank lines down to 2, strip carriage returns.
        var stripped = text.replacingOccurrences(of: "\r\n", with: "\n")
        stripped = stripped.replacingOccurrences(of: "\r", with: "\n")
        let collapsed = stripped.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Caches extracted text so refinements, regenerations, and follow-up turns in a
/// session don't re-parse the same PDF/Word files. Keyed by file URL + the file's
/// modification date so edits on disk invalidate stale text.
actor SourceExtractionCache {
    static let shared = SourceExtractionCache()

    private struct Entry {
        var modified: Date?
        var extracted: ExtractedSource
    }

    private var store: [String: Entry] = [:]

    func cached(for source: StudySource) -> ExtractedSource? {
        guard let entry = store[key(for: source)] else { return nil }
        if entry.modified != currentModificationDate(for: source) {
            return nil
        }
        return entry.extracted
    }

    func store(_ extracted: ExtractedSource, for source: StudySource) {
        store[key(for: source)] = Entry(
            modified: currentModificationDate(for: source),
            extracted: extracted
        )
    }

    private func key(for source: StudySource) -> String {
        source.accessibleURL.absoluteString
    }

    private func currentModificationDate(for source: StudySource) -> Date? {
        let url = source.accessibleURL
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

enum SourceExtractorError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .unreadable(let message), .unsupported(let message):
            return message
        }
    }
}
