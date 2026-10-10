#!/bin/sh
# Fail unless the active Swift toolchain has the major.minor version pinned
# in .swift-version. The Linux CI jobs build with whatever Swift the runner
# image preinstalls; this turns an image update that swaps the compiler into
# a red step instead of a silent change in what the packages are built with.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
wanted=$(tr -d '[:space:]' < "$root/.swift-version")
wanted_minor=$(printf '%s\n' "$wanted" | cut -d. -f1-2)

version_line=$(swift --version 2>&1 | grep 'Swift version' | head -n 1)
actual=$(printf '%s\n' "$version_line" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p')
actual_minor=$(printf '%s\n' "$actual" | cut -d. -f1-2)

echo "$version_line"
if [ -z "$actual" ]; then
    echo "error: could not read the Swift version from 'swift --version'" >&2
    exit 1
fi
if [ "$actual_minor" != "$wanted_minor" ]; then
    echo "error: Swift $actual is active, but .swift-version pins $wanted ($wanted_minor.x)" >&2
    exit 1
fi
