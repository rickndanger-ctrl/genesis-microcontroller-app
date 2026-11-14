#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/../genesis-mapper/Sources/RemoteProtocol.swift" "$ROOT/../genesis-mapper/Sources/RemoteNavigationLease.swift" "$ROOT/../genesis-mapper/Sources/ActionCatalog.swift" "$ROOT/tests/RemoteHostTests.swift" -o "$ROOT/build/remote-host-tests" -framework CryptoKit -framework Security
"$ROOT/build/remote-host-tests"
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/../genesis-mapper/Sources/RemoteProtocol.swift" "$ROOT/../genesis-mapper/Sources/RemoteNavigationLease.swift" "$ROOT/../genesis-mapper/Sources/RemoteHTTP.swift" "$ROOT/tests/RemoteHTTPTests.swift" -o "$ROOT/build/remote-http-tests" -framework Network -framework CryptoKit -framework Security
"$ROOT/build/remote-http-tests"
