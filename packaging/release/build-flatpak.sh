#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-flatpak.sh --version VERSION --output OUTPUT_DIR [--repo-slug OWNER/REPO]
EOF
}

version=""
output_dir=""
repo_slug="makoni/swifty-notes-gtk"
app_id="me.spaceinbox.SwiftyNotes"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --output)
            output_dir="$2"
            shift 2
            ;;
        --repo-slug)
            repo_slug="$2"
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

if [ -z "$version" ] || [ -z "$output_dir" ]; then
    usage >&2
    exit 1
fi

output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)"

if ! command -v flatpak-builder >/dev/null 2>&1; then
    echo "flatpak-builder is required to build the Flatpak artifact." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
work_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

source_dir="${work_dir}/source"
mkdir -p "$source_dir"

tar \
    --exclude=.git \
    --exclude=.build \
    --exclude=Packages \
    --exclude=packaging/out \
    --exclude=flatpak/me.spaceinbox.SwiftyNotes.yml \
    --exclude=default.profraw \
    -C "$repo_root" \
    -cf - \
    . \
    | tar -C "$source_dir" -xf -

manifest_path="${work_dir}/${app_id}.yml"
"${repo_root}/packaging/release/render-flatpak-manifest.sh" \
    --version "$version" \
    --repo-slug "$repo_slug" \
    --source-path source \
    --output "$manifest_path"

flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak-builder \
    --force-clean \
    --user \
    --default-branch=stable \
    --install-deps-from=flathub \
    --state-dir="${work_dir}/.flatpak-builder" \
    --repo="${work_dir}/repo" \
    "${work_dir}/build" \
    "$manifest_path"

flatpak build-bundle \
    "${work_dir}/repo" \
    "${output_dir}/swifty-notes-gtk-${version}-x86_64.flatpak" \
    "${app_id}" \
    stable \
    --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
