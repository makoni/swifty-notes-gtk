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

The bundle as built is **not portable** — it links against
`/opt/homebrew/lib/lib*.dylib` by absolute path. For a `.app` you can
hand to someone who does not have Homebrew installed, you need to:

1. **Vendor the dylibs.** Copy every `lib*.dylib` the executable links
   against (and its transitive deps) into `swiftynotes.app/Contents/Frameworks/`,
   then rewrite the install names with `install_name_tool` so they
   resolve via `@rpath`. The `dylibbundler` Homebrew formula automates
   it:

   ```bash
   brew install dylibbundler
   dylibbundler -od -b -x swiftynotes.app/Contents/MacOS/swiftynotes \
     -d swiftynotes.app/Contents/Frameworks/ \
     -p @rpath/
   ```

   Add this as a Run Script build phase on Release builds.

2. **Bundle the GSettings schemas.** Copy
   `/opt/homebrew/share/glib-2.0/schemas/gschemas.compiled` (and any
   `.gschema.xml` Swifty Notes ships) into
   `swiftynotes.app/Contents/Resources/glib-2.0/schemas/` and update the
   `LSEnvironment` `XDG_DATA_DIRS` to
   `@executable_path/../Resources` (which Launch Services expands).

3. **Bundle GdkPixbuf loaders, Pango modules, GTK media backends** —
   any `*.dylib` that `gdk-pixbuf` / `pango` / `gtk-4.0` looks up at
   runtime via `*.cache` files. Set `GDK_PIXBUF_MODULE_FILE`, `GTK_PATH`,
   etc. via `LSEnvironment` at bundle-relative paths.

4. **Re-enable Hardened Runtime, then code-sign and notarize.**
   ```bash
   codesign --deep --options runtime \
     --sign "Developer ID Application: <you>" \
     swiftynotes.app
   ditto -c -k --keepParent swiftynotes.app SwiftyNotes.zip
   xcrun notarytool submit SwiftyNotes.zip \
     --apple-id <you> --team-id <id> --wait
   xcrun stapler staple swiftynotes.app
   ```

5. **Wrap into a DMG**:
   ```bash
   hdiutil create -volname "Swifty Notes" \
     -srcfolder swiftynotes.app -ov -format UDZO SwiftyNotes.dmg
   ```

6. **(Optional) Publish via Homebrew Cask.** Once the DMG is signed +
   notarized + hosted somewhere, write a Cask formula in your tap and
   submit it to homebrew-cask. End users then `brew install --cask
   swifty-notes`.

This list is the rough recipe — every GTK app on macOS does some
variation of these steps. A fully-vendored bundle is ≈80–120 MB
(GTK 4 alone is 78 MB).
