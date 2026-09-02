#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERMINAL_ARTIFACT_ROOT="$ROOT_DIR"
export TERMINAL_ARTIFACT_ROOT
# shellcheck source=scripts/terminal-artifact-policy.sh
source "$ROOT_DIR/scripts/terminal-artifact-policy.sh"
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-policy-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-terminal-artifact-policy: %s\n' "$*" >&2
  exit 1
}

classify_fixture_metadata() {
  /usr/bin/ruby "$ROOT_DIR/scripts/support/test-fixture-metadata.rb" classify "$@"
}

inspect_fixture_metadata() {
  /usr/bin/ruby "$ROOT_DIR/scripts/support/test-fixture-metadata.rb" inspect "$TEST_DIR" "$1"
}

# These are availability controls, not native ZIP proof.
while IFS='|' read -r names size expected; do
  actual="$(classify_fixture_metadata "$names" "$size" 2>"$TEST_DIR/classification.log")" || actual=rejected
  [[ "$actual" == "$expected" ]] || fail "metadata classification: expected $expected, got $actual"
done <<'EOF'
||clean
com.apple.provenance|11|persistent-provenance
com.apple.provenance||rejected
com.apple.provenance|0|rejected
com.apple.provenance|10|rejected
com.apple.provenance|12|rejected
com.openclaw.peekaboo.fixture|11|rejected
|11|rejected
EOF
if classify_fixture_metadata $'com.apple.provenance\ncom.openclaw.peekaboo.fixture' 11 \
  2>"$TEST_DIR/classification.log"; then
  fail 'provenance plus an added attribute was accepted as a platform limitation'
fi
if inspect_fixture_metadata "$TEST_DIR/missing-fixture" >"$TEST_DIR/missing.log" 2>&1; then
  fail 'metadata inspection failure was accepted as a platform limitation'
fi
mkdir -p "$TEST_DIR/bounds" "$TEST_DIR/bounds-extra"
if /usr/bin/ruby "$ROOT_DIR/scripts/support/test-fixture-metadata.rb" inspect \
  "$TEST_DIR/bounds" "$TEST_DIR/bounds-extra" >"$TEST_DIR/bounds.log" 2>&1; then
  fail 'metadata inspection escaped its owned root'
fi
printf 'fixture\n' > "$TEST_DIR/bounds/value"
/usr/bin/xattr -w com.openclaw.peekaboo.fixture value "$TEST_DIR/bounds/value"
if inspect_fixture_metadata "$TEST_DIR/bounds" >"$TEST_DIR/unknown.log" 2>&1; then
  fail 'nested arbitrary metadata was accepted as a platform limitation'
fi
# A dangling target proves the reader inspects only the link, never its destination.
ln -s "$TEST_DIR/nonexistent-target" "$TEST_DIR/metadata-link"
inspect_fixture_metadata "$TEST_DIR/metadata-link" >/dev/null || fail 'no-follow symlink inspection failed'
/usr/bin/xattr -s -w com.openclaw.peekaboo.fixture value "$TEST_DIR/metadata-link"
if inspect_fixture_metadata "$TEST_DIR/metadata-link" >"$TEST_DIR/link.log" 2>&1; then
  fail 'symlink metadata was ignored'
fi
printf 'test-terminal-artifact-policy: PASS 14 metadata classification/inspection controls (not native ZIP proof)\n'

build_manifest="$TEST_DIR/build-manifest.json"
jq -n '{
  version: 1,
  source_commit: "fixture",
  release_helper: {},
  toolchain: {},
  unsigned_inputs: {},
  marketing_version: "1.0.0",
  dependency_lock_sha256: "fixture",
  dependency_lock_path: "Package.resolved",
  build_mode: "test_fixture"
}' > "$build_manifest"
jq -e --argjson expected "$TERMINAL_ARTIFACT_BUILD_MANIFEST_KEYS_JSON" \
  'keys == $expected' "$build_manifest" >/dev/null || {
  printf 'test-terminal-artifact-policy: valid build-manifest keys were rejected\n' >&2
  exit 1
}
if jq -e --argjson expected "$TERMINAL_ARTIFACT_BUILD_MANIFEST_KEYS_JSON" \
  'del(.source_commit) | keys == $expected' "$build_manifest" >/dev/null; then
  printf 'test-terminal-artifact-policy: missing build-manifest key was accepted\n' >&2
  exit 1
fi
if jq -e --argjson expected "$TERMINAL_ARTIFACT_BUILD_MANIFEST_KEYS_JSON" \
  '.unexpected = true | keys == $expected' "$build_manifest" >/dev/null; then
  printf 'test-terminal-artifact-policy: extra build-manifest key was accepted\n' >&2
  exit 1
fi
printf 'test-terminal-artifact-policy: PASS build-manifest key controls\n'

mkdir -p "$TEST_DIR/Fixture.app/Contents/Resources"
printf 'fixture\n' > "$TEST_DIR/Fixture.app/Contents/Resources/value"
fixture_metadata="$(inspect_fixture_metadata "$TEST_DIR/Fixture.app")" || fail 'unexpected or unreadable fixture metadata'

if [[ "$fixture_metadata" == clean ]]; then
  terminal_artifact_zip_app_exact "$TEST_DIR/Fixture.app" "$TEST_DIR/fixture.zip" "$TEST_DIR/tree.json"

  /usr/bin/xattr -w com.openclaw.peekaboo.fixture value "$TEST_DIR/Fixture.app/Contents/Resources/value"
  if terminal_artifact_assert_no_xattrs "$TEST_DIR/Fixture.app"; then
    printf 'test-terminal-artifact-policy: xattr was accepted\n' >&2
    exit 1
  fi
  /usr/bin/xattr -d com.openclaw.peekaboo.fixture "$TEST_DIR/Fixture.app/Contents/Resources/value"
  printf 'test-terminal-artifact-policy: PASS native positive ZIP and isolated injected-xattr control\n'
else
  # Inspection errors are failures, not evidence that the strict guard rejected metadata.
  /usr/bin/xattr -r "$TEST_DIR/Fixture.app" > "$TEST_DIR/provenance-names"
  if terminal_artifact_assert_no_xattrs "$TEST_DIR/Fixture.app" 2>"$TEST_DIR/guard-errors"; then
    fail 'production guard accepted provenance-bearing fixture'
  else
    [[ $? -eq 1 && ! -s "$TEST_DIR/guard-errors" ]] || fail 'production guard failed unexpectedly'
  fi
  printf 'test-terminal-artifact-policy: PASS strict production guard rejects persistent provenance\n'
  printf 'test-terminal-artifact-policy: SKIP native positive ZIP and isolated injected-xattr control: '
  printf 'fresh fixture contains only com.apple.provenance (11 bytes); no native positive ZIP proof\n'
fi

mkdir -p "$TEST_DIR/appledouble/__MACOSX"
printf 'extra\n' > "$TEST_DIR/appledouble/__MACOSX/._Fixture"
(cd "$TEST_DIR/appledouble" && /usr/bin/zip -qr "$TEST_DIR/appledouble.zip" .)
terminal_artifact_zip_has_appledouble "$TEST_DIR/appledouble.zip" || {
  printf 'test-terminal-artifact-policy: AppleDouble entry was accepted\n' >&2
  exit 1
}
printf 'test-terminal-artifact-policy: PASS AppleDouble control\n'

printf 'test-terminal-artifact-policy: ok (executed cases passed; any unavailable cases are marked SKIP above)\n'
