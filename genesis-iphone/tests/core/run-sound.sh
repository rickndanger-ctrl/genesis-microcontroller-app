#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
xcrun swiftc -swift-version 5 \
  "$ROOT/ios/Sources/ControllerSound.swift" "$ROOT/tests/core/ControllerSoundTests.swift" \
  -o "$ROOT/build/tests/controller-sound"
"$ROOT/build/tests/controller-sound"
