#!/usr/bin/env bash
# vm-uitest.sh — PROGRAMMATIC visual-UI validation on the macOS15 VM (TSK-492).
#
# Replaces "spawn over SSH + screencapture" (whose windows macOS 15 redacts to
# blank) with a LaunchAgent that runs the capture INSIDE the VM's Aqua session,
# where the WindowServer hands over real pixels. Eval is a dense-saturated-block
# check (scripts/vm-uitest/aqua-runner.sh) → deterministic PASS/FAIL, no human
# eyeballing (owner directive 2026-06-07: screenshots don't scale).
#
# Subcommands:
#   setup            ONE-TIME, OWNER-AUTHORIZED: rsync, install + bootstrap the
#                    LaunchAgent into gui/<uid>. After this the owner must grant
#                    Screen Recording to the agent ONCE on the VM (see below).
#   run <scene>      Sync the runner, kickstart the agent for <scene>, poll for
#                    the result, copy the PNG + result back, print PASS/FAIL.
#   teardown         Bootout + remove the LaunchAgent (clean uninstall).
#
# One-time Screen-Recording grant (macOS 15, on the VM GUI, owner action):
#   System Settings → Privacy & Security → Screen Recording → enable the entry
#   that appears the first time the agent runs `screencapture` (it will be
#   `bash`/the agent). If none appears, add `/bin/bash`. Then `run` again.
#
# Why setup needs the owner: installing/bootstrapping a LaunchAgent is a
# persistence change on a shared VM, and the TCC grant is a GUI action — both
# are the owner's to authorize. The agent scripts are committed so setup is a
# single authorized step.
set -uo pipefail

HOST="${MDV_VM_HOST:-macOS15}"
GUI_UID="${MDV_VM_GUI_UID:-501}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.markdownviewer.uitest"
REMOTE_HOME_CMD='echo $HOME'

