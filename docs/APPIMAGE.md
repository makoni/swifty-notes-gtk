# The AppImage build

`packaging/release/build-appimage.sh` turns an assembled `/usr` install root —
the same artifact the deb and rpm builds consume — into a single-file
`swifty-notes-gtk-<version>-<arch>.AppImage`. The release workflow builds one
per architecture and attaches it, with its `.zsync`, to the drafted release.

```bash
packaging/release/assemble-install-root.sh --dest packaging/out/install-root-usr --prefix /usr
packaging/release/build-appimage.sh --install-root packaging/out/install-root-usr
packaging/release/verify-appimage.sh \
    --appimage packaging/out/appimage/swifty-notes-gtk-1.5.0-x86_64.AppImage \
    --appdir packaging/out/appimage/work/AppDir
```

## An AppImage is not a sandbox

This is the first thing to get straight, because the other two Linux packages
are sandboxes and the habits do not transfer.

| | confinement | how the app sees the filesystem |
|---|---|---|
| Flatpak | bubblewrap, portals | only what the manifest permits |
| Snap | AppArmor + seccomp | only what the interfaces permit |
| **AppImage** | **none** | the real filesystem, as the invoking user |

An AppImage is a squashfs image with a runtime prepended: it mounts itself and
execs `AppRun`. Nothing restricts the process afterwards. So there are no
permissions to declare, no portal to negotiate with, and no interface to
connect — and equally no protection for the user. The notes directory is a
real path in the real home directory, the file chooser is GTK's own rather
than a portal, and the app can read anything the user can.

What *does* bite is the mirror image of a sandbox problem: the bundle is
mounted at a fresh directory on every launch (`/tmp/.mount_XXXXXX`), so every
library that resolves data by absolute path is looking in the wrong place. All
three of the problems below are that one problem.

## Absolute paths, and which ones can be fixed

### The launcher — fixed

`usr/bin/swiftynotes` is a shell launcher that execs
`${SWIFTY_NOTES_ROOT_PREFIX}/usr/libexec/swifty-notes/swiftynotes`. The prefix
is empty on a system install and `$SNAP` under Snap. Left unset in an AppImage
it resolves to `/usr/libexec/swifty-notes/swiftynotes` on the *host*, which
either does not exist:

```
$ AppDir/usr/bin/swiftynotes cli get
AppDir/usr/bin/swiftynotes: 6: exec: /usr/libexec/swifty-notes/swiftynotes: not found
```

or, worse, is a different copy of the app. `AppRun` exports
`SWIFTY_NOTES_ROOT_PREFIX="$APPDIR"`, and `verify-appimage.sh` runs the CLI
through the finished bundle in German — which only answers if the binary, its
SwiftPM resource bundle and its catalogues all resolved from inside the mount.

### Hunspell dictionaries — fixed

Enchant's hunspell provider walks `$XDG_DATA_DIRS/hunspell`, so dictionaries
can be bundled. `AppRun` prepends `$APPDIR/usr/share`, and the build installs
the same 20 dictionaries the Flatpak ships, from the same pinned
LibreOffice/dictionaries commit, driven by `packaging/hunspell-dictionaries.txt`
so the two packages cannot drift apart. Verified from a built AppDir:

```
$ XDG_DATA_DIRS="$AppDir/usr/share:/usr/share" enchant-lsmod-2 -list-dicts | grep -c hunspell
18
```

### Enchant's provider modules — **not** fixable

Enchant looks for its provider modules in a path compiled into the library,
and offers no environment variable to move it. Traced:

```
$ strace -e trace=openat enchant-lsmod-2
openat(AT_FDCWD, "/usr/lib/x86_64-linux-gnu/enchant-2", ...) = 3
openat(AT_FDCWD, "/usr/lib/x86_64-linux-gnu/enchant-2/enchant_hunspell.so", ...) = 4
```

`ENCHANT_CONFIG_DIR` moves only `enchant.ordering`, not the module directory.
So a bundled `libenchant-2.so.2` still loads providers from the *host's*
`/usr/lib/<triplet>/enchant-2`. The consequence:

- host has `enchant-2` installed → spell check works, with the bundled
  dictionaries;
- host has no enchant providers → enchant reports no providers, libspelling
  finds no checker, and **spell check is silently unavailable**. Everything
  else in the app works.

