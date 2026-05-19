#!/usr/bin/env bash
# =============================================================================
# bundle-macos-app.sh
# =============================================================================
#
# Turns a freshly-built `swiftynotes.app` (whose Mach-O binary still links
# against `/opt/homebrew/...` dylibs) into a self-contained `.app` that can
# be handed to a Mac without Homebrew installed. Drop-in invocation:
#
#   scripts/bundle-macos-app.sh <path-to-swiftynotes.app>
#
# What this does, in order:
#
#   1. `dylibbundler` walks the executable's transitive dylib graph,
#      copies every non-system dylib into `Contents/Frameworks/`, rewrites
#      every `LC_LOAD_DYLIB` install name to `@rpath/<libname>`, and adds
#      an `LC_RPATH` of `@executable_path/../Frameworks` to the executable
#      itself. After this step the binary no longer references
#      `/opt/homebrew/...` for libraries.
#
#   2. Vendor GLib's compiled GSettings schemas into
#      `Contents/Resources/glib-2.0/schemas/gschemas.compiled`. libadwaita
#      reads these at startup; missing => `g_assert_not_reached()` during
#      AdwApplication init.
#
#   3. Vendor the Adwaita and hicolor icon themes into
#      `Contents/Resources/icons/`. Every `Image(iconName: …)` call in the
#      app (sidebar chevrons, toolbar buttons, trash icon, ...) looks up
#      icons from these themes; the lookup is rooted at directories named
#      by `XDG_DATA_DIRS`.
#
#   4. Vendor GdkPixbuf module loaders into
#      `Contents/Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders/`, and emit a
#      bundle-local `loaders.cache` that lists each loader by a
#      *relative* path (just `loaders/libpixbufloader_svg.so`, no
#      `/opt/homebrew` prefix). GdkPixbuf resolves relative paths in the
#      cache against the cache file's own directory, which makes the
#      bundle relocatable — the user can drag `swiftynotes.app` to
#      `/Applications` (or anywhere) and SVG-symbolic icon decoding still
#      works because nothing is pinned to a specific bundle install path.
#
# Three pieces are NOT bundled because they are not needed for a markdown
# notes app on macOS:
#
#   * Pango modules — deprecated upstream, no shaping plugins ship in
#     the brew Pango build that GTK4 actually loads.
#   * GTK media backends (gstreamer / ffmpeg pull-ins) — the app does
#     not play audio or video.
#   * Vulkan / MoltenVK — brew's gtk4 is compiled with `-Dvulkan=disabled`.
#     GSK falls back to the OpenGL renderer, which links libepoxy
#     statically; nothing to vendor.
#
# After this script returns, the bundle is portable but NOT signed and
# NOT notarized. For that, run codesign / notarytool / stapler on top —
# see packaging/macos/README.md.
# =============================================================================

set -euo pipefail

# -- arg parsing ---------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-swiftynotes.app>" >&2
  exit 64
fi

APP_BUNDLE="$1"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: $APP_BUNDLE does not exist or is not a directory" >&2
  exit 1
fi

if [[ ! -f "$APP_BUNDLE/Contents/MacOS/swiftynotes" ]]; then
  echo "error: $APP_BUNDLE/Contents/MacOS/swiftynotes not found — pass the .app, not its parent" >&2
  exit 1
fi

# Apple Silicon Homebrew prefix. For Intel Macs swap to /usr/local — but
# the project is already pinned to ARCHS=arm64, so this is fine here.
BREW_PREFIX="/opt/homebrew"

EXECUTABLE="$APP_BUNDLE/Contents/MacOS/swiftynotes"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

