#!/bin/sh
# Builds a Developer ID signed, notarized and stapled copy of the Mac companion
# for download from GitHub. It never touches the copy installed on this Mac.
#
#   NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#   NOTARY_KEY_ID=XXXX NOTARY_ISSUER=uuid ./release.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SIGN_ID=${RELEASE_SIGN_ID:-"Developer ID Application: RICHARD LEE HOLGUIN (7FQA384X2F)"}
: "${NOTARY_KEY:?set NOTARY_KEY to the App Store Connect API key (.p8)}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?set NOTARY_ISSUER}"

"$ROOT/build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Agent Micro Controller.app/Contents/Info.plist")
DIST="$ROOT/dist"
APP="$DIST/Agent Micro Controller.app"
ZIP="$DIST/Agent-Micro-Controller-Mac-$VERSION.zip"
rm -rf "$DIST"; mkdir -p "$DIST"
ditto "$ROOT/Agent Micro Controller.app" "$APP"

codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Ready: $ZIP"
