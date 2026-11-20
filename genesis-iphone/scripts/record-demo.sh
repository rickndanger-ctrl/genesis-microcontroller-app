#!/bin/bash
# Records the choreographed demo run (tests/ui/DemoReelUITests.swift) on one simulator.
# Usage: scripts/record-demo.sh SIMULATOR_UUID OUTPUT.mp4
# Needs ffmpeg to trim and re-encode; without it the simulator's raw recording is kept.
# The app runs in demo mode: sample chats only, no Mac is contacted.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -eq 2 ] || { printf 'Usage: %s SIMULATOR_UUID OUTPUT.mp4\n' "$0" >&2; exit 2; }
sim="$1"; out="$2"; mkdir -p "$(dirname "$out")"
work="$(mktemp -d)"; trap 'xcrun simctl status_bar "$sim" clear >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
# A tidy status bar: 9:41, full signal, full battery.
xcrun simctl status_bar "$sim" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
TEST_RUNNER_GENESIS_DEMO_REEL=1 GENESIS_UI_TEST=testDemoReel "$root/scripts/test-ui.sh" "$sim" > "$work/run.txt" 2>&1 &
run=$!
log=""
for _ in $(seq 1 600); do
  [ -n "$log" ] || log="$(sed -n 's/^UI test log: //p' "$work/run.txt" | head -1)"
  if [ -n "$log" ] && grep -q "testDemoReel\]' started" "$log" 2>/dev/null; then break; fi
  kill -0 "$run" 2>/dev/null || { echo "The test run ended before the demo started." >&2; tail -5 "$work/run.txt" >&2; exit 1; }
  sleep 0.5
done
xcrun simctl io "$sim" recordVideo --codec h264 --force "$work/raw.mp4" > "$work/record.txt" 2>&1 &
record=$!
# Stop recording when the demo itself ends. The test tool sometimes lingers for
# minutes after an iPad run; give it a little while, then end it.
for _ in $(seq 1 360); do
  grep -Eq "testDemoReel\]' (passed|failed|skipped)" "$log" 2>/dev/null && break
  kill -0 "$run" 2>/dev/null || break
  sleep 0.5
done
kill -INT "$record" 2>/dev/null || true; wait "$record" 2>/dev/null || true
for _ in $(seq 1 60); do kill -0 "$run" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$run" 2>/dev/null; then
  pkill -P "$run" 2>/dev/null || true; pkill -f "xcodebuild .*GenesisControllerUIQA.*id=$sim" 2>/dev/null || true; kill "$run" 2>/dev/null || true
fi
wait "$run" 2>/dev/null || true
grep -o "testDemoReel\]' [a-z]* ([0-9.]* seconds)" "$log" | tail -1
[ -s "$work/raw.mp4" ] || { echo "No video was recorded." >&2; exit 1; }
# Drop the blank launch screen at the start and re-encode at a steady 60 frames a
# second, which editors and video sites handle better than the simulator's raw file.
# GENESIS_DEMO_TRIM is the seconds to drop; GENESIS_DEMO_ROTATE=left|right turns the
# picture when the simulator recorded a landscape screen sideways.
if command -v ffmpeg >/dev/null 2>&1; then
  filters="fps=60,scale=trunc(iw/2)*2:trunc(ih/2)*2"
  case "${GENESIS_DEMO_ROTATE:-}" in left) filters="transpose=2,$filters";; right) filters="transpose=1,$filters";; esac
  ffmpeg -v error -y -ss "${GENESIS_DEMO_TRIM:-2.3}" -i "$work/raw.mp4" -vf "$filters" -an \
    -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart "$out"
else
  mv "$work/raw.mp4" "$out"
fi
echo "Recorded $out"
