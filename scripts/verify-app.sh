#!/usr/bin/env bash
# Validates the structure and Info.plist content of dist/MarkdownViewer.app.
# Run after scripts/build-app.sh.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
APP_DIR="$ROOT_DIR/dist/MarkdownViewer.app"
INFO="$APP_DIR/Contents/Info.plist"

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
require_key LSMinimumSystemVersion "14.0"
require_key NSPrincipalClass     "NSApplication"
require_key CFBundleVersion
require_key CFBundleShortVersionString
require_key LSApplicationCategoryType

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

# Resource bundles (SPM-generated .bundle dirs for targets with resources).
res_bundle="$APP_DIR/Contents/Resources/MarkdownViewer_ViewerUI.bundle"
[[ -d "$res_bundle" ]] || fail "ViewerUI resource bundle missing at $res_bundle"
pass "ViewerUI resource bundle present"

[[ -f "$res_bundle/markdown.css" ]] || fail "markdown.css not in resource bundle"
pass "markdown.css present in resource bundle"

echo
echo "==> All bundle checks passed"
