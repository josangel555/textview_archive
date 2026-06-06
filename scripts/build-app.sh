#!/usr/bin/env bash
# Assemble dist/MarkdownViewer.app from the swift-built executable + Info.plist.
# Usage: bash scripts/build-app.sh [debug|release] [--install]   (default: debug)
#
# `--install` chains scripts/install-app.sh after a successful build so the
# fresh bundle replaces /Applications/TextView.app (the copy you actually
# launch). Without it the build lands in dist/ only — a common gotcha where a
# rebuild "doesn't show" a new feature because the running app is the stale
# /Applications copy.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

CONFIG="debug"
DO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install)     DO_INSTALL=1 ;;
    *) echo "Error: unknown arg '$arg' (expected debug|release|--install)" >&2; exit 2 ;;
  esac
done

# The on-disk bundle is named TextView.app — Finder/Dock/Spotlight
# show this filename, ignoring CFBundleName. The executable inside
# keeps the SwiftPM target name MarkdownViewer so we don't have to
# rename the build product; CFBundleExecutable in Info.plist points
# to it. The bundle identifier (com.markdownviewer.MarkdownViewer)
# stays constant so TCC grants survive the rename.
APP_NAME="TextView"
EXEC_NAME="MarkdownViewer"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

# Build the Rust core staticlib + cbindgen header FIRST. SwiftPM links
# libmdvcore_ffi.a (the RustCore target's -L rust-core/link), so the .a and the
# generated header must exist before any `swift build`. The Rust core backs the
# CSV viewer behind the RustCSVGate feature flag (default OFF — the shipping
# default keeps the Swift CSVParser). build-rust-core.sh builds the `dist`
# profile (panic=unwind, GUI-host-correct).
echo "==> bash scripts/build-rust-core.sh"
bash "$SCRIPT_DIR/build-rust-core.sh"

echo "==> swift build -c $CONFIG"
( cd "$ROOT_DIR" && swift build -c "$CONFIG" )

# SwiftPM's default `swift build` walks the executable's dep graph
# only — the lazy-grammar dynamic library products aren't reached
# that way (nothing static-links them) so we have to ask for each by
# name. Keep this list in sync with the `.library(.dynamic)` products
# in `Package.swift`. We don't iterate via package introspection
# because the cost (`swift package describe` ~3 s) isn't worth it for
# a ~ten-item allowlist that changes with reviewed commits.
LAZY_PRODUCTS=(
  TreeSitterXMLLazy
  TreeSitterPythonLazy
  TreeSitterJavaScriptLazy
  TreeSitterTypeScriptLazy
  TreeSitterBashLazy
  TreeSitterJavaLazy
  TreeSitterCLazy
  TreeSitterCPPLazy
  TreeSitterCSharpLazy
  TreeSitterRustLazy
  TreeSitterLuaLazy
)
for prod in "${LAZY_PRODUCTS[@]}"; do
  echo "==> swift build --product $prod -c $CONFIG"
  ( cd "$ROOT_DIR" && swift build -c "$CONFIG" --product "$prod" )
done

BIN_DIR="$( cd "$ROOT_DIR" && swift build -c "$CONFIG" --show-bin-path )"
BIN_PATH="$BIN_DIR/$EXEC_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: built executable not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$BIN_PATH" "$CONTENTS/MacOS/$EXEC_NAME"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Lazy-loaded TreeSitter grammar dylibs. Each is a SwiftPM `.dynamic`
# library product (see `Package.swift` for the list); the runtime
# loader (`GrammarLoader.swift`) dlopens them by basename out of
# `Contents/Frameworks/`. We deliberately glob `libTreeSitter*Lazy.dylib`
# rather than name each one — that way Phase 5 grammars (Java, C, …)
# pick up automatically once their wrapper targets land in Package.swift.
#
# `install_name_tool -id @rpath/...` fixes the dylib's own install
# name. SwiftPM emits a dylib with `install_name = libFoo.dylib`
# (relative, no @rpath), which works when the loader uses an absolute
# dlopen path — but a future caller that switches to `dlopen("libFoo.dylib")`
# bare-name would fail without an rpath-relative install name. Setting
# it now is cheap insurance.
echo "==> Copying lazy-grammar dylibs into Contents/Frameworks/"
shopt -s nullglob
DYLIB_COUNT=0
for dylib in "$BIN_DIR"/libTreeSitter*Lazy.dylib; do
  base="$(basename "$dylib")"
  cp "$dylib" "$CONTENTS/Frameworks/$base"
  /usr/bin/install_name_tool -id "@rpath/$base" "$CONTENTS/Frameworks/$base" 2>/dev/null || true
  /usr/bin/strip -x "$CONTENTS/Frameworks/$base" 2>/dev/null || true
  DYLIB_COUNT=$((DYLIB_COUNT + 1))
