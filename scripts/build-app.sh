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

# TSK-813: select the newest installed Swift toolchain when one is present in
# /Library/Developer/Toolchains. The UTM VM ships swift-6.3-RELEASE there but its
# DEFAULT `swift` is 6.1.2, which hits a type-checker `<unknown>:0: error:
# circular reference` on RustCore's recursive `MsgPackValue: Equatable` during a
# clean compile (an incremental build masks it) — so a from-scratch
# `build-app.sh` on the VM failed, blocking every clean VM dist build (hence all
# VM validation). 6.3 compiles it fine. HOST-SAFE: the host has no such toolchain
# dir, so this is a no-op (uses the default swift). Mirrors test-in-vm.sh's
# select_toolchain() (the TSK-439 fix for the test target's same 6.1.2 skew).
select_toolchain() {
  local newest tcid
  # `|| true`: on the HOST the glob matches nothing, so `ls` fails → under the
  # script's `set -euo pipefail` the pipe propagates that failure and the
  # `newest=$(…)` assignment aborts the whole build BEFORE `swift build` (the
  # TSK-813 select_toolchain regressed the host build this way — the VM never
  # caught it because its glob matches). Swallow the no-match so newest="".
  newest=$(ls -d /Library/Developer/Toolchains/swift-6.*-RELEASE.xctoolchain 2>/dev/null \
             | sort -V | tail -1 || true)
  [ -n "$newest" ] && [ -f "$newest/Info.plist" ] || return 0
  tcid=$(plutil -extract CFBundleIdentifier raw "$newest/Info.plist" 2>/dev/null) || return 0
  [ -n "$tcid" ] || return 0
  export TOOLCHAINS="$tcid"
  echo "==> toolchain: $(basename "$newest") ($tcid)"
}
select_toolchain

# TSK-851: opt-in compiler-cache wiring for the TreeSitter grammar C compiles.
# When ccache/sccache is on PATH (or forced via MDV_CC_CACHE_BIN), this exports a
# CC wrapper so SwiftPM routes the ~165 MB of grammar `parser.c` compiles through
# the cache — the 2nd clean build's C phase becomes a cache hit. A host WITHOUT a
# cache tool degrades to a normal build (no-op, no hard dependency). The wrapper
# only ever touches C compiles; Swift modules go straight through `swiftc`.
# shellcheck source=lib/ccache-env.sh
source "$SCRIPT_DIR/lib/ccache-env.sh"
mdv_setup_cc_cache "$SCRIPT_DIR"
if [[ -n "${MDV_CC_CACHE:-}" ]]; then
  echo "==> C compiler cache: $MDV_CC_CACHE (CC=$CC → $MDV_CC_REAL)"
else
  echo "==> C compiler cache: none (install ccache/sccache to speed clean rebuilds)"
fi

# Offline build support (the macOS15 VM has no github): MDV_SWIFT_OFFLINE=1
# adds --disable-automatic-resolution so `swift build` uses the already-present
# .build/{checkouts,repositories} + Package.resolved instead of re-fetching
# updates from remotes (which fails on an offline host). Deps must already be
# staged; see LESSONS "Offline VM dist build recipe".
OFFLINE_FLAG=()
if [[ "${MDV_SWIFT_OFFLINE:-}" == "1" ]]; then
  OFFLINE_FLAG=(--disable-automatic-resolution)
  echo "==> offline mode: swift build ${OFFLINE_FLAG[*]}"
fi

# TSK-1547 force-relink: build-rust-core.sh normally deletes the exec product
# (via cargo) so SwiftPM relinks against the freshly-staged staticlib. On a host
# WITHOUT cargo (the offline VM uses the PRE-STAGED .a), that deletion is
# skipped — SwiftPM then sees identical objects and SKIPS the link, leaving the
# exec older than the .a, and the STALE-LINK tooth below (correctly) refuses to
# ship. Force the link edge here: if the staged .a is newer than the exec (or
# the exec is missing), delete the exec so the swift build relinks it.
_STAGED_A="$ROOT_DIR/rust-core/link/libmdvcore_ffi.a"
_EXE="$ROOT_DIR/.build/$(uname -m)-apple-macosx/$CONFIG/$EXEC_NAME"
if [[ -f "$_STAGED_A" && ( ! -f "$_EXE" || "$_STAGED_A" -nt "$_EXE" ) ]]; then
  echo "==> force-relink: removing $_EXE (staticlib newer / exec missing)"
  rm -f "$_EXE"
fi

echo "==> swift build -c $CONFIG"
# macOS ships bash 3.2, where "${empty_array[@]}" trips `set -u` ("unbound
# variable"). The `${arr[@]+"${arr[@]}"}` idiom expands to nothing when empty
# (no stray empty-string arg) and to the elements otherwise — safe on 3.2 + 4+.
( cd "$ROOT_DIR" && swift build -c "$CONFIG" ${OFFLINE_FLAG[@]+"${OFFLINE_FLAG[@]}"} )

