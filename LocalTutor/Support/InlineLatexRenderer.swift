import Foundation

enum InlineLatexRenderer {
    static func render(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\") else { return text }

        var rendered = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "$", !isEscaped(index, in: text) else {
                rendered.append(text[index])
                index = text.index(after: index)
                continue
            }

            var delimiterLength = 1
            if text.index(after: index) < text.endIndex && text[text.index(after: index)] == "$" {
                let potentialContentStart = text.index(index, offsetBy: 2)
                if closingDollar(in: text, from: potentialContentStart, delimiterLength: 2) != nil {
                    delimiterLength = 2
                }
            }
            let contentStart = text.index(index, offsetBy: delimiterLength)
            guard let close = closingDollar(in: text, from: contentStart, delimiterLength: delimiterLength) else {
                rendered.append(text[index])
                index = text.index(after: index)
                continue
            }

            rendered += renderMath(String(text[contentStart..<close]))
            index = text.index(close, offsetBy: delimiterLength)
        }

        return renderBareCommands(rendered)
    }

    private static func renderBareCommands(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\\", !isEscaped(index, in: text) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            let afterSlash = text.index(after: index)
            guard afterSlash < text.endIndex, text[afterSlash].isLetter else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            var nameEnd = afterSlash
            while nameEnd < text.endIndex, text[nameEnd].isLetter {
                nameEnd = text.index(after: nameEnd)
            }
            let name = String(text[afterSlash..<nameEnd])
            if let symbol = symbols[name] {
                output += symbol
                index = nameEnd
            } else if knownCommands.contains(name) {
                let remaining = String(text[index...])
                let expanded = expandCommands(remaining)
                let scripted = renderScripts(expanded)
                output += cleanMathOutput(scripted)
                return output
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }

    private static let knownCommands: Set<String> = [
        "text", "textrm", "textit", "textbf", "mathrm", "mathbf", "mathit", "operatorname",
        "frac", "dfrac", "tfrac", "sqrt",
        "left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr"
    ]

    private static func renderMath(_ raw: String) -> String {
        cleanMathOutput(renderScripts(expandCommands(raw)))
    }

    private static func cleanMathOutput(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "{", with: "")
        result = result.replacingOccurrences(of: "}", with: "")
        result = result.replacingOccurrences(of: "\u{2983}", with: "{")
        result = result.replacingOccurrences(of: "\u{2984}", with: "}")
        result = result.replacingOccurrences(of: #"\\+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expandCommands(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "\\" else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            let commandStart = index
            index = text.index(after: index)
            guard index < text.endIndex else {
                output.append("\\")
                break
            }

            let nameStart = index
            while index < text.endIndex, text[index].isLetter {
                index = text.index(after: index)
            }

            let name: String
            if nameStart == index {
                name = String(text[index])
                index = text.index(after: index)
            } else {
                name = String(text[nameStart..<index])
            }

            switch name {
            case "text", "textrm", "textit", "textbf", "mathrm", "mathbf", "mathit", "operatorname":
                if let group = parseGroup(in: text, at: index) {
                    output += renderMath(group.content)
                    index = group.end
                } else {
                    output += name
                }
            case "frac", "dfrac", "tfrac":
                if let numerator = parseGroup(in: text, at: index),
                   let denominator = parseGroup(in: text, at: numerator.end) {
                    output += "\(renderMath(numerator.content))/\(renderMath(denominator.content))"
                    index = denominator.end
                } else {
                    output += String(text[commandStart..<index])
                }
            case "sqrt":
                if let group = parseGroup(in: text, at: index) {
                    output += "√\(renderMath(group.content))"
                    index = group.end
                } else {
                    output += "√"
                }
            case "left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr":
                if index < text.endIndex {
                    if text[index] == "\\" {
                        let escaped = text.index(after: index)
                        if escaped < text.endIndex, text[escaped] == "{" {
                            output += "\u{2983}"
                            index = text.index(after: escaped)
                        } else if escaped < text.endIndex, text[escaped] == "}" {
                            output += "\u{2984}"
                            index = text.index(after: escaped)
                        }
                    } else if text[index] != "." {
                        output.append(text[index])
                        index = text.index(after: index)
                    } else {
                        index = text.index(after: index)
                    }
                }
            case ",", ";", ":", "!", "quad", "qquad":
                output += " "
            case "_", "%", "$", "#", "&":
                output += name
            default:
                output += symbols[name] ?? name
            }
        }

        return output
    }

    private static func renderScripts(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let marker = text[index]
            guard marker == "^" || marker == "_" else {
                output.append(marker)
                index = text.index(after: index)
                continue
            }

            let unitStart = text.index(after: index)
            guard unitStart < text.endIndex else {
                output.append(marker)
                index = unitStart
                continue
            }

            let unit: String
            let unitEnd: String.Index
            if let group = parseGroup(in: text, at: unitStart) {
                unit = renderMath(group.content)
                unitEnd = group.end
            } else {
                unit = String(text[unitStart])
                unitEnd = text.index(after: unitStart)
            }

            output += marker == "^" ? superscript(unit) : subscriptText(unit)
            index = unitEnd
        }

        return output
    }

    private static func superscript(_ text: String) -> String {
        mapped(text, using: superscripts, fallbackPrefix: "^")
    }

    private static func subscriptText(_ text: String) -> String {
        mapped(text, using: subscripts, fallbackPrefix: "_")
    }

    private static func mapped(_ text: String, using table: [Character: String], fallbackPrefix: String) -> String {
        var output = ""
        for character in text {
            guard let mapped = table[character] else {
                return "\(fallbackPrefix)(\(text))"
            }
            output += mapped
        }
        return output
    }

    private static func parseGroup(in text: String, at start: String.Index) -> (content: String, end: String.Index)? {
        var index = start
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }

        guard index < text.endIndex, text[index] == "{" else { return nil }

        var depth = 1
        let contentStart = text.index(after: index)
        index = contentStart

        while index < text.endIndex {
            if text[index] == "{", !isEscaped(index, in: text) {
                depth += 1
            } else if text[index] == "}", !isEscaped(index, in: text) {
                depth -= 1
                if depth == 0 {
                    return (String(text[contentStart..<index]), text.index(after: index))
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func closingDollar(in text: String, from start: String.Index, delimiterLength: Int) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "$", !isEscaped(index, in: text) {
                if delimiterLength == 1 {
                    return index
                }

                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "$" {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        var slashCount = 0
        var current = index
        while current > text.startIndex {
            current = text.index(before: current)
            if text[current] == "\\" {
                slashCount += 1
            } else {
                break
            }
        }
        return slashCount % 2 == 1
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "square": "☐", "Box": "☐", "checked": "☑", "checkmark": "✓",
        "times": "×", "cdot": "·", "pm": "±", "mp": "∓", "div": "÷",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "sim": "∼", "propto": "∝", "infty": "∞",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "mapsto": "↦", "in": "∈", "notin": "∉", "subset": "⊂",
        "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨"
    ]

    private static let superscripts: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subscripts: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]
}
