#!/usr/bin/env bash
# Build the Swifty Notes AppImage from an assembled /usr install root.
#
# The install root is the same artifact the deb and rpm builds consume, so the
# AppImage ships the same binary, resources, desktop entry and metainfo the
# other Linux packages do — including the statically linked Swift runtime,
# which is why no Swift libraries need bundling here.
#
# What this adds on top is the GTK stack (via linuxdeploy's GTK plugin) and the
# hunspell dictionaries, then wraps the result with the current AppImage type-2
# runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=packaging/release/version.sh
. "$SCRIPT_DIR/version.sh"

usage() {
    cat <<'EOF'
Usage: build-appimage.sh --install-root DIR [options]

Options:
  --install-root DIR   Assembled /usr install root (from assemble-install-root.sh).
  --version VERSION    Version for the output filename. Default: VERSION file at repo root.
  --arch ARCH          Target architecture. Default: uname -m.
  --output DIR         Where to write the .AppImage and .zsync. Default: packaging/out/appimage.
  --workdir DIR        Scratch directory for the AppDir and downloads. Default: <output>/work.
  --repo-slug OWNER/REPO  GitHub slug embedded in the zsync update information.
                          Default: makoni/swifty-notes-gtk.
  --skip-update-info   Do not embed update information and do not write a .zsync.
EOF
}

# Pinned by tag *and* checksum. A release artifact must not depend on whatever
# happened to sit behind a moving tag the day it was built, and a checksum turns
# an upstream change into a loud failure rather than a silently different
# bundle. linuxdeploy publishes no stable channel, so this is its newest
# non-prerelease tag; the GTK plugin publishes no releases at all and is pinned
# by commit; the runtime's only maintained tag is `continuous`, so it is held by
# checksum alone.
LINUXDEPLOY_VERSION="1-alpha-20251107-1"
LINUXDEPLOY_SHA256_x86_64="c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d"
LINUXDEPLOY_SHA256_aarch64="620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff"
LINUXDEPLOY_PLUGIN_GTK_COMMIT="7a3fbc31a9e5075073ff8790f26effbac5f84453"
LINUXDEPLOY_PLUGIN_GTK_SHA256="b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171"
# github.com/AppImage/type2-runtime, tag `continuous`, published 2026-06-23.
# Static-pie with libfuse linked in: it needs only a `fusermount` on PATH,
# which is what makes it work on distros that stopped shipping libfuse2.
APPIMAGE_RUNTIME_TAG="continuous"
APPIMAGE_RUNTIME_SHA256_x86_64="1cc49bcf1e2ccd593c379adb17c9f85a36d619088296504de95b1d06215aebbf"
APPIMAGE_RUNTIME_SHA256_aarch64="7d5d772b7c32f0c84caf0a452a3072a5709027d7eac5856feb89a7a7a8881372"

# LibreOffice/dictionaries at the same commit the Flatpak manifest pins, and
# the same language list, so the two packages offer the same spell-check
# languages rather than quietly diverging.
DICTIONARIES_COMMIT="c011d96c90cc9c6c8b6d95ec6d83d11daacce994"

install_root=""
version=""
arch="$(uname -m)"
output=""
workdir=""
repo_slug="makoni/swifty-notes-gtk"
skip_update_info=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-root) install_root="${2:?}"; shift 2 ;;
        --version) version="${2:?}"; shift 2 ;;
        --arch) arch="${2:?}"; shift 2 ;;
        --output) output="${2:?}"; shift 2 ;;
        --workdir) workdir="${2:?}"; shift 2 ;;
        --repo-slug) repo_slug="${2:?}"; shift 2 ;;
        --skip-update-info) skip_update_info=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

if [ -z "$install_root" ]; then
    echo "--install-root is required" >&2
    usage >&2
    exit 64
fi
if [ ! -x "$install_root/usr/libexec/swifty-notes/swiftynotes" ]; then
    echo "No usr/libexec/swifty-notes/swiftynotes under $install_root:" >&2
    echo "that is not an install root assemble-install-root.sh produced." >&2
    exit 1
fi

version="$(resolve_release_version "$version")"
output="${output:-$REPO_ROOT/packaging/out/appimage}"
workdir="${workdir:-$output/work}"

case "$arch" in
    x86_64)
        linuxdeploy_sha256="$LINUXDEPLOY_SHA256_x86_64"
        runtime_sha256="$APPIMAGE_RUNTIME_SHA256_x86_64"
        ;;
    aarch64)
        linuxdeploy_sha256="$LINUXDEPLOY_SHA256_aarch64"
        runtime_sha256="$APPIMAGE_RUNTIME_SHA256_aarch64"
        ;;
    *)
        echo "Unsupported architecture for the AppImage build: $arch" >&2
        echo "Pin linuxdeploy and runtime checksums for it before enabling." >&2
        exit 1
        ;;
