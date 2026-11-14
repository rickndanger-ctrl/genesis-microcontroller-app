#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/CodexReadOnly.swift" "$ROOT/tests/CodexReadOnlyTests.swift" -o "$ROOT/build/codex-inventory-tests" -framework Foundation -framework CryptoKit
"$ROOT/build/codex-inventory-tests" "$@"
