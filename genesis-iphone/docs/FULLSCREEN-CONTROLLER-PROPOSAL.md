# Full-screen controller proposal

Status: **implemented in native 0.2.4 / build 22**. This document retains the design and acceptance criteria. See [build 22 validation](FULLSCREEN-BUILD22.md) for what was tested and installed.

## Purpose and screen limits

Give the deck a dedicated view that stays visible without scrolling, while keeping the current Mac, provider, chat, draft, and Send action clear. The app already requests full-screen presentation on iPad; this proposal is an alternate layout inside Genesis, not a new system display mode.

The current phone deck is largely width-limited. Removing the large heading and stacked panels will make it easier to reach, but will not necessarily make its keys substantially larger. Some iPads are already height-limited in landscape. Larger iPads could use space beyond the current 780-point landscape deck cap, where the remaining height permits it. Do not promise larger controls on every device.

- iPhone portrait: compact route bar, square deck, persistent draft preview and explicit Send. Expand the draft for editing or review. Keep the phone's existing portrait orientation support for the first version.
- iPad landscape: fit the square deck to available height; place draft review and essential status in a side panel when there is sufficient width.
- iPad portrait: stack the compact route bar, deck, and draft controls. A drawer can hold the detailed Follow controls.
- Fit the deck to the smaller remaining dimension after safe areas and essential controls. Do not impose a minimum deck size that pushes Exit or Send off screen. At large accessibility text sizes, prefer a readable scrolling arrangement over shrinking labels or clipping controls.

Xcode now warns that `UIRequiresFullScreen` will be ignored in a future OS release. Implement this as an adaptable layout within the available app window; do not depend on the legacy flag to force iPad windowing behavior. Orientation support and window resizing belong in its acceptance tests.

## Controls that remain available

Use a permanently visible Exit button with at least a 44-point target. Next to it, show a compact route bar containing the selected Mac, provider, and selected chat with its existing slot color. Host and provider switching remain explicit; the layout must not silently change the selected route.

Keep a persistent draft preview and a dedicated Send button outside the remappable quick keys. Send continues to use the existing guarded `sendDraft()` path and its current enabled state, receipt, and uncertain-delivery handling. Expanding or collapsing draft review must not clear or send it. Recording and finishing status remain visible.

An optional Follow drawer can expose Conversation, Draft, Home, paging, refresh, Follow ownership, and Keep reading. Show a compact truthful Follow status while the drawer is closed. Hiding the drawer must not enable, disable, take over, park, or resume Follow.

## Implementation boundaries

Keep the mode as local presentation state in the existing `ControllerScreen`, using the same `ControllerStore`, speech engine, Follow controller, and command client. Avoid creating a second screen-owned store or moving this mode into an independent app/session. Prefer a stable view hierarchy or layout adaptation so the deck's drag and selection state survives changes in available space.

Disable entry and Exit transitions while Talk is held or dictation is finishing. Do not call `clearPresentation()`, synthesize a Talk release, cancel capture, or restart polling merely because the layout changes. Existing host/provider changes and system background handling retain their established behavior. Do not change idle-timer policy or the tested Keep reading lifecycle as part of this presentation feature.

Preserve existing action IDs, accessibility labels, gestures, explicit Send protection, slot palette, sound preference, capture-time sound suppression, and Reduce Motion behavior. Normal and focused layouts must share the same actions rather than duplicate their implementation.

## Focused acceptance checks for an implementation

1. On phone portrait and iPad portrait/landscape, Exit, route, deck, draft preview, and Send remain reachable within safe areas. Check long titles, keyboard presentation, and large text.
2. Enter and exit with an unsent draft; exact host, provider, chat, draft, dial selection, and mappings remain intact. No command is sent by the transition.
3. During a Talk gesture or finalization, a mode change cannot interrupt or duplicate recording. Release-to-review and repeated dictation still retain every draft segment.
4. Verify knob rotation, reverse movement, key tap/hold mapping, and accessibility actions in both layouts. Disabled controls remain disabled.
5. Verify Send remains an explicit action with the same exact-target checks and receipt handling, including an uncertain receipt. Use the demo harness for automated sends.
6. With Follow enabled, opening/closing the drawer and changing layout preserve the active lease and exact selected chat. Background/lock still uses the existing Keep reading rules.
7. Verify muted sounds remain muted, capture and background suppress sound, and Reduce Motion prevents decorative animation.

No controller firmware or Mac companion change is required by this layout proposal.
