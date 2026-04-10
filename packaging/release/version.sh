#!/usr/bin/env bash
set -euo pipefail

release_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "${script_dir}/../.." && pwd
}

read_release_version_file() {
    local repo_root version_file version
    repo_root="$(release_repo_root)"
    version_file="${repo_root}/VERSION"

    if [ ! -f "$version_file" ]; then
        echo "Missing VERSION file at ${version_file}" >&2
        return 1
    fi

    version="$(tr -d '\r' < "$version_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$version" ]; then
        echo "VERSION file is empty: ${version_file}" >&2
        return 1
    fi

    printf '%s\n' "$version"
}

resolve_release_version() {
    local version="${1:-}"
    if [ -n "$version" ]; then
        printf '%s\n' "$version"
        return 0
    fi

    read_release_version_file
}
