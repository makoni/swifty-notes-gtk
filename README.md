# Swifty Notes

Native GTK markdown notes for Linux, written in Swift with `swift-adwaita`.

## Features

- file-backed markdown notes stored in per-note directories with `note.md`, `meta.json`, and `assets/`
- GTK/libadwaita UI with notes sidebar, live Markdown editor, and inspector-style preview
- first-launch seeded example note (`Markdown Showcase`)
- autosave, manual save, import/export, duplicate, rename, delete, and open-notes-folder flows
- settings window for choosing and moving the notes storage folder
- editor preferences for line wrapping, font size, tab width, and spaces-vs-tabs indentation
- configurable autosave delay and appearance override (follow system, light, dark)
- configurable note storage location that can live in a cloud-synced folder for cross-device sync
- CLI for listing, reading, creating, and replacing notes by stable ID
- workspace persistence for selection, search, sort mode, sidebar/preview visibility, and window layout
- native Wayland UI smoke coverage with headless Weston + AT-SPI

## Project layout

- `Sources/swiftynotes/main.swift` starts either the GTK app or the CLI entrypoint via the shared `SwiftyNotes` module.
- `Sources/SwiftyNotes/UI/` contains the main window, sidebar, editor, and preview widgets.
- `Sources/SwiftyNotes/Storage/` contains note persistence and workspace-state persistence.
- `Sources/SwiftyNotes/Services/MarkdownRenderer.swift` converts markdown into the native GTK preview model.
- `Tests/SwiftyNotesTests/` contains repository/MainWindow regressions, CLI tests, and Wayland UI smoke tests.

## Requirements

- Swift 6 toolchain
- Linux desktop environment with GTK 4, libadwaita, and GtkSourceView 5 available

If you want to test local `swift-adwaita` changes instead of the pinned git revision, set `SWIFTY_NOTES_LOCAL_SWIFT_ADWAITA_PATH=/absolute/path/to/swift-adwaita` before building.

## Build and run

```bash
swift build
swift run swiftynotes
```

## Tests

Run the full suite:

```bash
swift test --no-parallel
```

Run one regression:

```bash
swift test --filter 'mainWindowPresentRendersPreviewForInitiallySelectedNote' --no-parallel
```

Run one Wayland smoke test:

```bash
swift test --filter 'appLaunchesUnderHeadlessWaylandWithAccessibleWindowAndSeededControls' --no-parallel
```

The smoke tests require a working session bus and tools such as `weston` and `pyatspi`.

## Release packaging

Release packaging assets live under `packaging/`, `snap/`, and `data/`.

- Build a staged Linux install root: `packaging/release/assemble-install-root.sh --version 1.0.0 --dest packaging/out/install-root-usr --prefix /usr`
- Build a `.deb` from that root: `packaging/release/build-deb.sh --version 1.0.0 --install-root packaging/out/install-root-usr --output packaging/out/deb`
- Build a source-built `.flatpak` bundle: `packaging/release/build-flatpak.sh --version 1.0.0 --output packaging/out/flatpak`
- Build `.rpm` artifacts in CI with `packaging/release/build-rpm.sh`

The Flatpak manifest template lives in `flatpak/me.spaceinbox.swiftynotes.yml.in` and pins the SwiftPM dependency sources used in CI. GitHub Actions release automation lives in `.github/workflows/release-packages.yml` and accepts a `version` input via `workflow_dispatch`.

## CLI

The same executable exposes a CLI:

```bash
swift run swiftynotes -- cli list
swift run swiftynotes -- cli get <note-id>
swift run swiftynotes -- cli get <note-id> --raw
swift run swiftynotes -- cli create --content '# Title\n\nBody'
swift run swiftynotes -- cli update <note-id> --stdin
```

`update` replaces the full markdown content of the target note. The CLI emits JSON that is easy to drive from scripts, shell pipelines, and AI agents while still operating on the same file-backed notes as the desktop app.

## Storage

- Notes directory by default: `XDG_DATA_HOME/me.spaceinbox.swiftynotes/notes`
- Configurable notes directory: set in the app via **Settings** and persisted in `XDG_CONFIG_HOME/me.spaceinbox.swiftynotes/settings.json`
- Workspace state: `XDG_STATE_HOME/me.spaceinbox.swiftynotes/workspace.json`

If the notes directory is empty on first launch, the app creates the `Markdown Showcase` note automatically.

When you change the notes folder in Settings, the app moves the existing notes directory to the new location. The CLI follows the same configured folder automatically unless `--notes-dir` is passed explicitly.

That makes it practical to place the notes folder inside a cloud-synced directory such as Google Drive, Nextcloud, Syncthing, or another file-sync service and keep the same plain files in sync across devices.

## Settings

The Settings window currently lets you configure:

- notes storage location
- editor line wrapping
- editor font size
- editor tab width
- spaces vs tabs indentation
- autosave delay
- appearance override

This combination lets you tailor the editor to your screen and writing style while also relocating note storage to a directory that your preferred sync tool already mirrors.

## Preview architecture

The preview is fully native GTK. The rendering pipeline is:

`swift-markdown` -> `HTMLFormatter` -> local HTML subset parser -> `RenderedBlock` -> GTK widgets

There is no WebKit/WebView dependency.

## License

MIT. See [LICENSE](LICENSE).