# Idempotency guard. `dylibbundler` walks the executable's LC_LOAD_DYLIB
# entries, copies referenced dylibs, and rewrites the install names to
# `@executable_path/../Frameworks/<libname>`. After step 1 those install
# names no longer point at `/opt/homebrew/...`, so a second invocation
# of this script on the same .app cannot trace dylibs — dylibbundler
# silently does nothing and may even sweep an existing Frameworks/ dir
# (the `-od` overwrite flag). Easy footgun. Detect it before doing damage.
#
# We sample one well-known dylib reference (libgtk-4) on the executable
# and check whether it still points at brew (= "fresh Xcode build, OK to
# bundle") or at a bundle-relative path (= "already bundled").
if otool -L "$EXECUTABLE" 2>/dev/null | grep -q "@executable_path/.*libgtk-4"; then
  echo "error: $APP_BUNDLE has already been processed by this script." >&2
  echo "       The executable's install names point into Contents/Frameworks/" >&2
  echo "       rather than /opt/homebrew/. Re-run from a fresh Xcode build:" >&2
  echo "" >&2
  echo "         xcodebuild -project packaging/macos/swiftynotes.xcodeproj \\" >&2
  echo "                    -scheme swiftynotes -configuration Release \\" >&2
  echo "                    clean build" >&2
  echo "         $0 $APP_BUNDLE" >&2
  exit 1
fi

echo "==> Bundling $APP_BUNDLE"

# -- 1. dylib vendoring --------------------------------------------------------
#
# Flags:
#   -od   overwrite existing dylibs in Frameworks (so re-runs are idempotent)
#   -b    bundle dylibs into the destination dir (the actual file copy)
#   -x    binary to scan and rewrite (executable itself)
#   -d    destination directory for vendored dylibs
#   -p    new install-name prefix
#
# We use `@executable_path/../Frameworks/` (and NOT `@rpath/`) as the
# prefix. `dylibbundler` with `-p @rpath/` would also try to add an
# LC_RPATH of `@rpath/` itself to the binary, which dyld rejects as a
# duplicate / cyclic load command at launch time. The fully-resolved
# `@executable_path/...` form needs no rpath at all — each install-name
# is self-locating relative to the executable, so the resulting Mach-O
# is cleaner.
#
# `dylibbundler` recursively follows LC_LOAD_DYLIB entries on every dylib
# it copies in, so a single -x on the executable picks up the full
# transitive graph (gtk4 → glib → ... → libintl).

echo "==> [1/4] Vendoring dylibs via dylibbundler"
mkdir -p "$FRAMEWORKS_DIR"
dylibbundler -od -b \
  -x "$EXECUTABLE" \
  -d "$FRAMEWORKS_DIR" \
  -p "@executable_path/../Frameworks/" \
  >/dev/null

# Normalize LC_RPATH commands. dyld rejects duplicate rpaths at launch
# with `duplicate LC_RPATH '<path>'`, so the binary must have AT MOST
# ONE copy of each unique rpath value. Xcode adds an
# `@executable_path/../Frameworks/` rpath at link time (for Swift
# runtime resolution); `dylibbundler -p @executable_path/../Frameworks/`
# then adds the same rpath again unconditionally; we may also have
# stale `@rpath/` entries from older runs of this script. Drain every
# LC_RPATH the binary has, then re-add exactly one canonical entry.
#
# `install_name_tool -delete_rpath X` removes one occurrence per call;
# if X is no longer present it errors, hence the `|| true` and the
# while-loop that keeps deleting until none of the candidates remain.
for stale in "@rpath/" "@executable_path/../Frameworks/" "@executable_path/../Frameworks"; do
  while install_name_tool -delete_rpath "$stale" "$EXECUTABLE" 2>/dev/null; do
    :  # keep deleting same-named duplicates until install_name_tool exits non-zero
  done
done
install_name_tool -add_rpath "@executable_path/../Frameworks/" "$EXECUTABLE"

# -- 2. GSettings schemas ------------------------------------------------------

echo "==> [2/4] Vendoring GSettings schemas"
SCHEMAS_DEST="$RESOURCES_DIR/glib-2.0/schemas"
mkdir -p "$SCHEMAS_DEST"
# `gschemas.compiled` is the only file we need at runtime; the .xml
# sources are descriptive and not consulted by libadwaita/Gio.
cp "$BREW_PREFIX/share/glib-2.0/schemas/gschemas.compiled" "$SCHEMAS_DEST/"