esac

for tool in curl sha256sum; do
    command -v "$tool" > /dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done

appdir="$workdir/AppDir"
downloads="$workdir/downloads"
rm -rf "$appdir"
mkdir -p "$appdir" "$downloads" "$output"

echo "==> Populating the AppDir from $install_root"
cp -a "$install_root/." "$appdir/"

fetch() {
    local url="$1" dest="$2" expected="$3"
    if [ ! -f "$dest" ]; then
        curl -fL --retry 3 --retry-delay 2 "$url" -o "$dest"
    fi
    echo "${expected}  ${dest}" | sha256sum --check --strict
}

echo "==> Fetching linuxdeploy, the GTK plugin and the AppImage runtime"
linuxdeploy="$downloads/linuxdeploy-${arch}.AppImage"
plugin_gtk="$downloads/linuxdeploy-plugin-gtk.sh"
runtime="$downloads/runtime-${arch}"
fetch "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/linuxdeploy-${arch}.AppImage" \
    "$linuxdeploy" "$linuxdeploy_sha256"
fetch "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/${LINUXDEPLOY_PLUGIN_GTK_COMMIT}/linuxdeploy-plugin-gtk.sh" \
    "$plugin_gtk" "$LINUXDEPLOY_PLUGIN_GTK_SHA256"
fetch "https://github.com/AppImage/type2-runtime/releases/download/${APPIMAGE_RUNTIME_TAG}/runtime-${arch}" \
    "$runtime" "$runtime_sha256"
chmod +x "$linuxdeploy" "$plugin_gtk"

echo "==> Bundling hunspell dictionaries"
"$SCRIPT_DIR/fetch-hunspell-dictionaries.sh" \
    --commit "$DICTIONARIES_COMMIT" \
    --cache "$downloads" \
    --dest "$appdir/usr/share/hunspell"

output_name="swifty-notes-gtk-${version}-${arch}.AppImage"

echo "==> Running linuxdeploy"
export APPIMAGE_EXTRACT_AND_RUN=1
export ARCH="$arch"
export LINUXDEPLOY_PLUGIN_GTK="$plugin_gtk"
# The GTK plugin sniffs the version by running `ldd` over `usr/bin`, where this
# layout keeps only a shell launcher — so it finds no dynamic executable and
# gives up. Stating the version is both the fix and the more honest input.
export DEPLOY_GTK_VERSION=4
export LDAI_OUTPUT="$output_name"
export LDAI_RUNTIME_FILE="$runtime"
if [ "$skip_update_info" -eq 0 ]; then
    export LDAI_UPDATE_INFORMATION="gh-releases-zsync|${repo_slug%%/*}|${repo_slug##*/}|latest|swifty-notes-gtk-*${arch}.AppImage.zsync"
fi

# `--deploy-deps-only` rather than `--executable`: the binary is already at its
# final place beside the resource bundle SwiftPM emits next to it, and
# `--executable` would copy it into `usr/bin` — separating the two and leaving
# the app unable to find its own icons and catalogues.
(
    cd "$workdir"
    "$linuxdeploy" \
        --appdir "$appdir" \
        --deploy-deps-only "$appdir/usr/libexec/swifty-notes/swiftynotes" \
        --desktop-file "$appdir/usr/share/applications/me.spaceinbox.swiftynotes.desktop" \
        --icon-file "$appdir/usr/share/icons/hicolor/scalable/apps/me.spaceinbox.swiftynotes.svg" \
        --custom-apprun "$REPO_ROOT/packaging/appimage/AppRun.sh" \
        --plugin gtk \
        --output appimage
)

produced="$workdir/$output_name"
if [ ! -f "$produced" ]; then
    echo "linuxdeploy did not produce $output_name" >&2
    ls -1 "$workdir"/*.AppImage 2>/dev/null >&2 || true
    exit 1
fi
mv "$produced" "$output/"
# Do not rename the AppImage afterwards: zsyncmake wrote this exact basename
# into the .zsync URL header, and a rename leaves that header pointing at
# nothing.
if [ "$skip_update_info" -eq 0 ]; then
    if [ ! -f "$produced.zsync" ]; then
        echo "No $output_name.zsync: zsyncmake did not run" >&2
        exit 1
    fi
    mv "$produced.zsync" "$output/"
fi

echo "==> Wrote $output/$output_name"
