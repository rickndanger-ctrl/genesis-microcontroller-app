#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios26.0-simulator -sdk "$SDK" \
  "$ROOT/ios/Sources/Core/DictationTranscript.swift" "$ROOT/ios/Sources/Core/DictationDiagnostics.swift" \
  "$ROOT/ios/Sources/Core/DictationAudioInput.swift" "$ROOT/ios/Sources/Core/PhoneDictation.swift" \
  "$ROOT/tests/core/DictationAudioInputTests.swift" -o "$ROOT/build/tests/dictation-audio-input"
xcrun simctl spawn "${GENESIS_TEST_SIMULATOR:-booted}" "$ROOT/build/tests/dictation-audio-input"
