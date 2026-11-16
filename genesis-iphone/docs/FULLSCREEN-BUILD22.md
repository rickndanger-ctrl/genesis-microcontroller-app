# Full-screen controller — build 22

Version: **0.2.4 (22)**  
Validation date: **2026-11-16**  
Status: **built, tested, and installed on Rick's iPhone and iPad; physical acceptance of the new presentation remains pending**.

## What changed

The controller now has a focused full-screen layout inside Genesis. Tap the outward-pointing arrows beside Settings to enter it; tap the inward-pointing arrows to return. The compact layout keeps the selected computer, provider, and chat visible, with draft review and a dedicated Send button. Actions, Settings, and glasses controls remain available.

The controller keys and left dial have a brighter glow using the existing slot colors. The right dial retains its existing appearance. Both dials preserve their settled rotation and selection when the layout changes.

This is a presentation mode in the same app and controller store. It does not create a second Follow session. Follow, Keep reading, chat mappings, dictation, and the guarded Send path continue to use their existing implementations. Entering or leaving the mode is disabled during recording, finalization, or a dial drag. Send errors remain visible within the draft-review and glasses sheets, and unresolved-delivery recovery is available from draft review.

## Validation status

| Check | Result |
| --- | --- |
| Signed Release build, version 0.2.4 / build 22 | Passed |
| Strict code-signature verification | Passed |
| Sound policy tests | Passed — 18 checks using injected playback |
| iPhone UI: dial interactions | Passed |
| iPhone UI: selection and state preservation through layout changes | Passed |
| iPhone UI: dedicated Send and capture guards | Passed |
| iPhone UI: computer/provider menus and route isolation | Passed |
| iPhone screenshot review | Passed |
| iPad UI: state preservation, Send/capture guards, and route isolation | Passed |
| iPad rotation: observed landscape → portrait → landscape, draft and route preserved | Passed |
| iPad portrait and landscape screenshot review | Passed |
| iPhone installation | Passed — installed version independently verified as 0.2.4 / 22 |
| iPad installation | Passed — installed version independently verified as 0.2.4 / 22 |
| Saved settings after installation | Passed — each device's settings JSON exactly matches its own pre-install backup |
| Physical acceptance of the new layout and stronger glow | **Pending** |

The eight automated UI checks (four on each device class) use the isolated demo harness. They are not evidence of a real prompt being sent to a Mac. The sound policy checks verify gating and preference behavior without playing real audio. Device audibility is a separate physical check. iPhone Mirroring reported that the phone was in use, so build 22's visual review uses simulator captures; live mirrored acceptance is not claimed.

Source review confirmed that the layout preserves the existing Send checks and Follow controller, observes Follow status directly, and clears drag-active state when rotation removes a dial view. The build does not replace the previously accepted Keep reading implementation; a fresh physical lock test is not claimed here.

## Layout and platform limits

The focused layout respects safe areas and retains a scrolling fallback when space or accessibility text size requires it. On iPhone, the deck remains limited mainly by screen width; full-screen mode does not imply larger keys on every device. On iPad, the layout adapts between stacked and side-by-side arrangements.

The iPad UI run reports an OS warning about the existing `UIRequiresFullScreen` setting. The Release build and strict signature verification still pass. This setting is separate from the new in-app controller layout; the platform warning has not been removed.

## Rollback and retained evidence

Build 21 and settings backups were saved under the ignored local directory `.local/rollback-before-fullscreen/`. Installation receipts, installed-version queries, and post-install settings copies are saved there too. Preserve these until device acceptance is complete. Files are private and are not included in Git.

Current build 22 evidence is retained locally:

- Release build: `genesis-iphone/build/controller-build22.log`.
- iPhone UI: `genesis-iphone/build/ui-regression/20261116T185019Z-70239.xcresult` and matching log.
- iPad UI: `genesis-iphone/build/ui-regression/20261116T185416Z-80066.xcresult` and matching log.
- Exported screenshots: `fullscreen-phone-attachments/` and `fullscreen-ipad-attachments/` under that UI regression directory.

Because disk space was low, selected older generated test archives were cleared after their summaries were exported into the private rollback directory. The current build 22 raw test archives and screenshots remain available. No pairing credentials, private device identifiers, or draft content are included in this note.
