#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: assemble-install-root.sh --version VERSION --dest DESTDIR [options]

Options:
  --prefix PREFIX             Install prefix inside the package root (/usr or /app). Default: /usr
  --repo-slug OWNER/REPO      GitHub slug used for generated screenshot URLs.
  --build-date YYYY-MM-DD     Release date written into metainfo. Default: current UTC date.
  --screenshot-url URL        Override the AppStream screenshot URL.
EOF
}

version=""
dest=""
prefix="/usr"
repo_slug="makoni/swifty-notes-gtk"
build_date="$(date -u +%F)"
screenshot_url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --dest)
            dest="$2"
            shift 2
            ;;
        --prefix)
            prefix="$2"
            shift 2
            ;;
        --repo-slug)
            repo_slug="$2"
            shift 2
            ;;
        --build-date)
            build_date="$2"
            shift 2
            ;;
        --screenshot-url)
            screenshot_url="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$version" ] || [ -z "$dest" ]; then
    usage >&2
    exit 1
fi

case "$prefix" in
    /usr|/app)
        ;;
    *)
        echo "Unsupported prefix: $prefix" >&2
        exit 1
        ;;
esac

if [ -z "$screenshot_url" ]; then
    screenshot_url="https://raw.githubusercontent.com/${repo_slug}/main/data/screenshots/main-window.png"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "$repo_root"

swift build -c release --static-swift-stdlib
build_dir="$(swift build -c release --static-swift-stdlib --show-bin-path)"
binary_path="${build_dir}/SwiftyNotes"
resources_dir="${build_dir}/swifty-notes-gtk_SwiftyNotes.resources"

if [ ! -x "$binary_path" ]; then
    echo "Missing release binary at ${binary_path}" >&2
    exit 1
fi

if [ ! -d "$resources_dir" ]; then
    echo "Missing SwiftPM resources bundle at ${resources_dir}" >&2
    exit 1
fi

libexec_dir="${prefix}/libexec/swifty-notes"
bin_dir="${prefix}/bin"
applications_dir="${prefix}/share/applications"
icon_dir="${prefix}/share/icons/hicolor/scalable/apps"
metainfo_dir="${prefix}/share/metainfo"
license_dir="${prefix}/share/licenses/swifty-notes-gtk"

rm -rf "$dest"
mkdir -p \
    "${dest}${libexec_dir}" \
    "${dest}${bin_dir}" \
    "${dest}${applications_dir}" \
    "${dest}${icon_dir}" \
    "${dest}${metainfo_dir}" \
    "${dest}${license_dir}"

install -Dm755 "$binary_path" "${dest}${libexec_dir}/SwiftyNotes"
cp -R "$resources_dir" "${dest}${libexec_dir}/"
install -Dm644 data/me.spaceinbox.SwiftyNotes.desktop "${dest}${applications_dir}/me.spaceinbox.SwiftyNotes.desktop"
install -Dm644 data/me.spaceinbox.SwiftyNotes.svg "${dest}${icon_dir}/me.spaceinbox.SwiftyNotes.svg"
install -Dm644 LICENSE "${dest}${license_dir}/LICENSE"

cat > "${dest}${bin_dir}/SwiftyNotes" <<EOF
#!/bin/sh
set -eu
: "\${SWIFTY_NOTES_VERSION:=${version}}"
: "\${SWIFTY_NOTES_APP_ID:=me.spaceinbox.SwiftyNotes}"
root_prefix="\${SWIFTY_NOTES_ROOT_PREFIX:-\${SNAP:-}}"
exec "\${root_prefix}${libexec_dir}/SwiftyNotes" "\$@"
EOF
chmod 755 "${dest}${bin_dir}/SwiftyNotes"

sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@DATE@|${build_date}|g" \
    -e "s|@SCREENSHOT_URL@|${screenshot_url}|g" \
    data/me.spaceinbox.SwiftyNotes.metainfo.xml.in \
    > "${dest}${metainfo_dir}/me.spaceinbox.SwiftyNotes.metainfo.xml"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${dest}${applications_dir}/me.spaceinbox.SwiftyNotes.desktop"
fi

if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net --strict "${dest}${metainfo_dir}/me.spaceinbox.SwiftyNotes.metainfo.xml"
fi

validation_root="$(mktemp -d)"
cleanup() {
    rm -rf "$validation_root"
}
trap cleanup EXIT

mkdir -p \
    "${validation_root}/data" \
    "${validation_root}/config" \
    "${validation_root}/state"

SWIFTY_NOTES_ROOT_PREFIX="$dest" \
SWIFTY_NOTES_VERSION="$version" \
XDG_DATA_HOME="${validation_root}/data" \
XDG_CONFIG_HOME="${validation_root}/config" \
XDG_STATE_HOME="${validation_root}/state" \
    "${dest}${bin_dir}/SwiftyNotes" cli list >/dev/null
