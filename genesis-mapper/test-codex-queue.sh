#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/CodexQueue.swift" "$ROOT/tests/CodexQueueTests.swift" -o "$ROOT/build/codex-queue-tests" -framework Foundation -framework Security
"$ROOT/build/codex-queue-tests" "$@"