# Per-scene SEMANTIC expectation (TSK-492/640): the SwiftUI view a11y ids that
# MUST appear in the out-of-process AX tree (`<scene>.ax`) for the scene's UI to
# have actually rendered. Proven viable — the AX walk surfaces `mdv.*`
# accessibilityIdentifier values (e.g. mdv.terminal.pane, mdv.lspRename.panel),
# not just AppKit menu selectors. This is the authoritative PASS/FAIL for
# OVERLAY/sheet scenes, where the legacy dense-saturated-block pixel eval (tuned
# for the terminal tab strip) false-passes on an unrelated accent chip. The
# `.png` is still captured every run for visual corroboration; per CLAUDE.md a
# frame-targeted pixel-visibility assertion (needs a frame-aware ax-reader) is a
# follow-up — AX-presence is the regression guard for "the element stopped
# rendering", the most likely regression.
scene_expect() {
  case "$1" in
    lsp-rename) echo "mdv.lspRename.panel" ;;
    code-actions) echo "mdv.codeActions.panel" ;;
    folder-only) echo "mdv.statusBar mdv.emptyState.newFile mdv.emptyState.recentRow" ;;
    metadata-checksum) echo "mdv.metadata.checksumAlgorithm" ;;
    video-unsupported) echo "mdv.video.fallbackCard" ;;
    archive-preview) echo "mdv.archive.browser" ;;
    notebook) echo "mdv.notebook.cellList" ;;
    depgraph) echo "mdv.depgraph.canvas" ;;
    outline) echo "mdv.markdownOutline" ;;
    favorites) echo "mdv.terminalFavorites.editor" ;;
    monitor-rootmissing|monitor-sessions) echo "mdv.claudeMonitor" ;;
    secrets) echo "mdv.secretBanner" ;;
    omni) echo "mdv.emptyState.omni" ;;
    structural-search) echo "mdv.structuralSearch.examplesButton" ;;
    terminal-header) echo "mdv.terminal.header" ;;
    # 2026-08-11: the right-of-content AX void CLOSED once the .contain
    # chain (rails + dock headers + terminal pane) shipped in the built
    # app — a later mktg-split dump surfaced 235 ids incl. mdv.rail.right.*
    # (the first FAIL was evaluated against a stale build). Real AX
    # expectations restored:
    terminal-dock-right) echo "mdv.dock.right.terminal.header mdv.terminal.pane" ;;
    # I-19 (per-tab split preview): the split pane inside the tab.
    mktg-split) echo "mdv.split" ;;
    # I-21 S3 (editor panes): per-pane strips + the focused-pane marker
    # (the marker rides the strip id — pane-column container ids don't
    # materialize out-of-process).
    # Per-pane strips + focused marker + the PER-PANE ContentToolbar (the
    # window bar stands down while split — owner 2026-08-11). NOTE
    # mdv.pane.resize is deliberately NOT expected: the shapes-only gutter
    # never materializes an out-of-process AX element (bare id /
    # .accessibilityElement / .contain / label+trait all pruned — BACKLOG
    # "gutter AX materialization"); the divider is covered by PaneResizeTests
    # + the weighted-render pixel check instead.
    panes-split) echo "mdv.paneStrip mdv.paneStrip.focused mdv.pane.close mdv.contentToolbar mdv.viewModeControl" ;;
    panes-down) echo "mdv.paneStrip mdv.paneStrip.focused mdv.pane.close mdv.contentToolbar mdv.viewModeControl" ;;
    # The owner-bug repro: the SESSION strip must coexist with the split.
    panes-sessions) echo "mdv.sessionTabBar mdv.paneStrip mdv.paneStrip.focused" ;;
    # Owner 2026-08-29: the unsaved-delta viewer must mount its list + mode picker + restore.
    history-unsaved) echo "mdv.history.versionList mdv.history.modePicker mdv.history.restore" ;;
    # Sidebar-fill scenes (owner 2026-08-09): the PNG is the visual fill
    # proof; the a11y gate pins the right panel actually mounted. Without
    # these they fell through to the TERMINAL dense-chip pixel eval, which
    # is meaningless here (false-passed on stray accent chips, 2026-08-12).
    # The crowded shoulder: every one of the 5 forced panels must mount
    # (the PNG is the every-panel-IN-VIEW proof — eyeball it).
    fill-check-crowded) echo "mdv.bookmarks mdv.searchAnywhere mdv.gitPanel mdv.recentlyOpened mdv.lspOutline mdv.sidebar" ;;
    fill-check-git) echo "mdv.gitPanel" ;;
    fill-check-bookmarks) echo "mdv.bookmarks" ;;
    fill-check-recents) echo "mdv.recentlyOpened" ;;
    recover-deleted) echo "mdv.recover.sheet" ;;
    first-run) echo "mdv.content" ;;
    lsp-status) echo "mdv.statusBar" ;;
    git-panel) echo "mdv.git.statusTab" ;;
    *) echo "" ;;
  esac
}

# Per-scene WINDOW-COLOR expectation (TSK-641): for scenes whose subject is a
# COLOR (chrome theming), a11y-presence can't prove it — the chrome IS present;
# the question is whether it PAINTED the theme. Returns "<mode> <min-fraction>":
# `dark` asserts ≥ min-fraction of window pixels are dark (luminance < 80). The
# VM is in system LIGHT mode, so a dark theme flips the window predominantly
# dark — a clean discriminator (the light default fails the same threshold). The
# only validator for the CHROME surface (the stale-chrome / non-republishing
# class) — host tests prove Palette consults the theme; this proves it paints.
scene_color() {
  case "$1" in
    theme-dark) echo "dark 0.35" ;;
    *) echo "" ;;
  esac
}

