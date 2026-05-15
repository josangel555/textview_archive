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
# TCC re-prompt note: ad-hoc-signed apps get a new code-directory hash
# on every rebuild, so macOS treats consecutive rebuilds as different
# apps. The cleanest workaround is the FDA grant: once installed,
# System Settings → Privacy & Security → Full Disk Access → add
# /Applications/MarkdownViewer.app. That grant survives rebuilds as
# long as the identifier (com.markdownviewer.MarkdownViewer) stays
# the same. Real Developer ID signing is the proper fix (Phase 9).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

SRC_APP="$ROOT_DIR/dist/MarkdownViewer.app"
DEST_APP="/Applications/MarkdownViewer.app"

if [[ ! -d "$SRC_APP" ]]; then
  echo "Error: $SRC_APP not found. Run scripts/build-app.sh release first." >&2
  exit 1
fi

echo "==> Installing $SRC_APP → $DEST_APP"
# Kill any running instance so we can replace its on-disk bundle.
/usr/bin/killall MarkdownViewer 2>/dev/null || true
sleep 0.3
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"

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
echo "If you keep getting permission prompts:"
echo "  1. System Settings → Privacy & Security → Full Disk Access"
echo "  2. + → Applications → MarkdownViewer → enable"
echo "  This survives most rebuilds. Real Developer ID signing (Phase 9)"
echo "  eliminates the issue entirely."
