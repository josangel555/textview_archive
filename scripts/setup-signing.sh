#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate in the
# user's login keychain so build-app.sh can sign MarkdownViewer with a
# stable identity instead of ad-hoc.
#
# Why this matters for daily-driver use:
#   Ad-hoc signed apps get a new code-directory hash on every build,
#   and macOS TCC (the Privacy & Security subsystem) keys ad-hoc grants
#   off the cdhash. So Full Disk Access / Documents / Downloads grants
#   evaporate on every rebuild — the app re-prompts forever.
#
#   With a real signing identity (even self-signed), TCC keys the grant
#   off the (identifier, cert-leaf-hash) pair. That survives rebuilds
#   indefinitely as long as the cert stays in keychain.
#
#   Real Developer ID signing (Phase 9) gives the same property plus
#   Gatekeeper acceptance for distribution. For solo daily-driver use,
#   self-signed is enough.
#
# Idempotent: if the identity already exists, exits 0 with no changes.
#
# Usage:
#   bash scripts/setup-signing.sh
set -euo pipefail

IDENTITY_CN="MarkdownViewer Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Bail early if the identity already exists.
#
# Note: `security find-identity -p codesigning` runs a strict trust
# evaluation against the cert chain — self-signed code-signing certs
# get filtered out even though `codesign` itself happily uses them.
# Probe by trying to sign a throwaway binary instead.
PROBE="$TMP_DIR/probe"
printf '\xcf\xfa\xed\xfe' > "$PROBE"  # Mach-O magic, just enough for codesign to attempt
if codesign --force --sign "$IDENTITY_CN" --identifier test "$PROBE" 2>/dev/null; then
  echo "==> '$IDENTITY_CN' already in login keychain. Nothing to do."
  echo
  echo "    Re-run scripts/build-app.sh to sign with it."
  exit 0
fi

echo "==> Creating self-signed code-signing certificate"
echo "    CN: $IDENTITY_CN"
echo "    keychain: $KEYCHAIN"
echo

# Use system LibreSSL — it's known to produce PKCS#12 bundles that
# Apple's Security framework can import without MAC algorithm
# disagreements. Homebrew OpenSSL 3.x defaults bite here even with
# -legacy + PBE-SHA1-3DES flags, depending on minor version.
OPENSSL="/usr/bin/openssl"
if [[ ! -x "$OPENSSL" ]]; then
  echo "Error: /usr/bin/openssl missing. Did you nuke /usr/bin?" >&2
  exit 1
fi

# 2. Generate key + self-signed cert with the codeSigning EKU. Without
#    that EKU, codesign refuses to use the identity. 10-year validity
#    so we don't have to think about renewal in any reasonable horizon.
KEY="$TMP_DIR/sign.key"
CRT="$TMP_DIR/sign.crt"
P12="$TMP_DIR/sign.p12"

# OpenSSL config block to set the right keyUsage/extendedKeyUsage.
# Apple's codesign tool checks for codeSigning EKU specifically.
cat > "$TMP_DIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no
[req_dn]
CN = MarkdownViewer Local Dev
[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

"$OPENSSL" req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -config "$TMP_DIR/openssl.cnf" \
  -extensions v3_req \
  -keyout "$KEY" -out "$CRT" 2>/dev/null

# 3. Bundle into PKCS#12 for keychain import.
#    Empty passphrases trip 'security import' on macOS — the framework
#    interprets the missing password as a MAC mismatch. So we set a
#    throwaway password, use it for both export and import, then move
#    on. The cert never leaves this machine.
P12_PASS="mdv-local-dev"
"$OPENSSL" pkcs12 -export \
  -inkey "$KEY" -in "$CRT" \
  -name "$IDENTITY_CN" \
  -out "$P12" -passout "pass:$P12_PASS"

# 4. Import into login keychain. -A would allow any app to use it
#    without prompting, but we'd rather scope to codesign explicitly via
#    -T below.
echo "==> Importing into login keychain"
security import "$P12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

# 5. Allow codesign to use the key without an interactive prompt every
#    time. This requires the keychain password — macOS prompts.
echo "==> Authorizing codesign to use the key (you may be prompted for"
echo "    your login password — it's the same one you log in with)"
security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -k "$(security default-keychain | tr -d '\" ')" \
  "$KEYCHAIN" >/dev/null 2>&1 || {
    # Fallback path: prompt explicitly.
    echo "    First attempt skipped a password prompt; retrying interactively…"
    security set-key-partition-list \
      -S "apple-tool:,apple:,codesign:" \
      "$KEYCHAIN"
}

echo
echo "==> Verifying by signing a probe binary"
PROBE="$TMP_DIR/verify-probe"
printf '\xcf\xfa\xed\xfe' > "$PROBE"
if codesign --force --sign "$IDENTITY_CN" --identifier test "$PROBE" 2>/dev/null; then
  echo "    ✓ '$IDENTITY_CN' is usable for codesigning."
else
  echo "    ✗ codesign failed with this identity. Aborting." >&2
  echo "    Try: open Keychain Access → login → 'My Certificates' to inspect." >&2
  exit 1
fi

cat <<EOF

==> Next steps

  1. Rebuild the app so it picks up the new signature:
       bash scripts/build-app.sh
       bash scripts/install-app.sh

  2. The first launch will re-prompt for TCC permissions (Documents /
     Downloads / etc.) once because the signing identity changed.
     Accept those prompts.

  3. After that, every future rebuild will preserve the grant — TCC
     keys it off (identifier, cert-leaf-hash), both of which now stay
     stable across rebuilds.

  4. To revert, delete the cert in Keychain Access (login keychain →
     'My Certificates' → '$IDENTITY_CN').

EOF