# SwiftPM's default `swift build` walks the executable's dep graph
# only — the lazy-grammar dynamic library products aren't reached
# that way (nothing static-links them) so we have to ask for each by
# name. Keep this list in sync with the `.library(.dynamic)` products
# in `Package.swift`. We don't iterate via package introspection
# because the cost (`swift package describe` ~3 s) isn't worth it for
# a ~ten-item allowlist that changes with reviewed commits.
# TSK-854: only the grammars code-FOLDS + structural search need ship
# (highlighting is rust-only). The 8 highlight-only grammar dylibs were
# removed — ~16 MB reclaim out of Contents/Frameworks/.
LAZY_PRODUCTS=(
  TreeSitterXMLLazy
  TreeSitterJavaScriptLazy
  TreeSitterTypeScriptLazy
)
for prod in "${LAZY_PRODUCTS[@]}"; do
  echo "==> swift build --product $prod -c $CONFIG"
  ( cd "$ROOT_DIR" && swift build -c "$CONFIG" --product "$prod" ${OFFLINE_FLAG[@]+"${OFFLINE_FLAG[@]}"} )
done

BIN_DIR="$( cd "$ROOT_DIR" && swift build -c "$CONFIG" --show-bin-path ${OFFLINE_FLAG[@]+"${OFFLINE_FLAG[@]}"} )"
BIN_PATH="$BIN_DIR/$EXEC_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: built executable not found at $BIN_PATH" >&2
  exit 1
fi

# TSK-1547 freshness TOOTH: never bundle an exec older than the staged rust
# staticlib. The staged `.a`'s mtime only moves on CONTENT change (TSK-848
# cmp-gated restage), so `.a` newer than the exec means SwiftPM skipped the
# relink (the touch-based guard can't force the link edge — identical
# recompiled objects → link skipped) and the bundle would ship STALE rust
# code while reporting success. Hard fail — build-rust-core.sh's product
# deletion should make this unreachable; this guard catches any path around it.
STAGED_A="$ROOT_DIR/rust-core/link/libmdvcore_ffi.a"
if [[ -f "$STAGED_A" && "$STAGED_A" -nt "$BIN_PATH" ]]; then
  echo "Error: STALE LINK — $STAGED_A is newer than the built executable." >&2
  echo "       SwiftPM did not relink against the fresh staticlib. Delete the" >&2
  echo "       link products (rm .build/*/$CONFIG/$EXEC_NAME) and rebuild." >&2
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
# Copy ONLY the dylibs for the .dynamic TreeSitter*Lazy products DECLARED in
# Package.swift — NOT a bare glob of $BIN_DIR. A stale .build left over from a
# FORMER Package.swift (more lazy grammars) leaves orphan libTreeSitter*Lazy.dylib
# in the bin dir; globbing them ships removed grammars and trips verify-app.sh
# SIGN-13 (TSK-1235: both the host and VM .build carried 8 orphans → 11 shipped
# vs 3 declared). Deriving the allowlist from the same source verify-app.sh
# checks against keeps the bundle correct regardless of bin-dir cruft. Falls back
# to the glob if the parse finds nothing (regex-drift safety).
copy_one_dylib() {
  local src="$1" base
  base="$(basename "$src")"
  cp "$src" "$CONTENTS/Frameworks/$base"
  /usr/bin/install_name_tool -id "@rpath/$base" "$CONTENTS/Frameworks/$base" 2>/dev/null || true
  /usr/bin/strip -x "$CONTENTS/Frameworks/$base" 2>/dev/null || true
  DYLIB_COUNT=$((DYLIB_COUNT + 1))
}
DYLIB_COUNT=0
DECLARED_GRAMMARS="$(grep -oE '\.library\(name: "TreeSitter[A-Za-z0-9]+Lazy"' "$ROOT_DIR/Package.swift" 2>/dev/null \
  | grep -oE 'TreeSitter[A-Za-z0-9]+Lazy' | sort -u)"
shopt -s nullglob
if [[ -n "$DECLARED_GRAMMARS" ]]; then
  for name in $DECLARED_GRAMMARS; do
    src="$BIN_DIR/lib$name.dylib"
    if [[ -f "$src" ]]; then
      copy_one_dylib "$src"
    else
      echo "    WARN: declared grammar $name has no built dylib at $src" >&2
    fi
  done
else
  echo "    WARN: parsed 0 declared TreeSitter*Lazy products from Package.swift — falling back to glob" >&2
  for dylib in "$BIN_DIR"/libTreeSitter*Lazy.dylib; do copy_one_dylib "$dylib"; done
