# Selected glow and connection guidance — build 23

Version: **0.2.5 (23)**. Validation date: **2026-11-16**.

## Behavior

The selected chat cap now breathes gently over 5.6 seconds, with a brighter color core, expanding halo, and light inner rim. Selection follows the actual selected slot, not an unopened dial selection. Other caps and text stay steady. The animation is local to the decorative surface and pauses while backgrounded; Reduce Motion uses a static bright state. Existing dial appearance, routing, microphone behavior, and Send policy are unchanged.

HTTP 502 now explains that the Mac companion could not be reached and directs the user to open Genesis Agent Micro Controller on the selected Mac, then Refresh. The error remains a 502 internally. It does not retry Send or clear an unresolved receipt.

## Reported Mini 2 connection failure

The gateway returned HTTP 502 while the Mac companion process and loopback listener were absent. Reopening the installed companion restored authenticated HTTP 200 responses both locally and through Tailscale. A later check also returned 200. Login startup was already enabled; no startup or network configuration was changed. No matching crash report was found, so the reason the companion exited is unknown.

## Verification

- Signed Release build succeeded; strict signature verification passed.
- Core suite: **83 checks passed**.
- iPhone UI: fullscreen transitions preserve the draft, selected route, dial selection, and Follow controller.
- iPad UI: actual landscape → portrait → landscape transitions preserve draft and route.
- Both targeted UI tests passed with zero failures. These use the isolated demo app, not real messages to a Mac.
- Installed version was independently read back as **0.2.5 / 23** on Rick's iPhone and iPad.
- Each device's paired hosts, mappings, selected route, and draft text were preserved against its own pre-install backup. Some draft timestamps and the iPad's recent-chat history changed during use; byte-for-byte settings equality is not claimed.

The existing iPad orientation deprecation warning remains. Xcode's post-test diagnostic collector stalled after the iPad assertions passed; only that collector was stopped, allowing Xcode to finish with `TEST SUCCEEDED` and a valid result bundle. Physical acceptance of the new pulse is separate from these checks.

## Private rollback and evidence

The prior build 22 app, settings backups, install receipts, and post-install checks are retained under ignored `.local/rollback-before-pulse23/`. No credentials or draft contents are committed.

- Build log: `genesis-iphone/build/controller-build23.log`.
- iPhone result: `genesis-iphone/build/ui-regression/20261116T192246Z-54779.xcresult`.
- iPad result: `genesis-iphone/build/ui-regression/20261116T192402Z-58366.xcresult`.
- Exported demo screenshots: `pulse23-phone-attachments/` and `pulse23-ipad-attachments/` in the UI regression directory.
