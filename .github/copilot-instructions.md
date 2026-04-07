# Copilot Instructions

## Build and test commands

- Build the app: `swift build`
- Run the full test suite: `swift test --no-parallel`
- Run a single Swift Testing case: `swift test --filter 'mainWindowPresentRendersPreviewForInitiallySelectedNote' --no-parallel`
- Run a single Wayland UI smoke test: `swift test --filter 'appLaunchesUnderHeadlessWaylandWithAccessibleWindowAndSeededControls' --no-parallel`

## TDD workflow

- Work test-first for behavior changes and bug fixes: add or update a regression test before changing production code when the behavior is reproducible in tests.
- Prefer the narrowest test layer that covers the behavior:
  - `NotesRepositoryTests.swift` with repository/MainWindow debug hooks for most logic and UI regressions.
  - `UISmokeTests.swift` only for real Wayland startup/accessibility scenarios that need black-box coverage.
- After making the test fail, implement the fix, rerun the targeted test, then rerun the relevant broader suite. Use `swift test --no-parallel` before considering the work complete.

## High-level architecture

- `Sources/SwiftyNotes/main.swift` is the only entry point. The same executable runs either the GTK app or the CLI: if the first argument is `cli`, it routes into `NotesCLI`; otherwise it starts the Adwaita application.
- `MainWindow` is the orchestration hub for the desktop app. It wires together `NotesSidebar`, `MarkdownEditor`, and `MarkdownPreview`, owns headerbar actions, autosave scheduling, preview/sidebar visibility, context menus, toast notifications, workspace persistence, and external file reload handling.
- Persistent note storage lives in `NotesRepository`. Both GUI and CLI use the same repository and the same default XDG-backed notes directory (`XDG_DATA_HOME` or `~/.local/share/me.spaceinbox.SwiftyNotes/notes`), so storage behavior must stay compatible across both entry points.
- Persisted UI/session state lives in `WorkspaceStateStore`, backed by JSON under `XDG_STATE_HOME` or `~/.local/state/me.spaceinbox.SwiftyNotes/workspace.json`. `AppState` is the in-memory model for selected note, sidebar/preview visibility, search query, sort mode, and preferred window/pane sizes.
- Markdown preview is fully native GTK. The pipeline is `swift-markdown` -> `HTMLFormatter` / `HTMLSubsetParser` in `MarkdownRenderer` -> `RenderedBlock` values -> GTK widget construction in `MarkdownPreview`. Do not assume a WebView/WebKit architecture.
- Tests are split across:
  - `NotesRepositoryTests.swift` for repository, renderer, CLI parsing/integration, and MainWindow regression coverage via debug hooks.
  - `UISmokeTests.swift` for Wayland-native black-box UI checks under headless Weston + AT-SPI.

## Key conventions

- GTK-facing types are intentionally `@MainActor` (`MainWindow`, `NotesSidebar`, `MarkdownEditor`, `MarkdownPreview`, `AppState`, `AutosaveCoordinator`). Keep GTK widget mutation and UI orchestration on the main actor.
- `NotesRepository` is synchronous on purpose and serializes file access with its own `DispatchQueue`. Do not bypass it with ad-hoc filesystem writes from UI code.
- A note's display title comes from its markdown content, not its filename. Renaming a note means rewriting the first meaningful line of the markdown. Filenames are storage identifiers, not user-facing titles.
- Stable note identity is the lowercase UUID string exposed as `stableID`. Filenames encode timestamp + UUID, and `loadNotes()` reconstructs IDs from that filename format. In tests that depend on restored selection/persisted state, create notes through `NotesRepository` instead of inventing arbitrary filenames.
- First launch seeds `Markdown Showcase` only when the notes directory has no `.md` files. The showcase also includes a companion image asset in the notes directory.
- The CLI is intentionally storage-compatible with the GUI. `SwiftyNotes cli update` replaces the full markdown content of a note; do not implement partial patch semantics there unless the CLI contract changes explicitly.
- For unit-style UI regressions, prefer existing `MainWindow.debug...` helpers instead of trying to drive GTK widgets directly. Reserve `UISmokeTests` for real black-box Wayland scenarios that rely on accessibility-visible names and persisted startup state.
- `UISmokeTests` use a unique `SWIFTY_NOTES_APP_ID` per run so the smoke harness does not accidentally activate an already running `SwiftyNotes` instance. Keep that isolation behavior if you expand the smoke harness.
