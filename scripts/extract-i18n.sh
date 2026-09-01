#!/usr/bin/env bash
# Regenerates po/me.spaceinbox.swiftynotes.pot from every source of
# user-visible text: the Swift sources, the AppStream metainfo, and the
# desktop entry.
#
# The three need different extractors. Swift's `"literal".localized` is a
# property access, not a call, so xgettext cannot see it and a purpose-built
# scanner (extract-i18n.swift) reads it instead. The metadata files are XML
# and INI, which xgettext handles natively given the ITS rules gettext ships
# for AppStream. msgcat merges the results into one template, so translators
# keep working in a single catalogue per language.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

DOMAIN="me.spaceinbox.swiftynotes"
POT="po/${DOMAIN}.pot"
METAINFO="data/${DOMAIN}.metainfo.xml.in"
DESKTOP="data/${DOMAIN}.desktop.in"
ITS="/usr/share/gettext/its/metainfo.its"

for tool in xgettext msgcat swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is required (install gettext for xgettext/msgcat)." >&2
        exit 1
    fi
done

if [[ ! -f "$ITS" ]]; then
    echo "ERROR: $ITS not found — gettext's AppStream ITS rules are missing." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift scripts/extract-i18n.swift --output "$work/source.pot" >/dev/null

xgettext \
    --from-code=UTF-8 \
    --its="$ITS" \
    --omit-header \
    --output="$work/metainfo.pot" \
    "$METAINFO"

xgettext \
    -L Desktop \
    --omit-header \
    --output="$work/desktop.pot" \
    "$DESKTOP"

# --use-first keeps the Swift entry when a string appears in more than one
# source; only its plural forms and header carry information the others lack.
msgcat --use-first "$work/source.pot" "$work/metainfo.pot" "$work/desktop.pot" -o "$POT"

echo "Wrote $(grep -c '^msgid ' "$POT") entries to $POT"