rsync_tree() {
  rsync -az --delete \
    --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/' \
    --exclude='.git/objects/pack/' \
    "$ROOT/" "$HOST:markdown_viewer/"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  setup)
    echo "==> rsync tree to $HOST"
    rsync_tree
    HOME_DIR="$(ssh "$HOST" "$REMOTE_HOME_CMD")"
    echo "==> install LaunchAgent plist (HOME=$HOME_DIR)"
    sed "s#__HOME__#$HOME_DIR#g" \
      "$ROOT/scripts/vm-uitest/com.markdownviewer.uitest.plist.template" \
      | ssh "$HOST" "mkdir -p ~/.mdv-uitest ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/$LABEL.plist"
    echo "==> bootstrap into gui/$GUI_UID"
    ssh "$HOST" "launchctl bootstrap gui/$GUI_UID ~/Library/LaunchAgents/$LABEL.plist 2>&1 || launchctl enable gui/$GUI_UID/$LABEL"
    echo "==> done. Build dist on the VM (scripts/test-in-vm.sh or build-app) then:"
    echo "    bash scripts/vm-uitest.sh run terminal-paneright"
    echo "    (first run: grant Screen Recording to the agent on the VM GUI)"
    ;;
  run)
    scene="${1:-terminal-paneright}"
    echo "==> sync runner + kickstart '$scene' on $HOST (gui/$GUI_UID)"
    rsync_tree
    ssh "$HOST" "mkdir -p ~/.mdv-uitest; printf '%s' '$scene' > ~/.mdv-uitest/scene; rm -f ~/.mdv-uitest/done ~/.mdv-uitest/$scene.result; launchctl kickstart -k gui/$GUI_UID/$LABEL"
    echo "==> poll for completion (≤30s)"
    ok=""
    for _ in $(seq 1 60); do
      if ssh "$HOST" "test -f ~/.mdv-uitest/done" 2>/dev/null; then ok=1; break; fi
      sleep 0.5
    done
    [ -n "$ok" ] || { echo "FAIL: agent didn't finish (not bootstrapped? run setup)"; exit 3; }
    mkdir -p /tmp/mdv-vm-ui
    ssh "$HOST" "cat ~/.mdv-uitest/$scene.result" | tee "/tmp/mdv-vm-ui/$scene.result"
    scp -q "$HOST:.mdv-uitest/$scene.png" "/tmp/mdv-vm-ui/$scene.png" 2>/dev/null || true
    scp -q "$HOST:.mdv-uitest/$scene.ax" "/tmp/mdv-vm-ui/$scene.ax" 2>/dev/null || true
    if [ -s "/tmp/mdv-vm-ui/$scene.ax" ]; then
      echo "AX identifiers (out-of-process tree read):"; sed 's/^/  /' "/tmp/mdv-vm-ui/$scene.ax"
    fi
    grep -q '^CAPTURED' "/tmp/mdv-vm-ui/$scene.result" || { echo "FAIL: agent did not capture (Screen Recording denied? see result)"; exit 4; }
    # SEMANTIC ASSERTION (overlay/sheet scenes): PASS iff every expected mdv.*
    # a11y id is present in the out-of-process AX tree — generalizes the harness
    # beyond the terminal-only dense-block pixel eval (which false-passes on an
    # unrelated accent chip for non-terminal scenes). The .png stays captured for
    # visual corroboration.
    expect="$(scene_expect "$scene")"
    if [ -n "$expect" ]; then
      [ -s "/tmp/mdv-vm-ui/$scene.ax" ] || { echo "FAIL: no AX dump for '$scene' (Accessibility denied for the reader binary?)"; exit 6; }
      missing=""
      for id in $expect; do
        grep -qxF "$id" "/tmp/mdv-vm-ui/$scene.ax" || missing="$missing $id"
      done
      if [ -n "$missing" ]; then
        echo "FAIL: expected a11y id(s) absent from the AX tree:$missing -> /tmp/mdv-vm-ui/$scene.png"; exit 6
      fi
      echo "PASS (a11y): expected ids present [$expect] -> /tmp/mdv-vm-ui/$scene.png"; exit 0
    fi
    # WINDOW-COLOR ASSERTION (chrome theming scenes): PASS iff the window's dark
    # fraction meets the threshold — the only proof the CHROME surface painted
    # the theme (a11y can't see color). Prints the measured fraction either way.
    color="$(scene_color "$scene")"
    if [ -n "$color" ]; then
      set -- $color; mode="$1"; minfrac="$2"
      python3 - "/tmp/mdv-vm-ui/$scene.png" "$mode" "$minfrac" <<'PY'
