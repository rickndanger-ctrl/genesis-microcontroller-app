# Agent Micro Controller

Formerly Genesis Microcontroller App. The app and its Mac companion are now named Agent Micro Controller; internal identifiers, the pairing link scheme and the repository name keep the old name so existing pairings and installs carry over.

Agent Micro Controller is an iPhone and iPad controller for Codex, Claude Code and Muse on a paired Mac. It provides six assignable keys, chat switching, Hold to Talk, draft review, and Send. The iPad layout adapts to portrait and landscape. Turn the dials to browse chats or artifacts, then press to select. Under **Settings → Controller sounds** you can mute the key clicks and dial ticks, set their volume, or switch between five click sounds. The Mac companion handles chat navigation and sends the reviewed draft to the selected session. This app is a separate project from the [Genesis Mini hardware and firmware](https://github.com/rickndanger-ctrl/genesis-agent-micro-controller).

Version **0.5.0 / build 29**, with companion **0.6.0**, adds diagnostics and two guards. **Settings → Check this Mac** asks the companion what it can find in Claude, Muse and Codex and lists each control as found or not, with what to do; the same screen shows recent commands and how they ended. The phone warns when a Mac is running an older companion. When an app is installed but shut, the controller offers **Open Claude on …** (or Muse) so you are not stuck away from the Mac. On the Mac, the companion now waits for a quiet moment on the keyboard and mouse before it clicks or pastes, so its input cannot collide with someone typing; it does not refuse just because the Mac is in use.

Companion 0.7.0 and app version 0.5.1 / build 30 give each phone and tablet its own pairing secret. The QR code now carries a single-use code instead of the Mac's one shared secret, and the companion lists paired devices with a Revoke button for each.

Version 0.4.0 / build 28 renamed the app to **Agent Micro Controller** (Home Screen label: Agent Micro) and adds **Try the demo** on the unpaired screen. The demo is a sample controller with no Mac behind it; it never reads or writes your pairings, and **Exit demo** is always on screen. Mentions of the physical Genesis controller and of the separate Genesis G2 glasses app are unchanged, because those are their names.

Version 0.3.3 / build 27 added two things. While you dictate, the draft box stays on the newest words: it used to show only the first lines of a long dictation, so it looked as if recording had stopped. And **Settings → Glasses → I use Even G2 glasses** shows or hides everything to do with the glasses. It is off on a fresh install and stays on for anyone who already had a Mac paired; turning it off also stops Follow.

Version 0.3.2 / build 26 steadied the controls. Both knobs now measure a turn around the top face you actually see (the tilted render draws it above the middle of its frame); a stroke along the knob's edge turns it, while a stroke across it or from its middle is a swipe that moves one step per thumb-sized distance, right or up being forward. A detent clicks over at 65% of a step in either direction, so a finger resting on a boundary cannot flicker. A key pressed while the Mac is still finishing the previous command is held and runs when that command succeeds, instead of being dropped; Send and dictation never wait. Previous and Next in the menu panel queue the same way. On the Mac, the companion finds Claude's permission chooser by its place beside the model chooser rather than by the name of the current mode, which fixes Permissions in modes the catalog did not list. Installing that fix means updating the Mac companion as well as the iPhone and iPad app.

Version 0.3.1 / build 25 rebuilt the controller as a 3D model. `genesis-iphone/design/build_deck.py` models it in Blender — a light pearl body, tall sculpted snow keycaps, knurled knobs and a black Home button — and renders it through a camera tilted 24 degrees, so every key shows its front wall and stands off the plate like a real keyboard. Each control is rendered once in neutral light and once lit only by a white LED underneath; the app tints that LED pass with the slot color, so one render serves every color and brightness. Keys are rendered up and pressed, and sink while your finger is on them.

Lighting follows use. An assigned chat that is not open glows softly in its slot color. The chat in use glows hard, with a white-hot center and a slow pulse, and so does the chat knob. A slot the dial is resting on but has not opened sits in between. The utility keys, Talk, Home and the light under the body take a faint tint of the chat in use.

The chat knob is steadier. Its pointer now aims at one of six slot lights on its face and always points at the chat being browsed, including when you pick a chat with its key. A finger resting on a detent no longer flickers between two chats, turns made close to the hub count for less so a small slip cannot jump several chats, and a press with a slightly unsteady finger still registers as a press. While the dial rests on a chat you have not opened, its label reads **Press to open**.

Build 24 introduced the full-screen layout that grows the deck taller than square on a phone, reopening in the layout you last used, and louder click sounds: Crunch by default, with Thock, Clack, Arcade and the original Soft tick as alternatives. Click loudness also follows the device's ringer volume and silent mode. Routing, mappings, dictation, Send safeguards and accessibility labels are unchanged; Reduce Motion removes the pulse and the spring while keeping the pressed state.

Build 23 made the selected chat's cap brighter with a gentle glowing pulse. Other caps and text remain steady; Reduce Motion keeps the selected cap statically bright. If the Mac's companion cannot be reached through its gateway, the 502 message now explains which app to open and how to refresh. It never retries Send automatically. See [build 23 validation](genesis-iphone/docs/SELECTED-GLOW-BUILD23.md).

The full-screen controller view from build 22 remains available. Tap the outward arrows beside Settings to enter; use the inward arrows to exit. The compact computer and provider menus keep Mini 1, Mini 2, Neo, Claude and Codex within reach. Review draft opens the saved composer and delivery controls; Send remains available even when the quick keys are remapped. Glasses controls open in a drawer. The selected route, draft, dial angle and Follow controller survive layout changes. Mode changes are disabled during recording, finalization and active dial gestures.

The chat dial glows in the color being browsed and the artifact dial stays black. Click feedback respects the sound switch and is suppressed during microphone capture and while backgrounded. Reduce Motion and Reduce Transparency retain accessible alternatives. See [the full-screen design](genesis-iphone/docs/FULLSCREEN-CONTROLLER-PROPOSAL.md) and [build 22 validation](genesis-iphone/docs/FULLSCREEN-BUILD22.md).

## Build

The mobile project targets iOS and iPadOS 26 or later and uses Xcode and XcodeGen. Generate the project, then open it in Xcode:

```sh
cd genesis-iphone
xcodegen generate --spec project.yml
open GenesisController.xcodeproj
```

For a physical iPhone or iPad, select your Apple development team in Xcode and choose a unique bundle identifier if needed. The `--demo` launch argument shows an offline preview.

Build the companion from the repository root on macOS 14 or later with Xcode:

```sh
sh genesis-mapper/build.sh
open 'genesis-mapper/Agent Micro Controller.app'
```

The Mac build uses an ad hoc signature by default. Set `CLAUDE_CONTROLLER_SIGN_ID` to an Apple Development signing identity if you need a stable signature for local updates. Install under `~/Applications` if you use its launch-at-sign-in setting. The iPhone bridge runs without a USB controller. To opt into the companion’s hardware controls, run `defaults write local.richard.genesis-mapper GenesisUSBSerial -string "YOUR_GENESIS_SERIAL"` and reopen the companion.

## Pair and use

1. Connect the Mac and your iPhone or iPad to the same Tailscale network. On the Mac, give the companion Accessibility access if you use Claude Code or native desktop menu controls.
2. From the menu-bar dial, open **Pair iPhone / Artifacts** and enable private remote access. The companion listens on loopback port 18765. On the Mac, `tailscale serve --bg --https=8451 http://127.0.0.1:18765` makes the service available on a private HTTPS port to the tailnet. If you already use that port, choose a free port and enter its HTTPS URL in the pairing panel.
3. In the app, open **Settings → Scan pairing code** and scan the QR code from the companion. Pair each Mac separately. The code pairs one device, once, and stops working after ten minutes; the device trades it for a secret of its own, kept in its keychain.

**What pairing grants.** A paired device can open chats and send prompts to the agents on that Mac. If an agent is running with permissions bypassed, that amounts to running commands on the Mac. Pair only devices you own, and keep the companion on a private network such as Tailscale; never expose port 18765 or the Serve address to the public internet.

**Paired devices.** The pairing window lists every device paired this way, when it paired and when it was last seen. **Revoke** cuts off one device at once without touching the others. Devices paired before companion 0.7 share one older secret and cannot be told apart; once each has scanned a new code (this needs app build 30 or later), choose **Stop accepting…** to retire that secret.
4. Choose a provider and chat. Hold **Talk**, release to review the draft, then tap **Send**. Grant microphone and speech recognition access when prompted.

Codex Send uses the [bundled Codex queue command](https://learn.chatgpt.com/docs/developer-commands#codex-queue) to target the exact selected chat. **Queued** means Codex accepted the message. If the chat is busy, it can process the draft after the current turn. Open the chat on the Mac if it is unloaded. Claude Code uses the Mac composer and presents its own delivery status.

Under **Codex → Actions → Change model**, open the model and reasoning picker for the current Codex view on the paired Mac. You can also hold an A key or a quick key to assign **Change model**. Codex must be open, with Accessibility enabled for the companion, and its **Select effort** keyboard shortcut set to the default **Control–Shift–M**. The app offers menu navigation when macOS exposes the picker. After choosing a model, select your chat again if the controller returns to chat selection.

## Even Realities G2 glasses

Native version **0.2.5 / build 23** supports **Follow this controller** on both iPhone and iPad. The separate [Genesis G2 app](https://github.com/rickndanger-ctrl/genesis-g2) displays the selected Codex or supported Claude Code conversation above a dedicated draft box. The native app handles dictation and explicit Send; the glasses never submit a message themselves.

Open Genesis G2 inside Even on the paired iPhone, then enable **Follow this controller** in this app and tap an assigned chat. **Conversation** and **Draft** choose which area the page arrows navigate. The right arrow shows older text; the left returns toward the latest. One native device controls the display at a time, and taking over from another device requires an explicit choice.

You can use this controller on an iPad while Even remains open on iPhone. For control from that same iPhone, use the installed Genesis G2 Beta and enable **Try background relay — Even Beta only** in it first. Enable **Keep reading when iPhone locks** (or iPad) below Follow to leave the selected conversation readable for up to one hour while locked. The Mac must acknowledge Ready first; your microphone stops and the glasses draft is cleared, while the full local draft stays on your device. With the option off, leaving Genesis pauses Follow. Select a chat again after returning if the glasses show Home. The initial same-iPhone flow, conversation paging, and separate draft review are user-confirmed on the tested Mini 2 setup. The current lock-test evidence and limits are tracked in the [keep-reading validation](genesis-iphone/docs/KEEP-READING-VALIDATION.md); short tests do not prove indefinite background operation.

Claude chat selection, drafts, and native Send status can follow. Genesis G2 0.4.0 or later can also read a uniquely identified local Claude Code conversation; ordinary Claude web chats are not supported by that reader. G2 0.4.1 adds automatic paired-Mac connection recovery after Even restarts. G2 installation, pairing, build instructions, and validation are maintained in its separate repository. This integration does not require changing Genesis Mini firmware.

The [November 15 audit](genesis-iphone/docs/APP-AUDIT-2026-11-15.md) records build 19, the matching 0.5.1-preview Mac companion, live switching checks on both Minis, and the remaining physical test boundaries.

## Verify

From the repository root:

```sh
sh genesis-iphone/tests/core/run.sh
sh genesis-iphone/tests/core/run-dictation.sh
sh genesis-iphone/tools/test-host.sh
sh genesis-mapper/test-codex-queue.sh
sh genesis-iphone/tests/core/run-follow.sh
sh genesis-mapper/test-display-session.sh
```

For input restart regressions, boot an iOS 26+ simulator and run `GENESIS_TEST_SIMULATOR=<simulator-udid> sh genesis-iphone/tests/core/run-dictation-input.sh`. This uses synthetic audio buffers to test repeated capture lifetimes; it does not exercise physical speech recognition.

For the iOS HTTP integration suite, boot an iOS 26+ simulator and run `GENESIS_TEST_SIMULATOR=<simulator-udid> sh genesis-iphone/tests/core/run-integration.sh`. The Codex queue integration uses temporary local state and a loopback test model. Run it with `python3 genesis-iphone/tools/test-codex-queue-isolated.py --codex /path/to/codex`.

The simulator UI suite covers phone and tablet layouts, all slot and quick-key editors, microphone gestures, draft isolation, menus, and artifact browsing. See [UI test instructions](genesis-iphone/tests/ui/README.md) and [the app audit](genesis-iphone/docs/APP-AUDIT-2026-11-14.md).

Hold to Talk records on the phone or iPad. Shortcuts mapped to **Hold to talk** toggle recording on a tap; the wide microphone key records while held. Pauses and longer recordings retain earlier words, and releasing preserves the final transcript for review. Nothing is submitted until **Send** is pressed.

**Muse.** With Muse open on the Mac, the Muse tab lists your main chat and side chats, opens them from a key, sends your reviewed draft, opens a new side chat you can dictate into straight away, and starts a Muse call (**Voice**), which uses the Mac's microphone and speakers. Muse gives a chat no identifier other than its title, so side chats that share a title are left out; rename one in Muse to use it. Muse's message box cannot be read or written through Accessibility, so Send works the way a person would: it brings Muse to the front, clicks in the box, pastes the draft, reads it back by selecting all and copying, and only then presses Return. It refuses if the box already holds text, and it puts your clipboard and pointer back afterwards. View-only channels are not offered. Stop, the glasses Follow feature and menu navigation are not connected for Muse.

Two-way native Voice mode for Codex and Claude, and Steer, are not connected in this version. Unsupported mapped keys explain their limitation and can be remapped with a long press. Registered artifacts can be browsed; automatic artifact discovery is not implemented. The Mac Photos library picker still requires the mouse.

See [Mac bridge setup](genesis-iphone/docs/HOST-BRIDGE.md), [protocol details](genesis-iphone/docs/PROTOCOL.md), and [artwork and sound build instructions](genesis-iphone/design/README.md).
