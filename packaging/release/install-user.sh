#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: install-user.sh [options]

Options:
  --version VERSION         Version exported to the installed launcher. Default: VERSION file at repo root.
  --prefix PREFIX           User install prefix. Default: $HOME/.local
  --license-subdir NAME     Directory name under share/licenses. Default: swifty-notes-gtk
  --repo-slug OWNER/REPO    GitHub slug used for generated screenshot URLs.
  --repo-ref REF            Git ref used for generated screenshot URLs. Default: master
  --build-date YYYY-MM-DD   Release date written into metainfo. Default: current UTC date.
  --screenshot-url URL      Override the primary AppStream screenshot URL. Additional screenshots use the same directory.
EOF
}

version=""
prefix="${HOME}/.local"
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

case "$prefix" in
    /*)
        ;;
    *)
        echo "Prefix must be an absolute path: ${prefix}" >&2
        exit 1
        ;;
esac

if [ -z "$screenshot_url" ]; then
    screenshot_url="https://raw.githubusercontent.com/${repo_slug}/${repo_ref}/data/screenshots/main-window.png"
fi
screenshot_main_url="$screenshot_url"
screenshot_base_url="${screenshot_main_url%/*}"
screenshot_editor_url="${screenshot_base_url}/markdown-preview.png"
screenshot_cli_url="${screenshot_base_url}/cli-workflow.png"

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "${script_dir}/version.sh"
repo_root="$(release_repo_root)"
version="$(resolve_release_version "$version")"
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
icons_root="${prefix}/share/icons/hicolor"
metainfo_dir="${prefix}/share/metainfo"
license_dir="${prefix}/share/licenses/${license_subdir}"
desktop_file="${applications_dir}/me.spaceinbox.swiftynotes.desktop"
icon_file="${icon_dir}/me.spaceinbox.swiftynotes.svg"

mkdir -p \
    "$libexec_dir" \
    "$bin_dir" \
    "$applications_dir" \
    "$icon_dir" \
    "$metainfo_dir" \
    "$license_dir"

rm -f \
    "${applications_dir}/me.spaceinbox.SwiftyNotes.desktop" \
    "${applications_dir}/io.github.makoni.SwiftyNotes.desktop"

install -Dm755 "$binary_path" "${libexec_dir}/swiftynotes"
rm -rf "${libexec_dir}/swifty-notes-gtk_SwiftyNotes.resources"
cp -R "$resources_dir" "$libexec_dir/"
install -Dm644 data/me.spaceinbox.swiftynotes.desktop "$desktop_file"
install -Dm644 data/me.spaceinbox.swiftynotes.svg "$icon_file"
install -Dm644 LICENSE "${license_dir}/LICENSE"

cat > "${bin_dir}/swiftynotes" <<EOF
#!/bin/sh
set -eu
: "\${SWIFTY_NOTES_VERSION:=${version}}"
: "\${SWIFTY_NOTES_APP_ID:=me.spaceinbox.swiftynotes}"
exec "${libexec_dir}/swiftynotes" "\$@"
EOF
chmod 755 "${bin_dir}/swiftynotes"

sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@DATE@|${build_date}|g" \
    -e "s|@SCREENSHOT_MAIN_URL@|${screenshot_main_url}|g" \
    -e "s|@SCREENSHOT_EDITOR_URL@|${screenshot_editor_url}|g" \
    -e "s|@SCREENSHOT_CLI_URL@|${screenshot_cli_url}|g" \
    data/me.spaceinbox.swiftynotes.metainfo.xml.in \
    > "${metainfo_dir}/me.spaceinbox.swiftynotes.metainfo.xml"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$desktop_file"
fi

if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli validate --no-net "${metainfo_dir}/me.spaceinbox.swiftynotes.metainfo.xml"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q "$applications_dir"
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$icons_root"
fi

"${bin_dir}/swiftynotes" cli list >/dev/null

echo "Installed Swifty Notes into ${prefix}"
