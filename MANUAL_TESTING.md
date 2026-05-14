# Manual Smoke Test Checklist (Tier 0)

A targeted, **5-minute** checklist for things automated tests can't see:
drag-and-drop, native macOS integration, focus, perception bugs.

Run **before tagging a release**, and after any change to:
- `main.swift` (menus, AppDelegate, NSWindow setup)
- `MarkdownRenderedView` (WKWebView lifecycle)
- `SidebarView`, `TabBar`, `CommandPaletteView` (gesture surfaces)
- `scripts/Info.plist`, `scripts/build-app.sh` (bundle assembly)

## Setup

```sh
bash scripts/build-app.sh debug
killall MarkdownViewer 2>/dev/null
```

A previous fresh build is required; running stale binaries via Launch Services
masks real bugs.

## Checklist

### 1. Launch & menus (60 s)

- [ ] `open -a MarkdownViewer DESIGN.md` opens a window with the file rendered.
- [ ] Menu bar shows: **MarkdownViewer · File · View · Window · Edit**.
- [ ] `File ▸ Open Recent ▸` lists recently opened files.
- [ ] `File ▸ Close Tab` (⌘W) closes the current tab, *not* the window, as long as more than one tab is open.
- [ ] **No "Show Tab Bar" or "Merge All Windows" item** appears anywhere — those are macOS's native window-tabs UI, which we explicitly disabled.
- [ ] `Window ▸` lists Next/Previous + one menu item per open tab with the **actual tab title** (not "Show Tab 1..9").
- [ ] The current tab has a checkmark in the Window menu.

### 2. Tabs (60 s)

- [ ] `⌘T` creates a blank tab.
- [ ] Opening a file via `⌘O` while on a blank tab **reuses** the blank tab, doesn't create a second one.
- [ ] Open three files. `⌘1`, `⌘2`, `⌘3` switch among them. `⌥⌘→` / `⌥⌘←` cycle.
- [ ] Closing a middle tab selects its right neighbor. Closing the last tab selects the new last.
- [ ] Re-opening an already-open file (via `⌘O` or palette) **switches** to its tab — does not duplicate.

### 3. Rendered ↔ Source (45 s)

- [ ] Toggle `⇧⌘R` on `DESIGN.md` flips between rendered HTML and monospaced source.
- [ ] After several toggles **the rest of the tabs remain visible** and selecting another tab works. *(Regression: previously the WKWebView reloaded on every body tick and looked like tabs disappeared briefly.)*
- [ ] Source mode shows line numbers in the gutter.

### 4. Drag-and-drop (60 s)

This is the part that snapshot tests can't see.

- [ ] Drag a `.md` file from Finder onto the main window — an **accent-colored border** appears, the file opens in a new tab. Confirm the border appears whether the current view is **Rendered** or **Source**. *(Regression: WKWebView used to swallow file-URL drags.)*
- [ ] Drag a folder onto the window — the sidebar appears with the folder's contents.
- [ ] Drag a non-text file (e.g. `.png`) onto the window — should open as plain text (gracefully) or show the load error.

### 5. Sidebar (60 s)

- [ ] `⇧⌘O` opens the folder picker. Pick the repo root.
- [ ] Sidebar shows folders first, then files. Hidden files (`.gitignore`) are hidden by default.
- [ ] Toggle **Show hidden** — `.gitignore` and similar appear immediately.
- [ ] Single-click on a folder row expands/collapses it. **No double-tap needed.** *(Regression: a stray `.onTapGesture(count: 2)` used to swallow first clicks.)*
- [ ] Single-click on a file row opens it in the current tab.
- [ ] Drag the **right edge of the sidebar** — cursor turns into the resize indicator; width sticks across app restarts.
- [ ] If the folder is inside a git repo, files show colored M/A/?/D badges.
- [ ] `⌃⌘S` toggles the sidebar's visibility.

### 6. Command palette `⌘K` (45 s)

- [ ] `⌘K` opens the palette over the main window.
- [ ] Palette has a **solid window background** (not a washed-out translucent material).
- [ ] First match is highlighted with the **accent color**.
- [ ] **↑ / ↓** arrows move the selection. The selected row scrolls into view.
- [ ] Typing a query updates the list; selection resets to first match.
- [ ] **Enter** opens the selected file.
- [ ] **Esc** dismisses the palette without opening anything.
- [ ] Clicking outside the palette dismisses it.

### 7. Find (30 s)

- [ ] In **Source** mode (or a plain text file): `⌘F` opens the native find bar, regex works.
- [ ] In **Rendered** mode (markdown): `⌘F` — **known limitation, currently broken**; Phase 4.5 UI ships the fix. Note as a known gap; don't fail the checklist on it.

### 8. File watcher (45 s)

- [ ] Open `DESIGN.md` (or any file). In another terminal: `echo "—appended—" >> DESIGN.md`.
- [ ] The viewer updates within a second without manual reload.
- [ ] `⌘R` manually reloads the current file.

### 9. Persistence (45 s)

- [ ] Open a folder + a couple of files. Quit (`⌘Q`). Re-launch.
- [ ] The previously-open folder is restored in the sidebar.
- [ ] Sidebar width is the same as before.
- [ ] Tab restoration is **not** yet implemented (Phase 8.5 workspaces). Note as expected gap.

### 10. Bundle hygiene (30 s)

- [ ] `bash scripts/verify-app.sh` exits 0 with all 17 checks green.
- [ ] `codesign -dv dist/MarkdownViewer.app` reports an ad-hoc signature (no errors).
- [ ] `lsappinfo info MarkdownViewer` confirms Launch Services has it registered after a fresh `build-app.sh`.

## When something fails

1. **Reproduce twice** — flaky once vs twice tells you whether it's a real bug.
2. **Capture state**: screenshot, the steps, and the relevant log line.
3. **Write a Tier 1 or Tier 1m test that fails** *before* fixing the code. Even if the bug is visual, find a state-machine assertion that distinguishes correct from broken.
4. **Open a PR with the failing test + fix** so the regression is caught next time.

## What is *not* on this checklist

Anything reliably covered by automated tests:
- File-type detection, markdown rendering, history persistence, fuzzy matching, find engine, git status parsing, Claude log parsing — these have Tier 1 coverage. Re-testing them here adds time without finding new bugs.
- Pure model state transitions (`DocumentModel`, `SidebarModel`) — Tier 1m.

If you find yourself adding items here that could live in Tier 1 or 1m, write the test instead.
