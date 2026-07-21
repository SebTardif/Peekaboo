#!/usr/bin/env bash
# Live ScreenCaptureKit proof for cancel-during-retry on ScreenCaptureFallbackRunner.
# Builds a tiny package that depends on Core/PeekabooAutomationKit and runs real SCK.
#
# Requirements: macOS with ScreenCaptureKit (Screen Recording grant for the host process).
# Usage (repo root):
#   bash scripts/prove-live-sck-cancel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="${ROOT}/Core/PeekabooAutomationKit"
SRC="${ROOT}/scripts/prove-live-sck-cancel/main.swift"
WORK="${TMPDIR:-/tmp}/peekaboo-live-sck-cancel-$$"

if [[ ! -d "$KIT" ]]; then
  echo "error: PeekabooAutomationKit not found at $KIT" >&2
  exit 1
fi
if [[ ! -f "$SRC" ]]; then
  echo "error: missing $SRC" >&2
  exit 1
fi

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/Sources/LiveSCKProof"
cp "$SRC" "$WORK/Sources/LiveSCKProof/main.swift"

cat > "$WORK/Package.swift" <<PKG
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSCKProof",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "${KIT}"),
    ],
    targets: [
        .executableTarget(
            name: "LiveSCKProof",
            dependencies: [
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
            ]
        ),
    ]
)
PKG

echo "Building LiveSCKProof against $KIT ..."
(
  cd "$WORK"
  swift build -c debug
  BIN="$(swift build -c debug --show-bin-path)/LiveSCKProof"
  echo "Running: $BIN"
  codesign -dv "$BIN" 2>&1 | sed -n '1,12p' || true
  echo
  "$BIN"
)
