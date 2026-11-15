#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -D DEBUG -target arm64-apple-ios26.0-simulator -sdk "$SDK" \
  "$ROOT"/ios/Sources/Core/*.swift "$ROOT/tests/core/GlassesFollowFixture.swift" "$ROOT/tests/core/RemoteHTTPIntegration.swift" \
  -o "$ROOT/build/tests/remote-http-integration"
xcrun simctl spawn "${GENESIS_TEST_SIMULATOR:-booted}" "$ROOT/build/tests/remote-http-integration" "$@"
