import CAdwaita
import CRaTeXBridge
import Foundation
@testable import MathEngine
import Testing

/// The RaTeX engine behind ``MathRenderer``.
@MainActor
struct MathRendererTests {
    init() {
        MathRenderer.removeAllCachedFormulas()
    }

    @Test("A quadratic formula lays out with a baseline inside its box")
    func quadraticFormulaLaysOutWithBaseline() throws {
        let formula = try #require(
            MathRenderer.formula(tex: #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#, isDisplay: false, pixelSize: 20),
            "\(MathRenderer.lastError ?? "")"
        )
        #expect(formula.width > formula.height)
        #expect(formula.depth > 0)
        #expect(formula.ascent > 0)
        // The fraction reaches further below the baseline than a lone letter.
        let letter = try #require(MathRenderer.formula(tex: "x", isDisplay: false, pixelSize: 20))
        #expect(formula.depth > letter.depth * 2)
    }

    @Test("Display style sets a fraction taller than inline style")
    func displayStyleSetsFractionTallerThanInlineStyle() throws {
        let inline = try #require(MathRenderer.formula(tex: #"\frac{a}{b}"#, isDisplay: false, pixelSize: 20))
        let display = try #require(MathRenderer.formula(tex: #"\frac{a}{b}"#, isDisplay: true, pixelSize: 20))
        #expect(display.height > inline.height * 1.2)
    }

    @Test("Formula size scales with the pixel size")
    func formulaSizeScalesWithPixelSize() throws {
        let small = try #require(MathRenderer.formula(tex: "E = mc^2", isDisplay: false, pixelSize: 20))
        let large = try #require(MathRenderer.formula(tex: "E = mc^2", isDisplay: false, pixelSize: 30))
        #expect(abs(large.width / small.width - 1.5) < 0.05)
    }

    @Test("Drawing paints the default colour and keeps an explicit black")
    func drawingPaintsDefaultColourAndKeepsExplicitBlack() throws {
        // A white default with an explicit black part: a theme colour must
        // not repaint what the author coloured black.
        let plain = try #require(MathRenderer.formula(tex: "x", isDisplay: false, pixelSize: 40))
        let black = try #require(MathRenderer.formula(tex: #"\color{black}{x}"#, isDisplay: false, pixelSize: 40))
        let red = try #require(MathRenderer.formula(tex: #"\color{red}{x}"#, isDisplay: false, pixelSize: 40))

        #expect(inkColours(of: plain, red: 1, green: 1, blue: 1).white > 0)
        #expect(inkColours(of: plain, red: 1, green: 1, blue: 1).black == 0)
        #expect(inkColours(of: black, red: 1, green: 1, blue: 1).black > 0)
        #expect(inkColours(of: black, red: 1, green: 1, blue: 1).white == 0)
        #expect(inkColours(of: red, red: 1, green: 1, blue: 1).red > 0)
    }

