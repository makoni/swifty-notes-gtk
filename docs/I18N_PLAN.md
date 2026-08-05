# Swifty Notes Internationalization (i18n) Plan

> Goal: Make all user-visible strings translatable using the standard GLib gettext infrastructure already bundled in `swift-adwaita`.

---

## 0. Prerequisites — Already Available

`swift-adwaita` ships a `Localization.swift` module wrapping GLib's gettext functions:

| Function | Purpose |
|---|---|
| `localized("String")` / `"String".localized` | Translates a string |
| `localizedWithContext("context", "String")` | Disambiguates same text in different contexts |
| `nlocalized("singular", "plural", count: n)` | Plural-aware translation |
| `setTextDomain("com.example.App")` | Sets the gettext domain |

Uses `g_dgettext()` / `g_dngettext()` under the hood. No additional dependency needed.

---

## 1. Architecture

```
                            SwiftyNotesLauncher.run()
                            ┌──────────────────────────┐
                            │  initializeLocalization() │  ← called ONCE, before anything else
                            │  - g_setlocale()          │
                            │  - setTextDomain()        │
                            │  - bindtextdomain()       │
                            └──────────┬───────────────┘
                                       │
                     ┌─────────────────┴─────────────────┐
                     │                                   │
              ┌───────────┐                       ┌────────────┐
              │   GUI      │                       │    CLI     │
              │  Path      │                       │    Path    │
              │  (GTK app) │                       │ (swiftynotes cli)│
              └───────────┘                       └────────────┘
                     │                                   │
              ┌───────────┐                       ┌────────────┐
              │ UI/       │                       │ CLI/       │
              │ "text".localized                    │ "text".localized
              └───────────┘                       └────────────┘
              ┌───────────┐                       ┌────────────┐
              │ Services/ │                       │ Storage/   │
              │ "text".localized                    │ "text".localized
              └───────────┘                       └────────────┘
                     │                                   │
              ┌───────────┐                       ┌────────────┐
              │  .mo files │                       │  .mo files │
              │ locale/   │                       │ locale/    │
              └───────────┘                       └────────────┘
```

**Domain**: `me.spaceinbox.swiftynotes` (matches the app ID / GSettings schema)

---

## 2. Inventory of Hardcoded Strings

### 2.1 UI Labels & Chrome (UI/ directory)

