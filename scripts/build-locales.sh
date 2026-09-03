#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Locale directory inside SwiftyNotes target for SwiftPM resource discovery
LOCALE_ROOT="$PROJECT_ROOT/Sources/SwiftyNotes/locale"

# Homebrew's gettext is keg-only, so `brew install gettext` leaves msgfmt off
# PATH entirely. Look there before giving up, or the macOS bundle silently
# needs a manual PATH export.
if ! command -v msgfmt &> /dev/null; then
    for prefix in "$(brew --prefix gettext 2> /dev/null || true)" /opt/homebrew/opt/gettext /usr/local/opt/gettext; do
        if [[ -n "$prefix" && -x "$prefix/bin/msgfmt" ]]; then
            PATH="$prefix/bin:$PATH"
            export PATH
            break
        fi
    done
fi

if ! command -v msgfmt &> /dev/null; then
    echo "ERROR: msgfmt is not installed or not in PATH."
    echo "Install gettext to compile .po files (.mo)."
    echo "On macOS: brew install gettext (keg-only — this script looks in brew --prefix gettext)."
    exit 1
fi

PO_DIR="$PROJECT_ROOT/po"

if [[ ! -d "$PO_DIR" ]]; then
    echo "ERROR: $PO_DIR directory not found."
    exit 1
fi

# po/LINGUAS is the single list of shipped languages — msgfmt reads the same
# file when it merges translations into the desktop entry and the AppStream
# metainfo, so a language added there is picked up everywhere at once.
LINGUAS_FILE="$PROJECT_ROOT/po/LINGUAS"
if [[ ! -f "$LINGUAS_FILE" ]]; then
    echo "ERROR: $LINGUAS_FILE not found."
    exit 1
fi
# Read with a plain loop rather than `mapfile`: that is a bash 4 builtin and
# macOS still ships bash 3.2, where this script also runs (bundle-macos-app.sh
# and the macOS CI job).
LANGUAGES=()
while IFS= read -r lang; do
    [[ -z "$lang" || "$lang" == \#* ]] && continue
    LANGUAGES+=("$lang")
done < "$LINGUAS_FILE"

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

# The desktop entry and the AppStream metainfo carry translations too; they
# are rendered from their English templates plus the same catalogues.
#
# Not fatal here: this script also runs on macOS, where neither file is
# installed and an older gettext without msgfmt's XML/Desktop modes would
# otherwise fail the build. Linux packaging renders them itself and does
# treat a failure as fatal.
if bash "$SCRIPT_DIR/render-metadata.sh"; then
    :
else
    echo ""
    echo "WARNING: could not render the translated desktop entry and metainfo."
    echo "         Needs gettext with msgfmt --xml / --desktop support."
fi
