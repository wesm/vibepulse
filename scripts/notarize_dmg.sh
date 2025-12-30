#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$DMG_PATH" ]; then
  echo "Usage: scripts/notarize_dmg.sh /path/to/VibePulse.dmg"
  exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "DMG not found: $DMG_PATH"
  exit 1
fi

if [ -z "$NOTARY_PROFILE" ]; then
  echo "Set NOTARY_PROFILE (from 'xcrun notarytool store-credentials')."
  exit 1
fi

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

MOUNT_PATH="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | awk '/\/Volumes\// {print $NF; exit}')"
if [ -z "$MOUNT_PATH" ]; then
  echo "Failed to mount DMG for verification."
  exit 1
fi

APP_PATH="$MOUNT_PATH/VibePulse.app"
if [ ! -d "$APP_PATH" ]; then
  hdiutil detach "$MOUNT_PATH" >/dev/null 2>&1 || true
  echo "App not found in DMG: $APP_PATH"
  exit 1
fi

spctl --assess --type execute --verbose "$APP_PATH"
hdiutil detach "$MOUNT_PATH"

echo "Notarization complete: $DMG_PATH"
