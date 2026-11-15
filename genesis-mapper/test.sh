#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/test-build"
xcrun swiftc "$ROOT/Sources/ActionCatalog.swift" "$ROOT/Sources/CodexControls.swift" "$ROOT/Sources/NativeCommandNames.swift" "$ROOT/tests/catalog/main.swift" -o "$ROOT/test-build/catalog"
"$ROOT/test-build/catalog"
xcrun swiftc "$ROOT/Sources/PromptRouteGate.swift" "$ROOT/tests/PromptRouteGateTests.swift" -o "$ROOT/test-build/prompt-routing"
"$ROOT/test-build/prompt-routing"
xcrun swiftc "$ROOT/Sources/NavigationGate.swift" "$ROOT/tests/NavigationGateTests.swift" -o "$ROOT/test-build/navigation-gate"
"$ROOT/test-build/navigation-gate"
xcrun swiftc "$ROOT/Sources/FilePickerPolicy.swift" "$ROOT/tests/FilePickerPolicyTests.swift" -o "$ROOT/test-build/file-picker-policy"
"$ROOT/test-build/file-picker-policy"
xcrun swiftc "$ROOT/Sources/ClaudeTalkFocus.swift" "$ROOT/tests/ClaudeTalkFocusTests.swift" -o "$ROOT/test-build/claude-talk-focus"
"$ROOT/test-build/claude-talk-focus"
xcrun swiftc "$ROOT/Sources/ReadSnapshotCache.swift" "$ROOT/tests/ReadSnapshotCacheTests.swift" -o "$ROOT/test-build/read-snapshot-cache"
"$ROOT/test-build/read-snapshot-cache"

xcrun swiftc "$ROOT/Sources/RemoteNavigationLease.swift" "$ROOT/tests/RemoteNavigationLeaseTests.swift" -o "$ROOT/test-build/remote-navigation-lease"
"$ROOT/test-build/remote-navigation-lease"
sh "$ROOT/test-display-session.sh"
