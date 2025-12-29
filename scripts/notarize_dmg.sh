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
spctl --assess --type open --verbose "$DMG_PATH"

echo "Notarization complete: $DMG_PATH"
