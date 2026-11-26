#!/bin/sh
# Wraps a notarized, stapled "Agent Micro Controller.app" in a drag-to-Applications
# disk image, then signs, notarizes and staples the image itself.
# Usage: make-dmg.sh <path to .app> <output .dmg>
# Needs NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER, like release.sh.
# DMG_LAYOUT_ONLY=1 builds the image without signing or notarizing, to check the window.
set -eu
APP=$1
DMG=$2
ROOT=$(cd "$(dirname "$0")" && pwd)
VOLUME="Agent Micro Controller"
SIGN_ID=${RELEASE_SIGN_ID:-"Developer ID Application: RICHARD LEE HOLGUIN (7FQA384X2F)"}
LAYOUT_ONLY=${DMG_LAYOUT_ONLY:-0}
if [ "$LAYOUT_ONLY" != 1 ]; then
  : "${NOTARY_KEY:?set NOTARY_KEY to the App Store Connect API key (.p8)}"
  : "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
  : "${NOTARY_ISSUER:?set NOTARY_ISSUER}"
  xcrun stapler validate "$APP"
fi

# Finder lays the window out by volume name, so another copy must not be mounted.
if [ -e "/Volumes/$VOLUME" ]; then
  echo "Eject the mounted \"$VOLUME\" disk first." >&2; exit 1
fi

STAGE=$(mktemp -d)
RW="$STAGE.rw.dmg"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$STAGE" "$RW"; rmdir "$STAGE.mnt" 2>/dev/null || true
}
trap cleanup EXIT
ditto "$APP" "$STAGE/$VOLUME.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$ROOT/dmg/background.tiff" "$STAGE/.background/background.tiff"

# A writable image first, so Finder can save the window's layout into it.
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
[ -n "$MOUNT" ] || { echo "Could not mount the image." >&2; exit 1; }

# A 600 x 400 window: the app on the left, Applications on the right, the arrow
# and the instruction between them in the background picture.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    set win to container window
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set the bounds of win to {200, 120, 800, 520}
    set opts to the icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$VOLUME.app" of win to {150, 190}
    set position of item "Applications" of win to {450, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
# Give Finder time to write .DS_Store before the image is sealed.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MOUNT/.DS_Store" ] && break; sleep 1; done
[ -f "$MOUNT/.DS_Store" ] || { echo "Finder did not save the window layout." >&2; exit 1; }
# A window manager on the build Mac can resize the window after this, and Finder
# saves that size too. Keep the size Finder saved first and put it back below.
BOUNDS=$(python3 -I "$ROOT/dmg/set-window-bounds.py" "$MOUNT/.DS_Store" get)
case "$BOUNDS" in *"{600, 400}}") ;; *) echo "Finder saved an unexpected window size: $BOUNDS" >&2; exit 1 ;; esac
sync
hdiutil detach "$MOUNT" -quiet
# Hidden from Finder this time, so nothing rewrites the record after it is fixed.
mkdir "$STAGE.mnt"
hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$STAGE.mnt" >/dev/null
MOUNT="$STAGE.mnt"
python3 -I "$ROOT/dmg/set-window-bounds.py" "$MOUNT/.DS_Store" set "$BOUNDS"
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
if [ "$LAYOUT_ONLY" = 1 ]; then echo "Layout only (not signed): $DMG"; exit 0; fi
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Ready: $DMG"
