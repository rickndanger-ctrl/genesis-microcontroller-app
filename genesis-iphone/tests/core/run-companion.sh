#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
xcrun swiftc -swift-version 5 \
  "$ROOT/ios/Sources/Core/CompanionSupport.swift" "$ROOT/tests/core/CompanionSupportTests.swift" \
  -o "$ROOT/build/tests/companion-support"
"$ROOT/build/tests/companion-support"
