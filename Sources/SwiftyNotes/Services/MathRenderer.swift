import CRaTeXBridge
import Foundation

/// A TeX formula parsed and laid out by the RaTeX engine at one pixel size.
///
/// Immutable apart from the bridge's per-colour layout cache, and only ever
/// used from the main actor, so it is `@unchecked Sendable` to sit in
/// `Sendable` values; the underlying formula is freed with the object.
public final class MathFormula: @unchecked Sendable {
    public let tex: String
    public let isDisplay: Bool
    public let pixelSize: Double
    /// Box width in pixels.
    public let width: Double
    /// Whole box height in pixels, top to bottom.
    public let height: Double
    /// The part of `height` below the baseline.
    public let depth: Double

    /// Distance from the top of the box to the baseline.
    public var ascent: Double {
        height - depth
    }

    private let handle: OpaquePointer

    fileprivate init(tex: String, isDisplay: Bool, pixelSize: Double, handle: OpaquePointer) {
        self.tex = tex
        self.isDisplay = isDisplay
        self.pixelSize = pixelSize
        self.handle = handle
        var width = 0.0
        var height = 0.0
        var depth = 0.0
        ratex_bridge_metrics(handle, &width, &height, &depth)
        self.width = width
        self.height = height
        self.depth = depth
    }

    deinit {
        ratex_bridge_free(handle)
    }

    /// Draws the formula with its box's top-left corner at the origin of
    /// `cairoContext` (a `cairo_t *`). Explicit `\color` in the TeX keeps its
    /// colour; everything else uses the given one. Returns false if the
    /// engine failed to draw.
    @discardableResult
    public func draw(on cairoContext: UnsafeMutableRawPointer, red: Double, green: Double, blue: Double, alpha: Double = 1) -> Bool {
        ratex_bridge_draw(handle, cairoContext, red, green, blue, alpha) == 0
    }
}

/// Front door to the math engine for the preview.
///
/// Parsing is synchronous and runs on the main actor, so the work is
/// bounded: formulas longer than ``maxTeXBytes`` are not rendered (some
/// constructs, `\ce` chemistry in particular, parse in quadratic time), and
/// a render pass stops parsing new formulas once it has spent its
/// ``beginParseBudget(_:)`` — the rest show their source until the next
/// pass. Parsed formulas are cached (least recently used goes first),
/// because the preview re-renders the whole note on every edit.
@MainActor
public enum MathRenderer {
    /// Formulas longer than this many UTF-8 bytes stay TeX source.
    public static let maxTeXBytes = 2048

    /// The engine's message for the last formula that failed to parse.
    public private(set) static var lastError: String?

    static let cacheLimit = 512
    private static var cache: [CacheKey: CacheEntry] = [:]
    private static var useCounter = 0
    private static var parseDeadline: ContinuousClock.Instant?
    private static var parseMustProgress = false
    private static var parsedInBudget = false

    /// Set when a lookup returned nil only because the pass ran out of parse
    /// budget, so the caller can tell a postponed formula from a broken one;
    /// cleared by the next lookup.
    public private(set) static var lastLookupWasPostponed = false

    private struct CacheEntry {
        let formula: MathFormula?
        var lastUse: Int
    }

    private struct CacheKey: Hashable {
        let tex: String
        let isDisplay: Bool
        /// The pixel size in quarter pixels, so float noise from font
        /// metrics does not defeat the cache.
        let quarterPixels: Int
    }

    /// The formula for `tex` at `pixelSize` pixels per em, or nil when the
    /// TeX does not parse, is too long or lays out absurdly large.
    public static func formula(tex: String, isDisplay: Bool, pixelSize: Double) -> MathFormula? {
        lastLookupWasPostponed = false
        guard pixelSize.isFinite, pixelSize >= 1, pixelSize <= 1024 else { return nil }
        guard !tex.utf8.isEmpty, tex.utf8.count <= maxTeXBytes else { return nil }
        let key = CacheKey(tex: tex, isDisplay: isDisplay, quarterPixels: Int((pixelSize * 4).rounded()))
        useCounter += 1
        if let cached = cache[key] {
            cache[key]?.lastUse = useCounter
            return cached.formula
        }
        if let parseDeadline, ContinuousClock.now >= parseDeadline, !(parseMustProgress && !parsedInBudget) {
            // Out of time for this pass; not cached, so a later pass parses it.
            lastLookupWasPostponed = true
            return nil
        }
        parsedInBudget = true
        var formula = parse(tex: tex, isDisplay: isDisplay, pixelSize: Double(key.quarterPixels) / 4)
        if formula == nil, ratex_bridge_last_error_is_transient() != 0 {
            // The live formulas hold the engine's memory limit. Let go of
            // the least recently used cached ones (those no label shows any
            // more are freed) until one more formula surely fits, and try
            // once more.
            freeCachedFormulas(bytes: UInt(RATEX_BRIDGE_MAX_FORMULA_BYTES))
            formula = parse(tex: tex, isDisplay: isDisplay, pixelSize: Double(key.quarterPixels) / 4)
            // Still refused: not cached, as it may draw once memory frees.
            if formula == nil, ratex_bridge_last_error_is_transient() != 0 {
                return nil
            }
        }
        store(formula, for: key)
        return formula
    }

