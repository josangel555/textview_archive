# UX Overhaul — AUTONOMOUS BUILD progress tracker

> **STANDING DIRECTIVE (owner, 2026-06-03):** implement ALL items in
> `docs/UX_OVERHAUL_2026-06-03.md` (tasks #224–233 + D) **fully autonomously**.
> Add appropriate tests (headless/unit) to verify each. **DO NOT stop** to say
> "batch complete / resume tomorrow." **Only stop when EVERYTHING is complete +
> gate-green.** If this is read after a compaction: keep going from the first
> unchecked item below. Commit after each item; keep `main` green.

## Resolved decisions
- **A** ✅ `Render | Editor | HEX` × `ViewOnly`; **Source = Editor+ViewOnly**;
  HEX byte-edit when ViewOnly off; **Format = separate conditional button** for
  known-formattable types (JSON/XML/…).
- **C** ✅ worktree switch → **open in a new window** (non-destructive); branch
  switch → real `git checkout` **hard-gated** (refuse/stash-prompt if dirty).
- **M1** ✅ shortcut config = **`~/.textview/keybinding.json`** (user-editable
  dotfile; user entries override built-ins).
- **D** — SwiftTerm NOT approved → build the terminal **dependency-free** (Darwin
  `forkpty`/PTY + minimal ANSI). No new SPM deps without explicit approval.

## Progress (check off as landed + gate-green)
- [ ] **#233 quick-wins** — tab dividers (B4) · show-hidden ON+button (J2/J3) ·
  `..` tree entry (J1) · 24h dates (N1) · subtle IntelliJ special-chars (I2) ·
  close-button hover+glyph (H4) · find good-blue (G2) · Cmd+Shift+F white (G5) ·
  one-shoulder-opens-file bug (E1) · taller session row + git-root (B1).
- [ ] **#224 UX-A** — content-toolbar + breadcrumb + Render|Editor|HEX×ViewOnly +
  Format button + HEX-edit + bottom attr group + unify OpenAs/type + persist type.
- [ ] **#231 UX-K** — per-file scroll + open-tabs + OpenAs-type persistence.
- [ ] **#225 UX-C** — footer git/branch/worktree + edit stats + dual zoom.
- [ ] **#229 UX-G** — find/replace native rebuild (count/pos, sizing, colors).
- [ ] **#228 UX-F** — thorough zoom audit + fix all scaling/height artifacts.
- [ ] **#230 UX-H** — custom tooltip widget + full coverage + hover/click life.
- [ ] **#227 UX-E** — dockable tool windows (drag/snap, fixed height, resize, flicker).
- [ ] **#232 UX-M** — action catalog → `~/.textview/keybinding.json` + Omni invokability.
- [ ] **#226 UX-D** — embedded terminal (dep-free PTY) + shoulder toggle.
- [ ] **L (memory)** — ~200MB-after-close investigation (folds into #190/#191/#210).

## Notes / log
(append per-item: commit sha + what shipped + tests added)
