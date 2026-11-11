#!/usr/bin/env bash
set -euo pipefail

# Source app comes from `mise run build`, which exports a Release-signed .app
# under build/export/Hermit.app.
SRC="./build/export/Hermit.app"
if [[ ! -d "$SRC" ]]; then
  echo "ERROR: $SRC is not there. Run 'mise run build' first." >&2
  exit 1
fi

rm -rf /Applications/Hermit.app
ditto "$SRC" /Applications/Hermit.app

codesign --verify --deep --strict --verbose=2 /Applications/Hermit.app
