# Genesis Microcontroller App

**Muse hasn’t been connected yet.**

Genesis is an iPhone controller for Codex and Claude Code sessions on a paired Mac. It provides six assignable keys, chat switching, Hold to Talk, draft review, and Send. The Mac companion handles chat navigation and sends the reviewed draft to the selected session. This app is a separate project from the [Genesis Mini hardware and firmware](https://github.com/rickndanger-ctrl/genesis-agent-micro-controller).

## Build

The iPhone project targets iOS 26 or later and uses Xcode and XcodeGen. Generate the project, then open it in Xcode:

```sh
cd genesis-iphone
xcodegen generate --spec project.yml
open GenesisController.xcodeproj
```

For a physical iPhone, select your Apple development team in Xcode and choose a unique bundle identifier if needed. The `--demo` launch argument shows an offline preview.

Build the companion from the repository root on macOS 14 or later with Xcode:

```sh
sh genesis-mapper/build.sh
open 'genesis-mapper/Genesis Agent Micro Controller.app'
```

The Mac build uses an ad hoc signature by default. Set `CLAUDE_CONTROLLER_SIGN_ID` to an Apple Development signing identity if you need a stable signature for local updates. Install under `~/Applications` if you use its launch-at-sign-in setting. The iPhone bridge runs without a USB controller. To opt into the companion’s hardware controls, run `defaults write local.richard.genesis-mapper GenesisUSBSerial -string "YOUR_GENESIS_SERIAL"` and reopen the companion.

## Pair and use

1. Connect the Mac and iPhone to the same Tailscale network. On the Mac, give the companion Accessibility access if you use Claude Code or native desktop menu controls.
2. From the menu-bar dial, open **Pair iPhone / Artifacts** and enable private remote access. The companion listens on loopback port 18765. On the Mac, `tailscale serve --bg --https=8451 http://127.0.0.1:18765` makes the service available on a private HTTPS port to the tailnet. If you already use that port, choose a free port and enter its HTTPS URL in the pairing panel.
3. In the iPhone app, open **Settings → Scan pairing code** and scan the QR code from the companion. Pair each Mac separately. The pairing code contains a private credential.
4. Choose a provider and chat. Hold **Talk**, release to review the draft, then tap **Send**. Grant iPhone microphone and speech recognition access when prompted.

Codex Send uses the [bundled Codex queue command](https://learn.chatgpt.com/docs/developer-commands#codex-queue) to target the exact selected chat. **Queued** means Codex accepted the message. If the chat is busy, it can process the draft after the current turn. Open the chat on the Mac if it is unloaded. Claude Code uses the Mac composer and presents its own delivery status.

## Verify

From the repository root:

```sh
sh genesis-iphone/tests/core/run.sh
sh genesis-iphone/tools/test-host.sh
sh genesis-mapper/test-codex-queue.sh
```

For the iOS HTTP integration suite, boot an iOS 26+ simulator and run `GENESIS_TEST_SIMULATOR=<simulator-udid> sh genesis-iphone/tests/core/run-integration.sh`. The Codex queue integration uses temporary local state and a loopback test model. Run it with `python3 genesis-iphone/tools/test-codex-queue-isolated.py --codex /path/to/codex`.

See [Mac bridge setup](genesis-iphone/docs/HOST-BRIDGE.md), [protocol details](genesis-iphone/docs/PROTOCOL.md), and [artwork build instructions](genesis-iphone/design/README.md).
