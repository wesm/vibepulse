# Sparkle Auto-Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-app automatic update delivery via Sparkle 2.x so users receive signed, notarized new versions without manually downloading DMGs.

**Architecture:** Sparkle is added as a SwiftPM binary dependency, its framework is manually embedded into the `.app` bundle by `build_dmg.sh` (with rpath rewrite and per-component signing), and a new `generate_appcast.sh` script produces the EdDSA-signed appcast XML. The release workflow uses a three-phase draft-then-publish flow so the feed is never in a broken state.

**Tech Stack:** Swift/SwiftUI, Sparkle 2.9.1 (SwiftPM binary target), bash scripts, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-04-13-sparkle-auto-updates-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Package.swift` | Add Sparkle dependency |
| Create | `Sources/VibePulse/Services/UpdaterController.swift` | Thin wrapper around `SPUStandardUpdaterController` |
| Modify | `Sources/VibePulse/VibePulseApp.swift` | Instantiate and hold `UpdaterController` |
| Modify | `Sources/VibePulse/Views/MenuContentView.swift` | Add "Check for Updates…" button |
| Modify | `scripts/build_dmg.sh` | Embed framework, rewrite rpath, add Sparkle Info.plist keys, per-component signing |
| Create | `scripts/generate_appcast.sh` | Produce EdDSA-signed `appcast.xml` from release metadata |
| Modify | `scripts/release_local.sh` | Three-phase draft-then-publish with appcast |
| Modify | `.github/workflows/release.yml` | Three-phase draft-then-publish with appcast generation |
| Modify | `.github/workflows/release.yml` cleanup step | Delete Sparkle private key temp file |
| Modify | `docs/github-actions-release.md` | Document `SPARKLE_ED_PRIVATE_KEY` secret and key rotation |

---

### Task 1: Add Sparkle SwiftPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add Sparkle binary target dependency to Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibePulse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibePulse", targets: ["VibePulse"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "VibePulse",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/VibePulse",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "VibePulseTests",
            dependencies: ["VibePulse"],
            path: "Tests/VibePulseTests"
        ),
    ]
)
```

- [ ] **Step 2: Resolve and build**

Run: `swift package resolve && swift build`
Expected: Sparkle downloads into `.build/artifacts/...` and the project compiles.

- [ ] **Step 3: Verify the xcframework landed**

Run: `find .build/artifacts -type d -path '*macos-arm64_x86_64/Sparkle.framework' | head -1`
Expected: One path printed. Note this path — it's needed to verify `build_dmg.sh` later.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Add Sparkle 2.9.1 SwiftPM dependency"
```

---

### Task 2: Create UpdaterController

**Files:**
- Create: `Sources/VibePulse/Services/UpdaterController.swift`

- [ ] **Step 1: Create UpdaterController.swift**

```swift
import Sparkle

final class UpdaterController: ObservableObject {
  private let controller: SPUStandardUpdaterController

