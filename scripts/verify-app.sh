#!/usr/bin/env bash
# Validates the structure and Info.plist content of dist/TextView.app.
# Run after scripts/build-app.sh.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
# The on-disk bundle is TextView.app (see build-app.sh). Keep the name in
# one place so this validator and the build/sign scripts never diverge.
APP_NAME="TextView"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
INFO="$APP_DIR/Contents/Info.plist"
PACKAGE_SWIFT="$ROOT_DIR/Package.swift"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -d "$APP_DIR" ]] || fail "no app at $APP_DIR (run scripts/build-app.sh first)"
pass "app bundle exists"

[[ -x "$APP_DIR/Contents/MacOS/MarkdownViewer" ]] || fail "executable missing or not executable"
pass "executable present and executable"

[[ -f "$INFO" ]] || fail "Info.plist missing"
pass "Info.plist present"

plutil -lint "$INFO" >/dev/null
pass "Info.plist lint clean"

require_key() {
  local key="$1" expected="${2:-}"
  local value
  value="$(plutil -extract "$key" raw -o - "$INFO" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "Info.plist missing required key: $key"
  if [[ -n "$expected" && "$value" != "$expected" ]]; then
    fail "Info.plist $key = '$value', expected '$expected'"
  fi
  pass "$key = $value"
}

require_key CFBundleIdentifier   "com.markdownviewer.MarkdownViewer"
require_key CFBundleExecutable   "MarkdownViewer"
require_key CFBundlePackageType  "APPL"
require_key NSPrincipalClass     "NSApplication"
require_key CFBundleVersion
require_key CFBundleShortVersionString
require_key LSApplicationCategoryType

# SIGN-03: LSMinimumSystemVersion must not advertise a lower floor than
# the SDK the binary is compiled for. Derive the expected major from
# Package.swift's `platforms: [.macOS(.vNN)]` rather than hard-coding it,
# so this fails loudly if either side moves.
lsmsv="$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO" 2>/dev/null || true)"
[[ -n "$lsmsv" ]] || fail "Info.plist missing LSMinimumSystemVersion"
pkg_major="$(grep -oE '\.macOS\(\.v[0-9]+\)' "$PACKAGE_SWIFT" | head -1 | grep -oE '[0-9]+' || true)"
[[ -n "$pkg_major" ]] || fail "could not parse .macOS(.vNN) from $PACKAGE_SWIFT"
lsmsv_major="${lsmsv%%.*}"
if [[ "$lsmsv_major" != "$pkg_major" ]]; then
  fail "LSMinimumSystemVersion=$lsmsv (major $lsmsv_major) != Package.swift .macOS(.v$pkg_major); a lower floor lets the app launch on an OS missing symbols the binary expects"
fi
pass "LSMinimumSystemVersion = $lsmsv matches Package.swift .macOS(.v$pkg_major)"

# Document types — assert at least the markdown and plain-text entries.
plutil -extract CFBundleDocumentTypes xml1 -o - "$INFO" >/dev/null 2>&1 \
  || fail "CFBundleDocumentTypes missing"
pass "CFBundleDocumentTypes declared"

dt_xml="$(plutil -extract CFBundleDocumentTypes xml1 -o - "$INFO")"
echo "$dt_xml" | grep -q "net.daringfireball.markdown" \
  || fail "CFBundleDocumentTypes does not declare net.daringfireball.markdown"
pass "declares net.daringfireball.markdown"
echo "$dt_xml" | grep -q "public.plain-text" \
  || fail "CFBundleDocumentTypes does not declare public.plain-text"
pass "declares public.plain-text"
echo "$dt_xml" | grep -q "public.folder" \
  || fail "CFBundleDocumentTypes does not declare public.folder"
pass "declares public.folder"

# TCC usage descriptions for protected user folders — required so macOS
# stops re-prompting on every launch.
for key in NSDocumentsFolderUsageDescription NSDesktopFolderUsageDescription NSDownloadsFolderUsageDescription; do
  v="$(plutil -extract "$key" raw -o - "$INFO" 2>/dev/null || true)"
  [[ -n "$v" ]] || fail "Info.plist missing $key — privacy prompts will reappear every launch"
  pass "$key present"
done

# Resource bundles (SPM-generated .bundle dirs for targets with resources).
res_bundle="$APP_DIR/Contents/Resources/MarkdownViewer_ViewerUI.bundle"
[[ -d "$res_bundle" ]] || fail "ViewerUI resource bundle missing at $res_bundle"
pass "ViewerUI resource bundle present"

[[ -f "$res_bundle/markdown.css" ]] || fail "markdown.css not in resource bundle"
pass "markdown.css present in resource bundle"

# ---------------------------------------------------------------------------
# SIGN-13: lazy-grammar dylib count must match Package.swift.
# build-app.sh copies every libTreeSitter*Lazy.dylib SwiftPM emits into
# Contents/Frameworks/. The number that ends up there must equal the count
# of `.library(... type: .dynamic ...)` TreeSitter products declared in
# Package.swift — a mismatch means either a grammar silently failed to
# build/copy, or a new product was added without rebuilding. (We only READ
# Package.swift here; it is owned by another change set.)
# ---------------------------------------------------------------------------
shipped_dylibs=$(/usr/bin/find "$APP_DIR/Contents/Frameworks" \
  -maxdepth 1 -name 'libTreeSitter*Lazy.dylib' 2>/dev/null | wc -l | tr -d ' ')
declared_products=$(grep -cE '\.library\(name: "TreeSitter[A-Za-z0-9]+Lazy",[[:space:]]*type:[[:space:]]*\.dynamic' "$PACKAGE_SWIFT" || true)
[[ "$declared_products" -gt 0 ]] || fail "parsed 0 TreeSitter .dynamic products from $PACKAGE_SWIFT (regex drift?)"
if [[ "$shipped_dylibs" != "$declared_products" ]]; then
  fail "shipped lazy-grammar dylibs ($shipped_dylibs) != Package.swift .library(.dynamic) TreeSitter products ($declared_products); a grammar failed to build/copy or a product was added without a rebuild"
fi
pass "lazy-grammar dylib count $shipped_dylibs matches Package.swift ($declared_products products)"

# ---------------------------------------------------------------------------
# SIGN-05: signature integrity. --strict catches nested-code problems the
# default check skips; --deep walks the whole tree. We don't fail on the
# (local-dev) Authority being self-signed — just report it so a release
# build's Developer ID authority is visible in the log.
# ---------------------------------------------------------------------------
if codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>/dev/null; then
  pass "codesign --verify --deep --strict clean"
else
  fail "codesign --verify --deep --strict failed (signature is broken or nested code unsigned)"
fi

authorities=$(codesign -dvv "$APP_DIR" 2>&1 | grep '^Authority=' || true)
if [[ -n "$authorities" ]]; then
  echo "INFO: signing authorities:"
  echo "$authorities" | sed 's/^/    /'
else
  echo "INFO: no Authority lines (ad-hoc signed; expected for unsigned local builds)"
fi

echo
echo "==> All bundle checks passed"
