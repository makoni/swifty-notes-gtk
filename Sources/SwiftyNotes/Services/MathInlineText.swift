import Foundation

/// Short text that may hold `$…$` formulas — a note's title, a heading —
/// shown outside the preview: as label markup the preview's formula drawer
/// can draw over (``markup(for:)``), or as plain text where nothing can be
/// drawn — a window subtitle, a tooltip (``readable(_:)``).
enum MathInlineText {
    /// Pango markup for `text` with one formula marker (U+FFFC) per formula,
    /// and the formulas in order; `spans` is empty when there are none, and
    /// the markup is then just the escaped text. The first case-insensitive
    /// match of `query`, if any, is highlighted as the outline and palette
    /// filters do — a formula the match touches as a whole.
    static func markup(for text: String, highlighting query: String = "") -> (markup: String, spans: [MathSpan]) {
        let spans = MathSpanExtractor.extract(from: text).spans
        let sources = MathSpanExtractor.sourceRanges(in: text)
        guard !spans.isEmpty, sources.count == spans.count else {
            return (pangoHighlightedMarkup(text, query: query), [])
        }
        let scalars = Array(text.unicodeScalars)
        let hit = firstMatch(of: query, in: text)
        var markup = ""
        func appendText(_ range: Range<Int>) {
            guard let hit, hit.overlaps(range) else {
                markup += escapedText(scalars[range])
                return
            }
            let lit = range.clamped(to: hit)
            markup += escapedText(scalars[range.lowerBound..<lit.lowerBound])
            markup += pangoHighlightOpenTag + escapedText(scalars[lit]) + "</span>"
            markup += escapedText(scalars[lit.upperBound..<range.upperBound])
        }
        let marker = String(MathSpanExtractor.formulaMarker)
        var cursor = 0
        for source in sources {
            appendText(cursor..<source.lowerBound)
            markup += hit?.overlaps(source) == true ? pangoHighlightOpenTag + marker + "</span>" : marker
            cursor = source.upperBound
        }
        appendText(cursor..<scalars.count)
        return (markup, spans)
    }

    /// `text` with each formula spelled as readable plain text: delimiters
    /// dropped, common commands as their characters (`\pi` → π, `\le` → ≤),
    /// `\frac{a}{b}` as a/b, `\text{…}` as its content; anything else kept.
    static func readable(_ text: String) -> String {
        let extraction = MathSpanExtractor.extract(from: text)
        guard !extraction.spans.isEmpty else { return text }
        return MathSpanExtractor.replacingPlaceholders(in: extraction.markdown) { index in
            index < extraction.spans.count ? readableTeX(extraction.spans[index].tex) : nil
        }
    }

    /// Text around formulas in markup: escaped, and a stray U+FFFC (an
    /// object replacement character in the title) made U+FFFD so only
    /// formulas own a marker.
    private static func escapedText(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars.map { $0 == MathSpanExtractor.formulaMarker ? "\u{FFFD}" : $0 })
        return pangoEscape(String(text))
    }

    /// The first case-insensitive match of `query` in `text`, in Unicode
    /// scalars; found in `text` itself, as ``pangoHighlightedMarkup(_:query:)``
    /// does.
    private static func firstMatch(of query: String, in text: String) -> Range<Int>? {
        guard !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) else { return nil }
        let start = text.unicodeScalars.distance(from: text.startIndex, to: range.lowerBound)
        return start..<(start + text.unicodeScalars.distance(from: range.lowerBound, to: range.upperBound))
    }

    // MARK: - Readable TeX

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "cdots": "⋯", "ldots": "…",
        "dots": "…", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈",
        "equiv": "≡", "sim": "∼", "propto": "∝", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "mapsto": "↦",
        "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "partial": "∂",
        "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "sqrt": "√", "circ": "∘", "degree": "°",
        "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "angle": "∠", "perp": "⊥", "parallel": "∥",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "{": "{", "}": "}", "$": "$", "%": "%", "&": "&", "#": "#", "_": "_",
        ",": " ", ";": " ", ":": " ", "!": "", "quad": " ", "qquad": " ", "left": "", "right": "",
    ]

    /// Commands whose argument is shown as is.
    private static let textCommands: Set<String> = [
        "text", "textrm", "textbf", "textit", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathbb",
        "mathcal", "operatorname", "boldsymbol", "ce",
    ]

    private static func readableTeX(_ tex: String) -> String {
        var reader = Reader(scalars: Array(tex.unicodeScalars))
        return reader.readAll()
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func readAll() -> String {
            var output = ""
            while index < scalars.count {
                output += readItem()
            }
            return output
        }

        /// One item: a command with what it takes, a group, or a character.
        mutating func readItem() -> String {
            let scalar = scalars[index]
            if scalar == "\\" {
                return readCommand()
            }
            index += 1
            if scalar == "{" {
                return "{" + readGroupBody() + "}"
            }
            return String(scalar)
        }

        /// The content of a `{…}` group whose `{` was just read.
        mutating func readGroupBody() -> String {
            var output = ""
            while index < scalars.count, scalars[index] != "}" {
                output += readItem()
            }
            if index < scalars.count { index += 1 }
            return output
        }

        /// A command's argument: a group's content, or one item.
        mutating func readArgument() -> String {
            while index < scalars.count, scalars[index] == " " { index += 1 }
            guard index < scalars.count else { return "" }
            if scalars[index] == "{" {
                index += 1
                return readGroupBody()
            }
            return readItem()
        }

        mutating func readCommand() -> String {
            index += 1 // the backslash
            guard index < scalars.count else { return "\\" }
            var name = ""
            if scalars[index].properties.isAlphabetic {
                while index < scalars.count, scalars[index].isASCII, scalars[index].properties.isAlphabetic {
                    name.unicodeScalars.append(scalars[index])
                    index += 1
                }
            } else {
                name = String(scalars[index])
                index += 1
            }
            if name == "frac" || name == "dfrac" || name == "tfrac" {
                let numerator = readArgument()
                let denominator = readArgument()
                return parenthesized(numerator) + "/" + parenthesized(denominator)
            }
            if MathInlineText.textCommands.contains(name) {
                return readArgument()
            }
            if let symbol = MathInlineText.symbols[name] {
                return symbol
            }
            return "\\" + name
        }

        private func parenthesized(_ text: String) -> String {
            text.count <= 1 || text.allSatisfy(\.isNumber) ? text : "(\(text))"
        }
    }
}
