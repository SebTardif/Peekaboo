#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: scripts/create-app-zip.sh APP ZIP\n' >&2
  exit 1
fi

# Omit filesystem metadata/AppleDouble without altering the signed, stapled source tree.
exec /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$1" "$2"