| File | String(s) | Type |
|---|---|---|
| `MainWindow.swift:309,71` | `"Swifty Notes"`, `"Markdown notes"` | Window title / subtitle |
| `MainWindow.swift:310` | `"Swifty Notes"` (fallback title) | Window title |
| `MainWindowEditorToolbar.swift:9,14,19` | `"Editor"`, `"Split"`, `"Preview"` | View mode toggles |
| `MainWindowPreviewPane.swift:425-429,441-451,476-477` | `"Settings"`, `"Open Markdown File…"`, `"Import into Library…"`, `"Reload from disk"`, `"Open notes folder"`, `"Check for Updates…"`, `"About Swifty Notes"`, `"Library"`, `"Help"` | Menu items + section titles |
| `MainWindowPreviewPane.swift:529-537,542-547` | `"Hide Notes Sidebar"`, `"Show Notes Sidebar"`, `"New Note"`, `"New Folder"`, `"Save Note"`, `"Delete Note"`, `"Main Menu"`, `"Editor only"`, `"Split view"`, `"Preview only"` | Tooltips + accessibility labels |
| `NotesSidebar.swift:36` | `"Notes List"` | Accessible label |
| `NotesSidebar.swift:50` | `"Notes"` | Title label |
| `NotesSidebar.swift:54` | `"Search notes"` | Placeholder |
| `NotesSidebar.swift:57` | `"Search Notes"` | Accessible label |
| `NotesSidebar.swift:61` | `"Sort Notes"` | Dropdown tooltip |
| `NotesSidebar.swift:79` | `"No notes yet."` | Empty label |
| `NotesSidebar.swift:143` | `"Notes Sidebar"` | Accessible label |
| `NotesSidebar.swift:199-207` | `"Notes"`, `"No notes yet. Create one with +"`, `"No notes match..."`, `"Notes (N)"`, `"Notes (N/M)"` | Dynamic titles |
| `NotesSidebar.swift:242` | `"Trash"` | Row label |
| `NotesSidebar.swift:259` | `"Trash"` | Trash row title |
| `NotesSidebar.swift:264` | `"N"` (count) | Badge |
| `NotesSidebar.swift:297-299` | `"Deleted"`, `"Deleted \(date)"` | Trashed note subtitle |
| `NotesSidebar.swift:367` | `"Folder N"` | Folder row accessible label |
| `NotesSidebar.swift:387` | Folder display name | Folder title |
| `NotesSidebar.swift:485-500` | `"Newest First"`, `"Oldest First"`, `"Sort by Title"`, `"Sort Notes by..."` | Sort tooltips & a11y |
| `FindReplaceBar.swift:141` | `"Find…"` | Find placeholder |
| `FindReplaceBar.swift:146-147` | `"Case Sensitive"` | Tooltip + a11y |
| `FindReplaceBar.swift:151-152` | `"Whole Word Match"` | Tooltip + a11y |
| `FindReplaceBar.swift:156-157` | `"Regular Expression"` | Tooltip + a11y |
| `FindReplaceBar.swift:167-168` | `"Previous Match"` | Tooltip + a11y |
| `FindReplaceBar.swift:172-173` | `"Next Match"` | Tooltip + a11y |
| `FindReplaceBar.swift:177` | `"Replace…"` | Replace placeholder |
| `FindReplaceBar.swift:180-181` | `"Replace"` / `"Replace the current match"` | Button + tooltip |
| `FindReplaceBar.swift:183-184` | `"Replace All"` / `"Replace every match"` | Button + tooltip |
| `FindReplaceBar.swift:253,259,261` | `"No matches"`, `"N of M"`, `"N match(es)"` | Match counter |
| `CommandPaletteWindow.swift:81` | `"Jump to heading"` | Dialog title |
| `CommandPaletteWindow.swift:86` | `"Jump to heading…"` | Placeholder |
| `CommandPaletteWindow.swift:126` | `"↑↓ navigate · ↵ jump · Esc close"` | Keyboard hints |
| `CommandPaletteWindow.swift:248-249` | `"No headings in this note."`, `"No headings match \"N\""` | Empty state |
| `CommandPaletteWindow.swift:325` | `"current"` | Highlighted item hint |
| `CommandPaletteWindow.swift:298` | `"N ›"` (parent breadcrumb) | Parent indicator |
| `OutlineSidebar.swift:27` | `"Note Outline"` | Accessible label |
| `OutlineSidebar.swift:42` | `"Filter headings…"` | Placeholder |
| `OutlineSidebar.swift:45` | `"Filter Outline"` | Accessible label |
| `OutlineSidebar.swift:79` | `"Outline"` | Title |
| `OutlineSidebar.swift:98` | `"Outline Sidebar"` | Accessible label |
| `OutlineSidebar.swift:226` | `"N section(s) · N subsection(s)"` | Footer |
| `OutlineSidebar.swift:276` | `"No headings in this note. Add ## Heading to start."` | Empty state with link |
| `OutlineSidebar.swift:281` | `"No headings match the filter."` | Empty state |
| `SettingsWindow.swift:76` | `"Settings"` | Window title |
| `SettingsWindow.swift:115` | `"Settings"`, `"Preferences"` | Header bar |
| `SettingsWindow.swift:120-121` | `"Storage"`, `"Choose where Swifty Notes stores markdown files..."` | Preferences group |
| `SettingsWindow.swift:162-163` | `"Editor"`, `"Control wrapping, indentation..."` | Preferences group |
| `SettingsWindow.swift:196-197` | `"Preview"`, `"Control how rendered Markdown..."` | Preferences group |
| `SettingsWindow.swift:205-206` | `"Saving"`, `"Autosave runs after the last edit..."` | Preferences group |
| `SettingsWindow.swift:217-219` | `"Appearance"`, `"Override the application theme..."` | Preferences group |
| `SettingsWindow.swift:227-229` | `"Spell check"`, `"Underline misspellings..."` | Preferences group |
| `SettingsWindow.swift:247-249` | `"Outline"`, `"Tweak the right-hand outline..."` | Preferences group |
| `SettingsWindow.swift:20-37` | `"Notes folder"`, `"Use default location"`, `"Open current folder"`, `"Empty Trash automatically"`, `"Wrap long lines"`, `"Editor font size"`, `"Tab width"`, `"Indent style"`, `"Autosave delay"`, `"Appearance"`, `"Enable spell-check"`, `"Spell-check language"`, `"Outline density"`, `"Tree lines under H2 sections"`, `"Drag handles on hover"`, `"Breadcrumb strip above editor"`, `"Render emoji shortcodes"` | ActionRow titles |
| `SettingsWindow.swift:38-44` | `"Never"`, `"After 7 days"`, `"After 30 days"`, `"After 90 days"`, `"After a year"` | Trash retention options |
| `SettingsWindow.swift:45-47` | `"Browse…"` / `"Reset"` / `"Open"` | Button labels |
| `SettingsWindow.swift:172,180,209` | `"Points"`, `"Columns"`, `"Seconds"` | Unit labels |
| `SettingsWindow.swift:251-257,262-267` | Section-specific subtitles | Preferences descriptions |
| `SettingsWindow.swift:294` | `"Choose Notes Folder"` | File dialog title |
| `SettingsWindow.swift:308` | `"Could not choose a notes folder"` | Error heading |
| `SettingsWindow.swift:329` | `"Could not change the notes folder"` | Error heading |
| `SettingsWindow.swift:340` | `"Could not open notes folder"` | Error heading |
| `SettingsWindow.swift:444` | `"Could not update settings"` | Error heading |
| `UpdateBanner.swift:14,47` | `"Update"` / `"Dismiss"` | Button + tooltip |
| `UpdateBanner.swift:48` | `"Dismiss update notification"` | Accessible label |
| `UpdateBanner.swift:69` | `"Version N is available."` | Banner label |
| `ExternalDocumentWindowOutline.swift:24` | `"Hide outline (F9)"` / `"Show outline (F9)"` | Tooltip |
| `ExternalDocumentWindowOutline.swift:29` | `"No headings to jump to."` | Toast |
| `MainWindowSidebarDnD.swift:185` | `"Folder moved"` | Toast |
| `MainWindowEditorState.swift:10` | (empty toast dismiss) | N/A |
| `MainWindowEditorState.swift:11` | `"Sorting by N"` | Toast |
| `MainWindowEditorState.swift:26` | `"Markdown notes"` | Header subtitle |
| `MainWindowEditorState.swift:94` | `"Note saved"` | Toast |
| `MainWindowEditorState.swift:100` | `"Could not save note: N"` | Toast |
| `MainWindowEditorState.swift:108` | `"Title"` | Entry placeholder |
| `MainWindowEditorState.swift:113-114` | `"Rename note"`, `"The note title is derived..."` | Dialog heading/body |
| `MainWindowEditorState.swift:117-118` | `"Cancel"` / `"Rename"` | Dialog buttons |
| `MainWindowEditorState.swift:149` | `"Note renamed"` | Toast |
| `MainWindowEditorState.swift:152` | `"Could not rename note"` | Error heading |
| `MainWindowNotes.swift:56` | `"Could not load notes"` | Error heading |
| `MainWindowNotes.swift:200` | `"Note duplicated"` | Toast |
| `MainWindowNotes.swift:203` | `"Could not duplicate note"` | Error heading |
| `MainWindowNotes.swift:228` | `"Moved \"N\" to Trash"` | Toast |
| `MainWindowNotes.swift:230` | `"Undo"` | Toast button |
| `MainWindowNotes.swift:238` | `"Could not delete note"` | Error heading |
| `MainWindowNotes.swift:261` | `"Note restored"` | Toast |
| `MainWindowNotes.swift:264` | `"Could not restore note"` | Error heading |
| `MainWindowNotes.swift:273-274` | `"Delete "N" forever?"`, `"This permanently removes..."` | Delete dialog |
| `MainWindowNotes.swift:276-277` | `"Cancel"` / `"Delete forever"` | Dialog buttons |
| `MainWindowNotes.swift:314` | `"Moved \"N\" permanently"` | Toast |
| `MainWindowNotes.swift:316` | `"Undo"` | Toast button |
| `MainWindowNotes.swift:321` | `"Could not permanently delete note"` | Error heading |
| `MainWindowActionsAndFiles.swift:11-13` | `"Open or create a note before..."`, `"Unsupported image type for N"` | Error descriptions |
| `MainWindowActionsAndFiles.swift:228` | `"Copied note ID"` | Toast |
| `MainWindowActionsAndFiles.swift:393` | `"Image added to note"` / `"Images added to note"` | Toast |
| `MainWindowActionsAndFiles.swift:419` | `"Image pasted into note"` | Toast |
| `MainWindowActionsAndFiles.swift:454` | `"Imported N"` | Toast |
| `MainWindowActionsAndFiles.swift:503,505` | `"Export Note"` / `"Export"` | Dialog title + accept label |
| `MainWindowActionsAndFiles.swift:605` | `"Swifty Notes"` | About dialog app name |
| `MainWindowActionsAndFiles.swift:607` | `"Sergey Armodin"` | Developer name |
| `MainWindowActionsAndFiles.swift:611` | `"© 2026 Sergey Armodin"` | Copyright |
| `MainWindowActionsAndFiles.swift:614` | `"A native GTK markdown notes app..."` | Comments |
| `MainWindowActionsAndFiles.swift:616` | `"Source Code"` | Link label |
| `MainWindowActionsAndFiles.swift:424,426` | `"Import into Library"` / `"Import"` | Dialog title + accept label |
| `MainWindowActionsAndFiles.swift:466,468` | `"Open Markdown File"` / `"Open"` | Dialog title + accept label |
| `MainWindowActionsAndFiles.swift:573-574` | `"Cancel"` / `"Merge"` | Dialog buttons |
| `MainWindowActionsAndFiles.swift:844` | `"OK"` | Dialog button |
| `MainWindowActionsAndFiles.swift:723` | `"Notes folder updated"` | Toast |
| `MainWindowActionsAndFiles.swift:742` | `"Notes reloaded from disk"` | Toast |
| `MainWindowUpdates.swift:58` | `"Swifty Notes is up to date."` | Toast |
| `MainWindowUpdates.swift:62` | `"Could not check for updates: N"` | Toast |
| `MainWindowUpdates.swift:69` | `"Could not check for updates: no internet"` | Toast |
| `MainWindowUpdates.swift:99` | `"Could not open release page: N"` | Toast |
| `TableSizePicker.swift:90` | `"Insert"` | Button label |
| `TableSizePicker.swift:87` | `"Back to size picker"` | Tooltip |
| `TableSizePicker.swift:259` | `"N × M table"` | Readout |
| `TableSizePicker.swift:261` | `"Hover to pick size"` | Readout |
| `TableSizePicker.swift:364-365` | `"Left-aligned"`, `"Centred"` | Alignment labels |
| `BreadcrumbStrip.swift:128` | `"›"` | Separator |
| `EditorFormattingToolbar.swift:128-129` | `"linked"` | CSS class — **NOT translatable** |