done
shopt -u nullglob
echo "    copied $DYLIB_COUNT grammar dylib(s)"

# NOTE: the Rust core (libmdvcore_ffi.a) is STATIC-linked into the executable
# by SwiftPM (see the RustCore target in Package.swift +
# scripts/build-rust-core.sh) — it is NOT a dylib in Contents/Frameworks/. A
# separate dylib would be smaller, but a non-platform dylib that is a load-time
# dependency of a hardened-runtime, self-signed executable is refused by dyld on
# a Team-ID mismatch. Static-linking avoids that entirely. The size cost is
# accounted for in check-bundle-size.sh's caps.

# Strip local symbols (`strip -S`). Safe for Swift: keeps global
# symbols + dyld_info; only drops the local-symbol table that
# debuggers use for static analysis. Saves ~1 MB on debug builds and
# ~3 MB on release. Note: `strip` re-applies `com.apple.FinderInfo`
# to the binary it touches, so the subsequent `ditto --noextattr`
# in the codesign block is load-bearing — without it, codesign with
# `--options runtime` refuses the bundle.
/usr/bin/strip -S "$CONTENTS/MacOS/$EXEC_NAME" 2>/dev/null || true

# Add @executable_path/../Frameworks to the executable's rpath search
# list. `GrammarLoader` currently dlopens with an absolute path, so
# this is belt-and-suspenders — but it makes the dylibs reachable by
# bare-name `dlopen("libTreeSitterXMLLazy.dylib")` too, which matches
# what a third-party plugin loader (PLUGINS_DESIGN_v2.md) would need.
# `-add_rpath` is idempotent in the sense that adding the same path
# twice fails loud; we suppress that so re-runs of build-app.sh stay
# clean.
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks \
    "$CONTENTS/MacOS/$EXEC_NAME" 2>/dev/null || true

# App icon. Committed under Resources/AppIcon.icns and regenerated by
# scripts/render-icon.swift + iconutil. If it's missing, skip silently
# rather than fail the build (the .icns gets gitignored sometimes).
ICON_SRC="$ROOT_DIR/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$CONTENTS/Resources/AppIcon.icns"
fi

# Copy SPM-generated resource bundles (one per target with resources, e.g.
# MarkdownViewer_ViewerUI.bundle containing markdown.css).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

plutil -lint "$CONTENTS/Info.plist"

# Code sign. Prefer the local self-signed identity (created by
# scripts/setup-signing.sh) over ad-hoc because TCC grants tied to a
# real signing identity survive rebuilds — ad-hoc grants don't, since
# they're keyed on the code-directory hash which changes every build.
SIGN_IDENTITY="MarkdownViewer Local Dev"
# Probe with codesign on a throwaway binary — find-identity's policy
# filter is too strict for self-signed certs even when codesign accepts
# them. The probe writes a Mach-O magic header so codesign attempts a
# real sign rather than refusing on file format alone.
SIGN_PROBE="$(mktemp -t mdv-sign-probe.XXXXXX)"
printf '\xcf\xfa\xed\xfe' > "$SIGN_PROBE"
if codesign --force --sign "$SIGN_IDENTITY" --identifier test "$SIGN_PROBE" 2>/dev/null; then
  rm -f "$SIGN_PROBE"
  HAS_LOCAL_IDENTITY=1
else
  rm -f "$SIGN_PROBE"
  HAS_LOCAL_IDENTITY=0
