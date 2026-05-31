#!/usr/bin/env bash
# Assemble dist/MarkdownViewer.app from the swift-built executable + Info.plist.
# Usage: bash scripts/build-app.sh [debug|release]   (default: debug)
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "Error: config must be 'debug' or 'release', got '$CONFIG'" >&2; exit 2 ;;
esac

# The on-disk bundle is named TextView.app — Finder/Dock/Spotlight
# show this filename, ignoring CFBundleName. The executable inside
# keeps the SwiftPM target name MarkdownViewer so we don't have to
# rename the build product; CFBundleExecutable in Info.plist points
# to it. The bundle identifier (com.markdownviewer.MarkdownViewer)
# stays constant so TCC grants survive the rename.
APP_NAME="TextView"
EXEC_NAME="MarkdownViewer"
# Bundle identifier stays constant so TCC + LaunchServices grants
# survive the on-disk rename. Single source of truth: used as the main
# bundle's signing identity AND as the prefix for per-dylib identifiers.
BUNDLE_ID="com.markdownviewer.MarkdownViewer"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

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
# Remove any *other* .app left in dist/ (e.g. a stale MarkdownViewer.app
# from before the TextView rename). Two same-bundle-id apps in dist/
# make Launch Services pick one nondeterministically, so `open -a` and
# the Finder "Open With" entry can resolve to the wrong, stale binary.
# Only TextView.app should live here. Also drop a stray .DS_Store so it
# never sneaks into a signed/zipped artifact.
shopt -s nullglob
for other in "$DIST_DIR"/*.app; do
  [[ "$other" == "$APP_DIR" ]] && continue
  echo "    removing stale bundle: $other"
  rm -rf "$other"
done
shopt -u nullglob
rm -f "$DIST_DIR/.DS_Store"
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
#
# BR-08: the glob below copies bundles in filesystem-glob order, and the
# copy preserves mtimes. This bundle is intentionally NOT bit-for-bit
# reproducible — codesign embeds timestamps + per-build CDHashes anyway,
# so iteration order does not affect correctness. If reproducibility is
# ever needed, sort the glob and honor SOURCE_DATE_EPOCH before copying.
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
  TMP_CLEAN="${APP_DIR}.clean.$$"
  ditto --norsrc --noextattr --noacl --noqtn "$APP_DIR" "$TMP_CLEAN"
  rm -rf "$APP_DIR"
  mv "$TMP_CLEAN" "$APP_DIR"
  # Final sweep: recursive `xattr -dr` for FinderInfo. The xargs/find
  # combo silently failed for the root bundle path (xargs's quoting +
  # xattr exit codes don't play well together); `xattr -dr` does it
  # in one call and is idempotent.
  xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
  # Sign inside-out with *distinct* identifiers per nested Mach-O.
  #
  # A single `--deep --identifier com.markdownviewer.MarkdownViewer`
  # pass stamps that ONE identifier onto every nested dylib too — so
  # libTreeSitterXMLLazy.dylib and libTreeSitterPythonLazy.dylib end up
  # sharing the app's identifier. codesign(1) calls signing distinct
  # programs with the same identifier "a very bad idea": it breaks the
  # library-validation pairing of code-directory-hash to identifier and
  # is a notarization smell. So we derive a unique identifier per dylib
  # from its basename instead.
  #
  # Order is load-bearing — codesign requires nested code to be signed
  # before the enclosing bundle: (1) Frameworks dylibs, (2) SwiftPM
  # resource bundles, (3) the outer .app last.
  #
  # The resource `.bundle` wrappers are signed with their own `--deep`
  # (no explicit --identifier; each derives one from its own Info.plist
  # CFBundleIdentifier). We re-wipe `com.apple.FinderInfo` immediately
  # before the final non-deep outer pass: codesign can re-stamp it on
  # nested .bundle wrappers as a side-effect, and `--options runtime`
  # rejects a bundle carrying stray FinderInfo.

  # (1) Inner dylibs — each with a derived, unique identifier.
  shopt -s nullglob
  for dylib in "$CONTENTS/Frameworks"/*.dylib; do
    dybase="$(basename "$dylib" .dylib)"
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --identifier "$BUNDLE_ID.$dybase" \
      --options runtime \
      --timestamp=none \
      "$dylib" >/dev/null
  done

  # (2) SwiftPM resource bundles — own identifier from their Info.plist.
  for resbundle in "$CONTENTS/Resources"/*.bundle; do
    codesign --force --deep \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp=none \
      "$resbundle" >/dev/null
  done
  shopt -u nullglob

  # (3) Outer bundle — NOT --deep (inner code already signed above), so
  # the app's identifier never leaks onto the nested dylibs.
  xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --timestamp=none \
    "$APP_DIR" >/dev/null

  # Confirm the inside-out signature validates as a unit before we hand
  # the bundle off (lsregister / install / notarize).
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1 \
    || { echo "Error: codesign --verify --deep --strict failed on $APP_DIR" >&2; exit 1; }
else
  echo "==> No local signing identity; falling back to ad-hoc"
  echo "    (TCC will re-prompt on every rebuild — fix with"
  echo "     'bash scripts/setup-signing.sh')"
  codesign --force \
    --sign - \
    --identifier "$BUNDLE_ID" \
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
# Defaults (in check-bundle-size.sh): 37 MB total bundle, 16 MB main
# executable. Both caps active post-lazy-grammar migration: the exec
# cap separately catches silent static-linkage regressions. Caps were
# bumped 35→37 / 15→16 when the CodeMirror 6 editor landed (~570 KB
# JS resource + ~200 KB Swift wrapper code).
#
# Skip on debug builds — debug binaries carry Swift reflection +
# unstripped symbols and run ~3× the release size; the cap targets
# the shippable artifact. Use `bash scripts/build-app.sh release`
# to enforce.
if [[ "$CONFIG" == "release" ]]; then
  bash "$SCRIPT_DIR/check-bundle-size.sh"
fi

echo "==> Built $APP_DIR"
echo
echo "Open a file with it (any of these work):"
echo "  open -a TextView DESIGN.md                   # name lookup (after lsregister)"
echo "  open -a \"$APP_DIR\" DESIGN.md"
echo "  open DESIGN.md -a \"$APP_DIR\""
echo
echo "Right-click a .md file in Finder → Open With → TextView"
