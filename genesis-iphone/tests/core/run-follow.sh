#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
xcrun swiftc -swift-version 5 \
  "$ROOT/ios/Sources/Core/RemoteModels.swift" "$ROOT/ios/Sources/Core/RemoteClient.swift" \
  "$ROOT/ios/Sources/Core/DisplaySessionModels.swift" "$ROOT/ios/Sources/Core/GlassesFollowController.swift" \
  "$ROOT/tests/core/GlassesFollowFixture.swift" "$ROOT/tests/core/GlassesFollowTests.swift" \
  -o "$ROOT/build/tests/glasses-follow"
"$ROOT/build/tests/glasses-follow"
