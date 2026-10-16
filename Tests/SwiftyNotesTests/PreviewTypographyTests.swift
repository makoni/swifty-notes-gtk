import Foundation
@testable import SwiftyNotes
import Testing

/// The GdkModifierType bits the scroll gesture deals with, spelled out so
/// the tests do not depend on header layout.
private enum Modifiers {
    static let shift: UInt32 = 1 << 0
    static let capsLock: UInt32 = 1 << 1
    static let control: UInt32 = 1 << 2
    static let alt: UInt32 = 1 << 3
    static let numLockSlot: UInt32 = 1 << 4
}

struct PreviewTypographyTests {
    // MARK: css

    @Test("Generated preview CSS carries the default line heights at one hundred percent")
    func generatedPreviewCSSCarriesDefaultLineHeightsAtOneHundredPercent() {
        let css = PreviewTypography.css(zoomPercent: 100, lineSpacingPercent: 100)

        #expect(css.contains("font-size: 100%"))
        #expect(css.contains("line-height: 1.24"))
        #expect(css.contains("line-height: 1.14"))
        // The flat-list label had no line-height rule before; 1.00 is its
        // natural height, so the default look is unchanged.
        #expect(css.contains("line-height: 1.00"))
        // The prose classes the static preview CSS used to style stay covered.
        #expect(css.contains(".preview-paragraph-label"))
        #expect(css.contains(".preview-blockquote-label"))
        #expect(css.contains(".preview-compact-list-label"))
        #expect(css.contains(".preview-compact-list-marker"))
        #expect(css.contains(".preview-task-list-label"))
        #expect(css.contains(".preview-task-list-marker"))
        #expect(css.contains(".preview-flat-list-label"))
        // The table body label had no line-height rule before either; its
        // step shares the flat list's 1.00 base, so the default look is
        // unchanged for tables as well.
        #expect(css.contains(".preview-table-body {"))
        // At exactly 100 % the stylesheet must not touch the theme's title
        // sizes, or the default look drifts from whatever the theme defines.
        #expect(!css.contains(".title-1"))
        #expect(!css.contains(".title-2"))
        #expect(!css.contains(".title-3"))
        // …and must not touch the theme's monospace size either.
        #expect(!css.contains(".monospace"))
    }

    @Test("Generated preview CSS scales the line heights at one hundred fifty percent")
    func generatedPreviewCSSScalesLineHeightsAtOneHundredFiftyPercent() {
        let css = PreviewTypography.css(zoomPercent: 100, lineSpacingPercent: 150)

        // 1.24 × 150 % = 1.86, 1.14 × 150 % = 1.71, 1.00 × 150 % = 1.50 —
        // the flat list and the table body share the 1.00 base.
        #expect(css.contains(".preview-flat-list-label {"))
        #expect(css.contains(".preview-table-body {"))
        #expect(css.contains("line-height: 1.86"))
        #expect(css.contains("line-height: 1.71"))
        #expect(css.contains("line-height: 1.50"))
        #expect(!css.contains("1.24"))
        #expect(!css.contains("1.14"))
        #expect(!css.contains("1.00"))
    }

    @Test("Generated preview CSS scales the table line height at eighty percent")
    func generatedPreviewCSSScalesTheTableLineHeightAtEightyPercent() {
        let css = PreviewTypography.css(zoomPercent: 100, lineSpacingPercent: 80)

        // 1.00 × 80 % = 0.80: the first step below the table body's
        // natural 1.00 height.
        #expect(css.contains(".preview-table-body {"))
        #expect(css.contains("line-height: 0.80"))
    }

    @Test("Generated preview CSS scales the flat list line height at eighty percent")
    func generatedPreviewCSSScalesTheFlatListLineHeightAtEightyPercent() {
        let css = PreviewTypography.css(zoomPercent: 100, lineSpacingPercent: 80)

        // 1.00 × 80 % = 0.80: the first step below the flat list label's
        // natural 1.00 height.
        #expect(css.contains(".preview-flat-list-label {"))
        #expect(css.contains("line-height: 0.80"))
    }

