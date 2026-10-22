//
//  MarkupTextExtractor.swift
//  LocalTutor
//

import Foundation
import ZIPFoundation

enum MarkupTextExtractor {
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = replacing(#"(?is)<(script|style|head|nav|footer|svg)[^>]*>.*?</\1>"#, in: text, with: " ")
        text = replacing(#"(?is)<!--.*?-->"#, in: text, with: " ")
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            text = replacing("(?is)<h\(level)[^>]*>", in: text, with: "\n\n\(hashes) ")
            text = replacing("(?is)</h\(level)>", in: text, with: "\n\n")
        }
        text = replacing(#"(?i)<li[^>]*>"#, in: text, with: "\n- ")
        text = replacing(#"(?i)<br\s*/?>"#, in: text, with: "\n")
        text = replacing(#"(?i)</(p|div|section|article|tr|table|ul|ol|blockquote|pre)>"#, in: text, with: "\n\n")
        text = replacing(#"(?i)</t[dh]>"#, in: text, with: " | ")
        text = replacing(#"(?s)<[^>]+>"#, in: text, with: "")
        text = decodeEntities(text)
        text = replacing(#"[ \t\u{00A0}]+"#, in: text, with: " ")
        text = replacing(#" *\n *"#, in: text, with: "\n")
        text = replacing(#"\n{3,}"#, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(fromWebArchiveAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let resource = main["WebResourceData"] as? Data else {
            throw SourceExtractorError.unreadable("The web archive has no main page.")
        }
        let encodingName = main["WebResourceTextEncodingName"] as? String
        let html = decode(resource, encodingName: encodingName)
        return plainText(fromHTML: html)
    }

    static func plainText(fromEPUBAt url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        let container = try string(in: archive, path: "META-INF/container.xml")
        guard let rootPath = firstMatch(#"full-path="([^"]+)""#, in: container) else {
            throw SourceExtractorError.unreadable("The EPUB has no package document.")
        }
        let opf = try string(in: archive, path: rootPath)
        let base = (rootPath as NSString).deletingLastPathComponent

        var manifest: [String: String] = [:]
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            guard let id = firstMatch(#"\bid="([^"]+)""#, in: item),
                  let href = firstMatch(#"\bhref="([^"]+)""#, in: item) else { continue }
            manifest[id] = href
        }
        let spine = matches(#"<itemref\b[^>]*>"#, in: opf).compactMap {
            firstMatch(#"\bidref="([^"]+)""#, in: $0)
        }

        var chapters: [String] = []
        for idref in spine {
            guard let href = manifest[idref]?.removingPercentEncoding ?? manifest[idref] else { continue }
            let path = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
            guard let html = try? string(in: archive, path: path) else { continue }
            let text = plainText(fromHTML: html)
            if !text.isEmpty {
                chapters.append(text)
            }
        }
        guard !chapters.isEmpty else {
            throw SourceExtractorError.unreadable("No readable chapters were found in the EPUB.")
        }
        return chapters.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private static func string(in archive: Archive, path: String) throws -> String {
        guard let entry = archive[path] else {
            throw SourceExtractorError.unreadable("Missing \(path).")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return decode(data, encodingName: nil)
    }

    private static func decode(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "deg": "°",
        "times": "×", "divide": "÷", "plusmn": "±", "middot": "·", "bull": "•"
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: #"&(#x?[0-9A-Fa-f]+|[A-Za-z]+);"#) else {
            return text
        }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let body = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            let name = String(text[body])
            if name.hasPrefix("#") {
                let isHex = name.hasPrefix("#x") || name.hasPrefix("#X")
                let digits = name.dropFirst(isHex ? 2 : 1)
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += text[whole]
                }
            } else {
                result += namedEntities[name.lowercased()] ?? String(text[whole])
            }
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }
}
