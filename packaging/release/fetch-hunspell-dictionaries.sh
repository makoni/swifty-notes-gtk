#!/usr/bin/env bash
# Install the hunspell dictionaries listed in packaging/hunspell-dictionaries.txt
# into a destination directory, fetching the LibreOffice/dictionaries archive if
# it is not already cached.
#
# Split out of the AppImage build so the language list lives in one data file
# rather than being spelled out again in every packaging path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIST="$REPO_ROOT/packaging/hunspell-dictionaries.txt"
ARCHIVE_SHA256="cdbc8d6d79425b2749f7eee077c107ef96fb23c44e4f0ca450897f0a4402581a"

commit=""
cache=""
dest=""
licenses_dest=""

usage() {
    cat <<'EOF'
Usage: fetch-hunspell-dictionaries.sh --commit SHA --dest DIR [--cache DIR] [--licenses-dest DIR]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --commit) commit="${2:?}"; shift 2 ;;
        --cache) cache="${2:?}"; shift 2 ;;
        --dest) dest="${2:?}"; shift 2 ;;
        --licenses-dest) licenses_dest="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

if [ -z "$commit" ] || [ -z "$dest" ]; then
    usage >&2
    exit 64
fi
[ -f "$LIST" ] || { echo "Missing $LIST" >&2; exit 1; }

cache="${cache:-$(mktemp -d)}"
mkdir -p "$cache" "$dest"

archive="$cache/dictionaries-${commit}.tar.gz"
if [ ! -f "$archive" ]; then
    curl -fL --retry 3 --retry-delay 2 \
        "https://github.com/LibreOffice/dictionaries/archive/${commit}.tar.gz" -o "$archive"
fi
echo "${ARCHIVE_SHA256}  ${archive}" | sha256sum --check --strict

extracted="$cache/dictionaries-${commit}"
if [ ! -d "$extracted" ]; then
    mkdir -p "$extracted"
    tar -C "$extracted" --strip-components=1 -xzf "$archive"
fi

installed=0
missing=()
while read -r source target; do
    case "$source" in ''|\#*) continue ;; esac
    ok=1
    for ext in aff dic; do
        if [ ! -f "$extracted/$source.$ext" ]; then
            missing+=("$source.$ext")
            ok=0
        fi
    done
    [ "$ok" -eq 1 ] || continue
    install -Dm644 "$extracted/$source.aff" "$dest/$target.aff"
    install -Dm644 "$extracted/$source.dic" "$dest/$target.dic"
    installed=$((installed + 1))

    if [ -n "$licenses_dest" ]; then
        language_dir="$extracted/${source%%/*}"
        mkdir -p "$licenses_dest/${source%%/*}"
        # Upstream is inconsistent: some languages ship COPYING, some README,
        # some Copyright. Take whatever is there and do not fail when a
        # language ships none.
        find "$language_dir" -maxdepth 1 -type f \
            \( -iname 'COPYING*' -o -iname 'README*' -o -iname 'Copyright*' -o -iname 'LICENSE*' \) \
            -exec install -m644 {} "$licenses_dest/${source%%/*}/" \; 2> /dev/null || true
    fi
done < "$LIST"

if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: the dictionaries archive has no such files: ${missing[*]}" >&2
    echo "Upstream renamed or dropped them; update packaging/hunspell-dictionaries.txt" >&2
    echo "and the hunspell-dictionaries module in the Flatpak manifest together." >&2
    exit 1
fi

expected="$(grep -cvE '^#|^$' "$LIST")"
if [ "$installed" -ne "$expected" ]; then
    echo "ERROR: installed $installed dictionaries, expected $expected" >&2
    exit 1
fi
echo "Installed $installed hunspell dictionaries into $dest"
