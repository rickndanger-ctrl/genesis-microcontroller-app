# Shipping through TestFlight

Agent Micro Controller is being prepared for iPhone and iPad distribution through TestFlight. This document separates the completed preparation from uploading and making a build available to testers. The source repository was made public on November 16, 2026, at the owner’s request, after a scan of every commit found no credentials or private addresses.

## Current status

- **App Store Connect listing created:** Agent Micro Controller, Apple app ID `6835749940`, bundle ID `com.richardholguin.GenesisController`.
- **Release archive built:** version **0.5.2 (32)** at `genesis-iphone/build/AgentMicroController-build32.xcarchive`. Its signature, version and embedded privacy manifest have been verified locally.
- **Public privacy and support site live:** privacy <https://rickndanger-ctrl.github.io/agent-micro-controller-site/privacy/> and support <https://rickndanger-ctrl.github.io/agent-micro-controller-site/> both return HTTP 200 without sign-in and were checked in Chrome. The URLs are saved in App Store Connect. Only the support/policy site is public; app source remains private.
- **Local validation:** Release archive succeeded, code signature verifies, embedded bundle/version/manifest match, and all 367 remote core checks pass. These are local checks, not Apple processing or physical-device acceptance.
- **Listing preparation:** review demo notes saved, reviewer sign-in disabled, and App Store release set to manual. The initial store-version draft remains 1.0; the TestFlight candidate is 0.5.2 (32).
- **Owner-approved upload completed:** 0.5.2 (32) was distribution-signed and uploaded on November 16, 2026 at 22:08 Pacific. Xcode returned `EXPORT SUCCEEDED` and `Upload succeeded`. The copied IPA is `genesis-iphone/build/appstore-build32/AgentMicroController-0.5.2-32.ipa`; its signature, version and embedded privacy manifest verify. Apple processing is verified `VALID`; App Store Connect reports `READY_FOR_BETA_TESTING` internally and `READY_FOR_BETA_SUBMISSION` externally.
- **Apple build record:** `b293dc9c-448c-40e4-8995-262c518039bf`, version 0.5.2, build 32, uploaded November 16, 2026 at 22:08:48 Pacific, expires February 14, 2027.
- **Build 37 (0.7.2) uploaded and processed:** uploaded November 17, 2026 at 13:03 Pacific after an App Store Connect outage (the first three tries got HTTP 500 from Apple), processed as VALID by 13:07, expires February 15, 2027. It is the build with the status lights, deck themes and focused hints, and the same binary that is installed on the owner's iPhone and iPad.
- **Internal testing set up:** an internal group "Internal testers" with access to all builds, so each new build reaches it automatically. The account holder was added at the owner's request and invited by Apple. Build 37 is `IN_BETA_TESTING` for internal testers.
- **Not yet done:** external testers, external Beta App Review, public TestFlight link, or App Store review/release.
- **Separate later decisions:** adding external testers, submitting for Beta App Review and enabling a public TestFlight link. None is implied by approving an upload. App Store release is also separate.

## Review notes (paste into "Beta App Review Information")

Agent Micro Controller is a remote control for AI coding and assistant apps running on the user's own Mac. It needs a free companion app on that Mac, paired by scanning a code, and both devices on the user's private network.

You do not need a Mac to review it. On first launch tap **Try the demo**: it opens a sample controller with six sample chats. Keys press, the dials turn, **Hold to talk** produces a sample draft, and **Send** reports a sample result. Nothing is sent anywhere in the demo. **Exit demo** at the bottom returns to the pairing screen.

Permissions: Microphone and Speech Recognition are used only for dictating a draft, with on-device recognition. Camera is used only to scan the pairing code. Local Network is used only to reach the paired Mac. The app has no account, analytics or advertising.

## What to test (paste into "What to Test")

Pair with the Agent Micro Controller companion on your Mac, assign chats to the six keys, and try opening a chat, dictating a draft and sending it. Tell us about any key that needs a second press, a dial that skips, or a Send that reports the wrong result.

## Beta review status (Nov 18)

Build 37 (0.7.2) was submitted for TestFlight beta review and is waiting for review. Filled in: tester description, feedback email, reviewer contact, reviewer notes (above), What to Test, and no sign-in required. An "External testers" group holds build 37 with the public link off and no testers. Approval lets external testers install; enabling the public link and inviting people are separate decisions. Testers will also need a notarized Mac companion download, which doesn't exist yet.

**Update:** the companion is now notarized and published as the GitHub release `companion-v0.7.8` (built by `genesis-mapper/release.sh`).

## App Store status (Nov 18)

