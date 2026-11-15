#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/test-build"
xcrun swiftc "$ROOT/Sources/RemoteDisplaySession.swift" "$ROOT/tests/RemoteDisplaySessionTests.swift" -o "$ROOT/test-build/remote-display-session"
"$ROOT/test-build/remote-display-session"
