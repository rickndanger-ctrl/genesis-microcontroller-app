#!/bin/sh
# Wi-Fi pairing, end to end on this Mac: the companion's real Wi-Fi listener
# (genesis-mapper/tests/WiFiFixture.swift) and the app's real RemoteClient in a
# booted simulator, reaching the Mac by its .local name with a pinned certificate.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MAPPER="$ROOT/../genesis-mapper"
mkdir -p "$ROOT/build/tests" "$MAPPER/test-build"
xcrun swiftc -parse-as-library "$MAPPER/Sources/WiFiIdentity.swift" "$MAPPER/Sources/RemoteHTTP.swift" "$MAPPER/Sources/RemoteProtocol.swift" \
  "$MAPPER/Sources/RemoteNavigationLease.swift" "$MAPPER/Sources/DeviceRegistry.swift" "$MAPPER/tests/WiFiFixture.swift" \
  -framework SystemConfiguration -o "$MAPPER/test-build/wifi-fixture"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -D DEBUG -target arm64-apple-ios26.0-simulator -sdk "$SDK" -parse-as-library \
  "$ROOT"/ios/Sources/Core/*.swift "$ROOT/tests/core/WiFiRouteIntegration.swift" -o "$ROOT/build/tests/wifi-route-integration"
out=$(mktemp)
"$MAPPER/test-build/wifi-fixture" 60 > "$out" 2>&1 &
fixture=$!
trap 'kill $fixture 2>/dev/null || true; rm -f "$out"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q '^HOST' "$out" && break; sleep 0.5; done
pin=$(awk '/^PIN/{print $2}' "$out"); host=$(awk '/^HOST/{print $2}' "$out")
[ -n "$pin" ] && [ "$host" != "none" ] || { echo "The fixture did not start."; cat "$out"; exit 1; }
xcrun simctl spawn "${GENESIS_TEST_SIMULATOR:-booted}" "$ROOT/build/tests/wifi-route-integration" "$host" "$pin"
