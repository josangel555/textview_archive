#!/usr/bin/env bash
# Install dist/MarkdownViewer.app to /Applications so it's available
# from Spotlight, Launchpad, the Dock, and Finder's Open With menu.
# Optionally make it the default handler for common file types.
#
# Usage:
#   bash scripts/install-app.sh           # install only
#   bash scripts/install-app.sh --default # install + set as default for .md and code types
#
# Why /Applications instead of dist/: LaunchServices ranks apps in
# system locations higher; macOS treats apps in dist/ folders inside
# user home as transient. Installing also fixes the "can't find it in
# Spotlight" UX.
#
# TCC re-prompt note: once you've run scripts/setup-signing.sh, the
# app is signed with a stable self-signed cert and TCC grants survive
# rebuilds. If you skipped that script, every rebuild gets a new
# code-directory hash and TCC re-prompts forever — run setup-signing.sh
# to fix.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

SRC_APP="$ROOT_DIR/dist/TextView.app"
DEST_APP="/Applications/TextView.app"
LEGACY_DEST="/Applications/MarkdownViewer.app"

if [[ ! -d "$SRC_APP" ]]; then
  echo "Error: $SRC_APP not found. Run scripts/build-app.sh release first." >&2
  exit 1
fi

echo "==> Installing $SRC_APP → $DEST_APP"
# Kill any running instance so we can replace its on-disk bundle.
# The executable inside the bundle is still named MarkdownViewer (the
# SwiftPM target name) regardless of the .app filename — killall hits
# it by process name.
/usr/bin/killall MarkdownViewer 2>/dev/null || true
sleep 0.3
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"
# Sweep up the pre-rename bundle so Spotlight + Open With don't show
# two entries with the same identifier.
if [[ -d "$LEGACY_DEST" ]]; then
  echo "==> Removing legacy $LEGACY_DEST"
  rm -rf "$LEGACY_DEST"
fi

# Re-register with LaunchServices at the new path so `open -a
# MarkdownViewer` and Finder's Open With menu pick it up.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "==> Installed."
echo
echo "Open via:"
echo "  - Spotlight: ⌘Space, type 'MarkdownViewer'"
echo "  - Finder: drag any file onto /Applications/MarkdownViewer.app"
echo "  - Right-click a file → Open With → MarkdownViewer"
echo "  - Make it the default for .md:"
echo "    right-click a .md file → Get Info → 'Open with' → MarkdownViewer → Change All…"

# Optional: --default flag flips the default handler for common
# document UTIs to us. Uses `duti` if installed; otherwise prints a
# command for the user to run.
if [[ "${1:-}" == "--default" ]]; then
  if command -v duti >/dev/null 2>&1; then
    echo
    echo "==> Setting MarkdownViewer as default handler for common types…"
    for uti in \
        net.daringfireball.markdown \
        public.markdown \
        public.swift-source \
        public.json \
        public.python-script \
        public.shell-script \
        public.xml \
        public.yaml; do
      duti -s com.markdownviewer.MarkdownViewer "$uti" all 2>/dev/null || true
    done
    echo "Done. Reverting requires re-setting the default per type."
  else
    echo
    echo "==> --default requested but 'duti' isn't installed."
    echo "Install: brew install duti"
    echo "Or just set defaults manually via Finder → Get Info."
  fi
fi

echo
echo "If you keep getting permission prompts on every rebuild:"
echo "  1. Run once: bash scripts/setup-signing.sh"
echo "  2. Rebuild: bash scripts/build-app.sh && bash scripts/install-app.sh"
echo "  3. Approve the TCC prompts ONE more time (signing identity changed)."
echo "  After that, future rebuilds preserve the grant."
