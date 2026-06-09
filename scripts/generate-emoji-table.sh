#!/usr/bin/env bash
#
# Regenerate Sources/SwiftyNotes/Resources/emoji-shortcodes.tsv from the
# github/gemoji dataset (the same shortcode vocabulary GitHub renders, e.g.
# :white_check_mark: -> ✅). gemoji is MIT-licensed; its LICENSE is bundled
# alongside the generated table at Resources/gemoji-LICENSE.txt.
#
# The table is a tiny (~34 KB) tab-separated `shortcode<TAB>emoji` file, one
# line per alias. The app parses it once at runtime into a [String: String]
# map (see EmojiShortcodes). We deliberately bundle a generated resource
# rather than a Swift dictionary literal: a ~1900-entry literal cripples the
# Swift type-checker, and the resource path matches how the demo image ships.
#
# Bump GEMOJI_REF to a newer gemoji tag to pick up new Unicode releases, then
# re-run this script and commit the regenerated .tsv + LICENSE.
#
# Usage: scripts/generate-emoji-table.sh

set -euo pipefail

GEMOJI_REF="v4.1.0"
GEMOJI_COMMIT="5476a66d2794e0d1551b1f96e449afc72e9f7bec"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resources_dir="${repo_root}/Sources/SwiftyNotes/Resources"
out_tsv="${resources_dir}/emoji-shortcodes.tsv"
out_license="${resources_dir}/gemoji-LICENSE.txt"

base="https://raw.githubusercontent.com/github/gemoji/${GEMOJI_COMMIT}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Fetching gemoji ${GEMOJI_REF} (${GEMOJI_COMMIT})…"
curl -fsSL "${base}/db/emoji.json" -o "${tmp}/emoji.json"
curl -fsSL "${base}/LICENSE" -o "${out_license}"

python3 - "${tmp}/emoji.json" "${out_tsv}" "${GEMOJI_REF}" <<'PY'
import json
import sys

src, dst, ref = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(src, encoding="utf-8"))

rows = []
seen = set()
for entry in data:
    emoji = entry.get("emoji")
    if not emoji:
        continue
    for alias in entry.get("aliases", []):
        if not alias or alias in seen:
            continue
        if "\t" in alias or "\n" in alias:
            raise SystemExit(f"unexpected control char in alias: {alias!r}")
        seen.add(alias)
        rows.append((alias, emoji))

rows.sort(key=lambda r: r[0])
with open(dst, "w", encoding="utf-8") as f:
    f.write(f"# Generated from github/gemoji {ref} by scripts/generate-emoji-table.sh\n")
    f.write("# Do not edit by hand. shortcode<TAB>emoji, one alias per line.\n")
    for alias, emoji in rows:
        f.write(f"{alias}\t{emoji}\n")

print(f"Wrote {len(rows)} shortcodes to {dst}")
PY

echo "Done. Regenerated ${out_tsv} and ${out_license}."