    /// Points the engine at a serif system font (chosen through fontconfig,
    /// with Cyrillic and Greek) for text its own fonts lack, such as
    /// `\text{Площадь}`. Left alone it looks for one fixed CJK font path and
    /// then guesses, which comes out different in every package format and
    /// finds nothing in a Flatpak runtime. The engine reads the setting once
    /// from the environment, and changing the environment is only safe while
    /// the process has a single thread, so call this first thing at launch.
    /// An explicit `RATEX_UNICODE_FONT` wins. (The chosen font is an ordinary
    /// text font, so loading it on the first such formula is cheap.)
    /// macOS is left to the engine: Pango does not use fontconfig there, and
    /// the engine finds Arial Unicode by itself.
    nonisolated public static func configureTextFallbackFont() {
        #if !os(macOS)
        guard getenv("RATEX_UNICODE_FONT") == nil, let spec = ratex_bridge_text_fallback_font() else { return }
        setenv("RATEX_UNICODE_FONT", spec, 0)
        #endif
    }

    /// Runs one render pass, which may spend at most `duration` parsing
    /// formulas that are not cached yet; past that, ``formula(tex:isDisplay:pixelSize:)``
    /// returns nil for new formulas until the pass ends.
    ///
    /// With `guaranteeingProgress`, the first new formula of the pass is
    /// parsed whatever the time, so passes that follow one another always
    /// get through the postponed formulas.
    public static func withParseBudget<Result>(
        _ duration: Duration = .milliseconds(400),
        guaranteeingProgress: Bool = false,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let outer = (deadline: parseDeadline, mustProgress: parseMustProgress, parsed: parsedInBudget)
        parseDeadline = min(outer.deadline ?? .now + duration, .now + duration)
        parseMustProgress = guaranteeingProgress
        parsedInBudget = false
        defer {
            parseDeadline = outer.deadline
            parseMustProgress = outer.mustProgress
            parsedInBudget = outer.parsed || parsedInBudget
        }
        return try body()
    }

    /// Drops every cached formula and any parse budget (tests).
    static func removeAllCachedFormulas() {
        cache.removeAll()
        parseDeadline = nil
    }

    static var cachedFormulaCount: Int {
        cache.count
    }

    private static func parse(tex: String, isDisplay: Bool, pixelSize: Double) -> MathFormula? {
        let handle: OpaquePointer? = tex.utf8CString.withUnsafeBufferPointer { buffer in
            // utf8CString is NUL-terminated; pass the explicit length so a
            // NUL inside the TeX is an error, not a silent truncation.
            ratex_bridge_parse(buffer.baseAddress, buffer.count - 1, isDisplay ? 1 : 0, pixelSize)
        }
        guard let handle else {
            lastError = ratex_bridge_last_error().map { String(cString: $0) }
            return nil
        }
        return MathFormula(tex: tex, isDisplay: isDisplay, pixelSize: pixelSize, handle: handle)
    }

    private static func store(_ formula: MathFormula?, for key: CacheKey) {
        cache[key] = CacheEntry(formula: formula, lastUse: useCounter)
        guard cache.count > cacheLimit else { return }
        // Evict the least recently used quarter at once, so eviction (a
        // sort) runs once per many insertions rather than on every one.
        evictLeastRecentlyUsed(cacheLimit / 4)
    }

    /// Drops cached formulas, least recently used first, until the engine
    /// has given back `bytes` or the cache is empty.
    private static func freeCachedFormulas(bytes: UInt) {
        let start = ratex_bridge_live_bytes()
        for (key, _) in cache.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            cache.removeValue(forKey: key)
            let live = ratex_bridge_live_bytes()
            if live <= start, start - live >= bytes { return }
        }
    }

    private static func evictLeastRecentlyUsed(_ count: Int) {
        let evicted = cache.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(count)
        for (key, _) in evicted {
            cache.removeValue(forKey: key)
        }
    }
}