### 2.2 Services (non-UI display names)

| File | String(s) | Type |
|---|---|---|
| `AppSettings.swift:10,12` | `"Spaces"`, `"Tabs"` | Indent style display name |
| `AppSettings.swift:28,30` | `"Comfortable"`, `"Compact"` | Outline density display name |
| `AppSettings.swift:43,45,47` | `"Follow system"`, `"Light"`, `"Dark"` | Appearance mode display name |
| `MarkdownFormatting.swift:18-36` | `"Heading"`, `"Bold"`, `"Italic"`, `"Code"`, `"Link"`, `"Quote"`, `"Bulleted List"`, `"Numbered List"`, `"Task List"`, `"Insert Table"` | Accessibility labels |
| `MarkdownFormatting.swift:43-61` | `"Turn the current line into a heading"`, `"Wrap the selection in bold markdown"`, etc. | Tooltips |
| `MarkdownFormatting.swift:91,93,95,99,101` | `"Quote"`, `"</>"`, `"Bullets"`, `"1."`, `"[ ]"`, `"Table"` | Short labels |
| `UpdateChecker.swift:68,71` | `"Could not parse remote version \"N\""` | Error message |
| `UpdateChecker.swift:75` | `"Could not parse current version \"N\""` | Error message |
| `UpdateChecker.swift:82` | `"Could not resolve host"` | Error message |

