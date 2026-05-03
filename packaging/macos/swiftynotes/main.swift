// =============================================================================
// macOS .app entry point for Swifty Notes.
// =============================================================================
//
// Hands off to the same `SwiftyNotesLauncher.run(...)` that drives the Linux
// `swiftynotes` executable target — the Xcode build wraps that logic into
// a regular macOS `.app` bundle (Info.plist, code signing, archive,
// notarization) and adds the few macOS-specific bits the bundle launch
// path needs:
//
//   1. Filter Xcode's debug-only argv. When Xcode launches a debug build it
//      passes `-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState
//      YES`, and similar Cocoa-specific flags. GApplication aborts on the
//      first unknown CLI option, which from the user's chair looks like
//      the app launched and immediately disappeared.
//      `SwiftyNotesLauncher.run(arguments:)` defaults to
//      `CommandLine.arguments.dropFirst()`, which would pick those up.
//      Pass an empty array instead — the launcher already handles its
//      own internal CLI mode without needing argv.
//
//   2. `XDG_DATA_DIRS=/opt/homebrew/share` is supplied through the shared
//      scheme's "Run > Environment Variables" for Cmd+R, and through the
//      Info.plist's `LSEnvironment` for `open .app` / Launch Services
//      launches. swift-adwaita 1.3.0 also prepends the Homebrew prefix
//      programmatically as a final safety net (see DemoAppLib's
//      `ensureHomebrewSchemasOnPath`), but Swifty Notes doesn't go through
//      DemoAppLib.
// =============================================================================

import SwiftyNotes

SwiftyNotesLauncher.run(arguments: [])
