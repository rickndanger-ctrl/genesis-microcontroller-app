# Privacy

Agent Micro Controller is a remote control for apps on your own Mac. It has no accounts, no analytics, no advertising, and no server run by its authors. Nothing you do in it is sent to us.

## What stays on your iPhone or iPad

- **Drafts.** Text you type or dictate is saved on the device so it survives closing the app. It is protected by the device's passcode encryption.
- **Pairings and key mappings.** The address of each Mac you pair, and which chat or action each key opens. The pairing secret is kept in the device keychain.
- **Speech.** Dictation uses Apple's on-device speech recognition only. The app requires on-device recognition and will not dictate without it, so your audio is not sent to Apple or to anyone else. Audio is never stored.
- **Diagnostics.** A small local log of dictation events (names and counts only, such as "recording started") to help fix problems. It contains no transcript, audio, chat names, addresses or secrets, and it never leaves the device.

## What goes to your Mac

When you press a key, the app sends that command to the Agent Micro Controller companion app on a Mac you paired, over an encrypted connection on your own private network. When you press Send, your draft goes to that Mac, which hands it to the chat you chose. The Mac companion stores your key mappings and a record of recent command results on that Mac.

Sending a draft passes it to the app you are controlling (for example Claude, Codex or Muse). What that app does with it is governed by its own privacy policy.

## Permissions the app asks for

- **Microphone and Speech Recognition:** to turn your speech into a draft. Nothing is sent until you press Send.
- **Camera:** to scan the pairing code shown by your Mac.
- **Local Network:** to reach the Mac you paired.

## Glasses

If you turn on the optional Even G2 glasses feature, the chat and draft you select are sent to your paired Mac so the separate Genesis G2 app can show them on your glasses. Turning the feature off stops this.

## Deleting your data

Deleting the app removes everything it stored on the device. To remove a Mac's copy of your mappings, delete the companion's folder, named Genesis Agent Micro Controller, in that Mac's Application Support.

## Contact

Questions about this policy: open an issue on this project's GitHub page.
