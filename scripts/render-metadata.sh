#!/usr/bin/env bash
# Renders the translated desktop entry and AppStream metainfo from their
# English templates plus po/<lang>.po.
#
# Translations live in the catalogue, not in the metadata files: msgfmt merges
# them back in as xml:lang / Name[xx] entries at build time. Hand-maintaining
# those variants inside the XML means every new language edits the same file
# and translators work somewhere other than where the rest of the strings are.
#
# The metainfo comes out still holding its @VERSION@ / @DATE@ / @SCREENSHOT_*@
# placeholders — packaging substitutes those afterwards, since only it knows
# the version being built.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

DOMAIN="me.spaceinbox.swiftynotes"
OUT_DIR="${1:-data/generated}"

if ! command -v msgfmt >/dev/null 2>&1; then
    echo "ERROR: msgfmt is required (install gettext)." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

msgfmt --desktop -L Desktop \
    --template="data/${DOMAIN}.desktop.in" \
    -d po \
    -o "${OUT_DIR}/${DOMAIN}.desktop"
echo "Rendered ${OUT_DIR}/${DOMAIN}.desktop"

msgfmt --xml -L MetaInfo \
    --template="data/${DOMAIN}.metainfo.xml.in" \
    -d po \
    -o "${OUT_DIR}/${DOMAIN}.metainfo.xml.in"
echo "Rendered ${OUT_DIR}/${DOMAIN}.metainfo.xml.in"
