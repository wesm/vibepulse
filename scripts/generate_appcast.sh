#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VibePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_RAW="${1:-}"
BUILD_DIR="$ROOT_DIR/.build"

if [ -z "$VERSION_RAW" ]; then
  echo "Usage: scripts/generate_appcast.sh v0.3.0"
  exit 1
fi

VERSION="${VERSION_RAW#v}"
DMG_PATH="$ROOT_DIR/dist/${APP_NAME}-${VERSION}.dmg"
DIST_DIR="$ROOT_DIR/dist"

if [ ! -f "$DMG_PATH" ]; then
  echo "Error: DMG not found at $DMG_PATH"
  exit 1
fi

# --- Compute DMG metadata ---
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S %z')
DMG_URL="https://github.com/wesm/vibepulse/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"

# --- EdDSA signature ---
SIGN_UPDATE=$(find "$BUILD_DIR/artifacts" -name sign_update \
  -not -path '*/old_dsa_scripts/*' -type f | head -1)

if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: sign_update not found in .build/artifacts."
  echo "Run 'swift package resolve' first."
  exit 1
fi

SPARKLE_KEY_FILE=""
CLEANUP_KEY_FILE=""

if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  SPARKLE_KEY_FILE="$(mktemp)"
  echo "$SPARKLE_ED_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
  CLEANUP_KEY_FILE="$SPARKLE_KEY_FILE"
  ED_SIG=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" \
    "$DMG_PATH" | grep -o 'sparkle:edSignature="[^"]*"' \
    | sed 's/sparkle:edSignature="//;s/"//')
else
  ED_SIG=$("$SIGN_UPDATE" "$DMG_PATH" \
    | grep -o 'sparkle:edSignature="[^"]*"' \
    | sed 's/sparkle:edSignature="//;s/"//')
fi

if [ -n "$CLEANUP_KEY_FILE" ]; then
  rm -f "$CLEANUP_KEY_FILE"
fi

if [ -z "$ED_SIG" ]; then
  echo "Error: Failed to compute EdDSA signature."
  exit 1
fi

# --- Release notes ---
RELEASE_NOTES=""
if [ -n "${APPCAST_RELEASE_BODY_FILE:-}" ] \
    && [ -f "$APPCAST_RELEASE_BODY_FILE" ]; then
  BODY=$(cat "$APPCAST_RELEASE_BODY_FILE")
elif gh release view "v${VERSION}" --json body --jq .body \
    > /dev/null 2>&1; then
  BODY=$(gh release view "v${VERSION}" --json body --jq .body)
else
  BODY=""
fi

if [ -n "$BODY" ]; then
  HTML=$(echo "$BODY" \
    | gh api -X POST /markdown -F text=@- 2>/dev/null) || true
  if [ -n "$HTML" ]; then
    RELEASE_NOTES="$HTML"
  else
    RELEASE_NOTES="<pre>$(echo "$BODY" \
      | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</pre>"
  fi
fi

if [ -z "$RELEASE_NOTES" ]; then
  RELEASE_NOTES="Release v${VERSION}"
fi

# --- Emit appcast.xml ---
cat > "$DIST_DIR/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME}</title>
    <link>https://github.com/wesm/vibepulse</link>
    <description>${APP_NAME} release feed</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[${RELEASE_NOTES}]]></description>
      <enclosure
        url="${DMG_URL}"
        sparkle:edSignature="${ED_SIG}"
        length="${DMG_SIZE}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
APPCAST

# --- Validate ---
if command -v xmllint > /dev/null 2>&1; then
  xmllint --noout "$DIST_DIR/appcast.xml"
fi

if ! grep -q 'sparkle:edSignature' "$DIST_DIR/appcast.xml"; then
  echo "Error: sparkle:edSignature missing from appcast.xml"
  exit 1
fi

echo "Generated $DIST_DIR/appcast.xml"