App Store version **0.7.2** (renamed from the default 1.0 to match build 37) is filled in: description, keywords, promotional text, subtitle, support and marketing URL, copyright "2026 PyBird", Developer Tools / Productivity, no age-restricted content, no third-party content, free in all territories (new territories included), build 37 attached, reviewer contact and notes (with the companion link), and one demo-mode screenshot each for 6.9" iPhone and 13" iPad. Release is set to go out automatically after approval.

Apple blocks the submission until three forms are answered in the App Store Connect website (the API cannot fill them): **App Privacy** (data collection; the app sends nothing to the developer, so "Data Not Collected" fits), and two compliance forms Apple names only by code, one about security and one about AI-generated content. An empty review submission is already created; once the forms are done, add version 0.7.2 to it and submit.

**Update:** the two coded compliance forms (`SECURITYASF395E`, `AIGENERATEFD1DE`) are Apple's China mainland declarations, added November 16, 2026, on the new **App Compliance** page (sidebar → General). They ask whether the app offers AI-generated or synthetic content in China mainland, and whether it has features needing a security assessment there. A "Yes" requires Chinese government filing numbers and assessment reports. They apply because the app is available in every territory, China mainland included. The choice is the owner's: remove China mainland from availability, or answer them.

Build **0.7.3 (38)**, with Wi-Fi pairing, was uploaded on November 18, 2026 after the full iPhone/iPad screen tests passed. It is meant to replace build 37 in the App Store version, which then becomes 0.7.3. The matching notarized companion 0.7.9 is a draft GitHub release, not yet published.

**Update (later Nov 18):** at the owner's request, China mainland was removed from availability (174 territories remain), which cleared both China forms. The App Store version is now **0.7.3 with build 38**. Companion 0.7.9 is published as the latest GitHub release, and the reviewer notes link it and describe Wi-Fi pairing. The support site now links the download (`releases/latest`) and describes Wi-Fi pairing; the privacy policy's network paragraph was updated to match. The only remaining block is **App Privacy** (`APP_DATA_USAGES_REQUIRED`), which has to be answered and published in the App Store Connect website. After that, add version 0.7.3 to review submission `28057be4…` and submit.

**Submitted (Nov 18, 12:40 Pacific):** the owner answered and published App Privacy as "Data Not Collected". Version 0.7.3 (build 38) was added to the review submission and submitted; Apple shows it as `WAITING_FOR_REVIEW`. Release is automatic after approval, in 174 territories (not China mainland).

**Guided setup (Nov 18, afternoon):** build **0.7.4 (39)** was uploaded and processed `VALID`; it reaches the internal group automatically. It adds the Connect your Mac guide and plain-language connection errors. It is not attached to the App Store version: 0.7.3 (38) stays in review, and 0.7.4 is meant to follow as an update after approval. Companion **0.8.0** (guided setup window, menu-bar only, App Nap opt-out) is notarized and published as the latest GitHub release, installed on all three Macs, and the support site describes the new setup.

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

## Uploading a new build

Archive with `DEVELOPMENT_TEAM=7FQA384X2F`, then `xcodebuild -exportArchive` with `ExportOptions-AppStoreConnect.plist` and the saved App Store Connect key (`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`). Raise `CURRENT_PROJECT_VERSION` first: Apple refuses a build number it already has. New builds go to the internal group on their own once processed.

## Remaining release steps

1. Privacy and support URLs are saved and publicly reachable. Keep the pages aligned with future feature changes; keep using the dedicated site as the privacy address, not a link into the source repository, so the address stays the same if the repository is reorganised.
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

**Companion 0.8.1 (Nov 18, evening):** turning on Wi-Fi pairing on Neo exposed a crash: the first certificate was made by waiting on openssl on the main thread while SwiftUI was creating the app, and SwiftUI aborted before the certificate was saved, so it crashed on every restart. A new Mac without Tailscale (Wi-Fi on by default) could hit it on first launch. 0.8.1 makes the certificate off the main thread; it is published as the latest release, 0.8.0 and 0.7.9 are marked as replaced, and the App Store reviewer notes now link `releases/latest`. Wi-Fi pairing is on and answering on all three Macs.

**Fresh-Mac test and companion 0.8.3 (Nov 18, evening):** setup was run end to end as a new user on Mini 2 (its state set aside and restored afterwards): the notarized download from Downloads, Gatekeeper's prompt, setup, the Accessibility prompt, and a fresh simulator pairing over Wi-Fi from the on-screen code. It found a loop in Move to Applications (the copy kept its quarantine mark and was translocated again), fixed in 0.8.3 along with reopening showing setup and the agents step showing at once. The Mac icon was replaced with the iPhone app's keycap icon because the old one resembled OpenAI's and Anthropic's marks. 0.8.3 is the latest release and is on all three Macs. App build **0.7.4 (40)** carries the guide's shorter "Send link" label and is the build to submit after 0.7.3 is approved.

