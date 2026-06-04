# UX Overhaul backlog — 2026-06-03 (owner manual-test pass)

Tags: **[QW]** quick win · **[M]** medium · **[L]** large/architectural · **[D]** needs a decision before starting.

---

## A. View-mode + toolbar restructure [L][D]
The current "attributes bar" under the 2nd-from-top tab (wrap / special-char /
Source·Raw·Hex) is **removed**. Controls regroup into two places:

**A1. Bottom attribute toggle-button group** (move here): format/Front picker ·
Wrap · Special-char on/off · OpenAs type (drop-down/up to pick language /
"pretend to be this type").
**A2. New content-toolbar — directly above the Source/Editor pane** (NOT in the
L/R shoulder space):
- **Abbreviatable breadcrumb** (path), fully navigable (click segments to nav). [L]
- Right side: the view-mode control.
- **Rename modes to `Render | Editor | HEX` + a `ViewOnly` toggle** (drop the
  separate "Source"). `ViewOnly` default-ON for Render. **HEX gains edit
  capability gated by `ViewOnly`.** [L][D]
- **A3. OpenAs persistence** — remember the "pretend to be this type" per file. [M]
- **A4. Unify OpenAs and the file-type dropdown — one control, not two.** [M]

> **DECISION A:** confirm the view-mode model. Today: Source(raw text) / Editor
> (CM6) / Rendered / HEX / Preview / Formatted. Proposed: `Render | Editor | HEX`
> × `ViewOnly`. Where do Source(=Editor+ViewOnly?), Preview (images/pdf/sqlite),
> and Formatted (pretty-print) land? Need the full mode×type matrix nailed down.
> HEX-edit is a real new capability (byte editing + write-back).

## B. Tabs & sessions [M]
- **B1.** Session-tab row: taller, show more info (is-git-root, …). [M]
- **B2.** Move the `+` (session tabs AND file tabs) to sit beside the last tab as
  a placeholder-tab, not a disjoint icon. [M]
- **B3.** Add icons to the right of the session-tab row: Settings · File search ·
  Omni window. [M]
- **B4.** Weird separator between two tabs → full top-to-bottom divider lines; the
  gap looks wrong when one tab is active and the other isn't. [QW]

## C. Footer (git + stats + zoom) [M][D]
- **C1.** Left: git info — **[git folder name · branch/worktree]**. [M]
- **C2.** Toggle between worktrees/branches from the footer — **non-destructive**. [L][D]
- **C3.** Edit statistics beside git. [M]
- **C4.** Window zoom size + **C5.** Document zoom size (separate readouts, even
  though the controls were merged — useful for reading Markdown). [M]

> **DECISION C:** worktree/branch switching is inherently destructive to the
> working tree (a `git checkout` swaps files; uncommitted edits at risk). Define
> the intended behavior: real checkout (with dirty-guard/stash prompt) vs.
> open-the-other-worktree-in-a-new-window vs. read-only view. This is the
> riskiest item in the list.

## D. Terminal [L][D]
- **D1.** Embedded terminal at the bottom. [L]
- **D2.** Terminal toggle button on the left shoulder, bottom-aligned. [M]

> **DECISION D:** a real terminal = PTY + ANSI/VT emulation. Either vendor a dep
> (e.g. SwiftTerm — needs your minimal-deps approval) or build a minimal emulator
> (large). Confirm scope: full interactive shell vs. command-runner pane.

## E. Tool-window system (docking) [L]
- **E1. Bug:** selecting one shoulder button always opens a file — only the
  selected tool window should open. [M·bug]
- **E2.** Tool windows **draggable + snappable** to any edge: Left / Right / Main
  tab / Bottom (IDE-style docking). [L]
- **E3.** Tool windows **fixed height** (NOT content-driven) — user-controllable +
  remembered; open at a reasonable (not tiny) default. [M]
