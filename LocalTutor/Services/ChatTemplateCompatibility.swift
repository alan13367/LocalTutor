//
//  ChatTemplateCompatibility.swift
//  LocalTutor
//

import Foundation

enum ChatTemplateCompatibility {
    static func patchedTemplate(_ template: String) -> String {
        template.replacingOccurrences(of: #"\x00"#, with: "\u{0}")
    }

    static func patchedTokenizerConfig(_ json: String) -> String {
        json.replacingOccurrences(of: #"\\x00"#, with: #"\u0000"#)
    }

    static func patch(directory: URL) {
        rewrite(directory.appendingPathComponent("chat_template.jinja"), marker: #"\x00"#, with: patchedTemplate)
        rewrite(directory.appendingPathComponent("tokenizer_config.json"), marker: #"\\x00"#, with: patchedTokenizerConfig)
    }

    private static func rewrite(_ url: URL, marker: String, with transform: (String) -> String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) else { return }
        try? transform(text).write(to: url, atomically: true, encoding: .utf8)
    }
}
