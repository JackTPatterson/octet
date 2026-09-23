#!/bin/sh
# Prints the path to Sparkle's generate_appcast tool, fetching the pinned
# official distribution into ignored build output when it is not cached yet.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
version="2.10.0"
sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
tools="$root/build/tools/Sparkle-$version"
archive="$root/build/tools/Sparkle-$version.tar.xz"
generator="$tools/bin/generate_appcast"

if [ ! -x "$generator" ]; then
    mkdir -p "$tools"
    if [ ! -f "$archive" ]; then
        curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
    fi
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$actual" != "$sha256" ]; then
        echo "error: Sparkle $version archive checksum mismatch." >&2
        exit 1
    fi
    tar -xJf "$archive" -C "$tools"
fi

printf '%s\n' "$generator"
