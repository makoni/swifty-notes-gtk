# CodeGraph

This project has a CodeGraph MCP server (`codegraph_*` tools) configured. CodeGraph is a tree-sitter-parsed knowledge graph of every symbol, edge, and file. Reads are sub-millisecond and return structural information grep cannot.

## When to prefer codegraph over native search

Use codegraph for **structural** questions — what calls what, what would break, where is X defined, what is X's signature. Use native grep/read only for **literal text** queries (string contents, comments, log messages) or after you already have a specific file open.

| Question | Tool |
|---|---|
| "Where is X defined?" / "Find symbol named X" | `codegraph_search` |
| "What calls function Y?" | `codegraph_callers` |
| "What does Y call?" | `codegraph_callees` |
| "How does X reach/become Y? / trace the flow from X to Y" | `codegraph_trace` (one call = the whole path, incl. callback/React/JSX dynamic hops) |
| "What would break if I changed Z?" | `codegraph_impact` |
| "Show me Y's signature / source / docstring" | `codegraph_node` |
| "Give me focused context for a task/area" | `codegraph_context` |
| "See several related symbols' source at once" | `codegraph_explore` |
| "What files exist under path/" | `codegraph_files` |
| "Is the index healthy?" | `codegraph_status` |

## Rules of thumb

- **Answer directly — don't delegate exploration.** For "how does X work" / architecture questions, answer with 2-3 codegraph calls: `codegraph_context` first, then ONE `codegraph_explore` for the source of the symbols it surfaces. For a specific **flow** ("how does X reach Y") start with `codegraph_trace` from→to — one call returns the whole path with dynamic hops bridged — then ONE `codegraph_explore` for the bodies; don't rebuild the path with `codegraph_search` + `codegraph_callers`. Codegraph IS the pre-built index, so spawning a separate file-reading sub-task/agent — or running a grep + read loop — repeats work codegraph already did and costs more for the same answer.
- **Trust codegraph results.** They come from a full AST parse. Do NOT re-verify them with grep — that's slower, less accurate, and wastes context.
- **Don't grep first** when looking up a symbol by name. `codegraph_search` is faster and returns kind + location + signature in one call.
- **Don't chain `codegraph_search` + `codegraph_node`** when you just want context — `codegraph_context` is one call.
- **Don't loop `codegraph_node` over many symbols** — one `codegraph_explore` call returns several symbols' source grouped in a single capped call, while each separate node/Read call re-reads the whole context and costs far more.
- **Index lag**: the file watcher debounces ~500ms behind writes; don't re-query immediately after editing a file in the same turn.

## If `.codegraph/` doesn't exist

The MCP server returns "not initialized." Ask the user: *"I notice this project doesn't have CodeGraph initialized. Want me to run `codegraph init -i` to build the index?"*

# Copilot Instructions

## Build and test commands

- Build the app: `swift build`
- Run the full test suite: `swift test --no-parallel`
- Run a single Swift Testing case: `swift test --filter 'mainWindowPresentRendersPreviewForInitiallySelectedNote' --no-parallel`
- Run a single Wayland UI smoke test: `swift test --filter 'appLaunchesUnderHeadlessWaylandWithAccessibleWindowAndSeededControls' --no-parallel`

## Translations

