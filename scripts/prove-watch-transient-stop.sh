#!/usr/bin/env bash
# Red/green proof for watch transient backoff stop responsiveness.
# Usage: bash scripts/prove-watch-transient-stop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP_FILE="$ROOT/Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/Capture/WatchCaptureSession+Loop.swift"
CORE_DIR="$ROOT/Core/PeekabooCore"
TEST_FILTER='Stop request wakes transient capture backoff'

select_xcode() {
  for candidate in \
    /Applications/Xcode_26.2.app \
    /Applications/Xcode_26.1.app \
    /Applications/Xcode_26.0.app \
    /Applications/Xcode_16.4.app \
    /Applications/Xcode.app
  do
    if [[ -d "$candidate" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"
      return 0
    fi
  done
  return 1
}

echo "=== Step 1: Minimal backoff sleep reproduction (no XCTest) ==="
swift "$ROOT/scripts/prove-watch-transient-stop.swift"
echo

patch_unfixed() {
  python3 - "$LOOP_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """                    let retryStart = Date()
                    try await self.sleep(ns: delay, since: retryStart)"""
new = """                    try await Task.sleep(nanoseconds: delay)"""
if old not in text:
    raise SystemExit("expected fixed sleep block not found")
path.write_text(text.replace(old, new, 1))
PY
}

restore_fixed() {
  python3 - "$LOOP_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """                    try await Task.sleep(nanoseconds: delay)"""
new = """                    let retryStart = Date()
                    try await self.sleep(ns: delay, since: retryStart)"""
if "let retryStart = Date()" in text:
    raise SystemExit("already fixed")
if old not in text:
    raise SystemExit("expected unfixed sleep block not found")
path.write_text(text.replace(old, new, 1))
PY
}

if select_xcode; then
  echo "=== Step 2: Focused Swift test (red on raw Task.sleep, green on fix) ==="
  cd "$CORE_DIR"

  cp "$LOOP_FILE" "$LOOP_FILE.proof-bak"
  trap 'mv "$LOOP_FILE.proof-bak" "$LOOP_FILE"' EXIT

  echo "--- RED: unfixed raw Task.sleep (expect failure) ---"
  set +e
  patch_unfixed
  swift test --no-parallel --filter "$TEST_FILTER" 2>&1 | tee /tmp/watch-transient-stop-red.log
  RED_STATUS=${PIPESTATUS[0]}
  set -e
  if [[ "$RED_STATUS" -eq 0 ]]; then
    echo "ERROR: regression test passed on unfixed path; proof is invalid" >&2
    exit 4
  fi
  echo "red_status=$RED_STATUS (expected non-zero)"
  echo

  echo "--- GREEN: stop-aware sleep fix (expect pass) ---"
  restore_fixed
  swift test --no-parallel --filter "$TEST_FILTER" 2>&1 | tee /tmp/watch-transient-stop-green.log
  echo "green_status=0"
else
  echo "=== Step 2: skipped (no full Xcode.app found for Swift Testing) ==="
  echo "Step 1 still demonstrates the behavioral difference in terminal output above."
fi