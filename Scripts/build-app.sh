#!/bin/bash
# Builds the menu-bar app executable and assembles a signed .app bundle.
# A bundle is mandatory: Core Audio process taps only get a TCC grant from a signed
# app, and running the bare binary attributes the grant to the terminal (silent zeros).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/PerAppAudio.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PerAppAudio" "$APP/Contents/MacOS/PerAppAudio"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A stable signing identity keeps the TCC grant across rebuilds; ad-hoc does not.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -E 'Developer ID Application|Apple Development' \
  | awk '{print $2}' || true)"
if [ -n "$IDENTITY" ]; then
  echo "Signing with identity $IDENTITY"
else
  IDENTITY="-"
  echo "No codesigning identity found; signing ad-hoc."
  echo "The system-audio permission grant will reset on every rebuild."
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo
echo "Built $APP"
echo "Launch it with:  open \"$APP\""
echo "(Do NOT run Contents/MacOS/PerAppAudio directly - the tap will return silence.)"
