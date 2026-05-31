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
#   - assembles a fresh .app at dist/TextView.app (via build-app.sh)
#   - signs each inner dylib individually with a derived identifier, the
#     SwiftPM resource bundles, then the .app last (hardened runtime)
#   - signs ONLY the outer .app with the entitlements file
#   - submits to Apple's notary service via notarytool, polls until done
#   - staples the notarization ticket back onto the .app
#   - emits a zip at dist/TextView-<version>.zip for distribution
#
# On error: nothing is uploaded; the .app remains ad-hoc-signed locally.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# The on-disk bundle is named TextView.app (see build-app.sh). Keep the
# name in one variable so the build, sign, notarize, staple, and zip
# steps all reference the same artifact.
APP_NAME="TextView"
BUNDLE_ID="com.markdownviewer.MarkdownViewer"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
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

# build-app.sh removes other *.app in dist/, but be explicit: a stale
# dist/MarkdownViewer.app (pre-rename) must never reach notarization —
# it would ship an unsigned-by-this-pass bundle under the same id.
rm -rf "$DIST_DIR/MarkdownViewer.app"
[[ -d "$APP_DIR" ]] || die "expected assembled bundle at $APP_DIR"

# -----------------------------------------------------------------------------
# Sign inside-out: each inner Mach-O first, then the bundle.
# `--options runtime` enables hardened runtime (REQUIRED for notarization).
# `--timestamp` requests a secure timestamp from Apple (REQUIRED).
#
# Two rules this block enforces that the old single-deep pass violated:
#   1. Entitlements belong ONLY on the main app's signature, not on every
#      nested dylib. Stamping the entitlements file onto each inner Mach-O
#      grants those libraries entitlements they have no business carrying
#      and is a notarization red flag (SIGN-06).
#   2. No `|| true` / `2>/dev/null` swallowing — a failed inner signature
#      under set -e MUST abort the run before we upload anything (SIGN-07).
# Each inner dylib gets a unique identifier derived from its basename so
# we never ship N libraries sharing the app's identifier.
# -----------------------------------------------------------------------------
log "signing inner dylibs (Frameworks) with derived identifiers"
shopt -s nullglob
for dylib in "$APP_DIR/Contents/Frameworks"/*.dylib; do
  dybase="$(basename "$dylib" .dylib)"
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID.$dybase" \
    --options runtime \
    --timestamp \
    "$dylib"
done

log "signing SwiftPM resource bundles"
for resbundle in "$APP_DIR/Contents/Resources"/*.bundle; do
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$resbundle"
done

# Any other nested Mach-O we didn't enumerate above (defensive: helper
# tools, embedded frameworks). Exclude the main executable + the dylibs
# already signed. Still no error-swallowing.
log "signing any remaining nested Mach-O"
MAIN_EXEC="$APP_DIR/Contents/MacOS/MarkdownViewer"
while IFS= read -r -d '' f; do
  [[ "$f" == "$MAIN_EXEC" ]] && continue
  case "$f" in
    "$APP_DIR"/Contents/Frameworks/*.dylib) continue ;;
    "$APP_DIR"/Contents/Resources/*.bundle/*) continue ;;
  esac
  if file "$f" | grep -q Mach-O; then
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --identifier "$BUNDLE_ID.$(basename "$f")" \
      --options runtime \
      --timestamp \
      "$f"
  fi
done < <(find "$APP_DIR" -type f -print0)
shopt -u nullglob

log "signing the .app bundle (entitlements applied here ONLY, no --deep)"
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_DIR"

log "verifying signature (gate before submit)"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" \
  || die "codesign --verify --deep --strict failed; not submitting"
spctl --assess --type execute --verbose "$APP_DIR" || \
  log "(spctl assessment will fail until after notarization & stapling)"

# -----------------------------------------------------------------------------
# SIGN-14: a build signed with --timestamp=none (build-app.sh's local pass)
# would be rejected by the notary service — but only after a multi-minute
# upload + poll. Catch a missing secure timestamp on the main executable
# locally, before submit, and fail fast.
# -----------------------------------------------------------------------------
log "asserting secure timestamp present (pre-submit guard)"
codesign -dvv "$APP_DIR" 2>&1 | grep -q 'Timestamp=' \
  || die "main bundle signature has no secure Timestamp= (was it signed with --timestamp=none?); aborting before notary upload"

# -----------------------------------------------------------------------------
# Notarize: zip → submit → poll → staple.
# -----------------------------------------------------------------------------
VERSION="$(plutil -extract CFBundleShortVersionString raw \
            -o - "$APP_DIR/Contents/Info.plist")"
SUBMIT_ZIP="$DIST_DIR/$APP_NAME-submit-$VERSION.zip"
DIST_ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"
rm -f "$SUBMIT_ZIP" "$DIST_ZIP"

log "creating submission zip"
( cd "$DIST_DIR" && ditto -c -k --sequesterRsrc --keepParent \
    "$APP_NAME.app" "$SUBMIT_ZIP" )

log "submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

log "stapling notarization ticket onto the .app"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

log "creating final distribution zip"
( cd "$DIST_DIR" && ditto -c -k --sequesterRsrc --keepParent \
    "$APP_NAME.app" "$DIST_ZIP" )
rm -f "$SUBMIT_ZIP"

log "done → $DIST_ZIP"
log "verify on a clean Mac: spctl --assess --type execute --verbose ./$APP_NAME.app"
