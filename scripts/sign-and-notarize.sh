#!/usr/bin/env bash
# Sign and notarize MarkdownViewer for distribution.
#
# Usage:
#   bash scripts/sign-and-notarize.sh
#
# Requires (one-time setup):
#   1. A Developer ID Application certificate in the local keychain.
#      Get one from developer.apple.com → Certificates, Identifiers &
#      Profiles → Certificates → "+", "Developer ID Application". Download
#      and double-click to install into login keychain.
#
#   2. An app-specific password for notarytool, stored in keychain:
#         xcrun notarytool store-credentials "MV_NOTARY" \
#           --apple-id "you@example.com" \
#           --team-id "ABCDE12345" \
#           --password "xxxx-xxxx-xxxx-xxxx"     # app-specific password
#      App-specific passwords: appleid.apple.com → Sign-In and Security
#      → App-Specific Passwords → Generate Password.
#
#   3. Environment variables (or edit defaults below):
#         export MV_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#         export MV_NOTARY_PROFILE="MV_NOTARY"
#
# This script:
#   - swift build -c release
#   - assembles a fresh .app at dist/MarkdownViewer.app
#   - signs every framework / dylib / executable inside (deep)
#   - signs the .app with hardened runtime + the entitlements file
#   - submits to Apple's notary service via notarytool, polls until done
#   - staples the notarization ticket back onto the .app
#   - emits a zip at dist/MarkdownViewer-<version>.zip for distribution
#
# On error: nothing is uploaded; the .app remains ad-hoc-signed locally.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

APP_DIR="$ROOT_DIR/dist/MarkdownViewer.app"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# Read configuration with safe defaults that fail loud.
SIGN_IDENTITY="${MV_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MV_NOTARY_PROFILE:-MV_NOTARY}"

log() { printf "==> %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Try to auto-discover. The keychain should have at most one
  # Developer ID Application cert.
  candidate="$(security find-identity -v -p codesigning | \
               awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [[ -n "$candidate" ]]; then
    SIGN_IDENTITY="$candidate"
    log "auto-detected signing identity: $SIGN_IDENTITY"
  else
    die "No Developer ID Application identity found.
Set MV_SIGN_IDENTITY=\"Developer ID Application: ...\" and re-run.
List candidates: security find-identity -v -p codesigning"
  fi
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "notarytool profile '$NOTARY_PROFILE' not found.
Set up once:
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
    --apple-id you@example.com --team-id ABCDE12345 \\
    --password app-specific-password"
fi

[[ -f "$ENTITLEMENTS" ]] || die "entitlements.plist missing at $ENTITLEMENTS"

# -----------------------------------------------------------------------------
# Build release + assemble
# -----------------------------------------------------------------------------
log "swift build -c release"
swift build -c release

log "assembling .app bundle (release)"
bash "$SCRIPT_DIR/build-app.sh" release

# -----------------------------------------------------------------------------
# Deep sign: every inner Mach-O, then the bundle.
# `--options runtime` enables hardened runtime (REQUIRED for notarization).
# `--timestamp` requests a secure timestamp from Apple (REQUIRED).
# -----------------------------------------------------------------------------
log "signing inner executables / dylibs / frameworks"
# Find every Mach-O file in the bundle (excluding the main exec) and sign.
while IFS= read -r -d '' file; do
  if file "$file" 2>/dev/null | grep -q Mach-O; then
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      --entitlements "$ENTITLEMENTS" \
      "$file" 2>/dev/null || true
  fi
done < <(find "$APP_DIR" -type f -print0)

log "signing the .app bundle"
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --deep \
  "$APP_DIR"

log "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR" || \
  log "(spctl assessment will fail until after notarization & stapling)"

# -----------------------------------------------------------------------------
# Notarize: zip → submit → poll → staple.
# -----------------------------------------------------------------------------
VERSION="$(plutil -extract CFBundleShortVersionString raw \
            -o - "$APP_DIR/Contents/Info.plist")"
SUBMIT_ZIP="$ROOT_DIR/dist/MarkdownViewer-submit-$VERSION.zip"
DIST_ZIP="$ROOT_DIR/dist/MarkdownViewer-$VERSION.zip"
rm -f "$SUBMIT_ZIP" "$DIST_ZIP"

log "creating submission zip"
( cd "$ROOT_DIR/dist" && ditto -c -k --sequesterRsrc --keepParent \
    "MarkdownViewer.app" "$SUBMIT_ZIP" )

log "submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

log "stapling notarization ticket onto the .app"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

log "creating final distribution zip"
( cd "$ROOT_DIR/dist" && ditto -c -k --sequesterRsrc --keepParent \
    "MarkdownViewer.app" "$DIST_ZIP" )
rm -f "$SUBMIT_ZIP"

log "done → $DIST_ZIP"
log "verify on a clean Mac: spctl --assess --type execute --verbose ./MarkdownViewer.app"
