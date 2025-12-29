#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VibePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_RAW="${1:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$VERSION_RAW" ]; then
  echo "Usage: SIGN_IDENTITY=... NOTARY_PROFILE=... scripts/release_local.sh v0.1.0"
  exit 1
fi

if [ -z "$SIGN_IDENTITY" ]; then
  echo "Set SIGN_IDENTITY (e.g. 'Developer ID Application: Name (TEAMID)')."
  exit 1
fi

if [ -z "$NOTARY_PROFILE" ]; then
  echo "Set NOTARY_PROFILE (from 'xcrun notarytool store-credentials')."
  exit 1
fi

if [ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash changes before releasing."
  exit 1
fi

if ! git -C "$ROOT_DIR" rev-parse "$VERSION_RAW" >/dev/null 2>&1; then
  echo "Tag $VERSION_RAW not found. Create it first (e.g. git tag -a $VERSION_RAW -m 'Release $VERSION_RAW')."
  exit 1
fi

VERSION="${VERSION_RAW#v}"
DMG_PATH="$ROOT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/scripts/build_dmg.sh" "$VERSION_RAW"
"$ROOT_DIR/scripts/notarize_dmg.sh" "$DMG_PATH"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) not found. Install it to publish the release."
  exit 1
fi

if gh release view "$VERSION_RAW" >/dev/null 2>&1; then
  gh release upload "$VERSION_RAW" "$DMG_PATH" --clobber
else
  gh release create "$VERSION_RAW" "$DMG_PATH" --generate-notes
fi

echo "Release published: $VERSION_RAW"