import sys
from PIL import Image
png, mode, minfrac = sys.argv[1], sys.argv[2], float(sys.argv[3])
im = Image.open(png).convert("RGB"); W, H = im.size; px = im.load()
# Two regions, both fractional (resolution-independent): the LEFT SIDEBAR strip
# (CHROME surface — Palette.textBackground → ChromeTheme.current, TSK-641) AND
# the CENTER CONTENT band (the rendered-markdown reading page — TSK-815 made it
# theme-driven; before that it followed SYSTEM appearance and stayed light, so
# the chrome could be dark while the content was light — measured 0.18
# whole-window). Requiring BOTH dark guards both surfaces: a regression in
# either (chrome non-republish, or the markdown page-CSS override) drops its
# region's fraction below threshold and FAILs.
def dark_fraction(x0f, x1f, y0f, y1f):
    d = t = 0
    for y in range(int(H * y0f), int(H * y1f), 3):
        for x in range(int(W * x0f), int(W * x1f), 3):
            r, g, b = px[x, y]
            t += 1
            if 0.299 * r + 0.587 * g + 0.114 * b < 80: d += 1
    return d / t if t else 0.0
sidebar = dark_fraction(0.0, 0.18, 0.12, 0.95)
content = dark_fraction(0.30, 0.75, 0.20, 0.85)
if mode == "dark":
    ok = sidebar >= minfrac and content >= minfrac
else:
    ok = sidebar <= (1 - minfrac) and content <= (1 - minfrac)
print(f"color-eval scene mode={mode} sidebar_dark={sidebar:.3f} content_dark={content:.3f} threshold={minfrac} pass={ok}")
sys.exit(0 if ok else 7)
PY
      rc=$?
      [ $rc -eq 0 ] && { echo "PASS (color): window matches '$mode' -> /tmp/mdv-vm-ui/$scene.png"; exit 0; } \
                    || { echo "FAIL($rc): window does NOT match '$mode' -> /tmp/mdv-vm-ui/$scene.png"; exit 1; }
    fi
    # PIXEL EVAL on the HOST (has Pillow; the VM doesn't). A dense saturated
    # (accent-chip) block anywhere in the window-minus-status-bar band proves
    # the terminal tab strip composited — works for any dock edge.
    python3 - "/tmp/mdv-vm-ui/$scene.png" "$scene" <<'PY'
import sys
from PIL import Image
png, scene = sys.argv[1], sys.argv[2]
im = Image.open(png).convert("RGB"); W, H = im.size; px = im.load()
def sat(x, y):
    r, g, b = px[x, y]; return (max(r, g, b) - min(r, g, b)) > 90
def dense(cx, cy):
    tot = s = 0
    for dy in range(-16, 17, 4):
        for dx in range(-16, 17, 4):
            x, y = cx + dx, cy + dy
            if 0 <= x < W and 0 <= y < H:
                tot += 1
                if sat(x, y): s += 1
    return tot > 0 and s / tot >= 0.6
found = None
for y in range(int(H * 0.10), H - 50, 4):
    for x in range(0, W, 4):
        if sat(x, y) and dense(x, y): found = (x, y); break
    if found: break
print(f"eval scene={scene} size={W}x{H} dense_chip_block={found is not None} loc={found}")
sys.exit(0 if found else 5)
PY
    rc=$?
    [ $rc -eq 0 ] && { echo "PASS -> /tmp/mdv-vm-ui/$scene.png"; exit 0; } || { echo "FAIL($rc) -> /tmp/mdv-vm-ui/$scene.png"; exit 1; }
    ;;
  teardown)
    ssh "$HOST" "launchctl bootout gui/$GUI_UID/$LABEL 2>/dev/null; rm -f ~/Library/LaunchAgents/$LABEL.plist"
    echo "==> removed $LABEL"
    ;;
  *)
    echo "usage: vm-uitest.sh {setup|run <scene>|teardown}"; exit 2;;
esac
