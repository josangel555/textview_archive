#!/usr/bin/env bash
# Install dist/TextView.app to /Applications so it's available
# from Spotlight, Launchpad, the Dock, and Finder's Open With menu.
# NOTE: the app's user-facing name is "TextView" (CFBundleName /
# CFBundleDisplayName / the on-disk bundle are all TextView.app); only the
# bundle identifier + executable keep the legacy "MarkdownViewer" token.
# All user-facing guidance below MUST say TextView — never MarkdownViewer.
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
# Do NOT kill a running instance. The installed app and this bundle share the
# executable name `MarkdownViewer` (the SwiftPM target name), so a blanket
# `killall MarkdownViewer` terminates the user's OWN running app on EVERY
# install — the footgun that kept closing the owner's /Applications app on each
# `build-app.sh --install`. macOS lets us replace the bundle while it runs (the
# live process holds the old inode); the new code is picked up on the user's
# next manual relaunch. No killall, no surprise quits.
rm -rf "$DEST_APP"
# `ditto --noextattr` (not `cp -R`) so any com.apple.FinderInfo /
# com.apple.fileprovider.fpfs#P the iCloud file provider stamped onto dist/
# (the repo lives under ~/Documents) does NOT ride into /Applications. Those
# xattrs don't break launch but DO trip `codesign --verify --strict`. Stripping
# them on the copy keeps the installed bundle clean; /Applications isn't
# file-provider-synced, so nothing re-adds them. The code signature lives in
# file contents (_CodeSignature + Mach-O), not xattrs, so it survives. (TSK-449)
ditto --noextattr --noqtn "$SRC_APP" "$DEST_APP"
# Belt-and-suspenders: even with --noextattr, a FinderInfo xattr can land on the
# destination bundle root (observed when dist/ lives under iCloud). /Applications
# is not file-provider-synced, so clearing here sticks and makes the installed
# bundle pass `codesign --verify --strict` (xattrs don't break launch, but keep
# it clean). The signature lives in file contents, so this is signature-safe.
xattr -cr "$DEST_APP" 2>/dev/null || true
# Sweep up the pre-rename bundle so Spotlight + Open With don't show
# two entries with the same identifier.
if [[ -d "$LEGACY_DEST" ]]; then
  echo "==> Removing legacy $LEGACY_DEST"
  rm -rf "$LEGACY_DEST"
fi

# Re-register with LaunchServices at the new path so `open -a
# TextView` and Finder's Open With menu pick it up.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "==> Installed."
echo
echo "Open via:"
echo "  - Spotlight: ⌘Space, type 'TextView'"
echo "  - Finder: drag any file onto /Applications/TextView.app"
echo "  - Right-click a file → Open With → TextView"
echo "  - Make it the default for .md:"
echo "    right-click a .md file → Get Info → 'Open with' → TextView → Change All…"

# Optional: --default flag flips the default handler for common
# document UTIs to us. Uses `duti` if installed; otherwise prints a
# command for the user to run.
if [[ "${1:-}" == "--default" ]]; then
  if command -v duti >/dev/null 2>&1; then
    echo
    echo "==> Setting TextView as default handler for common types…"
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

# TSK-1536: opt-in CLI symlink — `install-app.sh --with-cli` links the mdv
# opener into /usr/local/bin (sudo only if the dir isn't writable).
for arg in "$@"; do
  if [ "$arg" = "--with-cli" ]; then
    CLI_SRC="$(cd "$(dirname "$0")" && pwd)/mdv"
    CLI_DST="/usr/local/bin/mdv"
    if [ -w "$(dirname "$CLI_DST")" ]; then
      ln -sf "$CLI_SRC" "$CLI_DST"
    else
      sudo ln -sf "$CLI_SRC" "$CLI_DST"
    fi
    echo "==> mdv CLI linked: $CLI_DST → $CLI_SRC  (try: mdv --help)"
  fi
done

# TSK-1553 (daemon s1): opt-in LaunchAgent — `install-app.sh --with-daemon`
# installs the mdv-serve socket-activation plist. launchd owns the 0600
# per-user socket and spawns the daemon on first connect. The template's
# __HOME__ is substituted here because launchd does NOT expand ~ in
# SockPathName.
for arg in "$@"; do
  if [ "$arg" = "--with-daemon" ]; then
    PLIST_SRC="$SCRIPT_DIR/com.markdownviewer.mdv-serve.plist.template"
    PLIST_DST="$HOME/Library/LaunchAgents/com.markdownviewer.mdv-serve.plist"
    DAEMON_BIN="$DEST_APP/Contents/MacOS/mdv-serve"
    if [ ! -x "$DAEMON_BIN" ]; then
      echo "==> --with-daemon: $DAEMON_BIN not present in the installed bundle" >&2
      echo "    (the mdv-serve bundle embed is a separate slice). Skipping." >&2
      continue
    fi
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
    plutil -lint "$PLIST_DST"
    echo "==> Daemon agent installed: $PLIST_DST"
    echo "    Activate now: launchctl bootstrap gui/$(id -u) $PLIST_DST"
    echo "    (or it activates on next login; the daemon spawns on first connect)"
  fi
done

echo
echo "If you keep getting permission prompts on every rebuild:"
echo "  1. Run once: bash scripts/setup-signing.sh"
echo "  2. Rebuild: bash scripts/build-app.sh && bash scripts/install-app.sh"
echo "  3. Approve the TCC prompts ONE more time (signing identity changed)."
echo "  After that, future rebuilds preserve the grant."
