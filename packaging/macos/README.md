# Swifty Notes on macOS — Xcode project

Xcode 26+ project that builds Swifty Notes into a regular macOS `.app`
bundle. Open `swiftynotes.xcodeproj` in Xcode, hit **⌘R**, and the
familiar sidebar / editor / preview window comes up.

> macOS port note. The bundle is GTK4 wrapped in a Cocoa-style `.app` —
> not a native Cocoa app. HeaderBars, dialogs, and toast styling look
> like libadwaita on macOS rather than AppKit. The Linux Snap / Flathub
> builds remain the canonical distribution.

## Prerequisites

```bash
brew install libadwaita gtksourceview5 libspelling pkgconf
```

Plus Rust ([rustup](https://rustup.rs)) for the math engine. Build it once
from the repository root before the first Xcode build, and again after
changing `Sources/RaTeXBridge`:

```bash
scripts/build-ratex-bridge.sh
```

Pulls `gtk4`, `glib`, `cairo`, `pango`, `gdk-pixbuf`, `harfbuzz`,
`librsvg`, `enchant`, and ~30 transitive deps (~1.5–2 GB).

Apple Silicon assumed. For Intel, replace `/opt/homebrew` with
`/usr/local` in `Project.xcconfig` and `Info.plist`.

Xcode 26.4.1 (Swift 6.3) recommended — matches the SwiftPM
`swift-tools-version: 6.0` floor in the parent `Package.swift` plus
the `MACOSX_DEPLOYMENT_TARGET = 13.0` in `Project.xcconfig`.

## Layout

```
packaging/macos/
├── swiftynotes.xcodeproj/      Xcode 26+ format (objectVersion 77)
├── swiftynotes/
│   ├── main.swift              entry point — calls SwiftyNotesLauncher.run()
│   └── Assets.xcassets/        icon catalog (left empty by default)
├── Info.plist                  bundle metadata + LSEnvironment
└── Project.xcconfig            Homebrew header / library / link flags
```

`swiftynotes/` is added to the target via Xcode's `PBXFileSystemSynchronizedRootGroup`,
so any new file dropped there gets compiled automatically.

## How it hangs together

1. **`Project.xcconfig`** lists Homebrew GTK4 / libadwaita / gtksourceview /
   libspelling header and library paths explicitly — Xcode has no native
   `pkg-config`. Both project- and target-level `XCBuildConfiguration`
   reference it via `baseConfigurationReference`. App Sandbox + Hardened
   Runtime are off (libadwaita dlopens GModule plugins from `/opt/homebrew/lib`,
   which the sandbox would block); enable both for distribution.

2. **The Xcode app target depends on the local Swift package** (relative
   path `../..`, the swifty-notes-gtk repo root) — specifically the
   `SwiftyNotes` library product. The `swiftynotes` SPM executable is
   ignored; we drive `SwiftyNotesLauncher.run(...)` directly from
   `main.swift` so the same gallery / sidebar / editor logic runs on
   Linux (`swift run swiftynotes`) and inside the `.app` bundle.

3. **`main.swift` runs `Adwaita.Application.run()` indirectly** via
   `SwiftyNotesLauncher.run(arguments: [])`. We pass an empty arguments
   array on purpose: `CommandLine.arguments` under Xcode's debug-launch
   contains `-NSDocumentRevisionsDebugMode YES` and similar Cocoa flags
   that GApplication aborts on. The launcher already manages its own
   internal CLI mode without needing argv from Xcode.

4. **`Info.plist` `LSEnvironment`** exports
   `XDG_DATA_DIRS=/opt/homebrew/share` so libadwaita finds its compiled
   GSettings schemas when the app is double-clicked or `open .app`'d
   (Launch Services injects `LSEnvironment` then). Xcode's debug-launch
   bypasses Launch Services, so the **shared scheme**
   (`swiftynotes.xcscheme`'s Run > Environment Variables) sets the same
   variable for ⌘R.

## Running

In Xcode: open `swiftynotes.xcodeproj`, scheme `swiftynotes` → ⌘R.

Command line (debug build, then launch through Launch Services):

```bash
xcodebuild -project packaging/macos/swiftynotes.xcodeproj \
           -scheme swiftynotes -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/swiftynotes-*/Build/Products/Debug/swiftynotes.app
```

(`open` goes through Launch Services, which is what applies
`LSEnvironment`.)

## Distributing the bundle

The Xcode-built bundle is **not portable** as it links against
`/opt/homebrew/lib/lib*.dylib` by absolute path. Turning it into
something you can hand to a Mac without Homebrew installed is a
three-step pipeline; the first step is automated.

### 1. Vendor brew dylibs + GTK runtime resources

```bash
brew install dylibbundler                  # one-time, ~200 KB
./scripts/bundle-macos-app.sh \
    /path/to/Build/Products/Release/swiftynotes.app
```

`scripts/bundle-macos-app.sh` does, in order:

* runs `dylibbundler` on the executable to copy every transitively
  linked brew dylib (~49 files, 66 MB) into `Contents/Frameworks/`
  and rewrite their install names to
  `@executable_path/../Frameworks/`;
* copies `gschemas.compiled` into `Contents/Resources/glib-2.0/schemas/`
  so libadwaita's `gtk_init` finds its settings schemas;
* copies the `Adwaita` and `hicolor` icon themes into
  `Contents/Resources/icons/` so every `Image(iconName: …)` lookup
  resolves;
* copies the 13 `gdk-pixbuf-2.0` module loaders into
  `Contents/Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders/`, rewrites
  each loader's `/opt/homebrew/...` LC_LOAD_DYLIB entries to
  `@executable_path/../Frameworks/...`, and emits a relocatable
  `loaders.cache` whose entries are bare filenames (the loader
  resolves them against the cache file's own directory);
* re-signs the bundle ad-hoc so macOS Gatekeeper actually lets it
  exec — `install_name_tool` and `dylibbundler` invalidate the
  signature Xcode applied, and on macOS 15+ Gatekeeper silently
  refuses to launch an unsigned/invalid binary (no error message,
  just exit 0 from `open .app`).

After this step the bundle has zero `/opt/homebrew/...` references in
any Mach-O it ships, and it launches with `env -i` (= a totally clean
environment, no PATH, no XDG\_\*, no GDK\_\*) on a Mac that doesn't have
Homebrew installed. `packaging/macos/swiftynotes/main.swift` sets the
runtime env vars (`XDG_DATA_DIRS`, `GDK_PIXBUF_MODULE_FILE`) off
`Bundle.main.resourcePath` at startup, so the `.app` is also
relocatable — drag it to `/Applications` (or anywhere) and it still
works.

The script is **not idempotent**: a second run on the same `.app`
errors out before doing damage (`dylibbundler` cannot trace
already-bundled install names back to the brew sources). To re-bundle,
do a clean rebuild first:

```bash
xcodebuild -project packaging/macos/swiftynotes.xcodeproj \
           -scheme swiftynotes -configuration Release clean build
./scripts/bundle-macos-app.sh /path/to/.../Release/swiftynotes.app
```

For Xcode integration, add a Run Script build phase on the `swiftynotes`
target gated on `${CONFIGURATION} == Release` that runs:
```sh
"${SRCROOT}/../../scripts/bundle-macos-app.sh" "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
```
This keeps the Debug developer loop fast (Debug builds skip vendoring
and continue linking against /opt/homebrew, which is what
`main.swift` falls back to when it detects no in-bundle schemas).

### 2. Code-sign with Developer ID and notarize

This is your responsibility — needs the certificate from your Apple
Developer account. Replace the ad-hoc signature from step 1 with a
real one and submit to Apple's notary service:

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: <Your Name> (<TeamID>)" \
  swiftynotes.app
ditto -c -k --keepParent swiftynotes.app SwiftyNotes.zip
xcrun notarytool submit SwiftyNotes.zip \
  --apple-id <email> --team-id <TeamID> --wait
xcrun stapler staple swiftynotes.app
```

Hardened Runtime (`--options runtime`) is required for notarization.
Sandboxing remains off (see `Project.xcconfig`) — libadwaita
dlopen's plugins from arbitrary paths and the sandbox would block
them. For App Store submission you'd additionally need the
`com.apple.security.cs.disable-library-validation` entitlement and
sandbox-compatible workarounds; out of scope here.

### 3. Wrap into a DMG

```bash
hdiutil create -volname "Swifty Notes" \
  -srcfolder swiftynotes.app -ov -format UDZO SwiftyNotes.dmg
```

### 4. (Optional) Publish via Homebrew Cask

Once the DMG is signed, notarized, and hosted somewhere, write a
Cask formula in your tap and submit it to `homebrew/homebrew-cask`.
End users then `brew install --cask swifty-notes`.

**Bundle size:** ~75 MB total (66 MB Frameworks/, 2.6 MB Resources/,
6 MB executable). GTK 4's 78 MB raw install shrinks because
`dylibbundler` only copies what's actually linked — pango-otf,
mediafile backends, etc. don't ride along.
