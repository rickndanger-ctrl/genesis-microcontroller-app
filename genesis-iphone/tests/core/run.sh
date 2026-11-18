#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$ROOT/build/tests"
xcrun swiftc -swift-version 5 "$ROOT/ios/Sources/Core/RemoteModels.swift" "$ROOT/ios/Sources/Core/DialTracking.swift" "$ROOT/ios/Sources/Core/DeferredTap.swift" "$ROOT/ios/Sources/Core/GlassesFeature.swift" "$ROOT/ios/Sources/Core/ConnectionHelp.swift" "$ROOT/tests/core/RemoteCoreTests.swift" -o "$ROOT/build/tests/remote-core"
"$ROOT/build/tests/remote-core"