### 2.3 Storage (error messages)

| File | String(s) | Type |
|---|---|---|
| `NotesDirectoryErrorMessage.swift:15-19` | `"Swifty Notes does not have permission..."`, `"There is not enough disk space..."`, `"The selected folder is on a read-only filesystem..."` | Error messages |
| `NotesDirectoryRelocator.swift:46,54,61,69` | `"The new notes folder cannot be inside..."`, `"The current notes folder could not be found."`, `"The selected destination is not a folder."`, `"Choose an empty destination folder..."` | Error messages |
| `NotesRepository.swift:87` | `"Unsupported image type for N"` | Error message |
| `NotesRepository.swift:104,106` | Folder name validation errors | Error messages |
| `NotesRepository.swift:114` | `"Cannot move \"N\" into its own descendant \"N\""` | Error message |

#### 2.7 External Document Window (UI/)

| File | String(s) | Type |
|---|---|---|
| `ExternalDocumentWindow.swift:85-87` | `"Editor"`, `"Split"`, `"Preview"` | View mode toggles (separate from MainWindow) |
| `ExternalDocumentWindowOutline.swift:24` | `"Hide outline (F9)"` / `"Show outline (F9)"` | Tooltip |
| `ExternalDocumentWindowOutline.swift:29` | `"No headings to jump to."` | Toast |
| `MainWindowOutline.swift:41` | `"Quick jump… (Ctrl+G)"`, `"No headings to jump to."` | Tooltip + toast |

### 2.8 CLI (CLI output + help)

| File | String(s) | Type |
|---|---|---|
| `NotesCLI.swift:93` | `"folders rm` cannot delete the root."` | Error message |
| `NotesCLI.swift:172` | Folder not empty error message | Error message |
| `NotesCLI.swift:help()` | Entire help text (~200 lines) — `"Usage: swiftynotes cli <command> [args]"`, `"Commands: list, get, update, folders, delete"`, `"Options: --help, --yes"`, etc. | Help text |
| `NotesCLI.swift:154` | `"interactive by default, scriptable with -y"` | Help subtitle |
| `NotesCLI.swift:214` | Folder path format explanation | Help text |
| `NotesCLI.swift:369,384,399,413` | JSON output examples in help | Help text |