    @Test("TeX that does not parse yields no formula and an error")
    func texThatDoesNotParseYieldsNoFormula() {
        #expect(MathRenderer.formula(tex: #"\frac{1}{"#, isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.lastError?.isEmpty == false)
        #expect(MathRenderer.formula(tex: #"\undefinedmacro{x}"#, isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("Formulas longer than the limit are not parsed")
    func formulasLongerThanTheLimitAreNotParsed() {
        let long = String(repeating: "x+", count: MathRenderer.maxTeXBytes / 2 + 1)
        #expect(MathRenderer.formula(tex: long, isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.formula(tex: "", isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("Unusable pixel sizes yield no formula", arguments: [0, -1, 0.5, 5000, .nan, .infinity])
    func unusablePixelSizesYieldNoFormula(pixelSize: Double) {
        #expect(MathRenderer.formula(tex: "x", isDisplay: false, pixelSize: pixelSize) == nil)
    }

    @Test("Absurdly large or non-finite boxes are rejected")
    func absurdlyLargeOrNonFiniteBoxesAreRejected() {
        let hostile = [
            #"\hspace{1000000000pt}"#,
            #"\rule{\#(String(repeating: "9", count: 400))em}{1em}"#,
            #"\kern-\#(String(repeating: "1", count: 400))em x"#,
            #"\raisebox{-\#(String(repeating: "9", count: 400))em}{x}"#,
        ]
        for tex in hostile {
            #expect(MathRenderer.formula(tex: tex, isDisplay: false, pixelSize: 20) == nil, "\(tex.prefix(30))")
        }
    }

    // RaTeX 0.1.14 never returned from these; 0.1.15 rejects them in
    // milliseconds. The time limit reports a regression, but cannot stop a
    // call that never returns: the CI jobs' timeout-minutes ends the run.
    @Test("Self-doubling macros stop instead of hanging", .timeLimit(.minutes(1)))
    func selfDoublingMacrosStopInsteadOfHanging() {
        for tex in [#"\def\a#1{\a{#1#1}}\a{x}"#, #"\newcommand{\a}[1]{\a{#1#1}}\a{x}"#] {
            #expect(MathRenderer.formula(tex: tex, isDisplay: false, pixelSize: 20) == nil)
        }
    }

    @Test("A formula that parses but lays out too large is rejected")
    func formulaThatLaysOutTooLargeIsRejected() {
        // 2000 em at 20 px is 40,000 px: valid TeX, past the bridge's box limit.
        #expect(MathRenderer.formula(tex: #"\hspace{2000em}x"#, isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.lastError?.contains("out of range") == true, "\(MathRenderer.lastError ?? "")")
        #expect(MathRenderer.formula(tex: #"\hspace{20em}x"#, isDisplay: false, pixelSize: 20) != nil)
    }

    @Test("Deep nesting is rejected without crashing")
    func deepNestingIsRejectedWithoutCrashing() {
        let deep = String(repeating: "{", count: 10000) + "x" + String(repeating: "}", count: 10000)
        #expect(MathRenderer.formula(tex: deep, isDisplay: false, pixelSize: 20) == nil)
        let fractions = String(repeating: #"\frac{1}{"#, count: 200) + "x" + String(repeating: "}", count: 200)
        #expect(MathRenderer.formula(tex: fractions, isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("A NUL inside the TeX is not silently cut off")
    func nulInsideTexIsNotSilentlyCutOff() {
        #expect(MathRenderer.formula(tex: "x^2\u{0}\\frac{", isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("Macros defined in one formula do not leak into the next")
    func macrosDefinedInOneFormulaDoNotLeak() {
        #expect(MathRenderer.formula(tex: #"\newcommand{\RR}{\mathbb{R}} x \in \RR"#, isDisplay: false, pixelSize: 20) != nil)
        #expect(MathRenderer.formula(tex: #"y \in \RR"#, isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("Environments, chemistry and tags render")
    func environmentsChemistryAndTagsRender() {
        for tex in [
            #"\begin{align*} a &= b \\ c &= d \end{align*}"#,
            #"\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}"#,
            #"f(x) = \begin{cases} x & x \geq 0 \\ -x & x < 0 \end{cases}"#,
            #"\ce{2H2 + O2 -> 2H2O}"#,
            #"a^2 + b^2 = c^2 \tag{1}"#,
        ] {
            #expect(MathRenderer.formula(tex: tex, isDisplay: true, pixelSize: 20) != nil, "\(tex): \(MathRenderer.lastError ?? "")")
        }
    }

    @Test("Cyrillic in text is measured from the font it is drawn with")
    func cyrillicInTextIsMeasuredFromItsFont() throws {
        // Without real metrics every character missing from the math fonts
        // gets the same estimated width, and wide and narrow letters would
        // come out equally wide (and overlap when drawn).
        let wide = try #require(MathRenderer.formula(tex: #"\text{шшшш}"#, isDisplay: false, pixelSize: 40))
        let narrow = try #require(MathRenderer.formula(tex: #"\text{гггг}"#, isDisplay: false, pixelSize: 40))
        #expect(wide.width > narrow.width * 1.2)
        // And their height: the box must hold the letters it draws, or Pango
        // sizes the line (and GTK clips the drawing) too small.
        let word = try #require(MathRenderer.formula(tex: #"\text{Площадь}"#, isDisplay: false, pixelSize: 40))
        #expect(word.ascent > 0.5 * 40, "ascent \(word.ascent)")
        #expect(word.depth > 0.1 * 40, "depth \(word.depth) (щ has a descender)")
    }

    @Test("Formulas are cached per TeX, style and size")
    func formulasAreCachedPerTexStyleAndSize() throws {
        let first = try #require(MathRenderer.formula(tex: "a+b", isDisplay: false, pixelSize: 20))
        let again = try #require(MathRenderer.formula(tex: "a+b", isDisplay: false, pixelSize: 20.05))
        let display = try #require(MathRenderer.formula(tex: "a+b", isDisplay: true, pixelSize: 20))
        let larger = try #require(MathRenderer.formula(tex: "a+b", isDisplay: false, pixelSize: 24))
        #expect(first === again)
        #expect(first !== display)
        #expect(first !== larger)
        #expect(MathRenderer.formula(tex: "a+b", isDisplay: true, pixelSize: 20) === display)
    }

    @Test("The cache drops the least recently used formulas first")
    func cacheDropsLeastRecentlyUsedFirst() throws {
        let kept = try #require(MathRenderer.formula(tex: "kept", isDisplay: false, pixelSize: 20))
        for index in 0..<MathRenderer.cacheLimit {
            _ = MathRenderer.formula(tex: "x_{\(index)}", isDisplay: false, pixelSize: 20)
            // Keep using the first formula while others pour in.
            _ = MathRenderer.formula(tex: "kept", isDisplay: false, pixelSize: 20)
        }
        #expect(MathRenderer.cachedFormulaCount <= MathRenderer.cacheLimit)
        #expect(MathRenderer.formula(tex: "kept", isDisplay: false, pixelSize: 20) === kept)
    }

    @Test("A render pass stops parsing new formulas once its budget is spent")
    func renderPassStopsParsingOnceBudgetIsSpent() {
        let cached = MathRenderer.formula(tex: "c", isDisplay: false, pixelSize: 20)
        MathRenderer.withParseBudget(.zero) {
            #expect(MathRenderer.formula(tex: "new", isDisplay: false, pixelSize: 20) == nil)
            #expect(MathRenderer.formula(tex: "c", isDisplay: false, pixelSize: 20) === cached)
        }
        // Not remembered as a failure: the next pass parses it.
        #expect(MathRenderer.formula(tex: "new", isDisplay: false, pixelSize: 20) != nil)
    }

    @Test("A pass that must progress parses its first formula whatever the time")
    func aPassThatMustProgressParsesItsFirstFormula() {
        MathRenderer.withParseBudget(.zero, guaranteeingProgress: true) {
            #expect(MathRenderer.formula(tex: "p_1", isDisplay: false, pixelSize: 20) != nil)
            #expect(MathRenderer.lookup(tex: "p_2", isDisplay: false, pixelSize: 20).isPostponed)
        }
    }

    @Test("Macros that build a huge tree do not keep it")
    func macrosThatBuildAHugeTreeDoNotKeepIt() throws {
        // ~500 bytes of TeX expanding to tens of thousands of nodes that draw
        // nothing: only the (empty) drawing may count.
        let fractions = String(repeating: "\\frac{a}{b}", count: 36)
        let tex = "\\def\\a{\(fractions)}\\def\\b{\(String(repeating: "\\a", count: 10))}\\vphantom{\(String(repeating: "\\b", count: 24))}"
        let before = ratex_bridge_live_bytes()
        let handle = try #require(tex.withCString { ratex_bridge_parse($0, strlen($0), 0, 20) })
        defer { ratex_bridge_free(handle) }
        #expect(ratex_bridge_live_bytes() < before + 16 * 1024)
    }

    @Test("Math symbols that also have emoji images are not counted as emoji")
    func mathSymbolsThatAlsoHaveEmojiImagesAreNotCountedAsEmoji() {
        // Digits, `#`, `*`, arrows and suits have emoji PNGs but KaTeX draws
        // them; a few real emoji are fine wherever they are drawn.
        #expect(MathRenderer.formula(tex: String(repeating: "1234567890", count: 10) + "\\#*", isDisplay: false, pixelSize: 20) != nil)
        #expect(MathRenderer.formula(tex: String(repeating: "\\leftrightarrow", count: 40), isDisplay: false, pixelSize: 20) != nil)
        #expect(MathRenderer.formula(tex: String(repeating: "\\spadesuit", count: 40), isDisplay: false, pixelSize: 20) != nil)
        #expect(MathRenderer.formula(tex: "😀😀😀", isDisplay: false, pixelSize: 20) != nil)
    }

    @Test("Emoji are drawn as images where the setup says they should be")
    func emojiAreDrawnAsImagesWhereTheSetupSaysTheyShouldBe() {
        // Keeps the gate below honest: where colour-emoji images are expected
        // (set on machines that have them), the gate must not turn itself off.
        guard ProcessInfo.processInfo.environment["SWIFTY_NOTES_EXPECT_EMOJI_IMAGES"] == "1" else { return }
        #expect(ratex_bridge_draws_emoji_images() == 1)
    }

    @Test("A formula drawing many emoji is refused", .enabled(if: ratex_bridge_draws_emoji_images() != 0))
    func aFormulaDrawingManyEmojiIsRefused() {
        // Each emoji is a PNG decoded on every draw; at most 32 per formula.
        #expect(MathRenderer.formula(tex: String(repeating: "😀", count: 32), isDisplay: false, pixelSize: 20) != nil)
        #expect(MathRenderer.formula(tex: String(repeating: "😀", count: 33), isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.lastError?.contains("emoji") == true, "\(MathRenderer.lastError ?? "")")
        // Emoji outside the pictograph blocks count too.
        #expect(MathRenderer.formula(tex: String(repeating: "⌚", count: 40), isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.formula(tex: String(repeating: "⏰", count: 40), isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.formula(tex: String(repeating: "⭐", count: 40), isDisplay: false, pixelSize: 20) == nil)
    }

    @Test("A formula that would keep too much memory is refused")
    func formulaKeepingTooMuchMemoryIsRefused() {
        // Each stretchy brace is a long path: ~2 KB of TeX, megabytes drawn.
        let tex = String(repeating: "\\overbrace{x}", count: 150)
        #expect(MathRenderer.formula(tex: tex, isDisplay: false, pixelSize: 20) == nil)
        #expect(MathRenderer.lastError?.contains("KiB") == true, "\(MathRenderer.lastError ?? "")")
        // A few braces are fine.
        #expect(MathRenderer.formula(tex: String(repeating: "\\overbrace{x}", count: 5), isDisplay: false, pixelSize: 20) != nil)
    }

    @Test("Live formulas count against the engine's memory until freed")
    func liveFormulasCountAgainstTheEnginesMemoryUntilFreed() throws {
        func held(by tex: String) throws -> Int {
            let before = ratex_bridge_live_bytes()
            let handle = try #require(tex.withCString { ratex_bridge_parse($0, strlen($0), 0, 20) })
            let held = ratex_bridge_live_bytes() - before
            ratex_bridge_free(handle)
            #expect(ratex_bridge_live_bytes() == before)
            return held
        }
        // The drawing is what counts: a brace's long path costs far more
        // than a single letter.
        let letter = try held(by: "x")
        let brace = try held(by: "\\overbrace{a+b}^{n}")
        #expect(letter > 0)
        #expect(brace > letter + 10_000, "brace \(brace), letter \(letter)")
    }

    @Test("Formulas refused at the memory limit are tried again later")
    func formulasRefusedAtTheMemoryLimitAreTriedAgainLater() {
        let previous = ratex_bridge_set_live_bytes_limit(0)
        defer { ratex_bridge_set_live_bytes_limit(previous) }
        #expect(MathRenderer.formula(tex: "m_1", isDisplay: false, pixelSize: 20) == nil)
        #expect(ratex_bridge_last_error_is_transient() == 1)
        ratex_bridge_set_live_bytes_limit(previous)
        #expect(MathRenderer.formula(tex: "m_1", isDisplay: false, pixelSize: 20) != nil)
        // A real parse error is not transient.
        #expect(MathRenderer.formula(tex: "\\frac{", isDisplay: false, pixelSize: 20) == nil)
        #expect(ratex_bridge_last_error_is_transient() == 0)
    }

    @Test("A formula that would cross the memory limit after layout is refused")
    func aFormulaThatWouldCrossTheMemoryLimitAfterLayoutIsRefused() {
        // Below the limit before parsing, over it once the drawing is known.
        let previous = ratex_bridge_set_live_bytes_limit(ratex_bridge_live_bytes() + 100)
        defer { ratex_bridge_set_live_bytes_limit(previous) }
        let tex = "\\overbrace{a}"
        let handle = tex.withCString { ratex_bridge_parse($0, strlen($0), 0, 20) }
        #expect(handle == nil)
        #expect(ratex_bridge_last_error_is_transient() == 1)
        if let handle { ratex_bridge_free(handle) }
    }

    @Test("At the memory limit, cached formulas no label holds make room")
    func atTheMemoryLimitCachedFormulasNoLabelHoldsMakeRoom() throws {
        // Cached only: nothing else keeps these alive.
        for index in 0..<8 {
            _ = MathRenderer.formula(tex: "\\overbrace{a_{\(index)}}", isDisplay: false, pixelSize: 20)
        }
        let previous = ratex_bridge_set_live_bytes_limit(ratex_bridge_live_bytes())
        defer { ratex_bridge_set_live_bytes_limit(previous) }
        #expect(MathRenderer.formula(tex: "\\overbrace{fresh}", isDisplay: false, pixelSize: 20) != nil)
    }

    #if !os(macOS)
    @Test("A serif fallback font with Cyrillic and Greek is found for text in formulas")
    func serifFallbackFontIsFound() throws {
        let spec = try #require(ratex_bridge_text_fallback_font().map { String(cString: $0) })
        let path = String(spec.split(separator: "#").first ?? "")
        #expect(FileManager.default.fileExists(atPath: path), "\(spec)")
    }
    #endif

    /// Draws `formula` with the given default colour on a transparent
    /// surface and counts strongly coloured pixels.
    private func inkColours(of formula: MathFormula, red: Double, green: Double, blue: Double) -> (white: Int, black: Int, red: Int) {
        let width = Int32(formula.width.rounded(.up)) + 4
        let height = Int32(formula.height.rounded(.up)) + 4
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)
        defer { cairo_surface_destroy(surface) }
        let cairo = cairo_create(surface)
        formula.draw(on: UnsafeMutableRawPointer(cairo!), red: red, green: green, blue: blue)
        cairo_destroy(cairo)
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let data = cairo_image_surface_get_data(surface)!
        var counts = (white: 0, black: 0, red: 0)
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                // ARGB32 is native-endian: B, G, R, A in memory here.
                let pixel = data + y * stride + x * 4
                let (b, g, r, a) = (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3]))
                guard a > 200 else { continue }
                if r > 200, g > 200, b > 200 { counts.white += 1 }
                if r < 40, g < 40, b < 40 { counts.black += 1 }
                if r > 200, g < 60, b < 60 { counts.red += 1 }
            }
        }
        return counts
    }
}