- Strings live in `po/<lang>.po`; `po/LINGUAS` is the list of shipped languages and drives both catalogue compilation and metadata rendering.
- `scripts/extract-i18n.sh` regenerates `po/me.spaceinbox.swiftynotes.pot` from all three sources: Swift (`scripts/extract-i18n.swift`, because `"literal".localized` is a property access xgettext cannot see), the AppStream metainfo, and the desktop entry.
- `scripts/build-locales.sh` compiles `.mo` files and renders `data/generated/` — the translated desktop entry and metainfo. Both generated files are gitignored; packaging renders them itself.
- `data/*.metainfo.xml.in` and `data/*.desktop.in` are **English templates**. Never hand-write `xml:lang="…"` or `Name[xx]=` in them: `msgfmt --xml` / `--desktop` merge those from `po/`, and a guard test fails if a template carries its own translations.
- Historical `<release>` descriptions are marked `translate="no"`; they were 70 of the 92 translatable strings and are archival. Drop the attribute on a release whose notes should be translated.
- When one English string means two things, disambiguate with `localizedWithContext("context", "Text")` (or `nlocalizedWithContext`) rather than inventing a second wording. `Preview` is the worked example: `"view mode"` gives «Просмотр» for the segmented toggle, `"settings group"` gives «Предварительный просмотр» for the Settings heading. The extractor reads both keywords and writes `msgctxt`; catalogue keys are `context\u{4}msgid`.
- Every argument a localizing call takes must be a plain literal on one line. The extractor fails the build otherwise, naming the argument — it cannot key a catalogue on a value it will only learn at runtime.
- The extractor stops at the first `//` outside a string literal, so a call quoted in a comment is not a call site — and a msgid it would otherwise refuse (`nlocalized("%d file", …)` mentioned in prose beside a real one) does not stop the build.
- A msgid can carry only what a PO file can spell: gettext's `\a \b \f \n \r \t \v \\ \"`. Any other control character is refused by name, because writing one raw ships a template that msgfmt or the next C consumer downstream reads differently than intended.
- `scripts/extract-i18n.swift --sources <dir>` scans a tree of your choosing, which is how `ExtractorTests` drives it over call sites this app does not contain.
- `msgmerge` flags a newly context-qualified string `#, fuzzy` (it copies the bare entry's translation as a guess) and `msgfmt` then omits fuzzy entries. Clear the flag or the string ships English while every tool reports success; the fuzzy guard catches it.
- Format specifiers are `%@`, never `%s`. On Linux Foundation, `%s` handed a Swift `String` substitutes nothing at all — the argument silently vanishes from the text. A guard test (`No localized format string uses %s`) enforces it.
- Anything Foundation formats rather than gettext — dates, times, numbers — goes through `interfaceLocale()`. `Locale.current` follows `LC_ALL`/`LANG` while the interface language follows `LANGUAGE`, so without it a Russian interface prints English dates.
- After changing user-visible strings: `bash scripts/extract-i18n.sh`, `msgmerge --update --backup=none --no-fuzzy-matching po/ru.po po/me.spaceinbox.swiftynotes.pot`, translate, then `bash scripts/build-locales.sh`.

### How layout is tested against other languages

- **Long strings** (`LongStringLayoutTests`): a pseudo-locale built by gettext itself — `msgen` fills each msgstr from its msgid, `msgfilter` pads it — so every string *in the template* is 100% and 200% longer at once. That is the same set as the app's only because `A catalogue template exists and covers every source string` fails when the template is stale, so re-extract after adding a string or the new one is measured at its English length. Padding is spaced tokens, not one long run: GTK's minimum width for a wrapping label is its widest word, so an unbroken run measures a token no language produces. It measures the settings window's *content*: an unrealized `GtkWindow` answers with its own size request and never consults its child, so measuring the window gives the same number in every language. libadwaita rows ellipsize and never blow up; what does is a `Button` label or a `Label` with `wrap = false`, and the budget is the 640px the window opens at.
- **Right-to-left** (`UISmokeTests`): launched under `LANGUAGE=ar` in the Weston harness, which gives it a process of its own — assigning GTK's default direction walks the list of live toplevels, and in a shared test process that list holds windows earlier suites left behind, so the walk reads freed memory and takes the run down. It compares accessible-component x extents in `WINDOW_COORDS`; desktop coordinates are all zero headless. No Arabic catalogue is needed: direction follows the language, not the translation.
- **A translated interface end to end** (`UISmokeTests`): seeds `settings.json` with `appLanguage: "ru"` and asserts Russian accessible names, so a packaging rule that flattened `<lang>/LC_MESSAGES/` fails a test rather than shipping. It goes through the app's own preference rather than the session locale because that path escapes the C locale through whichever locale the host does have.
- Still manual: CJK font fallback and line breaking under `ja_JP.UTF-8` / `zh_CN.UTF-8`, for whoever adds those catalogues. Arabic plural agreement (six categories) needs `ar.po` before it can be asserted.

## TDD workflow

- Work test-first for behavior changes and bug fixes: add or update a regression test before changing production code when the behavior is reproducible in tests.
- Prefer the narrowest test layer that covers the behavior:
  - `NotesRepositoryTests.swift` with repository/MainWindow debug hooks for most logic and UI regressions.
  - `UISmokeTests.swift` only for real Wayland startup/accessibility scenarios that need black-box coverage.
- After making the test fail, implement the fix, rerun the targeted test, then rerun the relevant broader suite. Use `swift test --no-parallel` before considering the work complete.

## High-level architecture

- `Sources/swiftynotes/main.swift` is the executable entry point. The same binary runs either the GTK app or the CLI: if the first argument is `cli`, it routes into `NotesCLI`; otherwise it starts the Adwaita application.
- `MainWindow` is the orchestration hub for the desktop app. It wires together `NotesSidebar`, `MarkdownEditor`, and `MarkdownPreview`, owns headerbar actions, autosave scheduling, preview/sidebar visibility, context menus, toast notifications, workspace persistence, and external file reload handling.
- Persistent note storage lives in `NotesRepository`. Both GUI and CLI use the same repository and the same default XDG-backed notes directory (`XDG_DATA_HOME` or `~/.local/share/me.spaceinbox.swiftynotes/notes`), so storage behavior must stay compatible across both entry points.
- Persisted UI/session state lives in `WorkspaceStateStore`, backed by JSON under `XDG_STATE_HOME` or `~/.local/state/me.spaceinbox.swiftynotes/workspace.json`. `AppState` is the in-memory model for selected note, sidebar/preview visibility, search query, sort mode, and preferred window/pane sizes.
- Markdown preview is fully native GTK. The pipeline is `swift-markdown` -> `HTMLFormatter` / `HTMLSubsetParser` in `MarkdownRenderer` -> `RenderedBlock` values -> GTK widget construction in `MarkdownPreview`. Do not assume a WebView/WebKit architecture.
- Tests are split across:
  - `NotesRepositoryTests.swift` for repository, renderer, CLI parsing/integration, and MainWindow regression coverage via debug hooks.
  - `UISmokeTests.swift` for Wayland-native black-box UI checks under headless Weston + AT-SPI.

## Key conventions

- GTK-facing types are intentionally `@MainActor` (`MainWindow`, `NotesSidebar`, `MarkdownEditor`, `MarkdownPreview`, `AppState`, `AutosaveCoordinator`). Keep GTK widget mutation and UI orchestration on the main actor.
- `NotesRepository` is synchronous on purpose and serializes file access with its own `DispatchQueue`. Do not bypass it with ad-hoc filesystem writes from UI code.
- A note's display title comes from its markdown content, not its filename. Renaming a note means rewriting the first meaningful line of the markdown. Filenames are storage identifiers, not user-facing titles.
- Stable note identity is the lowercase UUID string exposed as `stableID`. Filenames encode timestamp + UUID, and `loadNotes()` reconstructs IDs from that filename format. In tests that depend on restored selection/persisted state, create notes through `NotesRepository` instead of inventing arbitrary filenames.
- First launch seeds `Markdown Showcase`, `About Swifty Notes`, and `Using Swifty Notes CLI` only when the notes directory has no `.md` files. The showcase also includes a companion image asset in the note-local `assets/` directory.
- The CLI is intentionally storage-compatible with the GUI. `swiftynotes cli update` replaces the full markdown content of a note; do not implement partial patch semantics there unless the CLI contract changes explicitly.
- For unit-style UI regressions, prefer existing `MainWindow.debug...` helpers instead of trying to drive GTK widgets directly. Reserve `UISmokeTests` for real black-box Wayland scenarios that rely on accessibility-visible names and persisted startup state.
- `UISmokeTests` use a unique `SWIFTY_NOTES_APP_ID` per run so the smoke harness does not accidentally activate an already running `swiftynotes` instance. Keep that isolation behavior if you expand the smoke harness.
