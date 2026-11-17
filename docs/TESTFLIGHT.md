# Shipping through TestFlight

Agent Micro Controller is being prepared for iPhone and iPad distribution through TestFlight. This document separates the completed preparation from uploading and making a build available to testers. The source repository remains private.

## Current status

- **App Store Connect listing created:** Agent Micro Controller, Apple app ID `6835749940`, bundle ID `com.richardholguin.GenesisController`.
- **Release archive built:** version **0.5.2 (32)** at `genesis-iphone/build/AgentMicroController-build32.xcarchive`. Its signature, version and embedded privacy manifest have been verified locally.
- **Public privacy and support site live:** privacy <https://rickndanger-ctrl.github.io/agent-micro-controller-site/privacy/> and support <https://rickndanger-ctrl.github.io/agent-micro-controller-site/> both return HTTP 200 without sign-in and were checked in Chrome. The URLs are saved in App Store Connect. Only the support/policy site is public; app source remains private.
- **Local validation:** Release archive succeeded, code signature verifies, embedded bundle/version/manifest match, and all 367 remote core checks pass. These are local checks, not Apple processing or physical-device acceptance.
- **Listing preparation:** review demo notes saved, reviewer sign-in disabled, and App Store release set to manual. The initial store-version draft remains 1.0; the TestFlight candidate is 0.5.2 (32).
- **Owner-approved upload completed:** 0.5.2 (32) was distribution-signed and uploaded on November 16, 2026 at 22:08 Pacific. Xcode returned `EXPORT SUCCEEDED` and `Upload succeeded`. The copied IPA is `genesis-iphone/build/appstore-build32/AgentMicroController-0.5.2-32.ipa`; its signature, version and embedded privacy manifest verify. Apple processing is verified `VALID`; App Store Connect reports `READY_FOR_BETA_TESTING` internally and `READY_FOR_BETA_SUBMISSION` externally.
- **Apple build record:** `b293dc9c-448c-40e4-8995-262c518039bf`, version 0.5.2, build 32, uploaded November 16, 2026 at 22:08:48 Pacific, expires February 14, 2027.
- **Not yet done:** assigning testers, external Beta App Review, public TestFlight link, or App Store review/release.
- **Separate later decisions:** adding external testers, submitting for Beta App Review and enabling a public TestFlight link. None is implied by approving an upload. App Store release is also separate.

## Review notes (paste into "Beta App Review Information")

Agent Micro Controller is a remote control for AI coding and assistant apps running on the user's own Mac. It needs a free companion app on that Mac, paired by scanning a code, and both devices on the user's private network.

You do not need a Mac to review it. On first launch tap **Try the demo**: it opens a sample controller with six sample chats. Keys press, the dials turn, **Hold to talk** produces a sample draft, and **Send** reports a sample result. Nothing is sent anywhere in the demo. **Exit demo** at the bottom returns to the pairing screen.

Permissions: Microphone and Speech Recognition are used only for dictating a draft, with on-device recognition. Camera is used only to scan the pairing code. Local Network is used only to reach the paired Mac. The app has no account, analytics or advertising.

## What to test (paste into "What to Test")

Pair with the Agent Micro Controller companion on your Mac, assign chats to the six keys, and try opening a chat, dictating a draft and sending it. Tell us about any key that needs a second press, a dial that skips, or a Send that reports the wrong result.

## Archive preparation

- The app icon comes from the Blender deck pieces (`genesis-iphone/design/build_app_icon.py`).
- `ITSAppUsesNonExemptEncryption` is false in the app's Info: the app uses standard HTTPS.
- `genesis-iphone/ios/Resources/PrivacyInfo.xcprivacy` is bundled in build 32. It declares no tracking or collected data and UserDefaults access for the app's own settings (`CA92.1`).
- The reviewer demo, review notes and "What to Test" copy are prepared above.
- `genesis-iphone/scripts/record-demo.sh` can record screenshots and a preview video from a simulator. Capture and review the intended store assets before attaching them.

To reproduce the build 32 archive from the repository root, regenerate the project so it includes the privacy manifest, then archive:

```sh
xcodegen generate --spec genesis-iphone/project.yml
xcodebuild \
  -project genesis-iphone/GenesisController.xcodeproj \
  -scheme GenesisController \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath genesis-iphone/build/AgentMicroController-build32.xcarchive \
  DEVELOPMENT_TEAM=7FQA384X2F \
  archive
```

The archive is a build artifact, not an uploaded TestFlight build. App Store distribution export must use the appropriate distribution signing and provisioning. Anyone building their own app from source must use their own bundle identifier and signing team.

## Remaining release steps

1. Privacy and support URLs are saved and publicly reachable. Keep the pages aligned with future feature changes; a link into this private source repository is not a public privacy policy.
2. Complete the account's App Privacy answers and review the encryption declaration against the final build.
3. Fill in the feedback email and reviewer contact name and phone. Reviewer sign-in is not required; use the demo instructions above.
4. The owner approved use of the existing API key; build 32 uploaded and passed processing. Its Apple build record is verified above. Tester assignment and availability are separate from this processing result.
5. Add the processed build to an approved TestFlight testing group only when authorized. Check tester availability separately from upload success.
6. Before external testing, confirm testers can obtain and set up the matching Mac companion, provide the review notes, and obtain the owner's approval for the external group. Submit for Beta App Review as required. Enable a public link only with separate approval.

Build 32 is ready for internal beta testing, but no tester group or public link has been configured by this setup. Record the actual group and tester availability after that step, without including credentials or personal device details.

The third-party product names shown as tabs (Claude, Codex, Muse) describe compatibility. No logos are used; keep it that way.

## Build 32 signing recovery

Automatic cloud signing was denied by Apple before upload. The existing API key could create a standard Apple Distribution certificate and an active App Store profile for the explicit bundle ID. The private signing key stays outside the repository on this Mac. No account permissions were changed or existing certificates revoked.

`genesis-iphone/ExportOptions-AppStoreConnect.plist` now selects manual distribution signing and the `Agent Micro Controller App Store` profile, while preserving build 32. The profile was checked for the correct team/bundle and `get-task-allow=false`. Xcode successfully signed and uploaded the package with those settings.