- **E4.** Resizable tool windows; **right-edge resize has no limit**. [M]
- **E5.** Resizing a tool window **flickers** — fix. [M·bug]

## F. Zoom audit [L]
- **F1.** Elements that don't scale with zoom: file-nav tree icons, Wrap, Space,
  OpenAs. [M]
- **F2.** Vertical heights not growing proportionally: tab rows, footer row,
  bookmark item rows, git rows (and likely more). [M]
- **F3.** Goal: uniform/natural zoom, zero artifacts. **Do a thorough audit of all
  zoom behavior and fix every issue.** [L]

## G. Find / replace [M]
- **G1.** Native-mac-style search / search-and-replace (replace components if
  needed). [M]
- **G2.** Highlight color: a good bright blue (NOT `#0000FF`). [QW]
- **G3.** Show match count + current-match position. [M] (partly exists?)
- **G4.** Find/Replace UI sizing matches the rest of the UI sizing/zoom. [M]
- **G5.** `Cmd+Shift+F` panel background is grey → make it white. [QW]

## H. Tooltips & responsiveness [M]
- **H1. Custom tooltip widget** — default is slow + ugly; build faster, bigger,
  better UI/UX. [M]
- **H2.** Many elements lack tooltips → **tooltip for every element.** [M]
- **H3.** UI feels lifeless — add hover/mouseover/click interactivity across
  buttons + elements. [M]
- **H4.** Close (`x`) button: add a hover circle behind it; reconsider the glyph
  (reads as an "x", want a proper close icon). [QW]

## I. Source/Editor view polish [M]
- **I1.** Mouse-over line **hover highlight**, separate from the selected-line
  highlight. [M]
- **I2.** Special-char rendering more subtle — IntelliJ-style (centered dot for
  space, arrows for tab, etc.). [M]

## J. File-nav tree [QW]
- **J1.** Remove the up-arrow in the file tool window → add a `..` entry at the top
  of the tree. [M]
- **J2.** Remove the "Show hidden" checkbox → make it a button beside Pin/Lock/…
  button group. [QW]
- **J3.** **Show hidden ON by default.** [QW]

## K. Persistence & state [M]
- **K1.** Save every state we can: **per-file scroll position**, at minimum the
  set of open tabs. [M]
- **K2.** Remember OpenAs/"pretend type" per file (= A3). [M]

## L. Memory [M] (relates to #190/#191)
- **L1.** ~200 MB retained after closing tabs — not releasing promptly. Investigate
  + bound. [M]

## M. Actions / shortcuts / Omni (extends #223) [M][D]
- **M1.** User-editable **config file for keyboard shortcuts.** [M][D: format]
- **M2.** Catalog **every** user action → each must be (a) keyboard-shortcutable,
  (b) invokable from Omni search. (This is #223 + binding + palette wiring.) [L]

## N. Formats [QW]
- **N1.** Created/Modified dates → `YYYY-MM-DD HH:mm` (24-hour). [QW]

---

## Suggested sequencing
1. **Quick-win batch** (no decisions, low risk): B4, G2, G5, H4, J2, J3, N1,
   I2(subtle special-char), + E1 bug + the close-button. One PR.
2. **Decision-gated big rocks:** A (view-mode model), C2/D (worktree switch +
   terminal), E2 (docking). Resolve DECISIONS A/C/D first.
3. **Cross-cutting passes:** F (zoom audit), H (tooltip widget + coverage),
   K (state persistence), M (actions catalog + shortcut config), G (find rebuild).
4. **L (memory)** folds into the existing #190/#191/#210 memory work.

## Decisions owed (blocking the big rocks)
- **A** — full view-mode × file-type matrix incl. ViewOnly + HEX-edit + where
  Source/Preview/Formatted go.
- **C2** — worktree/branch switch semantics (non-destructive how?).
- **D** — terminal scope + vendor-a-dep (SwiftTerm) vs build.
- **M1** — shortcut config format (JSON/TOML) + precedence over built-ins.
