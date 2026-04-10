#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: render-flatpak-manifest.sh --source-path PATH --output FILE [--version VERSION] [--repo-slug OWNER/REPO]
EOF
}

version=""
source_path=""
output_path=""
repo_slug="makoni/swifty-notes-gtk"
repo_ref="master"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --source-path)
            source_path="$2"
            shift 2
            ;;
        --output)
            output_path="$2"
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

if [ -z "$source_path" ] || [ -z "$output_path" ]; then
    usage >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "${script_dir}/version.sh"
repo_root="$(release_repo_root)"
version="$(resolve_release_version "$version")"
mkdir -p "$(dirname "$output_path")"

sed \
    -e "s|@VERSION@|${version}|g" \
    -e "s|@REPO_SLUG@|${repo_slug}|g" \
    -e "s|@REPO_REF@|${repo_ref}|g" \
    -e "s|@SOURCE_PATH@|${source_path}|g" \
    "${repo_root}/flatpak/me.spaceinbox.swiftynotes.yml.in" \
    > "$output_path"