# -- 3. Icon themes ------------------------------------------------------------
#
# The app references Adwaita symbolic icons by name (e.g. `list-add-symbolic`).
# GTK searches `<XDG_DATA_DIR>/icons/<theme>/`, so we mirror exactly
# `share/icons/Adwaita` and `share/icons/hicolor` into `Resources/icons/`.
# `rsync -a --delete` keeps re-runs idempotent and skips files unchanged
# since the last run; cuts a clean copy by ~80% on subsequent invocations.
#
# `-L` (--copy-links) dereferences symlinks during the copy. Brew's icon
# dirs use relative symlinks pointing back into `../../../Cellar/<formula>/`,
# and `share/icons/hicolor/<size>/apps/qemu.*` aliases into the qemu cask.
# A plain `rsync -a` would mirror those links verbatim — they then resolve
# inside the bundle to non-existent `<bundle>/Cellar/...` paths, leaving
# broken symlinks. `codesign --verify --strict` traverses every sealed
# resource and fails with "No such file or directory" when it hits one,
# which previously broke the entire release pipeline.
echo "==> [3/4] Vendoring icon themes (Adwaita + hicolor)"
ICONS_DEST="$RESOURCES_DIR/icons"
mkdir -p "$ICONS_DEST"
rsync -aL --delete "$BREW_PREFIX/share/icons/Adwaita/" "$ICONS_DEST/Adwaita/"
rsync -aL --delete "$BREW_PREFIX/share/icons/hicolor/" "$ICONS_DEST/hicolor/"

# -- 4. GdkPixbuf module loaders ----------------------------------------------
#
# GdkPixbuf needs at least the SVG loader (`libpixbufloader_svg.so`) to
# decode Adwaita's symbolic icons; PNG support is built into libgdk_pixbuf
# itself and does not need a loader. We copy *all* loaders for resilience —
# total size is small (~1.5 MB) and saves the user a confusing
# "failed to decode image format X" later.
#
# The trick is the cache file. `gdk-pixbuf-query-loaders` prints absolute
# paths to whatever loaders you pass it, but absolute paths break the
# moment the user drags the bundle to /Applications. So we:
#   * generate the cache pointing at the loaders by their FULL brew path
#   * then sed-rewrite each absolute path down to its bare filename
#
# GdkPixbuf's loader-cache parser falls back to resolving each entry's
# first-line filename against the cache file's containing directory,
# which is exactly where we put the loaders. The result: a fully
# self-contained, relocatable Resources/lib/gdk-pixbuf-2.0/... tree.

echo "==> [4/4] Vendoring GdkPixbuf loaders + relocatable cache"
LOADERS_DEST="$RESOURCES_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders"
CACHE_DEST="$RESOURCES_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
mkdir -p "$LOADERS_DEST"
cp "$BREW_PREFIX/lib/gdk-pixbuf-2.0/2.10.0/loaders/"*.so "$LOADERS_DEST/" 2>/dev/null || true
cp "$BREW_PREFIX/lib/gdk-pixbuf-2.0/2.10.0/loaders/"*.dylib "$LOADERS_DEST/" 2>/dev/null || true

# Generate the cache. `gdk-pixbuf-query-loaders` reads the loaders we
# point it at and emits a parseable text manifest of which loader
# handles which MIME type / file extension / magic bytes.
"$BREW_PREFIX/bin/gdk-pixbuf-query-loaders" "$LOADERS_DEST/"*.so "$LOADERS_DEST/"*.dylib \
  2>/dev/null \
  > "$CACHE_DEST"

# Strip the absolute prefix from each loader line. After this every
# `"libpixbufloader_svg.so"` is just a filename, which GdkPixbuf resolves
# against the cache file's own directory at runtime.
#
# sed -i '' is the BSD form (macOS); GNU sed would be -i without the ''.
LOADERS_PREFIX_ESCAPED=$(printf '%s' "$LOADERS_DEST/" | sed 's/[\/&]/\\&/g')
sed -i '' "s|$LOADERS_PREFIX_ESCAPED||g" "$CACHE_DEST"

