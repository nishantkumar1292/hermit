#!/usr/bin/env bash
# Install or update Hermit from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/nishantkumar1292/hermit/main/scripts/get.sh | bash
#
# It downloads Hermit.dmg, copies Hermit.app to /Applications and clears the
# quarantine flag (Hermit is not notarized by Apple). Your shells keep running
# across an update: quitting Hermit only detaches from them.
set -euo pipefail

REPO="nishantkumar1292/hermit"
URL="https://github.com/$REPO/releases/latest/download/Hermit.dmg"
DEST="/Applications/Hermit.app"

say() { printf '\033[1;38;5;209m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Hermit runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || die "Hermit needs macOS 14 or later (this Mac runs $(sw_vers -productVersion))."
if pgrep -xq Hermit; then
  die "Hermit is running. Quit it with ⌘Q (your shells keep running), then run this again."
fi

tmp="$(mktemp -d)"
mnt=""
cleanup() {
  if [[ -n "$mnt" ]]; then hdiutil detach -quiet "$mnt" || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

say "Downloading the latest Hermit…"
curl -fL --progress-bar -o "$tmp/Hermit.dmg" "$URL" || die "Download failed: $URL"

mnt="$(hdiutil attach -nobrowse -readonly -noautoopen "$tmp/Hermit.dmg" | awk -F '\t' '/\/Volumes\// {print $NF}' | tail -1)"
[[ -d "$mnt/Hermit.app" ]] || die "The download does not contain Hermit.app."

say "Installing to $DEST…"
if [[ -e "$DEST" ]]; then rm -rf "$DEST" || die "Could not replace $DEST. Try: sudo rm -rf \"$DEST\", then run this again."; fi
ditto "$mnt/Hermit.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

say "Done. Open Hermit from Launchpad or Spotlight (⌘Space, then type Hermit)."