fi
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

# TSK-1575: the Help ▸ Capabilities page reads docs/CAPABILITIES.md from the app
# bundle (CapabilitiesDocument.markdown → Bundle.main). Copy it in so the doc
# stays the SINGLE source (dev/tests fall back to an embedded pointer).
CAPS_SRC="$ROOT_DIR/docs/CAPABILITIES.md"
if [[ -f "$CAPS_SRC" ]]; then
  cp "$CAPS_SRC" "$CONTENTS/Resources/CAPABILITIES.md"
fi

# LICENSING SHIP-BLOCKER (audit THEME 4, fixed 2026-07-29): the bundle
# redistributes MIT/Apache/BSD code (SwiftPM deps, ~47 Rust crates, Mermaid,
# CodeMirror), so the aggregated attribution file MUST ship inside it. The
# notices generator's header has claimed since day one that build-app.sh
# copies the file — this cp did not exist, so every assembled .app shipped
# with zero attribution. HARD-FAIL if the file is missing: an unattributed
# bundle is not a valid build, and the file is committed so this only fires
# if someone deletes it.
NOTICES_SRC="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
if [[ ! -f "$NOTICES_SRC" ]]; then
  echo "ERROR: THIRD_PARTY_NOTICES.md missing — cannot assemble a legally" >&2
  echo "redistributable bundle. Run scripts/gen-third-party-notices.sh." >&2
  exit 1
fi
cp "$NOTICES_SRC" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"

# Copy SPM-generated resource bundles (one per target with resources, e.g.
# MarkdownViewer_ViewerUI.bundle containing markdown.css) into Contents/Resources.
# This is the canonical, codesign-sealable, notarizable location — and where the
# Bundle.resolveResourceBundle resolver (TSK-1257) reads them from at runtime.
# (We deliberately do NOT place them at the .app ROOT, where the raw SwiftPM
# Bundle.module accessor looks: top-level resources break codesign --strict /
# notarization. The resolver bridges accessor → Contents/Resources instead.)
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

# Each SwiftPM resource bundle ships as a FLAT resource directory with NO
# Info.plist. Stamp a minimal one so it is a *real* macOS bundle — recognized
# by Bundle()/CFBundle and signed as a nested bundle by codesign on ANY machine,
# not merely a loose directory, and notarization-ready. (TSK-1257)
echo "==> Stamping Info.plist into resource bundles"
shopt -s nullglob
for bundle in "$CONTENTS/Resources"/*.bundle; do
  plist="$bundle/Info.plist"
  [[ -f "$plist" ]] && continue
  bname="$(basename "$bundle" .bundle)"
  # CFBundleIdentifier permits only alphanumerics, '-', '.'; map '_' → '-'.
  idname="${bname//_/-}"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleIdentifier</key><string>com.markdownviewer.resources.${idname}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${bname}</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist" >/dev/null
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
  # TSK-157 guard: prove the --deep pass did NOT stamp the main bundle
  # identifier onto the nested grammar dylibs (fails the build if an
  # `--identifier` is ever re-added to the deep codesign above).
  bash "$SCRIPT_DIR/check-dylib-identifiers.sh" "$APP_DIR"
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

# ---- RESOURCE PACKAGING SELF-CHECK (TSK-1257) -------------------------------
# Prove the assembled, SIGNED app resolves EVERY SwiftPM resource bundle from
# its OWN Contents/Resources — NOT the dev machine's .build (the hand-assembled
# .app's Bundle.module fallback that crashed on a clean M5-Pro at launch). This
# runs the real binary with --verify-resources, which resolves + exits BEFORE
# NSApplication is created, so it is HOST-SAFE: no window, no Dock tile, no focus
# theft (same headless contract as --mcp-stdio). It would have caught the M5-Pro
# crash at build time; a regression to plain Bundle.module fails it here.
echo "==> Resource packaging self-check (--verify-resources)"
if ! "$CONTENTS/MacOS/$EXEC_NAME" --verify-resources; then
  echo "ERROR: resource self-check FAILED — the app would crash on a clean" >&2
  echo "       machine (resources not resolvable from its own bundle)." >&2
  echo "       Bundle left at $APP_DIR for triage." >&2
  exit 8
fi

# Final size guardrail. Fails the build when the bundle goes past
# the budget — keeps us honest about TreeSitter / icon bloat.
# Defaults (in check-bundle-size.sh): 80 MB total bundle, 70 MB main
# executable. Both caps active post-lazy-grammar migration: the exec
# cap separately catches silent static-linkage regressions. The exec
# cap grew 26→44→52→60 (TSK-660 rust-grammar landings + a 2026-06-14
# headroom ask); see check-bundle-size.sh for the full per-bump history.
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
