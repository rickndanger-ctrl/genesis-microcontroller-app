#!/bin/bash
set -euo pipefail
controller_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -eq 0 ]; then
  printf 'Usage: %s SIMULATOR_UUID [SIMULATOR_UUID ...]\n' "$0" >&2
  exit 2
fi
# Explicit simulator IDs avoid touching paired phones, tablets, or another test run.
xcrun simctl list devices available --json | python3 -c '
import json,sys
known={d["udid"] for devices in json.load(sys.stdin)["devices"].values() for d in devices}
unknown=set(sys.argv[1:])-known
if unknown: raise SystemExit("Not available simulators: "+", ".join(sorted(unknown)))
' "$@"
run_root="$controller_root/build/ui-regression"
mkdir -p "$run_root"
xcodegen generate --spec "$controller_root/tests/ui/project.yml" --project "$run_root" --quiet
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_result="$run_root/$run_stamp.xcresult"
run_log="$run_root/$run_stamp.log"
destinations=()
for simulator in "$@"; do destinations+=(-destination "id=$simulator"); done
printf 'UI test log: %s\nResults: %s\n' "$run_log" "$run_result"
test_selection=(-parallel-testing-enabled NO)
if [ -n "${GENESIS_UI_TEST:-}" ]; then
  read -r -a scenarios <<< "$GENESIS_UI_TEST"
  for scenario in "${scenarios[@]}"; do
    test_selection+=(-only-testing "GenesisControllerUITests/ControllerUITests/$scenario")
  done
fi
set +e
xcodebuild -project "$run_root/GenesisControllerUIQA.xcodeproj" -scheme GenesisController \
  "${destinations[@]}" -derivedDataPath "$run_root/DerivedData" \
  -resultBundlePath "$run_result" "${test_selection[@]}" test > "$run_log" 2>&1
run_status=$?
set -e
if [ -d "$run_result" ]; then
  xcrun xcresulttool get test-results summary --path "$run_result" || true
fi
if [ "$run_status" -ne 0 ]; then tail -n 45 "$run_log"; fi
exit "$run_status"