fi
if [[ "$HAS_LOCAL_IDENTITY" == "1" ]]; then
  echo "==> Signing with '$SIGN_IDENTITY'"
  # Strip extended attributes / Finder metadata — codesign with
  # `--options runtime` refuses bundles with stray xattrs. `xattr -cr`
  # alone won't drop `com.apple.FinderInfo`, which is protected; copy
  # via `ditto --noextattr --noacl --norsrc` to produce a clean tree,
  # then swap. chmod first because SwiftPM resource bundles ship
  # read-only. The double pass + explicit FinderInfo wipe is
  # belt-and-suspenders: `strip` (above) adds FinderInfo back to the
  # binary, and certain cp paths preserve FinderInfo on nested files.
  chmod -R u+w "$APP_DIR"
  # Clean + sign in a NON-synced TMPDIR, never a sibling of $APP_DIR. If the repo
  # lives under an iCloud/Dropbox-synced tree (e.g. ~/Documents), the file
  # provider re-stamps com.apple.FinderInfo / com.apple.fileprovider.fpfs#P onto
  # the resource bundles in REAL TIME, racing `codesign --options runtime` (which
  # rejects any detritus) — an intermittent "resource fork ... not allowed"
  # failure on an unchanged tree. /private/tmp is not file-provider-synced, so the
  # cleaned tree stays clean through the sign. (LESSONS 2026-06-06; TSK-449.)
  SIGN_TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/mdv-sign.XXXXXX")"
  SIGN_STAGE="$SIGN_TMP/$(basename "$APP_DIR")"
  ditto --norsrc --noextattr --noacl --noqtn "$APP_DIR" "$SIGN_STAGE"
  xattr -cr "$SIGN_STAGE" 2>/dev/null || true
  # Single `--deep` pass signs the executable + all nested dylibs
  # (Contents/Frameworks/*.dylib) and SwiftPM resource bundles
  # (Contents/Resources/*.bundle) in one go. We deliberately do NOT
  # pre-sign the dylibs individually: Apple's codesign stamps
  # `com.apple.FinderInfo` on every nested .bundle wrapper as a side-
  # effect when the outer pass isn't `--deep`, which then trips the
  # bundle's own no-detritus check under `--options runtime`. `--deep`
  # is on the long-term deprecation path but remains the supported
  # way to sign SwiftPM resource-bundle trees today.
  #
  # Deliberately NO `--identifier`: with `--deep`, codesign reuses one
  # signing-options set for every nested Mach-O, so an explicit
  # `--identifier` would stamp the SAME id (com.markdownviewer.MarkdownViewer)
  # onto each grammar dylib instead of a per-file id — malformed signing
  # that notarization / stricter library validation rejects at the
  # ship-public / Developer ID transition. Omitting it lets codesign
  # derive the main exec id from `Info.plist` CFBundleIdentifier and a
  # per-file id (from the filename) for each nested dylib/.bundle.
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp=none \
    "$SIGN_STAGE" >/dev/null
  # Swap the signed, clean bundle back into place. dist/ may be re-stamped by the
  # file provider afterward, but xattrs added AFTER signing neither invalidate the
  # signature nor block launch — only codesign-time --options runtime rejects them.
  rm -rf "$APP_DIR"
  ditto "$SIGN_STAGE" "$APP_DIR"
  rm -rf "$SIGN_TMP"
else
  echo "==> No local signing identity; falling back to ad-hoc"
  echo "    (TCC will re-prompt on every rebuild — fix with"
  echo "     'bash scripts/setup-signing.sh')"
  codesign --force \
    --sign - \
    --identifier "com.markdownviewer.MarkdownViewer" \
    --timestamp=none \
    "$APP_DIR" >/dev/null 2>&1 || true
fi

# Register with Launch Services so `open -a MarkdownViewer` works by name.
# Without this, only an absolute-path `open -a /path/to/App.app` works.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi

# Final size guardrail. Fails the build when the bundle goes past
# the budget — keeps us honest about TreeSitter / icon bloat.
# Defaults (in check-bundle-size.sh): 48 MB total bundle, 26 MB main
# executable. Both caps active post-lazy-grammar migration: the exec
# cap separately catches silent static-linkage regressions. The exec
# cap was bumped to 26 MB (2026-06-03) for the UX-overhaul features
# (embedded terminal/ANSI, command registry, content toolbar, find/
# replace rebuild, footer git); see check-bundle-size.sh for the full
# per-bump history.
#
# Skip on debug builds — debug binaries carry Swift reflection +
# unstripped symbols and run ~3× the release size; the cap targets
# the shippable artifact. Use `bash scripts/build-app.sh release`
# to enforce.
if [[ "$CONFIG" == "release" ]]; then
  bash "$SCRIPT_DIR/check-bundle-size.sh"
