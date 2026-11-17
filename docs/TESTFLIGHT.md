# Shipping through TestFlight

The iPhone and iPad app is distributed with a TestFlight link. The Mac companion is a notarized download on the GitHub release page. This file holds what Apple asks for, so each release is a matter of pasting it in.

## Review notes (paste into "Beta App Review Information")

Agent Micro Controller is a remote control for AI coding and assistant apps running on the user's own Mac. It needs a free companion app on that Mac, paired by scanning a code, and both devices on the user's private network.

You do not need a Mac to review it. On first launch tap **Try the demo**: it opens a sample controller with six sample chats. Keys press, the dials turn, **Hold to talk** produces a sample draft, and **Send** reports a sample result. Nothing is sent anywhere in the demo. **Exit demo** at the bottom returns to the pairing screen.

Permissions: Microphone and Speech Recognition are used only for dictating a draft, with on-device recognition. Camera is used only to scan the pairing code. Local Network is used only to reach the paired Mac. The app has no account, analytics or advertising.

## What to test (paste into "What to Test")

Pair with the Agent Micro Controller companion on your Mac, assign chats to the six keys, and try opening a chat, dictating a draft and sending it. Tell us about any key that needs a second press, a dial that skips, or a Send that reports the wrong result.

## Checklist for the first external build

- App Store Connect listing created with the name **Agent Micro Controller** for the app ID `com.richardholguin.GenesisController`. The ID is internal and cannot be changed after the listing exists.
- Privacy policy address set to this repository's `PRIVACY.md`.
- Encryption question answered: the app uses only standard HTTPS, which is exempt.
- Feedback email and a contact name and phone for the reviewer filled in.
- Reviewer sign-in: not required. Leave it unticked and rely on the demo above.
- A build uploaded and, after processing, added to an external group with the public link turned on.

Builds expire 90 days after upload. Upload a fresh one before then to keep the link working.

## Not done yet

- The app icon still shows the earlier controller render.
- The bundle identifier and team are written into `genesis-iphone/project.yml`. Anyone building from source must change both.
- The third-party product names shown as tabs (Claude, Codex, Muse) are used to say what the controller works with. No logos are used; keep it that way.
