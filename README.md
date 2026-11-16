# Genesis Microcontroller App

**Muse hasn’t been connected yet.**

Genesis is an iPhone and iPad controller for Codex and Claude Code sessions on a paired Mac. It provides six assignable keys, chat switching, Hold to Talk, draft review, and Send. The iPad layout adapts to portrait and landscape. Turn the dials to browse chats or artifacts, then press to select. You can mute the dial ticks and key clicks under **Settings → Controller sounds**. The Mac companion handles chat navigation and sends the reviewed draft to the selected session. This app is a separate project from the [Genesis Mini hardware and firmware](https://github.com/rickndanger-ctrl/genesis-agent-micro-controller).

Version **0.2.4 / build 22** adds a full-screen controller view and more intense cap/dial illumination. Tap the outward arrows beside Settings to enter; use the inward arrows to exit. The compact computer and provider menus keep Mini 1, Mini 2, Neo, Claude and Codex within reach. Review draft opens the saved composer and delivery controls; Send remains available even when the quick keys are remapped. Glasses controls open in a drawer. The selected route, draft, dial angle and Follow controller survive layout changes. Mode changes are disabled during recording, finalization and active dial gestures.

Frosted caps use fixed slot colors and the chat dial glows in the color being browsed. The artifact dial stays black. Click feedback respects the sound switch and is suppressed during microphone capture and while backgrounded. Reduce Motion and Reduce Transparency retain accessible alternatives. See [the full-screen design](genesis-iphone/docs/FULLSCREEN-CONTROLLER-PROPOSAL.md) and [build 22 validation](genesis-iphone/docs/FULLSCREEN-BUILD22.md).

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
open 'genesis-mapper/Genesis Agent Micro Controller.app'
```

The Mac build uses an ad hoc signature by default. Set `CLAUDE_CONTROLLER_SIGN_ID` to an Apple Development signing identity if you need a stable signature for local updates. Install under `~/Applications` if you use its launch-at-sign-in setting. The iPhone bridge runs without a USB controller. To opt into the companion’s hardware controls, run `defaults write local.richard.genesis-mapper GenesisUSBSerial -string "YOUR_GENESIS_SERIAL"` and reopen the companion.

## Pair and use

1. Connect the Mac and your iPhone or iPad to the same Tailscale network. On the Mac, give the companion Accessibility access if you use Claude Code or native desktop menu controls.
2. From the menu-bar dial, open **Pair iPhone / Artifacts** and enable private remote access. The companion listens on loopback port 18765. On the Mac, `tailscale serve --bg --https=8451 http://127.0.0.1:18765` makes the service available on a private HTTPS port to the tailnet. If you already use that port, choose a free port and enter its HTTPS URL in the pairing panel.
3. In the Genesis app, open **Settings → Scan pairing code** and scan the QR code from the companion. Pair each Mac separately. The pairing code contains a private credential.
4. Choose a provider and chat. Hold **Talk**, release to review the draft, then tap **Send**. Grant microphone and speech recognition access when prompted.

Codex Send uses the [bundled Codex queue command](https://learn.chatgpt.com/docs/developer-commands#codex-queue) to target the exact selected chat. **Queued** means Codex accepted the message. If the chat is busy, it can process the draft after the current turn. Open the chat on the Mac if it is unloaded. Claude Code uses the Mac composer and presents its own delivery status.

Under **Codex → Actions → Change model**, open the model and reasoning picker for the current Codex view on the paired Mac. You can also hold an A key or a quick key to assign **Change model**. Codex must be open, with Accessibility enabled for the companion, and its **Select effort** keyboard shortcut set to the default **Control–Shift–M**. The app offers menu navigation when macOS exposes the picker. After choosing a model, select your chat again if the controller returns to chat selection.

## Even Realities G2 glasses

Native version **0.2.4 / build 22** supports **Follow this controller** on both iPhone and iPad. The separate [Genesis G2 app](https://github.com/rickndanger-ctrl/genesis-g2) displays the selected Codex or supported Claude Code conversation above a dedicated draft box. The native app handles dictation and explicit Send; the glasses never submit a message themselves.

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

Two-way native Voice mode, Steer, and Muse chat controls are not connected in this version. Unsupported mapped keys explain their limitation and can be remapped with a long press. Registered artifacts can be browsed; automatic artifact discovery is not implemented. The Mac Photos library picker still requires the mouse.

See [Mac bridge setup](genesis-iphone/docs/HOST-BRIDGE.md), [protocol details](genesis-iphone/docs/PROTOCOL.md), and [artwork build instructions](genesis-iphone/design/README.md).