### 2.5 Seed data

| File | String(s) | Type |
|---|---|---|
| `MarkdownShowcaseSeed.swift:53` | `"Editor"`, `"Split"`, `"Preview"` | Onboarding text |

### 2.6 Find/Replace coordinator

| File | String(s) | Type |
|---|---|---|
| `FindReplaceCoordinator.swift:107-109` | `"No matches to replace."`, `"Replaced 1 occurrence."`, `"Replaced N occurrences."` | Toast messages |

---

## 3. Implementation Phases

### Phase 1: Infrastructure

**Goal**: Set up gettext infrastructure so `.localized` calls work at runtime.

1. **Create a shared `initializeLocalization()` function** that is called BEFORE any localized calls in both GUI and CLI paths:
   ```swift
   // In a shared module (e.g. AppLocalization.swift)
   func initializeLocalization() {
       // Set locale from environment (LC_ALL, LANG, etc.)
       // g_setlocale() sets the process-wide locale
       // Returns the locale string on success, nil on failure
       guard let locale = g_setlocale(GLOBAL_LOCALE, nil), !locale.isEmpty, locale != "C" else {
           // Fallback: default to "C" locale — safe but no localization
           // g_setlocale already set it to "C" by default
           return
       }
       // Set gettext domain — must match the app ID
       setTextDomain("me.spaceinbox.swiftynotes")
       // Bind the locale directory — see Phase 7 for how .mo files are shipped
       bindtextdomain("me.spaceinbox.swiftynotes", localeDirectoryPath())
   }
   ```

2. **Call it in both entry points** (BEFORE any Application/GTK init, BEFORE CLI dispatch):
   - GUI path: In `SwiftyNotesLauncher.run()` before `Application(id:...)` creation (line ~214)
   - CLI path: In `SwiftyNotesLauncher.run()` before `NotesCLI.runIfRequested()` (line ~202)

3. **Create `.pot` file** — extract all translatable strings using a Swift script (not `xgettext`):

   **Why a Swift script?** `xgettext --keyword=localized` matches function calls `localized("text")` but NOT property access `"text".localized`, which is the primary pattern in this codebase. A Swift script that walks AST nodes is reliable.

   The script walks all `.swift` files and finds:
   - `"String".localized` (property access on string literals)
   - `localized("String")` (function calls)
   - `localizedWithContext("context", "String")` (function calls with context)
   - `nlocalized("singular", "plural", count: n)` (function calls with two strings)
   - Output a standard GNU gettext `.pot` file

   See Section 4 for the extraction script structure.

4. **Create initial `.po` files** for target languages:
    - `po/de.po` (German)
    - `po/es.po` (Spanish)
    - `po/fr.po` (French)
    - `po/pt_BR.po` (Brazilian Portuguese)
    - `po/ja.po` (Japanese)
    - `po/ko.po` (Korean)
    - `po/zh_CN.po` (Simplified Chinese)
    - `po/zh_TW.po` (Traditional Chinese)
    - `po/ru.po` (Russian)
    - `po/it.po` (Italian)
    - `po/nl.po` (Dutch)
    - `po/ar.po` (Arabic)
    - `po/he.po` (Hebrew)

5. **Build `.mo` files**:
    ```bash
    msgfmt -o de/LC_MESSAGES/me.spaceinbox.swiftynotes.mo de.po
    ```

6. **Determine locale directory at runtime**:
    - First check `SWIFTY_NOTES_LOCALE_DIR` env var
    - Then check `/usr/share/locale` (system install)
    - Then check `./locale` relative to the bundle (SwiftPM/macOS)
    - For Flatpak: `/app/share/locale`

### Phase 2: Services Layer

**Goal**: Make pure-logic display names translatable.

Files to modify:
- `AppSettings.swift` — `EditorIndentStyle.displayName`, `OutlineDensity.displayName`, `AppearanceMode.displayName`
- `MarkdownFormatting.swift` — `MarkdownFormattingAction.accessibilityLabel`, `.tooltip`, `.shortLabel`
- `NotesSidebar.swift` — `displayDate()` stays as-is (uses `DateFormatter` which auto-localizes), `"Deleted"` → `.localized`, sort mode labels → `.localized`

Pattern:
```swift
// Before
var displayName: String { "Spaces" }

// After
var displayName: String { "Spaces".localized }
```

### Phase 3: UI Layer (labels, toasts, dialogs)

**Goal**: Wrap all UI strings in `.localized`.

Files to modify (all in `UI/` directory):

