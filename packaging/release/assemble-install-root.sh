#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: assemble-install-root.sh --version VERSION --dest DESTDIR [options]

Options:
  --prefix PREFIX             Install prefix inside the package root (/usr or /app). Default: /usr
  --license-subdir NAME       Directory name under share/licenses. Default: swifty-notes-gtk
  --repo-slug OWNER/REPO      GitHub slug used for generated screenshot URLs.
  --repo-ref REF              Git ref used for generated screenshot URLs. Default: master
  --build-date YYYY-MM-DD     Release date written into metainfo. Default: current UTC date.
  --screenshot-url URL        Override the AppStream screenshot URL.
EOF
}

version=""
dest=""
prefix="/usr"
license_subdir="swifty-notes-gtk"
repo_slug="makoni/swifty-notes-gtk"
repo_ref="master"
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
        --license-subdir)
            license_subdir="$2"
            shift 2
            ;;
        --repo-slug)
            repo_slug="$2"
            shift 2
            ;;
        --repo-ref)
            repo_ref="$2"
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
    screenshot_url="https://raw.githubusercontent.com/${repo_slug}/${repo_ref}/data/screenshots/main-window.png"
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "$repo_root"

swift build -c release --static-swift-stdlib
build_dir="$(swift build -c release --static-swift-stdlib --show-bin-path)"
binary_path="${build_dir}/swiftynotes"
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
license_dir="${prefix}/share/licenses/${license_subdir}"

rm -rf "$dest"
mkdir -p \
    "${dest}${libexec_dir}" \
    "${dest}${bin_dir}" \
    "${dest}${applications_dir}" \
    "${dest}${icon_dir}" \
    "${dest}${metainfo_dir}" \
    "${dest}${license_dir}"

install -Dm755 "$binary_path" "${dest}${libexec_dir}/swiftynotes"
cp -R "$resources_dir" "${dest}${libexec_dir}/"
install -Dm644 data/me.spaceinbox.swiftynotes.desktop "${dest}${applications_dir}/me.spaceinbox.swiftynotes.desktop"
install -Dm644 data/me.spaceinbox.swiftynotes.svg "${dest}${icon_dir}/me.spaceinbox.swiftynotes.svg"
install -Dm644 LICENSE "${dest}${license_dir}/LICENSE"

cat > "${dest}${bin_dir}/swiftynotes" <<EOF
#!/bin/sh
set -eu
: "\${SWIFTY_NOTES_VERSION:=${version}}"
: "\${SWIFTY_NOTES_APP_ID:=me.spaceinbox.swiftynotes}"
root_prefix="\${SWIFTY_NOTES_ROOT_PREFIX:-\${SNAP:-}}"
exec "\${root_prefix}${libexec_dir}/swiftynotes" "\$@"
EOF
chmod 755 "${dest}${bin_dir}/swiftynotes"

sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@DATE@|${build_date}|g" \
    -e "s|@SCREENSHOT_URL@|${screenshot_url}|g" \
    data/me.spaceinbox.swiftynotes.metainfo.xml.in \
    > "${dest}${metainfo_dir}/me.spaceinbox.swiftynotes.metainfo.xml"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "${dest}${applications_dir}/me.spaceinbox.swiftynotes.desktop"
fi

if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net --strict "${dest}${metainfo_dir}/me.spaceinbox.swiftynotes.metainfo.xml"
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
    "${dest}${bin_dir}/swiftynotes" cli list >/dev/null
