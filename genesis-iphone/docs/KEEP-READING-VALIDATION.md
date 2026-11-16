# Keep reading when the phone locks

Date: 2026-11-16. Native 0.2.2 (20), companion 0.5.2-preview, Genesis G2 0.4.2.

## Behavior

Enable Follow this controller, open an assigned Claude or Codex chat, then enable Keep reading when iPhone locks (iPad uses its own device name). The option defaults off and the Mac must acknowledge it before the panel says Ready. Keep the existing Try background relay — Even Beta only option enabled in Genesis G2 on the connected iPhone.

Locking or backgrounding parks the exact selected conversation for up to one hour. The Mac owns the read-only update session; the native microphone stops, and the glasses draft is cleared while the complete local draft stays saved. The normal screen-awake behavior while Follow is foreground remains unchanged. Unlock resumes only the same unexpired owner, with a new lease; it never takes over from another controller automatically. Mac lock, companion restart, remote disable, explicit Follow off, or expiry ends the session.

## Automated validation

- 69 native Follow checks: arm acknowledgment, serialized park/resume, stale polling, rotated leases, missing responses, takeover, expiry, old companions.
- 231 Store/HTTP integration checks on Genesis iPad QA: microphone stop, draft retention, resume, host change, no extra Send.
- 185 Mac display-session checks, 22 bounded Claude inventory-read checks, and Swift typecheck; independent lifecycle/backend review.
- G2: 203 frontend and 43 bridge checks; TypeScript and production build passed.
- Release iOS build passed and strict code-sign verification passed.

## Installation evidence

Native build 20 installed in place on Rick's iPhone and the intended iPad. Device inventory confirms version 0.2.2/build20. Existing three hosts, selected chats, all slot assignments and full draft text remained present. iPad refreshed one Codex quick-action list from its paired host and draft modifiedAt; this was not a byte-identical settings snapshot. No settings restore was performed.

Both Minis received signed companion 0.5.2-preview and G2 bridge 0.4.2. Native profiles/host identity preserved; private G2 configuration, recovery credentials and compiled readers preserved. Rollbacks are local/private. No firmware or Neo install was performed. Private Even Beta 0.4.2 published.

## Live verification

Mini 2 Codex's actual bridge passed claim, arm, park, repeat park without extending the deadline, rejected parked update, rotated resume, rejected old-lease update/park, fresh sequence, and release. No Send or chat-opening command was used. Mini 1 Claude initially hit a transient target-inventory failure. The repair retries only missing, fresh full-inventory observations (three attempts, 100 ms spacing, shared 2.5 second budget); ambiguity fails immediately. After installing the revised companion, the same full live lifecycle passed on an exact assigned Claude target and ended inactive. No chat-opening or Send command was used.

Mirroring verified the new native toggle, Ready acknowledgment and connected-glasses acknowledgment for Mini 2 / Codex. Even Beta 0.4.2 was installed and reopened; the existing explicit background-relay preference remained enabled. Mirroring then quit, and device diagnostics confirmed passcodeRequired=true. The Mac received a sanitized read-only handoff. The user explicitly confirmed that the glasses remain visible and updating during this locked-phone test. The completed live checks are recorded below.


## Locked-phone acceptance, 2026-11-16

The actual iPhone was removed from Mirroring for each test; device diagnostics reported passcodeRequired=true during both runs. Both tests collected11 samples30 seconds apart over300 seconds, with active read-only mode, a fixed expiry, zero draft characters, recording=false, and fresh connected glasses acknowledgments throughout.

- Mini2 / Codex: read-only handoff began17:20:20 UTC; the observation ran17:20:57–17:25:57 UTC. Replies and SDK acknowledgments remained fresh. One sampled reply request returned503 and recovered automatically to200 at the next sample, without losing the session. The user confirmed the conversation remained visible and updating while locked. Reopening Mirroring resumed native control with keepReading=true, readingOnly=false, and fresh connected feedback.
- Mini1 / Claude C1: handoff began17:28:58 UTC; observation ran17:29:08–17:34:09 UTC. Every sampled reply request returned200; fresh display acknowledgments continued. The user confirmed Claude was visible while locked. Reopening the controller showed the same saved draft, Ready status, and a connected-glasses acknowledgment.

Both Minis run the final signed companion executable SHA256 `0e8e5e1654df4e3fa8b5359baede6dcb76ea5b91a749195f4fec95f6c37cf251`. No test prompts were sent. Phone mappings, local drafts, and both Mac profiles were preserved. The iPad build is installed but its own keep-reading switch was not enabled or physically lock-tested in this pass. Neo was not updated.

These five-minute results establish tested locked-phone operation on this iPhone/Even setup; they do not guarantee one hour of uninterrupted iOS background execution. The one-hour cap and stop conditions are covered by automated tests. Private metadata-only logs and rollback archives remain local.
