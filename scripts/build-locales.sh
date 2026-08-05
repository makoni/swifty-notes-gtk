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

LANGUAGES=("cs" "de" "es" "fr" "hi" "it" "ja" "ko" "ru" "tr" "uk" "zh_CN")

DOMAIN="me.spaceinbox.swiftynotes"

for lang in "${LANGUAGES[@]}"; do
    PO_FILE="$PO_DIR/${lang}.po"

    if [[ ! -f "$PO_FILE" ]]; then
        echo "SKIP: $PO_FILE not found, skipping $lang."
        continue
    fi

    LC_DIR="$LOCALE_ROOT/${lang}/LC_MESSAGES"
    MO_FILE="$LC_DIR/${DOMAIN}.mo"

    mkdir -p "$LC_DIR"

    echo "Compiling $PO_FILE -> $MO_FILE"
    msgfmt --check -o "$MO_FILE" "$PO_FILE"

    echo "  Done: $lang"
done

echo ""
echo "All .po files compiled successfully."
