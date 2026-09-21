#!/bin/sh
# Builds, signs, notarizes and staples a Herd release, then checks that
# Gatekeeper accepts it as another Mac would.
#
# Needs, once per machine:
#   1. A "Developer ID Application" certificate in the login keychain, from a
#      paid Apple Developer Program team (Xcode > Settings > Accounts >
#      Manage Certificates). If that team's ID differs from DEVELOPMENT_TEAM
#      in project.yml, change it there.
#   2. Notarization credentials, saved under a keychain profile:
#        xcrun notarytool store-credentials herd-notary \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific password>
#      (an app-specific password is made at account.apple.com).
#
# Usage: scripts/release.sh   (HERD_NOTARY_PROFILE picks another profile)
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${HERD_NOTARY_PROFILE:-herd-notary}"
out="$root/build/release"
app="$out/DerivedData/Build/Products/Release/Herd.app"

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
xcodebuild -project Herd.xcodeproj -scheme Herd -configuration Release \
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
done

echo "==> Notarizing (this waits on Apple, usually a few minutes)"
ditto -c -k --keepParent "$app" "$out/Herd-notarize.zip"
xcrun notarytool submit "$out/Herd-notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"

echo "==> Checking Gatekeeper"
spctl --assess --type execute --verbose=2 "$app"

# The ticket is stapled into the app, so zip it again for shipping.
ditto -c -k --keepParent "$app" "$out/Herd.zip"
rm -f "$out/Herd-notarize.zip"
echo "==> Ready: $out/Herd.zip"
