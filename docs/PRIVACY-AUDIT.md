# Privacy audit — 2026-11-16

Audited native 0.5.2 (31) and Mac companion 0.7.4 at revision `3dd338d`. Build 32 adds the manifest, accurate microphone explanation, and public privacy/support links. The current public policy is maintained in `../PRIVACY.md` and the separate public support-site repository. These are internal audit notes, not additional public policy text.

## Findings and corrections

- The absolute “nothing … sent to us” claim omits TestFlight's developer-facing diagnostics and submitted support material. No app-embedded analytics endpoint was found in the inspected native source, but that does not negate Apple's beta service.
- “Nothing is sent until Send” must mean submission to a chat, with an explicit exception for live Follow drafts. Build 32 corrects the same overbroad sentence in `NSMicrophoneUsageDescription`.
- New device credentials are hashed on the Mac, but `RemoteStore` still creates/loads the protected plaintext `pairing-token` used for legacy/local bridge compatibility. Do not claim the Mac stores only credential hashes in every setup.
- App deletion is not an implemented Keychain cleanup flow. `GenesisCredentials.remove` exists, but no production caller was found. Revocation on the Mac is the current reliable access-control instruction. The app's Application Support folder alone also does not represent all companion preferences or G2 storage.
- Artifact previews can reach configured external HTTPS sites, and file previews create temporary local files. Both were missing from the policy.
- Dictation logging is automatic, not an optional user setting. Optional Mac diagnostics are a separate feature. Avoid an absolute “never leaves the device” promise when users can deliberately provide diagnostic files for support.

Source evidence:

| Claim | Current source |
| --- | --- |
| On-device capability required; every recognition request requires it | `genesis-iphone/ios/Sources/Core/PhoneDictation.swift`, `start()` / `beginRecognition()` |
| No audio-file capture in built-in dictation | `PhoneDictation.swift`, `DictationAudioInput.swift`; in-memory audio relay |
| Protected settings, Keychain credentials, HTTPS client | `genesis-iphone/ios/Sources/Core/RemoteClient.swift` |
| Per-device hashes and legacy credential compatibility | `genesis-mapper/Sources/DeviceRegistry.swift`; `RemoteProtocol.swift` `RemoteStore.init`; `RemoteBridge.swift` `authorized()` |
| Local command activity and receipt fingerprint persistence | `genesis-mapper/Sources/ActivityLog.swift`; `RemoteProtocol.swift` `RemoteStore` |
| External website requests and temporary file previews | `ControllerStore.swift` `artifactRequest()`; `genesis-iphone/ios/Sources/ArtifactShelf.swift` |
| Automatic bounded local metadata logs; optional Mac checks | `DictationDiagnostics.swift`; `DiagnosticsScreen.swift` |
| Live draft forwarding and read-only lock expiry | `GlassesFollowController.swift`; `genesis-mapper/Sources/RemoteDisplaySession.swift` |
| Separate G2 pairing persistence and supported conversation reading | sibling `genesis-g2/src/storage.ts`, `bridge/server.mjs`, `bridge/claude/reader.mjs` |

Apple confirms the behavior of [`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition) when [`supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition) is true; the current code checks both. Apple's [Keychain deletion documentation](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items) describes explicit item deletion, which the current app does not expose as a user removal flow.

## Publication result

The final policy uses a November 16, 2026 effective date and the public support Issues URL. Public HTML excludes these audit notes and does not promise an unverified retention practice. Disabling legacy access is explicitly distinguished from deleting its stored credential. Public privacy/support pages returned HTTP 200 anonymously and were visually checked. App Store Connect privacy answers still require completion before release.
