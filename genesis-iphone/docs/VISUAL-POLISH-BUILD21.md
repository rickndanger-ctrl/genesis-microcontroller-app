# Controller appearance and feedback validation

2026-11-16. Native version 0.2.3 / build 21. Separate from the previously validated Keep reading release; no Mac companion, G2 package, or hardware firmware change.

## Changes

- Reused the Blender shell, cap bevels and dial artwork with native frosted surfaces and fixed slot-color illumination.
- The left chat dial smoothly follows the browsed slot color and has a slow, subtle glow. The right artifact dial remains black.
- Kept labels inside the caps with bounded two-line text and truncation for long assignments.
- Added deliberate click feedback across secondary menus, mapping, host/provider selection, refresh, and glasses controls. The existing sound preference and system silent/volume behavior remain in effect.
- Suppressed sounds while authorizing, recording, finalizing, inactive or backgrounded. Starting dictation uses haptics only, including mapped quick keys, six-slot assignments, the chat dial and accessibility actions. Suppressed sounds are never queued.
- Preserved existing command paths, explicit Send safeguards, drafts, mappings, slot colors and Keep reading lifecycle. Reduce Motion, Reduce Transparency and increased contrast are respected.

## Verification

- Signed iOS Release build passed; strict code-signature verification passed.
- 18 injected sound-policy checks passed. These exercise preference, capture and foreground guards without playing audio.
- iPhone simulator: five UI scenarios passed with zero failures: dial rotation/reversal and long labels, glasses panel, hold/release outside and mapped dictation, Claude review/Send in the isolated demo, and repeated dictation after review.
- iPad A16 simulator: dial/rotation/label/sound-switch and glasses-panel scenarios passed with zero failures. Inspected the exported landscape screenshots. Tests used the separate demo bundle and sent no commands to a Mac.
- The initial iPad attempt failed because Mini 2's disk filled. Removed only this project's regenerable caches and reran successfully. After tests passed, Xcode stalled collecting optional simulator diagnostics; stopped that child diagnostic collector. Xcode then exited successfully and finalized a Passed result bundle with both tests and screenshots intact.
- Existing Xcode warnings remain about future `UIRequiresFullScreen`/orientation behavior. They are separate from the proposed in-app full-screen layout.
- Installed build 21 in place on Rick's iPhone and the iPad A16. DeviceControl independently reported 0.2.3 / 21 on both. Both devices' normalized controller settings matched their pre-update snapshots exactly, including stored assignments and drafts.
- Used iPhone Mirroring to inspect the new appearance. Turning the chat dial changed its hue and preview selection; reversing returned to C1 without activating another chat. The existing unsent draft and uncertain-delivery receipt remained intact.
- Installation restarted the iPhone app. Restored its existing Follow session and selected C1 again. The UI then showed a fresh glasses acknowledgement and Keep reading Ready, with its saved option still on. No draft was sent or receipt resolved.

Actual click loudness and feel have not been confirmed by the user on build 21. The audio policy and sound-switch behavior passed tests; the original bundled click/tick assets are unchanged. Physical iPad appearance and gestures were not retested by the user in this pass.

## Evidence and rollback

Private local evidence: `.local/rollback-before-visual-polish/` contains the signed build 20 rollback, device settings/preferences snapshots, build 21 installation receipts and installed-version records. The current signed app is under `genesis-iphone/build/ipad-device/Build/Products/Release-iphoneos/`.

UI results:

- Phone: `genesis-iphone/build/ui-regression/20261116T174758Z-14828.xcresult`.
- iPad: `genesis-iphone/build/ui-regression/20261116T175327Z-28053.xcresult`.
- Exported previews: `polish-phone-attachments/` and `polish-ipad-attachments/` under the same build directory.

Full-screen controller mode is investigated in [the separate proposal](FULLSCREEN-CONTROLLER-PROPOSAL.md). It is not implemented in build 21.