  init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    if controller.updater.automaticallyChecksForUpdates {
      controller.updater.checkForUpdatesInBackground()
    }
  }

  var canCheckForUpdates: Bool {
    controller.updater.canCheckForUpdates
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Compiles without errors. Sparkle symbols resolve.

- [ ] **Step 3: Commit**

```bash
git add Sources/VibePulse/Services/UpdaterController.swift
git commit -m "Add UpdaterController wrapping Sparkle updater"
```

---

### Task 3: Wire UpdaterController into app and UI

**Files:**
- Modify: `Sources/VibePulse/VibePulseApp.swift`
- Modify: `Sources/VibePulse/Views/MenuContentView.swift`

- [ ] **Step 1: Instantiate UpdaterController in VibePulseApp**

In `Sources/VibePulse/VibePulseApp.swift`, add a `@StateObject` for the updater and pass it to `MenuContentView` via `environmentObject`:

```swift
import AppKit
import SwiftUI

@main
struct VibePulseApp: App {
  @StateObject private var model = AppModel()
  @StateObject private var updaterController = UpdaterController()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(model)
        .environmentObject(updaterController)
    } label: {
      MenuBarLabelView(totalText: model.menuTotalText)
    }
    .menuBarExtraStyle(.window)
    .windowResizability(.contentSize)

  }
}
```

- [ ] **Step 2: Add "Check for Updates…" button to MenuContentView**

In `Sources/VibePulse/Views/MenuContentView.swift`, add an `@EnvironmentObject` for `UpdaterController` and a button in the `controls` section. The full `controls` computed property becomes:

```swift
@EnvironmentObject private var updaterController: UpdaterController

// ... (add the @EnvironmentObject line after the existing model one)

private var controls: some View {
  HStack {
    Button("Refresh") {
      model.refreshNow()
    }
    .disabled(model.isRefreshing)

    Button("Settings") {
      model.openSettings()
    }

    Button("Check for Updates…") {
      updaterController.checkForUpdates()
    }

    Spacer()

    Button("Quit") {
      NSApp.terminate(nil)
    }
  }
  .buttonStyle(.borderless)
  .font(.caption)
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: Compiles. No errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/VibePulse/VibePulseApp.swift Sources/VibePulse/Views/MenuContentView.swift
git commit -m "Wire UpdaterController into app and add Check for Updates button"
```

---

### Task 4: Update build_dmg.sh — Info.plist Sparkle keys

**Files:**
- Modify: `scripts/build_dmg.sh`

The public EdDSA key is a placeholder `__SPARKLE_ED_PUBLIC_KEY__` until Task 9 (key generation). The implementer replaces it after running `generate_keys`.

- [ ] **Step 1: Add Sparkle keys to the Info.plist heredoc**

In `scripts/build_dmg.sh`, add four keys inside the `<dict>` block of the Info.plist heredoc, after the `LSUIElement` entry and before the closing `</dict>`:

```xml
  <key>SUFeedURL</key>
  <string>https://github.com/wesm/vibepulse/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>__SPARKLE_ED_PUBLIC_KEY__</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
```

- [ ] **Step 2: Verify the script still produces valid plist output**

Run: `SIGN_IDENTITY="" scripts/build_dmg.sh v0.0.0-test && plutil -lint dist/VibePulse.app/Contents/Info.plist`
Expected: `dist/VibePulse.app/Contents/Info.plist: OK`

- [ ] **Step 3: Clean up test build**

Run: `rm -rf dist/`

- [ ] **Step 4: Commit**

```bash
git add scripts/build_dmg.sh
git commit -m "Add Sparkle Info.plist keys to build_dmg.sh"
```

---

### Task 5: Update build_dmg.sh — framework embedding, rpath, signing

**Files:**
- Modify: `scripts/build_dmg.sh`

This is the highest-risk task. It adds framework embedding, rpath rewriting, `otool` verification, and per-component signing to `build_dmg.sh`.

- [ ] **Step 1: Add Sparkle embedding and rpath rewrite after executable copy**

Insert the following block in `scripts/build_dmg.sh` after `cp "$BUILD_DIR/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"` and the icon copy, but BEFORE the signing block (`if [ -n "$SIGN_IDENTITY" ]`):

```bash
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
```

- [ ] **Step 2: Replace the existing signing block with per-component signing**

Replace the existing signing block (from `if [ -n "$SIGN_IDENTITY" ]; then` through the matching `fi`) with:

```bash
if [ -n "$SIGN_IDENTITY" ]; then
  CODESIGN_ARGS=(--force --options runtime --timestamp
    --sign "$SIGN_IDENTITY")

  # Sign Sparkle components inside-out
  SPARKLE_EMBEDDED="$APP_DIR/Contents/Frameworks/Sparkle.framework"

  for xpc in "$SPARKLE_EMBEDDED"/Versions/B/XPCServices/*.xpc; do
    [ -d "$xpc" ] && codesign "${CODESIGN_ARGS[@]}" "$xpc"
  done

  if [ -d "$SPARKLE_EMBEDDED/Versions/B/Autoupdate.app" ]; then
    codesign "${CODESIGN_ARGS[@]}" \
      "$SPARKLE_EMBEDDED/Versions/B/Autoupdate.app"
  fi

  codesign "${CODESIGN_ARGS[@]}" "$SPARKLE_EMBEDDED"
  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"

  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi
```

- [ ] **Step 3: Test the full build locally (unsigned)**

Run: `SIGN_IDENTITY="" scripts/build_dmg.sh v0.0.0-test`
Expected:
- `Sparkle rpath verified.` printed to stdout
- `dist/VibePulse-0.0.0-test.dmg` created
- `otool -L dist/VibePulse.app/Contents/MacOS/VibePulse | grep Sparkle` shows `@rpath/Sparkle.framework/Versions/B/Sparkle`
- `ls dist/VibePulse.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/` shows `Downloader.xpc` and `Installer.xpc`

Run those verification commands to confirm.

- [ ] **Step 4: Test signed build locally (if signing identity available)**

Run: `SIGN_IDENTITY="Developer ID Application: ..." scripts/build_dmg.sh v0.0.0-test`
Expected: `codesign --verify --deep --strict --verbose=2` passes with `valid on disk` output.

- [ ] **Step 5: Clean up test build**

Run: `rm -rf dist/`

- [ ] **Step 6: Commit**

```bash
git add scripts/build_dmg.sh
git commit -m "Embed Sparkle framework with rpath rewrite and per-component signing"
```

---

### Task 6: Create generate_appcast.sh

**Files:**
- Create: `scripts/generate_appcast.sh`

- [ ] **Step 1: Write the script**

```bash
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
SPARKLE_FW=$(find "$BUILD_DIR/artifacts" -type d \
  -path '*macos-arm64_x86_64/Sparkle.framework' | head -1)
SIGN_UPDATE="$SPARKLE_FW/Versions/B/Resources/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: sign_update not found at $SIGN_UPDATE"
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/generate_appcast.sh`

- [ ] **Step 3: Verify the script parses without syntax errors**

Run: `bash -n scripts/generate_appcast.sh`
Expected: No output (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add scripts/generate_appcast.sh
git commit -m "Add generate_appcast.sh for EdDSA-signed Sparkle feed"
```

---

### Task 7: Update release_local.sh — three-phase draft-then-publish

**Files:**
- Modify: `scripts/release_local.sh`

- [ ] **Step 1: Replace the release publication section**

Replace everything in `scripts/release_local.sh` from `if ! command -v gh` through `echo "Release published: $VERSION_RAW"` (lines 41–52) with:

```bash
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) not found. Install it to publish the release."
  exit 1
fi

# Phase 1: create or update draft release with DMG
if gh release view "$VERSION_RAW" >/dev/null 2>&1; then
  gh release upload "$VERSION_RAW" "$DMG_PATH" --clobber
else
  gh release create "$VERSION_RAW" "$DMG_PATH" \
    --generate-notes --draft
fi

# Phase 2: generate and attach appcast
"$ROOT_DIR/scripts/generate_appcast.sh" "$VERSION_RAW"
gh release upload "$VERSION_RAW" \
  "$ROOT_DIR/dist/appcast.xml" --clobber

# Phase 3: publish the draft
gh release edit "$VERSION_RAW" --draft=false 2>/dev/null || true

echo "Release published: $VERSION_RAW"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/release_local.sh`
Expected: No output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/release_local.sh
git commit -m "Update release_local.sh with three-phase draft-then-publish"
```

---

### Task 8: Update release.yml — three-phase workflow with appcast

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Replace the full release.yml content**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-macos:
    name: Build Signed DMG
    runs-on: macos-15
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd  # v6.0.2
        with:
          persist-credentials: false
          fetch-depth: 0

      - name: Import signing certificate
        env:
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
        run: |
          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain"
          KEYCHAIN_PASS="$(openssl rand -base64 32)"

          security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

          CERT_PATH="$RUNNER_TEMP/certificate.p12"
          echo "$APPLE_CERTIFICATE" | base64 -d > "$CERT_PATH"
          security import "$CERT_PATH" \
            -k "$KEYCHAIN_PATH" \
            -P "$APPLE_CERTIFICATE_PASSWORD" \
            -T /usr/bin/codesign \
            -T /usr/bin/security
          rm -f "$CERT_PATH"

          security set-key-partition-list \
            -S apple-tool:,apple: \
            -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
          security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain

      - name: Write API key
        env:
          APPLE_API_KEY_CONTENT: ${{ secrets.APPLE_API_KEY_CONTENT }}
          APPLE_API_KEY: ${{ secrets.APPLE_API_KEY }}
        run: |
          KEY_DIR="$RUNNER_TEMP/apple-keys"
          mkdir -p "$KEY_DIR"
          echo "$APPLE_API_KEY_CONTENT" | base64 -d \
            > "$KEY_DIR/AuthKey_${APPLE_API_KEY}.p8"
          echo "APPLE_API_KEY_PATH=$KEY_DIR/AuthKey_${APPLE_API_KEY}.p8" \
            >> "$GITHUB_ENV"

      - name: Build signed DMG
        env:
          SIGN_IDENTITY: ${{ secrets.APPLE_SIGNING_IDENTITY }}
        run: scripts/build_dmg.sh "${{ github.ref_name }}"

      - name: Notarize DMG
        env:
          APPLE_API_KEY: ${{ secrets.APPLE_API_KEY }}
          APPLE_API_ISSUER: ${{ secrets.APPLE_API_ISSUER }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          DMG_PATH="dist/VibePulse-${VERSION}.dmg"

          xcrun notarytool submit "$DMG_PATH" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY" \
            --issuer "$APPLE_API_ISSUER" \
            --wait

          xcrun stapler staple "$DMG_PATH"
          xcrun stapler validate "$DMG_PATH"

      - name: Verify notarization
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          DMG_PATH="dist/VibePulse-${VERSION}.dmg"

          MOUNT_PATH="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" \
            | awk '/\/Volumes\// {print $NF; exit}')"
          spctl --assess --type execute --verbose "$MOUNT_PATH/VibePulse.app"
          hdiutil detach "$MOUNT_PATH"

      - name: Generate checksums
        run: |
          cd dist
          shasum -a 256 *.dmg > SHA256SUMS
          cat SHA256SUMS

      # Phase 1: Create draft release with DMG + checksums
      - name: Upload to draft GitHub Release
        uses: softprops/action-gh-release@153bb8e04406b158c6c84fc1615b65b24149a1fe  # v2.6.1
        with:
          draft: true
          generate_release_notes: true
          files: |
            dist/*.dmg
            dist/SHA256SUMS

      # Phase 2: Generate and attach appcast
      - name: Write Sparkle EdDSA key
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          SPARKLE_KEY_PATH="$RUNNER_TEMP/sparkle-ed-key.txt"
          echo "$SPARKLE_ED_PRIVATE_KEY" > "$SPARKLE_KEY_PATH"
          echo "SPARKLE_KEY_PATH=$SPARKLE_KEY_PATH" >> "$GITHUB_ENV"

      - name: Generate appcast
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: scripts/generate_appcast.sh "${{ github.ref_name }}"

      - name: Upload appcast to release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release upload "${{ github.ref_name }}" \
            dist/appcast.xml --clobber

      # Phase 3: Publish the draft
      - name: Publish release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release edit "${{ github.ref_name }}" --draft=false

      - name: Cleanup signing secrets
        if: always()
        run: |
          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain"
          security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
          rm -rf "$RUNNER_TEMP/apple-keys" 2>/dev/null || true
          rm -f "$RUNNER_TEMP/sparkle-ed-key.txt" 2>/dev/null || true
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
Expected: No output (valid YAML).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Update release workflow with three-phase Sparkle appcast"
```

---

### Task 9: Generate EdDSA keypair and set secrets

**Files:**
- Modify: `scripts/build_dmg.sh` (replace `__SPARKLE_ED_PUBLIC_KEY__` placeholder)

This task requires the user to run interactive commands. The implementer should present these as instructions, not execute them silently.

- [ ] **Step 1: Locate generate_keys**

Run: `find .build/artifacts -name generate_keys -type f | head -1`
Expected: Path to `Sparkle.framework/Versions/B/Resources/generate_keys`.

- [ ] **Step 2: Generate the keypair**

Run the `generate_keys` tool found in step 1. It stores the private key in the login Keychain and prints the base64 public key to stdout. Copy the public key output.

```bash
$(find .build/artifacts -name generate_keys -type f | head -1)
```

- [ ] **Step 3: Replace the placeholder in build_dmg.sh**

Replace `__SPARKLE_ED_PUBLIC_KEY__` in `scripts/build_dmg.sh` with the base64 public key string printed in step 2.

- [ ] **Step 4: Extract private key and set GitHub secret**

```bash
security find-generic-password \
  -s "https://sparkle-project.org" -w \
  > /tmp/sparkle-ed-private.txt

gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/sparkle-ed-private.txt

cp /tmp/sparkle-ed-private.txt \
  ~/code/agentsview-release-secrets/sparkle-ed-private.txt

rm /tmp/sparkle-ed-private.txt
```

- [ ] **Step 5: Verify the secret was set**

Run: `gh secret list | grep SPARKLE`
Expected: `SPARKLE_ED_PRIVATE_KEY` appears in the list.

- [ ] **Step 6: Commit the public key**

```bash
git add scripts/build_dmg.sh
git commit -m "Set Sparkle EdDSA public key in Info.plist"
```

---

### Task 10: Update docs/github-actions-release.md

**Files:**
- Modify: `docs/github-actions-release.md`

- [ ] **Step 1: Add Sparkle EdDSA key section**

Add a new section `## 3. Sparkle EdDSA Key (update signing)` after the existing section 2 in `docs/github-actions-release.md`:

```markdown
## 3. Sparkle EdDSA Key (update signing)

Sparkle uses an Ed25519 keypair to verify that downloaded updates were
produced by the same developer. The private key signs each release's DMG
via `sign_update`; the public key is embedded in the app's `Info.plist`.

### One-time setup

1. Build VibePulse so the Sparkle framework is available:
   ```bash
   swift build
   ```

2. Generate the keypair:
   ```bash
   $(find .build/artifacts -name generate_keys -type f | head -1)
   ```
   The tool stores the private key in the login Keychain and prints the
   base64 public key to stdout.

3. Extract the private key and upload to GitHub:
   ```bash
   security find-generic-password \
     -s "https://sparkle-project.org" -w \
     | gh secret set SPARKLE_ED_PRIVATE_KEY
   ```

4. Back up the private key alongside the Apple credentials:
   ```bash
   security find-generic-password \
     -s "https://sparkle-project.org" -w \
     > ~/code/agentsview-release-secrets/sparkle-ed-private.txt
   ```

### Secret

| Secret                    | Value                              |
| ------------------------- | ---------------------------------- |
| `SPARKLE_ED_PRIVATE_KEY`  | Ed25519 private key (base64, ~90 chars) |

### Key rotation

See `docs/superpowers/specs/2026-04-13-sparkle-auto-updates-design.md`,
section "Key rotation" for the planned-rotation and compromised-key
recovery procedures.
```

- [ ] **Step 2: Update the secrets table in "Setting the secrets" section**

Add `SPARKLE_ED_PRIVATE_KEY` to the `gh secret set` example block and update the expected count from six to seven.

- [ ] **Step 3: Commit**

```bash
git add docs/github-actions-release.md
git commit -m "Document SPARKLE_ED_PRIVATE_KEY secret and key rotation"
```

---

### Task 11: Local smoke test — full build + appcast dry-run

This task verifies the complete pipeline locally before pushing.

- [ ] **Step 1: Full unsigned build**

Run: `SIGN_IDENTITY="" scripts/build_dmg.sh v0.0.0-test`
Expected:
- `Sparkle rpath verified.` printed
- `dist/VibePulse-0.0.0-test.dmg` created

- [ ] **Step 2: Verify framework embedding**

Run: `ls dist/VibePulse.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/`
Expected: `Downloader.xpc` and `Installer.xpc`

- [ ] **Step 3: Verify rpath**

Run: `otool -L dist/VibePulse.app/Contents/MacOS/VibePulse | grep Sparkle`
Expected: `@rpath/Sparkle.framework/Versions/B/Sparkle`

Run: `otool -l dist/VibePulse.app/Contents/MacOS/VibePulse | grep -A2 LC_RPATH`
Expected: Contains `@executable_path/../Frameworks`

- [ ] **Step 4: Appcast dry-run**

Create a stub release-notes file and run the appcast generator:

```bash
echo "Test release notes" > /tmp/stub-notes.md
APPCAST_RELEASE_BODY_FILE=/tmp/stub-notes.md \
  scripts/generate_appcast.sh v0.0.0-test
```

Expected: `Generated dist/appcast.xml` printed.

- [ ] **Step 5: Validate appcast XML**

Run: `xmllint --noout dist/appcast.xml && grep -c 'sparkle:edSignature' dist/appcast.xml`
Expected: No xmllint errors, count = `1`.

- [ ] **Step 6: Cold-start smoke test**

Open `dist/VibePulse.app` by double-clicking it in Finder. The app should launch and show its menubar icon. If it crashes with a "library not loaded" dyld error, the rpath rewrite is broken — go back to Task 5.

- [ ] **Step 7: Verify "Check for Updates…" button appears**

Click the menubar icon. The popover should show a "Check for Updates…" button in the controls row. Clicking it will show an error (no real feed exists yet) — that is expected.

- [ ] **Step 8: Clean up**

```bash
rm -rf dist/ /tmp/stub-notes.md
```

---

### Task 12: Push and cut first Sparkle-enabled release

- [ ] **Step 1: Push the branch and merge**

Push the feature branch, create a PR, merge to `main`.

- [ ] **Step 2: Tag and push**

```bash
git tag -a v0.3.0 -m "Release v0.3.0 — Sparkle auto-updates"
git push origin v0.3.0
```

- [ ] **Step 3: Watch the release workflow**

Run: `gh run watch --exit-status`
Expected: All steps pass. Release page shows DMG, SHA256SUMS, and `appcast.xml` as assets. The release is NOT a draft (Phase 3 published it).

- [ ] **Step 4: Verify appcast from the release**

Run: `curl -sL https://github.com/wesm/vibepulse/releases/latest/download/appcast.xml | xmllint --noout -`
Expected: Valid XML, no errors.

- [ ] **Step 5: Install v0.3.0 locally**

Download the DMG from the release, install VibePulse. This is the first Sparkle-enabled version. Users on v0.2.0 must install this one manually.

---

### Task 13: End-to-end update test (v0.3.0 → v0.3.1)

- [ ] **Step 1: Make a trivial change**

Any visible change — e.g., update `AppInfo.currentYear` or tweak a label.

- [ ] **Step 2: Commit, tag, push**

```bash
git commit -am "Bump for updater validation"
git tag -a v0.3.1 -m "Release v0.3.1"
git push origin main v0.3.1
```

- [ ] **Step 3: Wait for release workflow to complete**

Run: `gh run watch --exit-status`

- [ ] **Step 4: Test the updater**

With v0.3.0 installed, click "Check for Updates…" in the menubar popover. Sparkle should show its update dialog with the v0.3.1 release notes. Click "Install Update". The app should download the DMG, verify signatures, replace itself, and relaunch as v0.3.1. Verify the version in Settings → About.

- [ ] **Step 5: Mark feature as validated**

If v0.3.0 → v0.3.1 succeeds, the Sparkle integration is complete.
