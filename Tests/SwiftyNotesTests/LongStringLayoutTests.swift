#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// What a long translation does to the layout.
///
/// German runs 30–60% longer than English and Finnish compounds worse; the
/// first sign of trouble is a control that stops fitting and pushes the window
/// wider than it means to open. Rather than wait for a real German catalogue,
/// this generates a pseudo-locale from the template — which covers every
/// string in it, and `A catalogue template exists and covers every source
/// string` is what keeps that the same set as the app's.
///
/// The catalogue is built by gettext itself (`msgen` fills each msgstr from
/// its msgid, `msgfilter` pads it) rather than by a generator here: contexts,
/// plural forms and escaping are then correct by construction.
///
/// Binding the domain elsewhere and selecting a language are process-global,
/// so the suite is serialized, `@MainActor`, and puts the real catalogue back
/// through ``LocalizationTestSupport``.
@Suite(.serialized)
struct LongStringLayoutTests {
    /// The widest the settings content may need to be, in pixels.
    ///
    /// The window asks to open at 640 (`SettingsWindow` sets that as its
    /// default size), so content that cannot be narrower than this cannot be
    /// shown at the size the app chose for it. Not a margin of taste: a
    /// smaller number would fail a legitimately wide row, and a larger one
    /// would let the window open wrong.
    private static let widthBudget = 640

    /// A language code no real catalogue uses, so selecting it can only pick
    /// up the generated one.
    private static let pseudoLanguage = "qqx"

    @Test("Settings survives a translation twice as long as the English") @MainActor
    func settingsSurvivesATranslationTwiceAsLongAsTheEnglish() throws {
        // Measured before anything is bound: the English baseline needs no
        // catalogue, and asserting "the pseudo-translation reads as its
        // msgid" for an unpadded pass could not tell a bound catalogue from
        // an unbound one — both hand back the msgid.
        let english = try measureSettingsContent(suffix: "english")
        #expect(
            english <= Self.widthBudget,
            "the settings content already needs \(english)px in English",
        )

