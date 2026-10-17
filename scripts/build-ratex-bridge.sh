#!/usr/bin/env bash
# Builds the RaTeX math bridge (Sources/RaTeXBridge, Rust) and stages it where
# Package.swift looks for it:
#
#   build/ratex-bridge/
#     lib/libratex_bridge.a
#     native-static-libs        the system libraries the .a needs (from cargo)
#     share/licenses/           notices for everything compiled into the .a
#
# Run this once before the first `swift build`, and again after changing the
# crate: the app links the static library unconditionally.
#
# Environment:
#   CARGO                    cargo binary (default: cargo on PATH)
#   RATEX_BRIDGE_OFFLINE=1   build with --offline (crates pre-fetched into
#                            CARGO_HOME or vendored, as the Flatpak build does)
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$APP_ROOT/Sources/RaTeXBridge"
PREFIX="$APP_ROOT/build/ratex-bridge"
TARGET_DIR="$PREFIX/target"
CARGO="${CARGO:-cargo}"

offline=()
if [ "${RATEX_BRIDGE_OFFLINE:-0}" = "1" ]; then
    offline=(--offline)
fi

mkdir -p "$PREFIX/lib"

# `cargo rustc` both builds the static library and prints the native
# libraries it needs (cairo, glib, … plus the platform runtime), which is
# exactly what a consumer of the .a has to link; it is checked against
# Package.swift's list below.
log="$PREFIX/cargo-build.log"
(
    cd "$CRATE"
    "$CARGO" rustc --release --locked ${offline[@]+"${offline[@]}"} \
        --manifest-path "$CRATE/Cargo.toml" \
        --target-dir "$TARGET_DIR" \
        --crate-type staticlib \
        -- --print native-static-libs
) 2>&1 | tee "$log"

native_libs="$(sed -n 's/.*native-static-libs: //p' "$log" | tail -n 1)"
if [ -z "$native_libs" ]; then
    # A no-op rebuild prints nothing; reuse what the last real build recorded.
    native_libs="$(cat "$PREFIX/native-static-libs" 2>/dev/null || true)"
fi
if [ -z "$native_libs" ]; then
    echo "build-ratex-bridge.sh: cargo did not report native-static-libs" >&2
    exit 1
fi
printf '%s\n' "$native_libs" > "$PREFIX/native-static-libs"

# Package.swift links a fixed list of system libraries (it cannot read this
# build's output reliably). Fail here, with the fix spelled out, if cargo now
# needs one that list lacks. The list for this platform is read out of
# Package.swift itself, so there is one copy of it; the C runtime itself
# (-lc, -lSystem) is always linked.
case "$(uname -s)" in
    # Parentheses are literal in a basic regular expression.
    Darwin) branch='/^#if os(macOS)/,/^#else/p' ;;
    *) branch='/^#else/,/^#endif/p' ;;
esac
listed="$(sed -n "$branch" "$APP_ROOT/Package.swift" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ' || true)"
if [ -z "$listed" ]; then
    echo "build-ratex-bridge.sh: could not read mathBridgeSystemLibraries for this platform from Package.swift" >&2
    exit 1
fi
allowed="-lc -lSystem $listed"
missing=""
for flag in $native_libs; do
    case " $allowed " in
        *" $flag "*) ;;
        *) missing="$missing $flag" ;;
    esac
done
if [ -n "$missing" ]; then
    echo "build-ratex-bridge.sh: the bridge needs system libraries Package.swift does not link:$missing" >&2
    echo "Add them to mathBridgeSystemLibraries in Package.swift." >&2
    exit 1
fi

# Licence notices for everything compiled into the static library: our
# hand-kept notices for RaTeX, KaTeX, its fonts and mhchem (the published
# RaTeX crates ship no licence files), plus every crate's own licence files.
mkdir -p "$PREFIX/share/licenses"
cp -f "$CRATE"/licenses/*.txt "$PREFIX/share/licenses/"
(
    cd "$CRATE"
    host="$("$CARGO" -vV | sed -n 's/^host: //p')"
    "$CARGO" metadata --format-version 1 --locked ${offline[@]+"${offline[@]}"} \
        --manifest-path "$CRATE/Cargo.toml" --filter-platform "$host"
) | python3 -c '
import json, os, sys
metadata = json.load(sys.stdin)
out = ["Rust crates compiled into the RaTeX math bridge", "=" * 47, ""]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["name"] == "ratex_bridge":
        continue
    out.append("%s %s — %s" % (package["name"], package["version"], package.get("license") or "see files"))
    directory = os.path.dirname(package["manifest_path"])
    names = sorted(n for n in os.listdir(directory)
                   if n.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")))
    for name in names:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            out += ["", "--- %s/%s ---" % (package["name"], name), open(path, encoding="utf-8", errors="replace").read().rstrip()]
    out += ["", ""]
print("\n".join(out))
' > "$PREFIX/share/licenses/rust-crates.txt"

# SwiftPM does not see the library as an input of the link (it only gets -l
# and -L flags), so after the library changes it would happily keep linked
# binaries that embed the old one. Remove them so the next build relinks.
staged="$PREFIX/lib/libratex_bridge.a"
if ! cmp -s "$TARGET_DIR/release/libratex_bridge.a" "$staged"; then
    cp -f "$TARGET_DIR/release/libratex_bridge.a" "$staged"
    # Both SwiftPM build systems: the native one (.build/<triple>/<config>)
    # and swift-build (.build/out/Products/<Config>-<platform>), whose test
    # products are a shared object plus a runner per test target.
    for products in "$APP_ROOT"/.build/*/debug "$APP_ROOT"/.build/*/release "$APP_ROOT"/.build/out/Products/*; do
        [ -d "$products" ] || continue
        rm -rf "$products/swiftynotes" "$products"/*PackageTests.xctest \
            "$products"/*Tests.so "$products"/*Tests-test-runner
    done
fi

echo "build-ratex-bridge.sh: staged $PREFIX"