# The loaders themselves are dlopen()'d at runtime by libgdk_pixbuf — they
# are not in the executable's LC_LOAD_DYLIB graph, so dylibbundler's
# `-x $EXECUTABLE` pass in step 1 never saw them. Each loader still
# references its build-time brew paths for libgdk_pixbuf, libglib,
# libgobject, libtiff, libintl, librsvg, etc. On a machine WITH brew
# installed those paths happen to resolve and the bundle appears to
# "work" while still being fundamentally non-portable; on a clean Mac
# they fail. Rewrite every loader's LC_LOAD_DYLIB to point into our
# already-vendored Frameworks/ directory.
#
# Strategy:
#   1. Each Mach-O loader has install names like
#      `/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib`. We just need to
#      know the basename (libglib-2.0.0.dylib) — that file already
#      exists in Frameworks/ because dylibbundler put it there for the
#      executable.
#   2. `install_name_tool -change OLD NEW` rewrites a single
#      LC_LOAD_DYLIB entry per call.
#   3. For each `/opt/homebrew/...` reference we find via `otool -L`,
#      compute `@executable_path/../Frameworks/<basename>` and rewrite.
#
# The librsvg loader has an extra wrinkle: its own LC_ID_DYLIB points
# at `/opt/homebrew/opt/librsvg/lib/gdk-pixbuf-2.0/.../libpixbufloader_svg.dylib`
# (i.e. references its own pre-vendoring location). dyld doesn't use
# LC_ID_DYLIB for dlopen'd modules, so leaving it alone is harmless,
# but we clean it up too for hygiene with `install_name_tool -id`.
for loader in "$LOADERS_DEST"/*; do
  [[ -f "$loader" ]] || continue

  # Rewrite each /opt/homebrew/... LC_LOAD_DYLIB to our vendored copy.
  # `awk` extracts column 1 (the install name path); column 2 is the
  # version info in parens which we don't need. `tail -n +2` skips the
  # first otool -L line which is the file's own path.
  otool -L "$loader" 2>/dev/null \
    | tail -n +2 \
    | awk '{print $1}' \
    | grep "^/opt/homebrew/" \
    | while read -r old_path; do
        new_path="@executable_path/../Frameworks/$(basename "$old_path")"
        install_name_tool -change "$old_path" "$new_path" "$loader" 2>/dev/null || true
      done

  # Self-id cleanup (cosmetic — see comment above).
  install_name_tool -id "@rpath/$(basename "$loader")" "$loader" 2>/dev/null || true
done

# -- 5. Re-sign ad-hoc --------------------------------------------------------
#
# `install_name_tool` and `dylibbundler` rewrite every Mach-O they touch,
# which invalidates whatever code signature Xcode applied during the
# link step. On macOS 15+ Gatekeeper silently refuses to exec a binary
# with a broken signature (no error message, just exit 0 from the
# parent shell) — so always re-sign at the end. `--sign -` is the
# "ad-hoc" identity, fine for local distribution to other Macs that
# have the developer's certificate disabled but NOT acceptable for App
# Store / Developer ID distribution. Production builds replace this
# with `--sign "Developer ID Application: <Name>"` and follow up with
# notarytool — see packaging/macos/README.md.

echo "==> [5/5] Re-signing bundle (ad-hoc) so macOS lets it launch"
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 \
  | grep -v "replacing existing signature" \
  || true

echo "==> Bundle ready: $APP_BUNDLE"
echo "    Vendored dylibs:  $(find "$FRAMEWORKS_DIR" -name "*.dylib" | wc -l | tr -d ' ')"
echo "    Pixbuf loaders:   $(find "$LOADERS_DEST" -type f | wc -l | tr -d ' ')"
echo "    Resources size:   $(du -sh "$RESOURCES_DIR" | cut -f1)"
echo "    Frameworks size:  $(du -sh "$FRAMEWORKS_DIR" | cut -f1)"
echo "    Total bundle:     $(du -sh "$APP_BUNDLE" | cut -f1)"
echo
echo "Next steps (not done by this script):"
echo "  * Update Info.plist LSEnvironment to point env vars at @executable_path/../Resources"
echo "  * codesign --deep --options runtime --sign <identity> $APP_BUNDLE"
echo "  * xcrun notarytool submit ... --wait && xcrun stapler staple"
