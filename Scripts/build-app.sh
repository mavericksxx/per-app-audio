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
# Preference is ordered: Developer ID Application (distributable) first, then the free
# Apple Development cert. One grep for both would just take whichever came first.
# Lines look like:  1) <SHA-1> "Apple Development: Name (TEAMID)"
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY_LINE=""
for PREFERRED in 'Developer ID Application' 'Apple Development'; do
  IDENTITY_LINE="$(printf '%s\n' "$IDENTITY_LIST" | grep -m1 -F "$PREFERRED" || true)"
  if [ -n "$IDENTITY_LINE" ]; then break; fi
done
if [ -n "$IDENTITY_LINE" ]; then
  IDENTITY="$(printf '%s\n' "$IDENTITY_LINE" | awk '{print $2}')"
  IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_LINE" | awk -F'"' '{print $2}')"
  echo "Signing with \"$IDENTITY_NAME\" ($IDENTITY)"
else
  IDENTITY="-"
  echo "No codesigning identity found; signing ad-hoc."
  echo "The system-audio permission grant will reset on every rebuild."
  echo "Create a free Apple Development cert (see README > Install) to make it stick."
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo
echo "Built $APP"
echo "Launch it with:  open \"$APP\""
echo "(Do NOT run Contents/MacOS/PerAppAudio directly - the tap will return silence.)"
