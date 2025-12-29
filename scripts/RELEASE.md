# Local release (signed + notarized)

This project ships releases locally to avoid CI/CD credentials.

## Prerequisites

- Developer ID Application certificate (created in Xcode).
- Notary API key stored in Keychain via `notarytool` (you already did this).
- GitHub CLI (`gh`) authenticated for publishing.

## One-time setup

1. Confirm your signing identity:

```bash
security find-identity -v -p codesigning
```

Look for `Developer ID Application: ... (TEAMID)`.

2. Store notarization credentials (if not already done):

```bash
xcrun notarytool store-credentials "VibePulseNotary" \
  --key /path/to/AuthKey_XXXX.p8 \
  --key-id YOUR_KEY_ID \
  --issuer YOUR_ISSUER_ID
```

## Release flow (signed + notarized + GitHub)

1. Create a tag:

```bash
git tag -a v0.1.0 -m "Release v0.1.0"
```

2. Run the local release script:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="VibePulseNotary" \
scripts/release_local.sh v0.1.0
```

This will:
- build the app bundle
- sign it (Hardened Runtime)
- create a DMG
- notarize + staple the DMG
- publish a GitHub release via `gh`

## Build + notarize without publishing

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
scripts/build_dmg.sh v0.1.0

NOTARY_PROFILE="VibePulseNotary" \
scripts/notarize_dmg.sh dist/VibePulse-0.1.0.dmg
```

## Troubleshooting

- If codesign fails, verify the exact signing identity name and that the cert is in the login keychain.
- If notarization fails, open the log URL from `notarytool` for details.
- If stapling fails, verify that notarization succeeded and the DMG is not in a sandboxed location.
