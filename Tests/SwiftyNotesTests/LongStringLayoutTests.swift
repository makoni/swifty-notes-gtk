#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// What a long translation does to the layout.
///
/// German runs 30–60% longer than English and Finnish compounds worse; the
/// first sign of trouble is a control that stops wrapping and pushes the
/// window wider than a small screen can show. Waiting for a real German
/// catalogue to find that out is the slow way round, so this generates a
/// pseudo-locale from the template — which covers every string the app has,
/// including the ones added after this test was written.
///
/// The catalogue is built by gettext itself (`msgen` fills each msgstr from
/// its msgid, `msgfilter` pads it) rather than by a generator here: contexts,
/// plural forms and escaping are then correct by construction.
///
/// Binding the domain elsewhere and selecting a language are process-global,
/// so the suite is serialized, `@MainActor`, and puts the real catalogue back.
@Suite(.serialized)
struct LongStringLayoutTests {
    /// The widest the settings content may need to be, in pixels.
    ///
    /// The window asks for 640 at its default size, and a 1024×768 screen —
    /// still the floor GNOME designs to — leaves nothing spare for content
    /// that cannot go narrower than this.
    private static let widthBudget = 640

    @Test("Settings survives a translation twice as long as the English") @MainActor
    func settingsSurvivesATranslationTwiceAsLongAsTheEnglish() throws {
        var widths: [Int: Int] = [:]
        for expansion in [0, 100, 200] {
            try withPseudoLocale(expansion: expansion) { sample in
                // Without this the test passes for the wrong reason: an
                // unbound catalogue hands every msgid straight back, and
                // measuring English three times proves nothing.
                let english = "Wrap long lines"
                if expansion == 0 {
                    #expect(
                        sample == english,
                        "an unpadded pseudo-translation should read as its msgid: \(sample.debugDescription)",
                    )
                } else {
                    #expect(
                        sample.hasPrefix(english + " ") && sample.count > english.count,
                        "the pseudo-catalogue was not applied: \(sample.debugDescription)",
                    )
                }
                let width = try measureSettingsContent(suffix: "e\(expansion)")
                widths[expansion] = width
                #expect(
                    width <= Self.widthBudget,
                    """
                    with strings \(expansion)% longer the settings content cannot be \
                    made narrower than \(width)px, past the \(Self.widthBudget)px budget. \
                    Something in it stopped wrapping — a Button label or a Label with \
                    wrap = false, neither of which ellipsizes.
                    """,
                )
            }
        }

        // The measurement has to be live, or the assertion above is vacuous:
        // a longer catalogue must move it.
        #expect(
            (widths[200] ?? 0) > (widths[0] ?? 0),
            "measured the same width for English and for strings 200% longer: \(widths)",
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
        let application = Application(id: "me.spaceinbox.swiftynotes.tests.longstring.\(suffix)")
        try application.register()
        let parent = ApplicationWindow(application: application)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = SettingsWindow(
            application: application,
            parentWindow: parent,
            currentSettings: AppSettings(customNotesDirectoryPath: directory.path()),
            currentNotesDirectory: directory,
            defaultNotesDirectory: directory,
            applyNotesDirectoryChange: { $0 },
            applySettingsChange: { $0 },
            openDirectory: { _ in },
        )
        let content = try #require(settings.window.content, "the settings window has no content")
        return content.measure(orientation: GTK_ORIENTATION_HORIZONTAL).minimum
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
            // Rebinds the domain to the shipped catalogue and restores the
            // session language; both are process-global.
            initializeLocalization()
            if let previousLanguage {
                setenv("LANGUAGE", previousLanguage, 1)
            } else {
                unsetenv("LANGUAGE")
            }
            recaptureSessionLanguage()
            _ = applyLanguage(.system)
            if let previousMessagesLocale {
                #expect(
                    setMessagesLocale(previousMessagesLocale),
                    "failed to restore LC_MESSAGES — later suites would sample a locale they did not set",
                )
            }
        }

        try compilePseudoCatalogue(expansion: expansion, into: messages)

        // The domain has to be set before the binding moves, or `.localized`
        // queries no domain at all and hands back the msgid.
        initializeLocalization()
        bindTextDomain(AppIdentity.identifier, to: root.path)
        try #require(
            setLanguage(Self.pseudoLanguage, localeCandidates: ["en_US.UTF-8", "en_GB.UTF-8"]),
            "no usable locale on this host — gettext ignores LANGUAGE under C",
        )
        try body("Wrap long lines".localized)
    }

    /// A language code no real catalogue uses, so selecting it can only pick
    /// up the generated one.
    private static let pseudoLanguage = "qqx"

    /// The catalogue template, resolved from this file rather than through
    /// `LocalizationCatalogFixture`, which is file-private to its own suite.
    private static let templateURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent() // SwiftyNotesTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // <package root>
        .appendingPathComponent("po/me.spaceinbox.swiftynotes.pot")

    private func compilePseudoCatalogue(expansion: Int, into messages: URL) throws {
        let template = Self.templateURL
        let scratch = messages.deletingLastPathComponent().deletingLastPathComponent()
        let po = scratch.appendingPathComponent("pseudo.po", isDirectory: false)
        let mo = messages.appendingPathComponent("\(AppIdentity.identifier).mo", isDirectory: false)

        // `msgen` fills every msgstr from its msgid; `msgfilter` pipes each
        // one through awk, which pads it. awk must `printf` without a
        // newline — `print` would append one to every msgstr, which msgfmt
        // then rejects as a format mismatch for the whole catalogue.
        //
        // A template legitimately carries xgettext's `nplurals=INTEGER`
        // placeholder, which msgfmt will not compile, so the header gets a
        // real plural rule and a language.
        let pipeline = """
        set -euo pipefail
        msgen "\(template.path)" -o - \
          | msgfilter --keep-header -o "\(po.path)" \
              awk -v EXPANSION=\(Double(expansion) / 100) \
                  '{ t = int(length($0) * EXPANSION); p = ""; while (length(p) < t) p = p "x"; \
                     if (t > 0) printf "%s %s", $0, p; else printf "%s", $0 }'
        sed -i -e 's/nplurals=INTEGER; plural=EXPRESSION;/nplurals=2; plural=(n != 1);/' \
               -e 's/^"Language: \\\\n"/"Language: \(Self.pseudoLanguage)\\\\n"/' "\(po.path)"
        msgfmt --check-format -o "\(mo.path)" "\(po.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
        process.arguments = ["-c", pipeline]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            """
            could not build the pseudo-catalogue (\(process.terminationStatus)); \
            gettext's msgen/msgfilter/msgfmt are required:
            \(String(decoding: errorData, as: UTF8.self))
            """,
        )
    }
}
#endif
