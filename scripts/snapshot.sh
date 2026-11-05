#!/bin/zsh
# Capture a Notesy window as a PNG, even when it is behind other windows.
# Usage: scripts/snapshot.sh <output.png> [app-path]
set -euo pipefail

OUT="${1:?usage: snapshot.sh <output.png> [app-path]}"
APP="${2:-$(cd "$(dirname "$0")/.." && pwd)/dist/Notesy.app}"
BUNDLE_ID="com.notesy.app"

if ! pgrep -x Notesy >/dev/null; then
  open -a "$APP"
  sleep 2
fi

# Bring the app forward so the window exists, is on the active space, and
# renders with active (saturated) glass rather than the inactive variant.
open -a "$APP" 2>/dev/null || true
sleep 0.4
osascript -e 'tell application "System Events" to set frontmost of process "Notesy" to true' >/dev/null 2>&1 || \
  osascript -e "tell application id \"$BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
sleep 0.6

HERE="$(cd "$(dirname "$0")" && pwd)"
WINDOWID_BIN="$HERE/.build/windowid"
if [[ ! -x "$WINDOWID_BIN" ]]; then
  mkdir -p "$HERE/.build"
  swiftc -O "$HERE/windowid.swift" -o "$WINDOWID_BIN"
fi

WIN_ID=$("$WINDOWID_BIN" Notesy || true)

if [[ -z "${WIN_ID:-}" ]]; then
  echo "snapshot: Notesy window not found" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l "$WIN_ID" "$OUT"
echo "snapshot: $OUT (window $WIN_ID)"