    @Test("Generated preview CSS scales the root font size with the zoom")
    func generatedPreviewCSSScalesRootFontSizeWithTheZoom() {
        let css = PreviewTypography.css(zoomPercent: 120, lineSpacingPercent: 100)

        #expect(css.contains("font-size: 120%"))
    }

    @Test("Generated preview CSS re-opens the monospace font size to the zoom off one hundred percent")
    func generatedPreviewCSSReopensMonospaceFontSizeOffOneHundredPercent() {
        // Recent libadwaita themes pin `.monospace { font-size: … }`, and
        // `gtk_text_view_set_monospace` puts that class on the code
        // SourceView — the pin would hold the code blocks at the theme
        // size while the body zooms. Off 100 % the step re-opens the node
        // to its inherited (already scaled) size so code zooms with
        // everything else; at 100 % nothing is emitted, so the theme's own
        // monospace size stays exactly as it is today.
        let css = PreviewTypography.css(zoomPercent: 150, lineSpacingPercent: 100)

        #expect(css.contains(".markdown-preview .monospace {"))
        #expect(css.contains("font-size: inherit"))
    }

    @Test("Generated preview CSS scales the theme title sizes off one hundred percent")
    func generatedPreviewCSSScalesThemeTitleSizesOffOneHundredPercent() {
        // libadwaita 1.5 defines .title-1/-2/-3 as 20pt/15pt/15pt; the
        // stylesheet re-asserts those point sizes scaled by the zoom so the
        // headings move with the body text instead of standing still.
        let css = PreviewTypography.css(zoomPercent: 150, lineSpacingPercent: 100)

        #expect(css.contains(".markdown-preview .title-1 {"))
        #expect(css.contains("font-size: 30.0pt"))
        #expect(css.contains(".markdown-preview .title-2 {"))
        #expect(css.contains(".markdown-preview .title-3 {"))
        #expect(css.contains("font-size: 22.5pt"))
    }

    @Test("Generated preview CSS keeps dot decimals under a German numeric locale")
    func generatedPreviewCSSKeepsDotDecimalsUnderAGermanNumericLocale() {
        // The stylesheet is consumed by the C GTK CSS parser, which wants
        // `.` regardless of the process locale. Integer formatting keeps the
        // dot; this test proves it does not drift when LC_NUMERIC is German.
        // A host without the de_DE locale cannot prove it, so the test
        // verifies nothing there instead of leaking a "C" locale into the
        // suites that run afterwards.
        let originalPointer = setlocale(LC_NUMERIC, "")
        let original = originalPointer.map { String(cString: $0) } ?? "C"
        guard setlocale(LC_NUMERIC, "de_DE.UTF-8") != nil else {
            return
        }
        defer { setlocale(LC_NUMERIC, original) }
        let css = PreviewTypography.css(zoomPercent: 120, lineSpacingPercent: 150)

        #expect(css.contains("font-size: 120%"))
        #expect(css.contains("line-height: 1.86"))
        #expect(css.contains("line-height: 1.71"))
        #expect(!css.contains("line-height: 1,86"))
        #expect(!css.contains("line-height: 1,71"))
    }

    // MARK: zoomAfterScroll

