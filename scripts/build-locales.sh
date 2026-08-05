#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Locale directory inside SwiftyNotes target for SwiftPM resource discovery
LOCALE_ROOT="$PROJECT_ROOT/Sources/SwiftyNotes/locale"

if ! command -v msgfmt &> /dev/null; then
    echo "ERROR: msgfmt is not installed or not in PATH."
    echo "Install gettext to compile .po files (.mo)."
    exit 1
fi

PO_DIR="$PROJECT_ROOT/po"

if [[ ! -d "$PO_DIR" ]]; then
    echo "ERROR: $PO_DIR directory not found."
    exit 1
fi

LANGUAGES=("cs" "de" "es" "fr" "hi" "it" "ja" "ko" "ru" "tr" "uk" "zh-CN")

DOMAIN="me.spaceinbox.swiftynotes"

for LANG in "${LANGUAGES[@]}"; do
    PO_FILE="$PO_DIR/${LANG}.po"

    if [[ ! -f "$PO_FILE" ]]; then
        echo "SKIP: $PO_FILE not found, skipping $LANG."
        continue
    fi

    LC_DIR="$LOCALE_ROOT/${LANG}/LC_MESSAGES"
    MO_FILE="$LC_DIR/${DOMAIN}.mo"

    mkdir -p "$LC_DIR"

    echo "Compiling $PO_FILE -> $MO_FILE"
    msgfmt -o "$MO_FILE" "$PO_FILE"

    echo "  Done: $LANG"
done

echo ""
echo "All .po files compiled successfully."
