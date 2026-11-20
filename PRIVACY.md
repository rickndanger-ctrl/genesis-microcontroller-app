# Agent Micro Controller — Privacy policy

Effective date: November 16, 2026

Public policy: https://rickndanger-ctrl.github.io/agent-micro-controller-site/privacy/

Agent Micro Controller lets your iPhone or iPad control supported apps on Macs you pair. It does not require an Agent Micro Controller account. The app has no advertising, cross-app tracking, or embedded analytics service. Controller commands and content are not routed through a backend operated by the app's developer. Apple/TestFlight diagnostics and information you choose to submit for support are described separately below.

## Information on your devices

The iPhone or iPad saves your drafts, paired Mac addresses and names, chat selections and titles, key mappings, preferences, artifact pins, and Send receipts. These let the controller restore your work and avoid resending an unconfirmed prompt. Drafts and controller settings use iOS file protection. System backups may retain copies according to your backup settings.

Pairing credentials are stored in the device's Keychain. Current pairing codes give each newly paired phone or tablet its own credential. The Mac stores that credential's hash, a device identifier and display name, and pairing and last-seen times so access can be revoked. Older setups may also retain a protected shared credential on the Mac for compatibility; legacy access can be disabled separately.

## Speech and permissions

Built-in **Hold to talk** uses Apple's on-device speech recognition. The app requires on-device recognition support and does not fall back to server-based transcription. It does not upload microphone audio for this feature or save audio recordings as files. The recognized text becomes an editable draft.

A draft is not submitted as a chat prompt until you press Send. If you enable glasses Follow, draft text can be mirrored before Send, as explained below. A shortcut that opens another app's voice feature uses that app's own audio handling and privacy policy.

The app requests Microphone and Speech Recognition permissions for dictation, Camera permission to scan a Mac's pairing code, and Local Network permission to reach your paired Macs. You can manage these permissions in iOS or iPadOS Settings.

## Communication with your Mac

The app connects to your paired Mac over HTTPS, commonly through your private Tailscale network. It exchanges chat and action lists, mappings, status, artifacts, commands, and command receipts. This communication also occurs when you refresh or when the app checks connection status, not just when you press a controller key.

When you press Send, the draft goes to the selected Mac and is passed to the selected supported chat app. That app may store the message or send it to its own services. Claude, Codex, Muse, Tailscale, and any other services you use have their own privacy policies and account requirements.

The Mac companion stores mappings, artifact records and files you choose to export, pairing records, command-result records, and a bounded activity log. The activity log records command types, result messages, timestamps, and timings; it does not record the submitted prompt text. Command fingerprints are retained to distinguish repeated requests without storing a second prompt copy in the receipt ledger. The destination chat app may retain the prompt itself.

## Artifact previews and websites

An artifact may be a file shared by your Mac or an HTTPS website link you configured. File previews download content to temporary, protected device storage; the app attempts to remove that temporary file when the preview closes. Website previews use a nonpersistent web view, but the website and its embedded services can receive ordinary network requests and information you enter there. Their policies apply. Pairing credentials are not added to requests for external website links.

## Optional Even G2 glasses

When you turn on **Follow this controller**, the app sends the selected chat identity, draft text or a bounded excerpt, recording indicator, and display state to your paired Mac. The separate Genesis G2 integration retrieves this state and supported conversation text from that Mac and displays it through the Even app and glasses. **An unsent draft can therefore leave the controller device while Follow is enabled.** This display feature does not submit the draft as a prompt.

If you enable **Keep reading**, the selected conversation can remain available for up to one hour after the controller backgrounds or locks. Recording stops, and the parked display state removes the unsent draft. Turning Follow off requests release of the display session; if the connection is unavailable, the session has a bounded expiry. This cannot remove a copy or screenshot already made on another device.

The G2 integration keeps its own pairing information in the Even app's local package storage and its Mac bridge configuration. Removing the native controller does not remove those separate copies. Even's and your network provider's policies also apply.

## Diagnostics, testing, and support

The app automatically keeps a small, bounded local dictation log containing event names, timestamps, numeric counts, and error codes. It does not include recorded audio, recognized text, chat names, addresses, or pairing credentials. The app has no automatic upload mechanism for this log.

The optional **Check this Mac** screen requests capability checks and recent command activity from your own Mac. These results are displayed on your controller device, not uploaded to the developer. A check may show the controlled app's chat panel to inspect its available controls.

If you use a TestFlight build, Apple collects and shares beta usage and crash information with the developer. Feedback, screenshots, or comments you submit can also be shared. This is separate from the controller's local logs and is governed by [Apple's TestFlight privacy information](https://www.apple.com/legal/privacy/data/en/test-flight/).

Support for this app is provided through public GitHub issues. The maintainer and anyone visiting the repository can read what you post. Do not include pairing codes, credentials, private chat content, or unredacted screenshots. GitHub stores and processes issue content under its own [privacy policy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement); use its issue/account controls or contact the maintainer to request removal where available.

## Removal and access controls

You can remove draft text in the composer. Deleting the app removes its ordinary app-container data, but must not be relied on to delete Keychain credentials, system backups, data on your Mac, or the separate G2 integration's storage.

To stop a paired device from controlling a Mac, use **Revoke** in that Mac companion's paired-device list. Older shared credentials have a separate control for disabling legacy access. Revocation disables access; it does not delete chat history or files already delivered to another app.

Mac companion records and exported files are stored locally under its Application Support folder, with some preferences in macOS preferences storage. Remove those separately if you no longer want them. The controlled chat apps, backup services, and Even integration each manage their own stored data. There is no central Agent Micro Controller account to delete.

## Contact

Privacy questions and deletion requests: [Open a public support issue](https://github.com/rickndanger-ctrl/agent-micro-controller-site/issues).
