# Simulator UI regressions

Run from the repository with explicit available simulator IDs:

```sh
genesis-iphone/scripts/test-ui.sh IPHONE_SIMULATOR_UUID IPAD_SIMULATOR_UUID
```

To rerun one changed scenario, prefix the command with `GENESIS_UI_TEST=testArtifactShelfSearchAndPreview` (or space-separated test method names).

Requires Xcode, XcodeGen, and Python 3. The runner rejects physical-device IDs and builds a separate simulator bundle. Every test launches `--demo`; no prompts, approvals, real chat switches, or host commands are sent. It does not test real microphone recognition or the Mac accessibility bridge.

Coverage: six slot taps/editors, four quick-key editors, unavailable-action feedback, action search and model mapping, menu controls, both rotary dials, iPad landscape, long labels, sound setting, hold/release including drag-out, toggle recording, draft edit lock, background capture stop, host/provider/chat draft isolation, refresh, demo Send, artifact search/preview, and camera-sheet cancel. Voice remains unavailable and must explain that.

Results and screenshots are saved under ignored `build/ui-regression`. A failed run's xcresult and log distinguish UI regressions from test-selector problems. If Xcode stalls after test workers finish, inspect the log before stopping only that run's `simctl diagnose` collector; do not reset other simulators or kill shared simulator services.