That is a genuine limitation of the format, not something to work around with
more `LD_LIBRARY_PATH`. It is worth stating in release notes rather than
letting users discover it. The Flatpak and Snap have no such problem, because
they carry their own `/usr`.

### glycin — not in the bundle today, and a trap when it is

GTK 4.20 moved image loading to glycin, which runs *separate loader processes*
found through `$XDG_DATA_DIRS/glycin-loaders/<version>/conf.d/*.conf`. Those
files carry absolute `Exec=` paths:

```
[loader:image/jpeg]
Exec=/usr/libexec/glycin-loaders/2+/glycin-image-rs
```

An AppImage cannot ship a correct one, because the path is only known at
launch. glycin does read `GLYCIN_DATA_DIR`, so the fix — when it is needed —
is for `AppRun` to write a `conf.d` into a temporary directory with
`$APPDIR`-relative paths and point `GLYCIN_DATA_DIR` at it. Note also that
glycin sandboxes its loaders with `bwrap`, and degrades to
`WARNING: Glycin running without sandbox.` where user namespaces are
unavailable; that fallback is glycin's, not something to configure.

None of this applies to the current build. Two reasons:

1. The AppImage is built on Ubuntu 24.04, matching the project's GTK 4.14 /
   libadwaita 1.5 baseline, and glycin arrived in GTK 4.20. There is no
   `libglycin` in the bundle at all.
2. Even on a newer GTK, the app decodes raster images through
   `Texture.loadSynchronously` → GdkPixbuf, whose loaders *are* bundled by
   linuxdeploy's GTK plugin. Only SVG takes GTK's own loading path.

When the baseline moves to Ubuntu 26.04, revisit this section before assuming
SVG previews still render.

## FUSE, and why the runtime is pinned to `continuous`

The AppImage runtime is taken from `AppImage/type2-runtime`, tag `continuous`,
pinned by sha256 in `build-appimage.sh`. It is the newest runtime published,
and the reason to want it is concrete: it is `static-pie` with libfuse linked
in, so it needs only a `fusermount` binary on `$PATH` rather than a
`libfuse.so.2` that current distributions no longer install. Older runtimes
fail on Ubuntu 24.04+ with `dlopen(): error loading libfuse.so.2`.

`continuous` is a moving tag, which is normally a bad thing to depend on for a
release artifact. Pinning by checksum resolves it the honest way: an upstream
change fails the build loudly and somebody re-pins deliberately, instead of a
different runtime shipping unnoticed. `linuxdeploy` is pinned to its newest
non-prerelease tag, and its GTK plugin — which publishes no releases at all —
by commit, both also with checksums.

The runtime looks for `fusermount`; a host with only fuse3 may provide
`fusermount3` alone. Users on such a host can either install a `fusermount`
symlink, set `FUSERMOUNT_PROG=fusermount3`, or run the AppImage with
`--appimage-extract-and-run`.

## Updates

`AppSandbox.isSandboxed` matches Flatpak and Snap only, which is correct for
AppImage: there is no store to keep the app current, so "Check for Updates…"
stays in the menu and does its own thing — exactly as on a deb or rpm install.

Separately, the AppImage carries `gh-releases-zsync|…` update information and
a `.zsync` file, so AppImage-aware updaters can fetch a delta of the next
release. The two halves have to agree: zsyncmake writes the AppImage's exact
basename into the `.zsync` URL header, so the file must never be renamed after
the build. `verify-appimage.sh` checks both.

## Layout notes

- linuxdeploy is invoked with `--deploy-deps-only` rather than `--executable`,
  because the binary is already at its final place beside the resource bundle
  SwiftPM emits next to it. `--executable` copies the binary into `usr/bin`,
  which separates the two and leaves the app unable to find its own icons and
  catalogues.
- `DEPLOY_GTK_VERSION=4` is set explicitly. The GTK plugin otherwise sniffs the
  version by running `ldd` over `usr/bin`, finds only a shell launcher, and
  gives up with "failed to auto-detect GTK version".
- `AppRun` sources `$APPDIR/apprun-hooks/*.sh`. Only linuxdeploy's *generated*
  AppRun does that automatically, so a custom one that forgets loses the GTK
  plugin's GdkPixbuf loader cache, GIO modules and fontconfig setup — which
  looks like missing images and missing fonts rather than a packaging mistake.
- The Swift runtime needs no bundling: `assemble-install-root.sh` builds with
  `--static-swift-stdlib`.
