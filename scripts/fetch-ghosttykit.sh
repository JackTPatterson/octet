#!/bin/sh
# Downloads the prebuilt GhosttyKit.xcframework Octet links against, checks
# it against a pinned SHA-256, and unpacks it into Vendor/.
#
# The archive is published by manaflow-ai/ghostty (MIT), a Ghostty fork, from
# the commit pinned below. Pass a path instead to use a framework you built
# yourself: scripts/fetch-ghosttykit.sh /path/to/GhosttyKit.xcframework
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Vendor/GhosttyKit.xcframework"

ghostty_commit="4a0e9e185313fd9d09b2f3564a3dfbab444453c0"
flavor="crashsubdir-cmux-crash-sentry-off-noi18n-v2"
sha256="daf00df2d558846491e4db20b7c301d6775e87663af24607073ff3492efe3428"
url="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-$ghostty_commit-$flavor/GhosttyKit.xcframework.tar.gz"

mkdir -p "$root/Vendor"

if [ "$#" -gt 0 ]; then
    source="$1"
    if [ ! -d "$source" ]; then
        echo "error: $source is not a directory" >&2
        exit 1
    fi
    rm -rf "$dest"
    cp -R "$source" "$dest"
    echo "Copied $source to Vendor/GhosttyKit.xcframework"
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/octet-ghosttykit.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM

echo "Downloading GhosttyKit (ghostty ${ghostty_commit%"${ghostty_commit#???????}"})"
curl --fail --show-error --location --progress-bar --retry 3 -o "$work/GhosttyKit.tar.gz" "$url"

actual="$(shasum -a 256 "$work/GhosttyKit.tar.gz" | awk '{print $1}')"
if [ "$actual" != "$sha256" ]; then
    echo "error: GhosttyKit checksum mismatch" >&2
    echo "  expected $sha256" >&2
    echo "  actual   $actual" >&2
    exit 1
fi

tar --no-same-owner -xzf "$work/GhosttyKit.tar.gz" -C "$work"
rm -rf "$dest"
mv "$work/GhosttyKit.xcframework" "$dest"
echo "Installed Vendor/GhosttyKit.xcframework"
