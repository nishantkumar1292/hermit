#!/usr/bin/env bash
# Install or update Hermit from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/nishantkumar1292/hermit/main/scripts/get.sh | bash
#
# It downloads Hermit.dmg, checks it against the release's SHA-256, copies
# Hermit.app to /Applications and clears the quarantine flag (Hermit is not
# notarized by Apple). Your shells keep running across an update: quitting
# Hermit only detaches from them.
#
# Everything runs inside main(), called on the last line, so a download of
# this script that stops halfway runs nothing.
set -euo pipefail

main() {
  local repo="nishantkumar1292/hermit"
  local url="https://github.com/$repo/releases/latest/download/Hermit.dmg"
  local dest="/Applications/Hermit.app"
  local staged="/Applications/.Hermit-installing.app"

  [[ "$(uname -s)" == Darwin ]] || die "Hermit runs on macOS only."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  (( major >= 14 )) || die "Hermit needs macOS 14 or later (this Mac runs $(sw_vers -productVersion))."
  if pgrep -xq Hermit; then
    die "Hermit is running. Quit it with ⌘Q (your shells keep running), then run this again."
  fi

  tmp="$(mktemp -d)"
  trap cleanup EXIT

  say "Downloading the latest Hermit…"
  curl -fL --progress-bar -o "$tmp/Hermit.dmg" "$url" || die "Download failed: $url"
  if curl -fsSL -o "$tmp/Hermit.dmg.sha256" "$url.sha256"; then
    local want got
    want="$(awk '{print $1}' "$tmp/Hermit.dmg.sha256")"
    got="$(shasum -a 256 "$tmp/Hermit.dmg" | awk '{print $1}')"
    [[ "$want" == "$got" ]] || die "The download is damaged (SHA-256 mismatch). Run this again."
  fi

  mnt="$(hdiutil attach -nobrowse -readonly -noautoopen "$tmp/Hermit.dmg" | awk -F '\t' '/\/Volumes\// {print $NF}' | tail -1)"
  [[ -n "$mnt" && -d "$mnt/Hermit.app" ]] || die "The download does not contain Hermit.app."

  say "Installing to $dest…"
  rm -rf "$staged"
  ditto "$mnt/Hermit.app" "$staged" || die "Could not write to /Applications. Is your account an administrator?"
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  rm -rf "$dest" || die "Could not replace $dest. Try: sudo rm -rf \"$dest\", then run this again."
  mv "$staged" "$dest"

  say "Done. Open Hermit from Launchpad or Spotlight (⌘Space, then type Hermit)."
}

tmp=""
mnt=""
say() { printf '\033[1;38;5;209m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "$mnt" ]]; then hdiutil detach -quiet "$mnt" || true; fi
  if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi
  rm -rf "/Applications/.Hermit-installing.app" 2>/dev/null || true
}

main "$@"
