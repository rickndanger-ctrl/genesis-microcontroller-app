# Mac bridge preview

The existing signed Genesis companion now includes a private remote service. It starts independently of USB, retains the original bundle identity, and does not rewrite hardware mappings. `RemoteProtocol.swift`, `RemoteHTTP.swift`, and `RemoteBridge.swift` are compiled by the companion build.

## Pairing and transport

- In the companion menu bar, choose **Pair iPhone / Artifacts**.
- The remote service binds **127.0.0.1:18765 only**. Tailscale Serve should proxy a separate HTTPS port **8451** to that service, retaining all existing Serve handlers.
- The endpoint is discovered read-only from `tailscale status --json`, and can be edited in the pairing window. Discovery does not configure Tailscale.
- The QR code is `genesiscontroller://pair?data=...` and contains a private bearer credential. Do not capture it in public screenshots or logs.
- Remote state is under `~/Library/Application Support/Genesis Agent Micro Controller/Remote/`. The directory is mode700; pairing token, ledger/profile JSON and exported files are mode600. Back this directory up privately, not into GitHub.
- Turning off **Enable private remote access** stops the listener. Reenable to resume. Pairing requires the HTTPS endpoint to be reachable and the phone to verify the saved host UUID.

## Implemented controls and current limits

Claude uses the existing verified navigation code. A remote Send opens/revalidates an exact visible Code session, refuses a composer containing any non-whitespace text, requires a writable Accessibility prompt, verifies inserted text exactly, then resolves a fresh Send control and rechecks the target immediately before clicking once. Claude can expose a newline for an empty editor; Unicode whitespace alone counts as blank, while an unreadable value or zero-width non-whitespace text remains protected. It confirms only when the composer is blank and response activity is observed. Ambiguous titles or lost context fail closed; uncertain results are never automatically retried.

Claude desktop UI updates may stop exposing a writable prompt; the explicit failure leaves the phone draft intact. Locked Macs and unavailable Accessibility prevent desktop commands.

Codex supports mapping and opening saved chats. `CodexReadOnly.swift` reads up to 500 eligible current-account, nonarchived chats from the existing local daemon, returning UUID and name only. A fresh inventory check validates the chosen UUID before opening its existing-chat deep link in `com.openai.codex`. The receipt confirms macOS accepted that request; it does not independently prove the visible thread changed. Genesis uses the inventory endpoint for metadata and leaves running turns to the existing session owner. Codex Send checks the exact current-account chat UUID and queues the reviewed text through the signed CLI bundled with Codex. Genesis requires the CLI’s acknowledgement for that UUID before reporting queue acceptance. An unloaded or busy chat can process the entry later. The installed CLI accepts text as a process argument, which is briefly visible to local process inspection. Genesis does not log the prompt. Codex Stop and native live voice remain unavailable. Muse still exposes only the registered artifact shelf and is deferred.

Native live voice is not replaced with a custom voice layer. It remains disabled until correct-thread launch and two-way iPhone audio are verified.

## Artifacts

Register an image/PDF/text export or HTTPS artifact link in **Pair iPhone / Artifacts**. Optional chat association scopes it to one conversation; provider-wide items appear in every chat. Requests without a chat filter return the provider's entire shelf. Exported files are copied into a private directory with opaque UUID names; the content route serves only registered UUIDs and rejects nonregular/symlink files or content larger than20MB. Browser requests from arbitrary origins are not allowed to call the controller API. External artifact links never receive the pairing bearer token.

Artifact discovery from provider internals is not implemented. Local interactive servers are not exposed automatically: register a usable HTTPS link or export instead. An HTTPS artifact may require the user's own phone login.

## Verification

Run `sh tools/test-host.sh` from the `genesis-iphone` directory for policy, storage, lookup, and loopback HTTP checks. The fixture listener uses port18766 and never invokes desktop controls. From that directory, run `sh ../genesis-mapper/test-codex-inventory.sh` for inventory protocol checks, `sh ../genesis-mapper/test.sh` for controller regressions, and `sh ../genesis-mapper/build.sh` for the signed companion. No real chat prompt is sent by these tests.

Claude discovery and selection share the same sidebar row validator. A nested More options menu is accepted. A button may exactly match its title plus an allowlisted status badge, including Running, Unread response, or Cloud, when the same row's menu independently names that exact title; this remains valid when Electron omits text descendants from inactive rows. Other decorated labels additionally require an exact title text child. Primary toolbar/header copies do not count as sidebar destinations, and two real destinations with the same title remain ambiguous. The authenticated `GET /v1/diagnostics/claude` route reports AX structure only around saved slot titles, with attribute values reduced to match categories. It does not return message text, composer content, or credentials.

Known slot commands resolve their title from saved mappings or recent metadata, then freshly validate that target instead of rescanning all chats. AX attributes are cached only inside one synchronous read snapshot and cleared at its end, including error exits. No cache crosses an await or UI action; Send still rechecks the current header and exact inserted draft immediately before the click. Each post-click verification tick checks the header, unique blank composer, and response activity from one fresh read snapshot. A blank composer alone never confirms delivery.

Command receipts persist a fingerprint and outcome, never prompt text. Pending receipts become uncertain after restart. Reusing a request ID with changed content fails; an identical request gets its saved receipt. On an uncertain Send, inspect the actual chat before manually composing a new submission.

Muse is driven through Accessibility by `MuseAccess.swift`; the rules it applies live in `MuseChatList.swift` and are covered by `tests/MuseChatListTests.swift`. Chats are the rows of Muse's chat panel, identified by title, so titles shared by several rows are excluded. The open chat is read from the header button and confirmed by the message box, whose label names its chat. A row is opened with a real click because Muse ignores an accessibility press on it. macOS cannot hit-test inside Muse's page, so a click is allowed only when the point lies on Muse's frontmost standard window with no sheet over it, and its effect is confirmed afterwards. Send pastes into the message box and reads it back through the clipboard, which is restored; `rehearsal: true` stops before Return and removes the draft, for checking a Mac without sending. Pressing the message box through Accessibility opens Muse's file picker, so the connector never does that.

A side chat Muse has just opened has no row, no header and the same plain message box as the main chat. It is offered as "New side chat" and recognised by having no header and a Back to main chat control; the New chat action returns it as the active chat so a draft can go straight in. Leaving it for another chat goes back through the main chat. Delivery is confirmed by the exact draft appearing once more than before, or, for text Muse re-renders (markdown, links), by the history gaining an entry while the box's Send turns to Stop. A send while Muse is still answering is refused. A minimized Muse window is restored before any click.

Other hardening found by adversarial testing: a Claude session row is scrolled into view before it is clicked, since a row further down a long sidebar would otherwise fail the hit test; Codex is activated with a yielded activation and its menu bar is read with a short retry, because a plain `activate()` from a background app is ignored; a command refused because another is running answers 409, which the phone treats as "nothing ran", not "result unknown"; and a connection that has not delivered a complete request within five seconds is dropped so stalled connections cannot hold the listener's slots.

