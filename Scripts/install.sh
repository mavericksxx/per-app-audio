#!/bin/bash
# Builds the .app and installs it into /Applications, replacing any previous copy.
# Installing matters for two reasons beyond tidiness: SMAppService (Launch at login)
# refuses to register a bundle sitting in build/, and a bundle re-signed with the same
# identity keeps its System Audio Recording grant across updates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PerAppAudio.app"
APP_NAME="PerAppAudio"

# Build first. A failed build must not have already killed the running copy.
"$ROOT/Scripts/build-app.sh"

# /Applications is group-admin writable, so no sudo in the normal case.
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo
  echo "/Applications is not writable; installing to $DEST_DIR instead."
  echo "Launch at login may refuse a bundle outside /Applications."
fi
DEST="$DEST_DIR/$APP_NAME.app"

# Quit gracefully rather than killing: quitting tears routes down and saves gains.
# osascript returns an error when the app is not running, which is not a failure here.
echo
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running $APP_NAME..."
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  # Wait for it to actually exit; we must not rm -rf a live bundle.
  for _ in $(seq 1 20); do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "It did not quit in 5s; terminating."
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
fi
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "ERROR: $APP_NAME is still running; refusing to replace $DEST." >&2
  exit 1
fi

# ditto merges into an existing bundle, so clear the old one out first or stale
# files from a previous version survive. ditto preserves the signature.
rm -rf "$DEST"
ditto "$APP" "$DEST"

codesign --verify --strict --verbose=1 "$DEST"
echo
echo "Installed $DEST"
# -dvv (not -dv) is what prints Authority, i.e. proof this is not an ad-hoc signature.
codesign -dvv "$DEST" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)' || true

# Launch by explicit path: two bundles share the ID dev.perappvolume.app while
# build/ still exists, and `open -a` could resolve to the wrong one.
echo
open "$DEST"
echo "Launched $DEST - look for the splitter icon in the menu bar."
