#!/usr/bin/env bash
# Verify a built Swifty Notes AppImage.
#
# Every check here answers a way the bundle can be wrong while still building
# and still starting on the machine that made it — which is the only kind of
# breakage worth a script.
set -euo pipefail

appimage=""
appdir=""
repo_slug="makoni/swifty-notes-gtk"
arch="$(uname -m)"

usage() {
    cat <<'EOF'
Usage: verify-appimage.sh --appimage FILE [--appdir DIR] [--repo-slug OWNER/REPO] [--arch ARCH]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --appimage) appimage="${2:?}"; shift 2 ;;
        --appdir) appdir="${2:?}"; shift 2 ;;
        --repo-slug) repo_slug="${2:?}"; shift 2 ;;
        --arch) arch="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[ -n "$appimage" ] || { usage >&2; exit 64; }
[ -f "$appimage" ] || { echo "No such AppImage: $appimage" >&2; exit 1; }
chmod +x "$appimage"

# Deliberately not exported: with APPIMAGE_EXTRACT_AND_RUN set, the runtime
# unpacks and execs the payload instead of handling its own `--appimage-*`
# arguments, so an update-information query comes back empty. Reading the
# header needs no mount; only actually running the app does, and that one call
# opts in below.
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

if [ -n "$appdir" ] && [ -d "$appdir" ]; then
    # 1. GTK has to be *in* the bundle. If the plugin stops deploying it, the
    #    AppImage falls back to the host's GTK where there is one and fails
    #    outright where there is not — and the runner always has one.
    if ! find "$appdir" -name 'libgtk-4.so*' -print -quit | grep -q .; then
        fail "no libgtk-4 in the AppDir: the GTK plugin did not deploy it"
    fi
    for library in libadwaita-1.so libspelling-1.so libgtksourceview-5.so; do
        if ! find "$appdir" -name "${library}*" -print -quit | grep -q .; then
            fail "no $library in the AppDir"
        fi
    done

    # 2. The plugin's environment hook has to be there, because AppRun sources
    #    it for the GdkPixbuf loader cache and the GIO modules. A custom AppRun
    #    with no hooks to source loses both silently.
    if ! find "$appdir/apprun-hooks" -name '*.sh' -print -quit 2>/dev/null | grep -q .; then
        fail "no apprun-hooks/*.sh in the AppDir: GdkPixbuf and GIO setup would be missing"
    fi

    # 3. The spell-check dictionaries, which reach enchant through
    #    XDG_DATA_DIRS and are the half of spell-check a bundle can carry.
    dictionaries=$(find "$appdir/usr/share/hunspell" -name '*.dic' 2>/dev/null | wc -l)
    expected_dictionaries=$(grep -cvE '^#|^$' "$(dirname "${BASH_SOURCE[0]}")/../hunspell-dictionaries.txt")
    if [ "$dictionaries" -ne "$expected_dictionaries" ]; then
        fail "AppDir carries $dictionaries hunspell dictionaries, expected $expected_dictionaries"
    fi

    # 4. The real binary must still sit beside the resource bundle SwiftPM
    #    emits next to it. linuxdeploy's `--executable` would have moved it to
    #    usr/bin and split the two.
    if [ ! -d "$appdir/usr/libexec/swifty-notes/swifty-notes-gtk_SwiftyNotes.resources" ]; then
        fail "the SwiftyNotes resource bundle is not beside usr/libexec/swifty-notes/swiftynotes"
    fi
fi

# 5. It has to start and reach its own catalogues. The CLI is the cheapest path
#    that proves the binary runs, finds its resource bundle and translates —
#    all three of which depend on AppRun getting SWIFTY_NOTES_ROOT_PREFIX right.
config_home="$(mktemp -d)"
trap 'rm -rf "$config_home"' EXIT
mkdir -p "$config_home/me.spaceinbox.swiftynotes"
printf '{"appLanguage":"de"}' > "$config_home/me.spaceinbox.swiftynotes/settings.json"
reported=$(APPIMAGE_EXTRACT_AND_RUN=1 XDG_CONFIG_HOME="$config_home" LANG=C.UTF-8 \
    "$appimage" cli get 2>&1 | head -n 1 || true)
echo "AppImage CLI says: $reported"
if [ "$reported" != '`get` erwartet eine Notiz-ID.' ]; then
    fail "the AppImage did not answer in German: its catalogues or its resource bundle are unreachable"
fi

# 6. Update information and the zsync file are the two halves that let an
#    AppImage updater find the next release. Half of that pair is useless.
expected_update="gh-releases-zsync|${repo_slug%%/*}|${repo_slug##*/}|latest|swifty-notes-gtk-*${arch}.AppImage.zsync"
actual_update=$("$appimage" --appimage-updateinformation 2>/dev/null || true)
echo "Update information: $actual_update"
if [ "$actual_update" != "$expected_update" ]; then
    fail "embedded update information is '$actual_update', expected '$expected_update'"
fi

if [ ! -f "$appimage.zsync" ]; then
    fail "no $appimage.zsync beside the AppImage"
else
    # `|| true` is load-bearing: grep -m1 stops reading, SIGPIPEs head, and
    # would trip pipefail before the check below could report anything.
    zsync_url=$(head -c 4096 "$appimage.zsync" | grep -a -m1 '^URL:' | cut -d' ' -f2- || true)
    echo "zsync URL header: $zsync_url"
    if [ "$zsync_url" != "$(basename "$appimage")" ]; then
        fail "the .zsync URL header is '$zsync_url', not '$(basename "$appimage")' — the AppImage was renamed after zsyncmake ran"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "AppImage verified"
