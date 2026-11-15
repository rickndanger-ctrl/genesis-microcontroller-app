#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
xcrun swiftc -swift-version 5 "$ROOT/ios/Sources/Core/DictationTranscript.swift" "$ROOT/tests/core/DictationTranscriptTests.swift" -o "$ROOT/build/tests/dictation-transcript"
"$ROOT/build/tests/dictation-transcript"
