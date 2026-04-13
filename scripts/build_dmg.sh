#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VibePulse"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_RAW="${1:-dev}"
VERSION="${VERSION_RAW#v}"
GIT_HASH="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
APP_ICON="$ROOT_DIR/assets/VibePulse.icns"
STAGING_DIR="$DIST_DIR/staging"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swift build -c release --package-path "$ROOT_DIR"
cp "$BUILD_DIR/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "$APP_ICON" ]; then
  cp "$APP_ICON" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
else
  echo "Warning: $APP_ICON not found; app icon will be missing."
fi

# --- Embed Sparkle.framework ---
SPARKLE_MATCHES=()
while IFS= read -r match; do
  SPARKLE_MATCHES+=("$match")
done < <(find "$BUILD_DIR/artifacts" -type d \
  -path '*macos-arm64_x86_64/Sparkle.framework')

if [ "${#SPARKLE_MATCHES[@]}" -eq 0 ]; then
  echo "Error: Sparkle.framework not found in .build/artifacts."
  echo "Run 'swift package resolve' first."
  exit 1
fi
if [ "${#SPARKLE_MATCHES[@]}" -gt 1 ]; then
  echo "Error: Multiple Sparkle.framework matches found:"
  printf '  %s\n' "${SPARKLE_MATCHES[@]}"
  exit 1
fi
SPARKLE_FW="${SPARKLE_MATCHES[0]}"

mkdir -p "$APP_DIR/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

# --- Rewrite rpath so dyld finds Sparkle in the bundle ---
BINARY="$APP_DIR/Contents/MacOS/$APP_NAME"
SPARKLE_OLD_NAME=$(otool -L "$BINARY" \
  | grep Sparkle | awk '{print $1}')
if [ -z "$SPARKLE_OLD_NAME" ]; then
  echo "Error: Sparkle not found in otool -L output for $BINARY"
  exit 1
fi
install_name_tool -add_rpath \
  "@executable_path/../Frameworks" "$BINARY"
install_name_tool -change "$SPARKLE_OLD_NAME" \
  "@rpath/Sparkle.framework/Versions/B/Sparkle" "$BINARY"

# --- Verify rpath rewrite ---
if ! otool -L "$BINARY" | grep -q '@rpath/Sparkle.framework'; then
  echo "Error: rpath rewrite failed. otool -L still shows:"
  otool -L "$BINARY" | grep Sparkle
  exit 1
fi
if ! otool -l "$BINARY" | grep -A2 LC_RPATH \
    | grep -q '@executable_path/../Frameworks'; then
  echo "Error: LC_RPATH missing @executable_path/../Frameworks"
  exit 1
fi
echo "Sparkle rpath verified."

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.vibepulse.${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>${APP_NAME}.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>VPGitHash</key>
  <string>${GIT_HASH}</string>
  <key>VPBuildDate</key>
  <string>${BUILD_DATE}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>SUFeedURL</key>
  <string>https://github.com/wesm/vibepulse/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>cEYWDZYALSBQ23f4ttD75PSjVqpUIj4atr+vCFnH2M0=</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
</dict>
</plist>
PLIST

if [ -n "$SIGN_IDENTITY" ]; then
  CODESIGN_ARGS=(--force --options runtime --timestamp
    --sign "$SIGN_IDENTITY")

  # Sign Sparkle components inside-out
  SPARKLE_EMBEDDED="$APP_DIR/Contents/Frameworks/Sparkle.framework"

  for xpc in "$SPARKLE_EMBEDDED"/Versions/B/XPCServices/*.xpc; do
    [ -d "$xpc" ] && codesign "${CODESIGN_ARGS[@]}" "$xpc"
  done

  # Sparkle 2.9.1: Autoupdate is a bare Mach-O, Updater.app is a bundle
  if [ -f "$SPARKLE_EMBEDDED/Versions/B/Autoupdate" ]; then
    codesign "${CODESIGN_ARGS[@]}" \
      "$SPARKLE_EMBEDDED/Versions/B/Autoupdate"
  fi
  if [ -d "$SPARKLE_EMBEDDED/Versions/B/Updater.app" ]; then
    codesign "${CODESIGN_ARGS[@]}" \
      "$SPARKLE_EMBEDDED/Versions/B/Updater.app"
  fi

  codesign "${CODESIGN_ARGS[@]}" "$SPARKLE_EMBEDDED"
  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"

  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DIST_DIR/$DMG_NAME"

echo "Created $DIST_DIR/$DMG_NAME"
