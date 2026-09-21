#!/bin/sh
# Copies the terminal engine binary and its license into Vendor/engine so the
# Xcode build can bundle it inside Octet.app (Contents/MacOS/octet-engine).
#
# Usage: scripts/fetch-engine.sh [path-to-engine-binary]
# With no argument, the binary is taken from the Homebrew install.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Vendor/engine"

if [ "$#" -ge 1 ]; then
    binary="$1"
    source_dir="$(cd "$(dirname "$binary")/.." && pwd)"
else
    source_dir="$(brew --prefix)/opt/herdr"
    binary="$source_dir/bin/herdr"
fi

if [ ! -x "$binary" ]; then
    echo "error: engine binary not found or not executable: $binary" >&2
    exit 1
fi

mkdir -p "$dest"
rm -f "$dest/octet-engine"
cp "$binary" "$dest/octet-engine"
chmod 755 "$dest/octet-engine"

license=""
for candidate in "$source_dir/LICENSE" "$(dirname "$binary")/LICENSE"; do
    if [ -f "$candidate" ]; then
        license="$candidate"
        break
    fi
done
if [ -n "$license" ]; then
    cp "$license" "$dest/LICENSE"
else
    echo "warning: no LICENSE found next to $binary" >&2
fi

if [ -f "$source_dir/NOTICE" ]; then
    cp "$source_dir/NOTICE" "$dest/NOTICE"
fi

echo "Engine copied to $dest/octet-engine"
"$dest/octet-engine" --version 2>/dev/null || true
