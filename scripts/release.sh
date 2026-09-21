#!/bin/sh
# Builds, signs, notarizes and staples an Octet release, then checks that
# Gatekeeper accepts it as another Mac would.
#
# Needs, once per machine:
#   1. A "Developer ID Application" certificate in the login keychain, from a
#      paid Apple Developer Program team (Xcode > Settings > Accounts >
#      Manage Certificates). If that team's ID differs from DEVELOPMENT_TEAM
#      in project.yml, change it there.
#   2. Notarization credentials, saved under a keychain profile:
#        xcrun notarytool store-credentials octet-notary \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific password>
#      (an app-specific password is made at account.apple.com).
#
# Usage: scripts/release.sh   (OCTET_NOTARY_PROFILE picks another profile)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${OCTET_NOTARY_PROFILE:-octet-notary}"
out="$root/build/release"
app="$out/DerivedData/Build/Products/Release/Octet.app"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no Developer ID Application certificate in the keychain." >&2
    echo "       Release builds are signed for distribution; see the top of this script." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "error: no notarization credentials under the profile '$profile'." >&2
    echo "       Save them with 'xcrun notarytool store-credentials $profile …'; see the top of this script." >&2
    exit 1
fi

echo "==> Building"
cd "$root"
xcodegen generate
rm -rf "$out"
xcodebuild -project Octet.xcodeproj -scheme Octet -configuration Release \
    -derivedDataPath "$out/DerivedData" build | grep -E "^\*\* BUILD|: error:" || true
[ -d "$app" ] || { echo "error: the build produced no app." >&2; exit 1; }

echo "==> Checking signatures"
codesign --verify --deep --strict "$app"
# Notarization rejects any executable without the hardened runtime or a
# secure timestamp, so check each one here rather than wait for Apple to.
for binary in "$app/Contents/MacOS/"*; do
    details="$(codesign -dvv "$binary" 2>&1)"
    echo "$details" | grep -q "flags=.*runtime" || { echo "error: $binary lacks the hardened runtime." >&2; exit 1; }
    echo "$details" | grep -q "^Timestamp=" || { echo "error: $binary has no secure timestamp." >&2; exit 1; }
    echo "$details" | grep -q "Authority=Developer ID Application" || { echo "error: $binary isn't signed with Developer ID." >&2; exit 1; }
    if codesign -d --entitlements - "$binary" 2>&1 | grep -q "get-task-allow"; then
        echo "error: $binary carries the get-task-allow entitlement." >&2; exit 1
    fi
done

echo "==> Notarizing (this waits on Apple, usually a few minutes)"
ditto -c -k --keepParent "$app" "$out/Octet-notarize.zip"
xcrun notarytool submit "$out/Octet-notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"

echo "==> Checking Gatekeeper"
spctl --assess --type execute --verbose=2 "$app"

# The ticket is stapled into the app, so zip it again for shipping.
ditto -c -k --keepParent "$app" "$out/Octet.zip"
rm -f "$out/Octet-notarize.zip"

# The disk image is what people download. It holds the stapled app, and is
# notarized and stapled itself so it opens cleanly on a Mac that is offline.
"$root/scripts/make-dmg.sh" "$app" "$out/Octet.dmg"
echo "==> Notarizing the disk image"
xcrun notarytool submit "$out/Octet.dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$out/Octet.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$out/Octet.dmg"

echo "==> Ready: $out/Octet.dmg (and $out/Octet.zip)"