        var padded: [Int: Int] = [:]
        for expansion in [100, 200] {
            try withPseudoLocale(expansion: expansion) { sample in
                let base = "Wrap long lines"
                #expect(
                    sample.hasPrefix(base + " ") && sample.count > base.count,
                    "the pseudo-catalogue was not applied: \(sample.debugDescription)",
                )

                let width = try measureSettingsContent(suffix: "e\(expansion)")
                padded[expansion] = width
                #expect(
                    width <= Self.widthBudget,
                    """
                    with strings \(expansion)% longer the settings content cannot be \
                    narrower than \(width)px, past the \(Self.widthBudget)px the window \
                    opens at — so it would open wider than the app asked for, or clip. \
                    English needs \(english)px.
                    """,
                )
            }
        }

        // The measurement has to be live, or the assertions above are
        // vacuous: a longer catalogue must move it.
        #expect(
            (padded[200] ?? 0) > english,
            "measured no more for strings 200% longer than for English: \(padded), \(english)",
        )
    }

    // MARK: - Harness

    /// Builds the settings window and reports the narrowest its content can be.
    ///
    /// Measures the content rather than the window: an unrealized `GtkWindow`
    /// answers with its own size request and never consults its child, so the
    /// window measures the same in every language.
    @MainActor
    private func measureSettingsContent(suffix: String) throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rig = try LocalizationTestSupport.makeSettingsWindow(
            suffix: "longstring.\(suffix)",
            directory: directory,
        )
        let content = try #require(rig.window.window.content, "the settings window has no content")
        let width = content.measure(orientation: GTK_ORIENTATION_HORIZONTAL).minimum
        // Read while the rig is still alive; releasing it first hands back a
        // finalized object whose content is nil.
        withExtendedLifetime(rig) {}
        return width
    }

    /// Compiles a pseudo-locale whose every translation is `expansion` percent
    /// longer than its msgid, selects it, and hands `body` one translated
    /// sample so it can check the catalogue actually took.
    @MainActor
    private func withPseudoLocale(expansion: Int, _ body: (String) throws -> Void) throws {
        let previousLanguage = ProcessInfo.processInfo.environment["LANGUAGE"]
        let previousMessagesLocale = currentMessagesLocale()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftynotes-pseudo-\(UUID().uuidString)", isDirectory: true)
        let messages = root.appendingPathComponent("\(Self.pseudoLanguage)/LC_MESSAGES", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            LocalizationTestSupport.restore(
                language: previousLanguage,
                messagesLocale: previousMessagesLocale,
            )
        }

        try compilePseudoCatalogue(expansion: expansion, into: messages)

        // The domain has to be set before the binding moves, or `.localized`
        // queries no domain at all and hands back the msgid.
        initializeLocalization()
        bindTextDomain(AppIdentity.identifier, to: root.path)
        try #require(
            setLanguage(Self.pseudoLanguage, localeCandidates: AppLanguage.english.messagesLocaleCandidates),
            """
            no usable locale on this host — gettext ignores LANGUAGE while LC_MESSAGES \
            names the C locale, and none of \
            \(AppLanguage.english.messagesLocaleCandidates.joined(separator: ", ")) is generated
            """,
        )
        try body("Wrap long lines".localized)
    }

    /// The catalogue template, resolved from this file rather than through
    /// `LocalizationCatalogFixture`, which is file-private to its own suite.
    private static let templateURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent() // SwiftyNotesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // <package root>
        .appendingPathComponent("po/me.spaceinbox.swiftynotes.pot")

    private func compilePseudoCatalogue(expansion: Int, into messages: URL) throws {
        let po = messages.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pseudo.po", isDirectory: false)
        let mo = messages.appendingPathComponent("\(AppIdentity.identifier).mo", isDirectory: false)

        // `msgen` fills every msgstr from its msgid; `msgfilter` pipes each one
        // through awk, which pads it.
        //
        // The padding is spaced tokens, not one long run: GTK's minimum width
        // for a wrapping label is its widest *word*, so a single 476-character
        // run — which is what one unbroken run produces here — measures a
        // token no language has instead of a longer sentence.
        //
        // awk must `printf` without a newline; `print` appends one to every
        // msgstr, which msgfmt then rejects for the whole catalogue.
        //
        // A template legitimately carries xgettext's `nplurals=INTEGER`
        // placeholder, which msgfmt will not compile, so the header gets a
        // real plural rule and a language.
        //
        // Paths arrive as positional arguments rather than interpolated into
        // the script: `#filePath` is whatever the checkout is called, and a
        // directory name holding `$(…)` or a quote would otherwise be run.
        let pipeline = """
        set -euo pipefail
        msgen "$1" -o - \
          | msgfilter --keep-header -o "$2" \
              awk -v EXPANSION=\(Double(expansion) / 100) \
                  '{ t = int(length($0) * EXPANSION); p = ""; while (length(p) < t) p = p "xxxx "; \
                     if (t > 0) printf "%s %s", $0, p; else printf "%s", $0 }'
        sed -i -e 's/nplurals=INTEGER; plural=EXPRESSION;/nplurals=2; plural=(n != 1);/' \
               -e 's/^"Language: \\\\n"/"Language: \(Self.pseudoLanguage)\\\\n"/' "$2"
        msgfmt --check-format -o "$3" "$2"
        """
        // bash, not sh: `pipefail` is bash-only, and dash before 0.5.12 exits
        // 2 on the `set` line without running anything — which this would
        // then report as gettext being missing.
        let result = try ToolRunner.run(
            URL(fileURLWithPath: "/bin/bash", isDirectory: false),
            ["-c", pipeline, "pseudo-catalogue", Self.templateURL.path, po.path, mo.path],
        )
        try #require(
            result.status == 0,
            """
            could not build the pseudo-catalogue (\(result.status)); \
            gettext's msgen/msgfilter/msgfmt are required:
            \(result.stderr)
            """,
        )
    }
}
#endif
