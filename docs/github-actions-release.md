# GitHub Actions release setup

This doc covers the one-time setup for the `.github/workflows/release.yml`
workflow that builds, signs, and notarizes VibePulse DMGs on `v*` tag pushes.

For the local release flow (`scripts/release_local.sh`), see
[`scripts/RELEASE.md`](../scripts/RELEASE.md).

## Overview

The workflow triggers on `v*` tag pushes and produces:

- Signed + notarized `VibePulse-<version>.dmg`
- `SHA256SUMS`
- A GitHub Release with both files attached

Two credential sets are needed, both tied to an Apple Developer account:

| Credential set                  | Purpose      |
| ------------------------------- | ------------ |
| Apple Developer certificate     | Code signing |
| Apple App Store Connect API key | Notarization |

VibePulse does not use an updater, so there is no signing-key equivalent to
Tauri's updater key.

## 1. Apple Developer Certificate (code signing)

Code signing proves the app was built by a known developer. macOS Gatekeeper
blocks unsigned apps. The workflow imports the certificate into a temporary
keychain, signs the `.app` bundle, then deletes the keychain.

### Prerequisites

- Apple Developer Program membership ($99/year — required for "Developer ID"
  certificates)
- A Mac with Keychain Access

### Step 1: Create a Certificate Signing Request

1. Open **Keychain Access** (`/Applications/Utilities/`)
1. Menu bar: **Keychain Access > Certificate Assistant > Request a Certificate
   from a Certificate Authority...**
1. Fill in:
   - **User Email Address**: your Apple ID email
   - **Common Name**: your name
   - **CA Email Address**: leave blank
   - Select **Saved to disk**
1. Save the `.certSigningRequest` file

### Step 2: Create the certificate on Apple's portal

