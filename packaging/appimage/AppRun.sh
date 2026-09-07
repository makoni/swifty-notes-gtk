#!/bin/sh
# AppRun for the Swifty Notes AppImage.
#
# An AppImage is not a sandbox: it is a self-mounting archive whose contents
# run with the invoking user's full privileges. Nothing here confines the app
# the way Flatpak's bubblewrap or Snap's AppArmor profile does. What this
# script does instead is point every library that resolves data by *path* at
# the AppDir, because the mount point is a fresh directory on every launch and
# nothing inside can be baked in at build time.
set -eu

APPDIR="${APPDIR:-$(dirname "$(readlink -f "$0")")}"
export APPDIR

# linuxdeploy plugins drop their environment setup here, and only the plugin's
# own generated AppRun sources it. A custom AppRun that forgets to is the
# classic way to ship a bundle whose GdkPixbuf loaders, GIO modules and
# fontconfig never get found — the symptoms are missing images and missing
# fonts, both of which look like application bugs.
if [ -d "$APPDIR/apprun-hooks" ]; then
    for hook in "$APPDIR/apprun-hooks"/*.sh; do
        [ -e "$hook" ] || continue
        # shellcheck disable=SC1090
        . "$hook"
    done
fi

case "$(uname -m)" in
    x86_64) triplet=x86_64-linux-gnu ;;
    aarch64) triplet=aarch64-linux-gnu ;;
    *) triplet="" ;;
esac
LD_LIBRARY_PATH="$APPDIR/usr/lib${triplet:+:$APPDIR/usr/lib/$triplet}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# `$APPDIR/usr/share` first, which is what carries the app's icon, its
# AppStream metainfo and the bundled hunspell dictionaries. Enchant's hunspell
# provider walks `$XDG_DATA_DIRS/hunspell`, so the dictionaries the Flatpak
# ships reach an AppImage user through this line — see docs/APPIMAGE.md for
# the half of spell-check that cannot be bundled this way.
XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export XDG_DATA_DIRS

export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
export GI_TYPELIB_PATH="$APPDIR/usr/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
export GTK_EXE_PREFIX="$APPDIR/usr"
export GTK_DATA_PREFIX="$APPDIR/usr"

# The launcher the install root puts in `usr/bin` execs
# `${SWIFTY_NOTES_ROOT_PREFIX}/usr/libexec/swifty-notes/swiftynotes`, an
# absolute path that is empty-prefixed on a normal system install. Left unset
# it would look for `/usr/libexec/...` on the host, which either does not exist
# or — worse — is some other copy of the app.
export SWIFTY_NOTES_ROOT_PREFIX="$APPDIR"

exec "$APPDIR/usr/bin/swiftynotes" "$@"