    @Test("Ctrl plus scroll up zooms the preview in by one step")
    func ctrlPlusScrollUpZoomsInByOneStep() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: -1, modifiers: Modifiers.control) == 110,
        )
    }

    @Test("Ctrl plus scroll down zooms the preview out by one step")
    func ctrlPlusScrollDownZoomsOutByOneStep() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: 1, modifiers: Modifiers.control) == 90,
        )
    }

    @Test("A full wheel rotation still moves exactly one zoom step")
    func aFullWheelRotationStillMovesExactlyOneZoomStep() {
        // Real wheels report |deltaY| > 1 for a full rotation; the gesture
        // is per notch, so the step must not multiply with the delta.
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: -3, modifiers: Modifiers.control) == 110,
        )
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: 3, modifiers: Modifiers.control) == 90,
        )
    }

    @Test("Scroll without modifiers is not a zoom gesture")
    func scrollWithoutModifiersIsNotAZoomGesture() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: -1, modifiers: 0) == nil,
        )
    }

    @Test("Shift alone is not a zoom gesture")
    func shiftAloneIsNotAZoomGesture() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: -1, modifiers: Modifiers.shift) == nil,
        )
    }

    @Test("Ctrl with Caps Lock held still zooms")
    func ctrlWithCapsLockHeldStillZooms() {
        #expect(
            PreviewTypography.zoomAfterScroll(
                current: 100,
                deltaY: -1,
                modifiers: Modifiers.control | Modifiers.capsLock,
            ) == 110,
        )
        #expect(
            PreviewTypography.zoomAfterScroll(
                current: 100,
                deltaY: -1,
                modifiers: Modifiers.control | Modifiers.numLockSlot,
            ) == 110,
        )
    }

    @Test("Ctrl plus scroll up at the zoom ceiling is consumed at 200")
    func ctrlPlusScrollUpAtTheZoomCeilingIsConsumed() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 200, deltaY: -1, modifiers: Modifiers.control) == 200,
        )
    }

    @Test("Ctrl plus scroll down at the zoom floor is consumed at 50")
    func ctrlPlusScrollDownAtTheZoomFloorIsConsumed() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 50, deltaY: 1, modifiers: Modifiers.control) == 50,
        )
    }

    @Test("A zero scroll delta never zooms")
    func aZeroScrollDeltaNeverZooms() {
        #expect(
            PreviewTypography.zoomAfterScroll(current: 100, deltaY: 0, modifiers: Modifiers.control) == nil,
        )
    }

    @Test("Ctrl plus Shift is not a zoom gesture")
    func ctrlPlusShiftIsNotAZoomGesture() {
        #expect(
            PreviewTypography.zoomAfterScroll(
                current: 100,
                deltaY: -1,
                modifiers: Modifiers.control | Modifiers.shift,
            ) == nil,
        )
    }

    @Test("Ctrl plus Alt is not a zoom gesture")
    func ctrlPlusAltIsNotAZoomGesture() {
        #expect(
            PreviewTypography.zoomAfterScroll(
                current: 100,
                deltaY: -1,
                modifiers: Modifiers.control | Modifiers.alt,
            ) == nil,
        )
    }

    // MARK: stylesheet

    @Test("The static stylesheet covers every zoom step with its own class")
    func staticStylesheetCoversEveryZoomStepWithItsOwnClass() {
        let css = PreviewTypography.stylesheet()

        for zoom in stride(from: PreviewTypography.minZoomPercent, through: PreviewTypography.maxZoomPercent, by: PreviewTypography.zoomStepPercent) {
            #expect(css.contains(".markdown-preview.preview-zoom-\(zoom) {"))
            #expect(css.contains("font-size: \(zoom)%"))
        }
        // Only step values exist — a half step must not select a rule.
        #expect(!css.contains("preview-zoom-55"))
        #expect(!css.contains("preview-zoom-105"))

        // Off 100 % EVERY step pins the theme title sizes, scaled, and
        // re-opens the theme's monospace font-size pin to the zoomed
        // inherited size, so the code blocks zoom with the body — checked
        // per step, not just at spot-checked zooms.
        for zoom in stride(from: PreviewTypography.minZoomPercent, through: PreviewTypography.maxZoomPercent, by: PreviewTypography.zoomStepPercent) where zoom != 100 {
            #expect(
                css.contains(
                    ".markdown-preview.preview-zoom-\(zoom) .title-1 {\n    font-size: \(PreviewTypography.scaledTitleSize(basePoints: 20, zoomPercent: zoom));\n}",
                ),
            )
            #expect(
                css.contains(
                    ".markdown-preview.preview-zoom-\(zoom) .title-2 {\n    font-size: \(PreviewTypography.scaledTitleSize(basePoints: 15, zoomPercent: zoom));\n}",
                ),
            )
            #expect(
                css.contains(".markdown-preview.preview-zoom-\(zoom) .monospace {\n    font-size: inherit;\n}"),
            )
        }
        // At exactly 100 % the step leaves the theme's titles and monospace
        // sizes alone.
        #expect(!css.contains(".preview-zoom-100 .title-"))
        #expect(!css.contains(".preview-zoom-100 .monospace"))
    }

    @Test("The static stylesheet covers every line-spacing step with its own class")
    func staticStylesheetCoversEveryLineSpacingStepWithItsOwnClass() {
        let css = PreviewTypography.stylesheet()

        for spacing in stride(from: PreviewTypography.minLineSpacingPercent, through: PreviewTypography.maxLineSpacingPercent, by: PreviewTypography.lineSpacingStepPercent) {
            #expect(css.contains(".markdown-preview.preview-spacing-\(spacing) .preview-paragraph-label,"))
            #expect(css.contains(".markdown-preview.preview-spacing-\(spacing) .preview-task-list-marker {"))
            #expect(css.contains(".markdown-preview.preview-spacing-\(spacing) .preview-flat-list-label {"))
            #expect(css.contains(".markdown-preview.preview-spacing-\(spacing) .preview-table-body {"))
        }
        #expect(!css.contains("preview-spacing-85"))

        // 124/114/100 scaled: 80 % → 0.99/0.91/0.80, 100 % → 1.24/1.14/1.00,
        // 200 % → 2.48/2.28/2.00.
        #expect(css.contains("line-height: 0.99"))
        #expect(css.contains("line-height: 0.91"))
        #expect(css.contains("line-height: 0.80"))
        #expect(css.contains("line-height: 1.24"))
        #expect(css.contains("line-height: 1.14"))
        #expect(css.contains("line-height: 1.00"))
        #expect(css.contains("line-height: 2.48"))
        #expect(css.contains("line-height: 2.28"))
        #expect(css.contains("line-height: 2.00"))
    }

    @Test("The static stylesheet never restyles code blocks")
    func staticStylesheetNeverRestylesCodeBlocks() {
        // Line spacing must not touch the code views: no rule in the
        // stylesheet may target the source view or set its line-height.
        // (The zoom steps DO scale the code font — through the generic
        // theme `.monospace` rule, which the code views carry via
        // `gtk_text_view_set_monospace`, never through the preview's own
        // code classes.)
        let css = PreviewTypography.stylesheet()

        #expect(!css.contains("preview-code-sourceview"))
        #expect(!css.contains("preview-code-scroll"))
    }

    // MARK: cssClasses

    @Test("Typography classes select the step the preferences already name")
    func typographyClassesSelectTheStepThePreferencesAlreadyName() {
        let step = PreviewTypography.cssClasses(zoomPercent: 150, lineSpacingPercent: 120)
        #expect(step.zoom == "preview-zoom-150")
        #expect(step.spacing == "preview-spacing-120")

        let defaults = PreviewTypography.cssClasses(zoomPercent: 100, lineSpacingPercent: 100)
        #expect(defaults.zoom == "preview-zoom-100")
        #expect(defaults.spacing == "preview-spacing-100")
    }

    @Test("Typography classes snap any persisted value to an existing step")
    func typographyClassesSnapAnyPersistedValueToAnExistingStep() {
        let snapped = PreviewTypography.cssClasses(zoomPercent: 77, lineSpacingPercent: 82)
        #expect(snapped.zoom == "preview-zoom-80")
        #expect(snapped.spacing == "preview-spacing-80")

        let low = PreviewTypography.cssClasses(zoomPercent: 0, lineSpacingPercent: 10)
        #expect(low.zoom == "preview-zoom-50")
        #expect(low.spacing == "preview-spacing-80")

        let high = PreviewTypography.cssClasses(zoomPercent: 999, lineSpacingPercent: 1000)
        #expect(high.zoom == "preview-zoom-200")
        #expect(high.spacing == "preview-spacing-200")

        let boundary = PreviewTypography.cssClasses(zoomPercent: 199, lineSpacingPercent: 201)
        #expect(boundary.zoom == "preview-zoom-200")
        #expect(boundary.spacing == "preview-spacing-200")
    }
}