1. **MainWindow.swift** — window title, header subtitle
2. **MainWindowPreviewPane.swift** — menu items, section titles, tooltips, a11y labels
3. **MainWindowEditorState.swift** — dialogs, toasts
4. **MainWindowNotes.swift** — toasts, dialogs, error headings
5. **MainWindowActionsAndFiles.swift** — dialogs, toasts, error messages
6. **MainWindowUpdates.swift** — toasts
7. **MainWindowEditorToolbar.swift** — view mode toggles
8. **NotesSidebar.swift** — labels, placeholders, sort tooltips
9. **FindReplaceBar.swift** — placeholders, tooltips, match counter
10. **FindReplaceCoordinator.swift** — toast messages
11. **CommandPaletteWindow.swift** — dialog title, placeholder, empty states, hints
12. **OutlineSidebar.swift** — labels, placeholders, footer, empty states
13. **SettingsWindow.swift** — window title, header, preferences group titles/descriptions, button labels, dialog titles, error headings
14. **UpdateBanner.swift** — button labels, tooltip, banner label
15. **ExternalDocumentWindowOutline.swift** — tooltips, toast
16. **MainWindowSidebarDnD.swift** — toast
17. **TableSizePicker.swift** — button label, tooltip, readout text, alignment labels
18. **BreadcrumbStrip.swift** — separator (may not need translation)
19. **EditorFormattingToolbar.swift** — none (CSS classes)

**Important**: Dynamic strings with interpolation need `nlocalized`, `localizedWithContext`, or a format helper:

```swift
// Before
let toast = "Moved \"\(note.title)\" to Trash"

// After — use String(format) with GLib-style %s (NOT Swift's %@)
// The English template with %s is the msgid in the .po file.
// Translators translate the template, keeping %s. The %s position
// may be reordered in the translation (e.g. "Trash \"N\" Moved").
let toast = Toast(title: String(format: "Moved \"%s\" to Trash".localized, note.title))
```

⚠️ **Gotcha**: Use `%s` (GLib C style), NOT `%@` (Swift Objective-C style). gettext expects C-style format specifiers. `String(format:)` with `%s` works because Swift's `String(format:)` accepts `%s` as a string placeholder.

⚠️ **Gotcha**: gettext `.po` files can't contain dynamic values. Patterns like `"N match(es)"` need `nlocalized`:
```swift
// Before
countLabel.text = "\(total) match\(total == 1 ? "" : "es")"

// After — nlocalized handles plural forms for all languages
countLabel.text = nlocalized("%d match", "%d matches", count: total)
```

### Phase 4: Storage Layer

**Goal**: Translatable error messages.

Files to modify:
- `NotesDirectoryErrorMessage.swift`
- `NotesDirectoryRelocator.swift`
- `NotesRepository.swift` (validation errors)

### Phase 5: CLI Layer

**Goal**: Translatable CLI messages.

File to modify:
- `NotesCLI.swift`

### Phase 6: About Dialog & Seed Data

**Goal**: Localize About dialog text and seed note content.

- `MainWindowActionsAndFiles.swift:presentAboutDialog()` — `comments` field, `addLink` label
- `MarkdownShowcaseSeed.swift` — seed note titles and content (or make them locale-aware)

### Phase 7: Build System & Packaging

**Goal**: `.mo` files ship with the app.

