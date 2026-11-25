#!/bin/sh
# Wraps a notarized, stapled "Agent Micro Controller.app" in a drag-to-Applications
# disk image, then signs, notarizes and staples the image itself.
# Usage: make-dmg.sh <path to .app> <output .dmg>
# Needs NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER, like release.sh.
set -eu
APP=$1
DMG=$2
SIGN_ID=${RELEASE_SIGN_ID:-"Developer ID Application: RICHARD LEE HOLGUIN (7FQA384X2F)"}
: "${NOTARY_KEY:?set NOTARY_KEY to the App Store Connect API key (.p8)}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?set NOTARY_ISSUER}"

xcrun stapler validate "$APP"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Agent Micro Controller.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Agent Micro Controller" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Ready: $DMG"
