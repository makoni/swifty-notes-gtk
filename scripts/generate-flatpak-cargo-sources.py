#!/usr/bin/env python3
"""Writes flatpak/ratex-cargo-sources.json from Sources/RaTeXBridge/Cargo.lock.

Flatpak builds have no network, so every crate the math bridge needs is a
flatpak-builder source: the .crate archive from static.crates.io (checked
against Cargo.lock's sha256), unpacked into cargo/vendor/<name>-<version>,
plus the .cargo-checksum.json cargo expects there, and a cargo config that
points crates.io at that directory. This is the layout
flatpak-cargo-generator produces, for the crates.io-only lock file this crate
has, with nothing but the standard library.

Run it after changing Sources/RaTeXBridge/Cargo.lock and commit the result.
"""

import json
import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = ROOT / "Sources" / "RaTeXBridge" / "Cargo.lock"
OUTPUT = ROOT / "flatpak" / "ratex-cargo-sources.json"
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"


def main() -> int:
    lock = tomllib.loads(LOCK.read_text(encoding="utf-8"))
    sources = []
    for package in sorted(lock["package"], key=lambda p: (p["name"], p["version"])):
        source = package.get("source")
        if source is None:
            continue  # the bridge crate itself
        if source != CRATES_IO:
            print(f"unsupported source for {package['name']}: {source}", file=sys.stderr)
            return 1
        name, version, checksum = package["name"], package["version"], package["checksum"]
        directory = f"cargo/vendor/{name}-{version}"
        sources.append({
            "type": "archive",
            "archive-type": "tar-gzip",
            "url": f"https://static.crates.io/crates/{name}/{name}-{version}.crate",
            "sha256": checksum,
            "dest": directory,
        })
        sources.append({
            "type": "inline",
            "contents": json.dumps({"package": checksum, "files": {}}),
            "dest": directory,
            "dest-filename": ".cargo-checksum.json",
        })
    sources.append({
        "type": "inline",
        "contents": (
            '[source.vendored-sources]\ndirectory = "cargo/vendor"\n\n'
            '[source.crates-io]\nreplace-with = "vendored-sources"\n'
        ),
        "dest": "cargo",
        "dest-filename": "config.toml",
    })
    OUTPUT.write_text(json.dumps(sources, indent=4) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({(len(sources) - 1) // 2} crates)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
