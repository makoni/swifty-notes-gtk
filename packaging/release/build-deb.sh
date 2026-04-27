#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-deb.sh --install-root ROOT --output OUTPUT_DIR [--version VERSION]
EOF
}

version=""
install_root=""
output_dir=""
package_name="swifty-notes-gtk"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --install-root)
            install_root="$2"
            shift 2
            ;;
        --output)
            output_dir="$2"
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

if [ -z "$install_root" ] || [ -z "$output_dir" ]; then
    usage >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "${script_dir}/version.sh"
version="$(resolve_release_version "$version")"

if [ ! -d "$install_root/usr" ]; then
    echo "Expected /usr install tree under ${install_root}" >&2
    exit 1
fi

architecture="$(dpkg --print-architecture)"
build_root="$(mktemp -d)"
cleanup() {
    rm -rf "$build_root"
}
trap cleanup EXIT

mkdir -p "${build_root}/DEBIAN" "$output_dir"
cp -a "${install_root}/." "$build_root/"

cat > "${build_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Version: ${version}
Section: utils
Priority: optional
Architecture: ${architecture}
Maintainer: Sergey Armodin <makoni@users.noreply.github.com>
Depends: libc6, libgcc-s1, libstdc++6, libgtk-4-1, libadwaita-1-0, libgtksourceview-5-0, libspelling-1-0
Description: Native GTK markdown notes for Linux
 Swifty Notes is a native GTK/libadwaita markdown notes application for Linux.
 It keeps notes in plain files, supports a native Markdown preview, autosave,
 drag-and-drop image import, and a storage-compatible CLI.
EOF

dpkg-deb --build --root-owner-group \
    "$build_root" \
    "${output_dir}/${package_name}_${version}_${architecture}.deb"
