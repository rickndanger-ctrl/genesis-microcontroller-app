#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/build"
# Compile the real protocol and allowlist; policy tests never open or control an app.
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Sources/RemoteProtocol.swift" "$ROOT/Sources/RemoteNavigationLease.swift" "$ROOT/Sources/CodexNativeActions.swift" \
  "$ROOT/tests/CodexNativeActionTests.swift" \
  -o "$ROOT/build/codex-native-action-tests" -framework Foundation -framework AppKit -framework ApplicationServices
"$ROOT/build/codex-native-action-tests"