1. Go to
   [developer.apple.com/account/resources/certificates/list](https://developer.apple.com/account/resources/certificates/list)
1. Click **+**
1. Under "Software", select **Developer ID Application** (not "Mac App
   Distribution" or "Apple Development")
1. Upload the `.certSigningRequest` file
1. Download the `.cer` and double-click it to install into Keychain Access

### Step 3: Export as .p12

1. In Keychain Access, select **login** keychain > **My Certificates**
1. Right-click `Developer ID Application: Your Name (TEAMID)` > **Export**
1. Format: **Personal Information Exchange (.p12)**
1. Set a strong password (needed for `APPLE_CERTIFICATE_PASSWORD`)

Base64-encode the `.p12`:

```bash
base64 -i Developer_ID_Application.p12 | pbcopy
```

This entire string becomes the `APPLE_CERTIFICATE` secret.

### Step 4: Find your signing identity

```bash
security find-identity -v -p codesigning
```

Expected output:

```
1) <SHA1> "Developer ID Application: Your Name (TEAMID)"
```

The quoted string is `APPLE_SIGNING_IDENTITY`.

### Secrets

| Secret                       | Value                                              |
| ---------------------------- | -------------------------------------------------- |
| `APPLE_CERTIFICATE`          | Base64-encoded `.p12` (3000–5000 chars)            |
| `APPLE_CERTIFICATE_PASSWORD` | Password from step 3                               |
| `APPLE_SIGNING_IDENTITY`     | `Developer ID Application: Your Name (TEAMID)`     |

## 2. Apple App Store Connect API Key (notarization)

Notarization sends the signed app to Apple for automated malware scanning.
After approval (1–5 minutes), macOS trusts the app as checked by Apple. The
workflow uses an App Store Connect API key to authenticate with `notarytool`.

### Step 1: Create the API key

1. Go to
   [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api)
1. Note the **Issuer ID** (UUID at the top of the page) → `APPLE_API_ISSUER`
1. Click **Generate API Key** (or **+**)
1. Name: `VibePulse Notarization`
1. Access: **Developer** (minimum role for notarization)
1. Click **Generate**

### Step 2: Download the key

**Download the `.p8` file immediately.** Apple only lets you download it once.
If you lose it, revoke and create a new key.

File is named `AuthKey_XXXXXXXXXX.p8` where `XXXXXXXXXX` is the Key ID →
`APPLE_API_KEY`.

### Step 3: Base64-encode

```bash
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

This becomes `APPLE_API_KEY_CONTENT`.

### Secrets

| Secret                  | Value                                  |
| ----------------------- | -------------------------------------- |
| `APPLE_API_KEY_CONTENT` | Base64-encoded `.p8` (~400 chars)      |
| `APPLE_API_KEY`         | Key ID (10 chars, e.g. `ABC123DEF0`)   |
| `APPLE_API_ISSUER`      | Issuer UUID from the API keys page     |

## Setting the secrets

Use `gh secret set` from the repo root. The command reads the value from stdin
so it never appears in shell history:

```bash
# Paste base64 when prompted, then Ctrl-D
gh secret set APPLE_CERTIFICATE

echo -n 'your-p12-password' | gh secret set APPLE_CERTIFICATE_PASSWORD
echo -n 'Developer ID Application: Your Name (TEAMID)' | gh secret set APPLE_SIGNING_IDENTITY

gh secret set APPLE_API_KEY_CONTENT   # paste base64, Ctrl-D
echo -n 'ABC123DEF0'                       | gh secret set APPLE_API_KEY
echo -n 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' | gh secret set APPLE_API_ISSUER
```

Verify:

```bash
gh secret list
```

Expected: six rows with the names above.

## Triggering a release

1. Merge the workflow to `main` (or tag on a branch that contains
   `.github/workflows/release.yml`).
1. Tag and push:
   ```bash
   git tag -a v0.2.0 -m "Release v0.2.0"
   git push origin v0.2.0
   ```
1. Watch the run: `gh run watch` or
   [actions page](https://github.com/wesm/vibepulse/actions/workflows/release.yml).
1. On success, the release appears at
   [Releases](https://github.com/wesm/vibepulse/releases) with the DMG and
   `SHA256SUMS` attached.

## Key rotation

### Rotate the certificate

Developer ID Application certs are valid for 5 years.

1. Generate a new cert (steps 1–3 above)
1. Re-export and base64-encode the `.p12`
1. Update `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, and
   `APPLE_SIGNING_IDENTITY` (if the identity changed)
1. Revoke the old cert in the Apple Developer portal after confirming new
   builds work

### Rotate the API key

API keys don't expire but can be revoked.

1. Generate a new key in App Store Connect
1. Base64-encode the new `.p8`
1. Update `APPLE_API_KEY_CONTENT` and `APPLE_API_KEY`
1. `APPLE_API_ISSUER` does not change (it's per-organization)
1. Revoke the old key

## Troubleshooting

### "no identity found" / "Developer ID Application not found"

- `APPLE_SIGNING_IDENTITY` must match `security find-identity` exactly,
  including the Team ID in parentheses.
- Certificate type must be **Developer ID Application**, not "Mac Developer"
  or "Apple Development".
- When exporting the `.p12`, export from **My Certificates** (bundles the
  private key), not from **Certificates** (public only).

### "errSecInternalComponent" / "User interaction is not allowed"

`APPLE_CERTIFICATE_PASSWORD` does not match the password used when exporting
the `.p12`. Re-export and update the secret.

### "invalid credentials" during notarization

Check each value independently:

1. Is `APPLE_API_KEY` the 10-char Key ID, not the Issuer UUID?
1. Is `APPLE_API_ISSUER` the UUID, not the Key ID?
1. Decode `APPLE_API_KEY_CONTENT` and confirm it looks like a PEM private key:
   ```bash
   gh secret set APPLE_API_KEY_CONTENT < /tmp/check.p8   # only re-set if corrupt
   ```
1. If the original `.p8` is lost, revoke the key and create a new one — Apple
   only allows one download per key.

### "package is invalid" / "signature is invalid"

App was signed with the wrong certificate type (must be Developer ID
Application), or the DMG was modified after signing. Re-run the workflow.