fi

# ---- PRE-INSTALL LIVE-APP SMOKE GATE ----------------------------------
# Drive the just-assembled (signed, lsregistered) bundle through the
# (file type x view mode) matrix and assert the RIGHT content rendered in
# the RIGHT view — the gap that let the fd11e61 "source won't load / Editor
# shows HEX" regression ship (every other gate asserts on model state,
# which stays self-consistent; the desync is purely in the realized view
# tree, and the WKWebView-backed Editor/Rendered modes are #192-excluded
# from the headless gate). ViewModeMatrixSmokeTests is a T4 LiveAppTestCase
# that spawns THIS dist/ bundle via --script; the window opens occluded
# (MDV_BACKGROUND=1, set inside AppLauncher) so it never steals focus.
#
# Placement is deliberate: AFTER sign + size check (so the smoke drives the
# shippable artifact exactly as a user launches it) and BEFORE the "Built"
# banner (so a failed smoke aborts via `set -e` and we never report a
# usable bundle for a broken build).
#
# `env -u MDV_HEADLESS_GATE` is load-bearing: LaunchHarness.isAppBuilt
# returns false when MDV_HEADLESS_GATE=1, which would make the T4 suite
# self-skip — a silent false-green. Unsetting it lets the suite actually
# run against the freshly built dist/.
#
# Opt-out for the fast inner debug loop: MDV_SKIP_SMOKE_GATE=1. The gate is
# ALWAYS enforced on `release` (the artifact that gets installed) — the
# opt-out only applies to debug rebuilds.
#
# The runner ALWAYS compiles in debug, regardless of $CONFIG: it spawns the
# already-assembled (release) dist/ bundle as an external process via
# --script, so the runner's own optimization level is irrelevant to what
# ships. Forcing `-c release` here re-broke the build, because the
# #if-DEBUG test-support hooks (e.g. TreeSitterEngine._jsonLanguagePointer-
# ForTesting, deliberately kept out of the release symbol table) make the
# TEST target uncompilable in release. Debug is the config the test target
# is known-good in; the dist/ under test is still the real release artifact.
# OWNER DIRECTIVE (2026-06-06): NO UI tests on the Mac — UI/live-tier
# validation runs on the UTM VM only. The pre-install ViewModeMatrix smoke
# SPAWNS the app on the host (a live UI test), so it is now OPT-IN
# (`MDV_RUN_SMOKE_GATE=1`) instead of default-on. The default build/install
# path never opens a window on the Mac. Run UI validation via the VM
# (`ssh macOS15 'cd markdown_viewer && swift test …'` / `vm-smoke.sh`).
if [[ "${MDV_RUN_SMOKE_GATE:-0}" == "1" ]]; then
  echo "==> Pre-install live-app smoke gate (ViewModeMatrixSmokeTests, debug runner)"
  if ! ( cd "$ROOT_DIR" && env -u MDV_HEADLESS_GATE \
           swift test \
             --filter 'ViewerUITests.ViewModeMatrixSmokeTests' ); then
    echo "ERROR: pre-install smoke gate FAILED — refusing to report a" >&2
    echo "       usable bundle. Bundle left at $APP_DIR for triage." >&2
    exit 7
  fi
fi

echo "==> Built $APP_DIR"
echo
echo "Open a file with it (any of these work):"
echo "  open -a TextView DESIGN.md                   # name lookup (after lsregister)"
echo "  open -a \"$APP_DIR\" DESIGN.md"
echo "  open DESIGN.md -a \"$APP_DIR\""
echo
echo "Right-click a .md file in Finder → Open With → TextView"

# --install: push the fresh bundle to /Applications/TextView.app (the copy the
# user launches). install-app.sh replaces the running instance so the new build
# takes effect on next open. Without this, `build-app.sh` only updates dist/ and
# the installed app stays stale (the "rebuild didn't show my change" gotcha).
if [[ "$DO_INSTALL" == "1" ]]; then
  echo
  echo "==> --install: bash scripts/install-app.sh"
  bash "$SCRIPT_DIR/install-app.sh"
fi
