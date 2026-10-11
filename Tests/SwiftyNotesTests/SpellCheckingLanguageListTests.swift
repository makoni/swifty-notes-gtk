#if !os(macOS)
    import CAdwaita
    import Foundation
    @testable import SwiftyNotes
    import Testing

    // Counted by `countingCriticalHandler` while a test has it installed.
    // Module scope because a GLogFunc cannot capture context.
    private nonisolated(unsafe) var capturedLanguageListCriticals = 0

    private let countingCriticalHandler: GLogFunc = { _, _, _, _ in
        capturedLanguageListCriticals += 1
    }

    extension MainWindowActionsTests {
        /// libspelling 0.2 (Ubuntu 24.04, the CI runner) returns the language
        /// list as a `GPtrArray`; 0.4 returns a `GListModel`. Reading the
        /// array as a model fired `g_list_model_get_n_items` and
        /// `g_object_unref` CRITICALs on a non-object, which corrupted memory
        /// that later crashed the suite under swift-adwaita 2.0's longer-lived
        /// wrappers. Passes trivially on 0.4; it is the CI run that guards it.
        @Test("Listing spell-check languages fires no GLib criticals") @MainActor
        func listingSpellCheckLanguagesFiresNoGLibCriticals() {
            capturedLanguageListCriticals = 0
            let domains = ["GLib-GIO", "GLib-GObject", "GLib"]
            let handlerIDs = domains.map { domain in
                // G_LOG_LEVEL_CRITICAL; the enum constant is not imported.
                g_log_set_handler(domain, GLogLevelFlags(rawValue: 1 << 3), countingCriticalHandler, nil)
            }
            defer {
                for (domain, id) in zip(domains, handlerIDs) {
                    g_log_remove_handler(domain, id)
                }
            }

            _ = SpellChecking.availableLanguages()

            #expect(capturedLanguageListCriticals == 0)
        }
    }
#endif