1. **SwiftPM**: Create a build script (`scripts/build-locales.sh`) that compiles `.po` → `.mo` at build time:
    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    LOCALE_DIR="${SWIFT_PACKAGE_RESOURCE_DIR}/locale"
    mkdir -p "$LOCALE_DIR"
    for lang in de es fr ja ko zh_CN zh_TW pt_BR ru it nl ar he; do
        if [[ -f "po/${lang}.po" ]]; then
            mkdir -p "${LOCALE_DIR}/${lang}/LC_MESSAGES"
            msgfmt -o "${LOCALE_DIR}/${lang}/LC_MESSAGES/me.spaceinbox.swiftynotes.mo" "po/${lang}.po"
        fi
    done
    ```
    Add a custom `run-script` build phase in `Package.swift` that calls this script, then reference the resource dir at runtime via `Bundle.module.resourceURL`.

2. **Flatpak**: Add locale exports in `flatpak/me.spaceinbox.swiftynotes.yml`:
    ```yaml
    modules:
      - name: swiftynotes-locales
        buildcommands:
          - msgfmt -o de/LC_MESSAGES/me.spaceinbox.swiftynotes.mo po/de.po
          - msgfmt -o fr/LC_MESSAGES/me.spaceinbox.swiftynotes.mo po/fr.po
          # ... etc
          - install -d $DESTDIR/share/locale
          - cp -r */LC_MESSAGES $DESTDIR/share/locale/
    ```

3. **macOS bundle**: Ship `.mo` files using the **gettext-standard** directory layout (NOT Cocoa `.lproj`):
    ```
    Swifty Notes.app/Contents/Resources/
    ├── de/
    │   └── LC_MESSAGES/
    │       └── me.spaceinbox.swiftynotes.mo
    ├── fr/
    │   └── LC_MESSAGES/
    │       └── me.spaceinbox.swiftynotes.mo
    └── ...
    ```
    Point `bindtextdomain("me.spaceinbox.swiftynotes", "Swifty Notes.app/Contents/Resources")` at this path at runtime. **Do NOT use `.lproj`** — gettext won't find translations there.

4. **Runtime locale directory resolution** (in `initializeLocalization`):
    ```swift
    func localeDirectoryPath() -> String? {
        // 1. SWIFTY_NOTES_LOCALE_DIR env var (for testing/debugging)
        if let envPath = ProcessInfo.processInfo.environment["SWIFTY_NOTES_LOCALE_DIR"],
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }
        // 2. Flatpak: /app/share/locale
        if FileManager.default.fileExists(atPath: "/app/share/locale") {
            return "/app/share/locale"
        }
        // 3. System: /usr/share/locale (for .deb/.rpm/native installs)
        if FileManager.default.fileExists(atPath: "/usr/share/locale") {
            return "/usr/share/locale"
        }
        // 4. macOS bundle: app-relative Resources/
        if let bundle = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: bundle.path) {
            return bundle.path
        }
        return nil
    }
    ```

### Phase 8: Testing

**Goal**: Verify translations load correctly.

⚠️ **Critical**: `g_setlocale()` is process-global. Tests that change locale will interfere with each other. Use one of these approaches:

**Option A**: Run all localization tests sequentially in a single `@MainActor` test suite.
**Option B**: Spawn a helper process per locale (the test runner binary itself, invoked with `LC_ALL=de_DE`).

1. **Unit tests** (`LocalizationTests.swift`):
   - **Basic translation**: Set locale to `de_DE` and verify key strings from the inventory are translated (not returned as English)
   - **Fallback to English**: Verify that when no `.mo` file is loaded, `.localized` returns the original string
   - **Plural forms** — must test enough counts to exercise all plural categories:
     - Arabic (6 forms): counts 0, 1, 2, 3-10, 11-99, 100+
     - Polish (3 forms): counts 1, 2, 5, 21, 100
     - Russian (2 forms): counts 1, 2, 5, 21, 100
     - English (2 forms): counts 0, 1, 2
   - **Context disambiguation**: Test `localizedWithContext` with same English string, two different contexts, verify each returns the correct translation
   - **Missing translation**: Load a partial `.mo` with only a few strings, verify all other strings fall back to English
   - **Edge cases**: Empty string `"".localized`, special characters in interpolated values (quotes, emoji, newlines), `localizedWithContext` with empty context
   - **No crash without setup**: Call `.localized` without calling `setTextDomain` — should return the original string, no crash
   - **Locale directory resolution**: Test each path priority (env var → Flatpak → system → bundle)

2. **Widget tests** (in `SwiftyNotesWidgetTests`):
   - Verify UI renders correctly with translated strings that are 2-3x longer than English (e.g., German often is)
   - Test that Settings Window labels, dialog buttons, and menu items don't overflow or clip
   - Test RTL layout (Arabic `ar_AE`): verify window layout mirrors, button order flips, text alignment is right-aligned

3. **CLI tests** (`LocalizationCLITests.swift`):
   - Run `swiftynotes cli` with `LC_ALL=de_DE.UTF-8` and verify error messages are German
   - Test `nlocalized` for CLI count messages ("1 note" vs "N notes")
   - Test CLI output is byte-valid UTF-8 in all target locales

4. **POT extraction correctness test**:
   - Run the extraction script and assert the output contains the expected number of entries (compare against the ~160+ strings in the inventory)
   - Verify every `.localized` call in the source code is present in the extracted `.pot` file

5. **Manual testing**:
   - Run the app with `LC_ALL=de_DE.UTF-8` and verify all screens
   - Run with `LC_ALL=ar_AE.UTF-8` and verify RTL layout
   - Run with `LC_ALL=ja_JP.UTF-8` and verify CJK font rendering
   - Test seed data localization (if implemented)

6. **Smoke test integration**:
   - Update `UISmokeTests` to be locale-aware — assert localized titles when available, or assert English as the universal fallback
   - Use the existing `SWIFTY_NOTES_APP_ID` per-run isolation pattern for locale-specific smoke tests

---

## 4. String Extraction Script

A Swift script to extract all `.localized` calls from the codebase. Place it at `scripts/extract-i18n.swift`.

**Why a Swift script instead of `xgettext`?** `xgettext --keyword=localized` matches function calls `localized("text")` but NOT property access `"text".localized`, which is the primary pattern throughout this codebase. A Swift AST walker is reliable for both patterns.

The script:
1. Walks all `.swift` files under `Sources/` (excluding `CSpelling/` and CLI help text comments)
2. Finds string literals followed by `.localized` property access
3. Finds function calls to `localized("String")`, `localizedWithContext("context", "String")`, `nlocalized("singular", "plural", count: n)`
4. For `nlocalized`, extracts both singular and plural as separate msgid/msgid_plural entries
5. Outputs a standard GNU gettext `.pot` file with proper headers

Run it after every batch of localization changes:
```bash
swift scripts/extract-i18n.swift > me.spaceinbox.swiftynotes.pot
```

Integrate into the build: call it as a `run-script` phase in `Package.swift`, or as a CI check that fails if the `.pot` file is out of date.

---

## 5. Non-Translatable Strings (Do NOT localize)

- CSS class names (`"navigation-sidebar"`, `"heading"`, `"flat"`, etc.)
- GTK icon names (`"pan-down-symbolic"`, `"format-text-bold-symbolic"`, etc.)
- Action names (`"rename-note"`, `"win.settings"`, etc.)
- Keyboard shortcuts (`"<Primary>q"`, `"F9"`, etc.)
- URL strings (`"https://github.com/..."`)
- File extensions (`"png"`, `"svg"`, `"md"`)
- MIME types (`"image/png"`, `"image/jpeg"`)
- HTML/XML tag names (`"blockquote"`, `"pre"`, `"span"`, etc.)
- Language identifiers in code (`"en"`, `"de"`, `"language-python"`)
- CSpelling/Markdown formatting prefixes (`"**"`, `"*"`, ```"```"`)
- Breadcrumb separator (`"›"`) — a Unicode standard symbol, consistent across locales
- Unicode escape characters and Pango markup

---

## 6. Implementation Order

1. **Phase 1** — Infrastructure (setlocale, setTextDomain, .pot extraction)
2. **Phase 2** — Services layer (display names, no UI changes)
3. **Phase 3** — UI layer (all the heavy lifting)
4. **Phase 5** — CLI layer (move before Storage — CLI help is large and user-facing)
5. **Phase 4** — Storage layer (error messages)
6. **Phase 6** — About dialog & seed
7. **Phase 7** — Build/packaging
8. **Phase 8** — Testing

---

## 7. Target Languages (Initial)

Start with the languages most relevant to the GNOME/Linux desktop audience, plus RTL languages for layout testing:

| Priority | Language | Code | RTL? |
|---|---|---|---|
| 1 | German | `de` | no |
| 2 | French | `fr` | no |
| 3 | Spanish | `es` | no |
| 4 | Japanese | `ja` | no |
| 5 | Simplified Chinese | `zh_CN` | no |
| 6 | Brazilian Portuguese | `pt_BR` | no |
| 7 | Korean | `ko` | no |
| 8 | Russian | `ru` | no |
| 9 | Italian | `it` | no |
| 10 | Dutch | `nl` | no |
| 11 | Arabic | `ar` | **yes** |
| 12 | Hebrew | `he` | **yes** |

---

## 8. Date/Time Formatting

`DateFormatter` with `.medium` style and `.short` style (already used in `NotesSidebar.displayDate()`) already respects locale. No changes needed.

**Exception**: The `"Deleted"` prefix in trashed notes should be localized separately from the date:
```swift
// Before
"Deleted \(displayDate(deletedAt))"

// After — concatenate localized text with already-localized date
"\("Deleted".localized) \(displayDate(deletedAt))"
```

**Why not use `String(format:)` here?** `DateFormatter` already returns a locale-aware string, so concatenation is cleaner. The date display doesn't need format specifiers, and translators won't need to understand `%s`.

---

## 9. Pluralization Rules

Different languages have different plural rules. GLib's `g_dngettext` handles this automatically:

| Pattern | Use |
|---|---|
| `"N match" / "N matches"` | `nlocalized` |
| `"N section(s)" / "N subsection(s)"` | `nlocalized` |
| `"1 occurrence" / "N occurrences"` | `nlocalized` |
| `"1 note" / "N notes"` (CLI) | `nlocalized` |
| `"1 subfolder" / "N subfolders"` (CLI) | `nlocalized` |

---

## 10. Migration Strategy

Since all `.localized` calls gracefully fall back to the original string when no translation is found, the migration is **non-breaking**:

1. Start with Phase 1 (infrastructure) — no visible change
2. Phase 2-6: Wrap strings one file at a time
3. Phase 7: Ship translations with the app
4. Phase 8: Add tests

At any point before Phase 7, the app works exactly as it does today (English only). The `.localized` calls are no-ops.
