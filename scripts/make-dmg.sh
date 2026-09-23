#!/bin/sh
# Packs the app into a disk image whose window shows the app beside the
# Applications folder, so installing is one drag. The image is signed with
# Developer ID when that certificate is present; release.sh notarizes it.
#
# Finder lays the window out, so the first run on a machine asks to let the
# terminal control Finder (System Settings > Privacy & Security > Automation).
#
# Usage: scripts/make-dmg.sh <path-to-app> <out.dmg>
set -eu

[ "$#" -eq 2 ] || { echo "usage: $0 <path-to-app> <out.dmg>" >&2; exit 1; }
app="$1"
dmg="$2"
[ -d "$app" ] || { echo "error: no app at $app" >&2; exit 1; }

scripts="$(cd "$(dirname "$0")" && pwd)"
# The volume, the icon and the caption all take the app's own name.
name="$(basename "$app" .app)"
volume="$name"
work="$(mktemp -d)"
mount=""
cleanup() {
    [ -n "$mount" ] && hdiutil detach "$mount" -force >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

echo "==> Drawing the window background"
swift "$scripts/dmg-background.swift" "$work/background.png" 1 "$name"
swift "$scripts/dmg-background.swift" "$work/background@2x.png" 2 "$name"

stage="$work/stage"
mkdir -p "$stage/.background"
# One TIFF holding both sizes, so Retina displays get the sharp one.
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
    -out "$stage/.background/background.tiff" >/dev/null 2>&1
ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"

echo "==> Building the image"
# Room for the app plus what Finder writes while laying out the window.
megabytes=$(( $(du -sm "$stage" | cut -f1) + 20 ))
hdiutil create -srcfolder "$stage" -volname "$volume" -fs HFS+ \
    -format UDRW -size "${megabytes}m" -ov "$work/rw.dmg" >/dev/null
mount="$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" \
    | awk -F'\t' '/\/Volumes\//{print $NF}')"
[ -d "$mount" ] || { echo "error: the image didn't mount." >&2; exit 1; }
# Another "Octet" volume may be mounted already, making this one "Octet 1".
disk="$(basename "$mount")"

echo "==> Laying out the window"
# Positions are icon centres and must match dmg-background.swift. The window
# is the background's 660x400 plus the title bar.
osascript <<EOF
tell application "Finder"
    tell disk "$disk"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "$name.app" of container window to {180, 170}
        set position of item "Applications" of container window to {480, 170}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Finder writes the layout lazily; don't unmount before it has.
tries=0
until [ -s "$mount/.DS_Store" ] || [ "$tries" -ge 10 ]; do
    sleep 1
    tries=$((tries + 1))
done
[ -s "$mount/.DS_Store" ] || { echo "error: Finder never saved the window layout." >&2; exit 1; }
rm -rf "$mount/.fseventsd"
# `hdiutil detach` flushes this image. A global `sync` also waits on every
# unrelated mounted volume and can stall a release indefinitely when a network
# or external disk is unhealthy.

tries=0
until hdiutil detach "$mount" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || { echo "error: couldn't unmount $mount." >&2; exit 1; }
    sleep 2
done
mount=""

echo "==> Compressing"
rm -f "$dmg"
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "==> Signing"
    codesign --force --sign "Developer ID Application" --timestamp "$dmg"
else
    echo "warning: no Developer ID Application certificate; the image is unsigned." >&2
fi
echo "==> Ready: $dmg"
