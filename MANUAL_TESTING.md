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

### 5a. Sidebar accordion panels (45 s)

Visual / layout-only checks for the resizable accordion sections above
the FILES tree. Snapshot tests can't see colour or padding; verify
with eyes.

- [ ] Each section above FILES (Bookmarks, Search, Git, Claude, Outline,
  any plugin section) renders on a **subtle background swatch** that's
  visibly distinct from the sidebar's main background — the panels read
  as their own cards.
- [ ] There is a **small vertical gap** between adjacent sections; the
  resize handle (1-px hairline) sits inside that gap.
- [ ] Hover the gap between two sections — cursor changes to
  `resizeUpDown`. Drag vertically — the section above grows/shrinks; the
  height **persists across app relaunch**.
- [ ] You **cannot drag a section below ~120 px**. Past that the drag
  stops; the section never collapses into the divider.
- [ ] Open Bookmarks with **zero bookmarks** — the panel still occupies
  its full body height and shows "No bookmarks yet." inside the
  scrollable area. The panel's height does **not** shrink to fit content.
- [ ] Bookmark something — the placeholder disappears; the panel's
  outer height stays the same.
- [ ] Apply a chip filter that excludes everything — placeholder reads
  "No bookmarks match this filter." (still inside the fixed envelope).
- [ ] Open a folder with a clean git working tree — the Git panel's
  Status tab reads "Working tree clean." inside the same fixed envelope
  (panel doesn't shrink).
- [ ] Open the Stash tab on a repo with no stashes — "No stashes."
  inside the fixed envelope.
- [ ] Open a Swift / Python file with an LSP server attached — the
  OUTLINE section header shows the symbol count and the body is the
  same height as other sections (no DisclosureGroup chevron — it uses
  the same chevron + uppercase header as Bookmarks / Search / Git).
- [ ] Open a `.md` file — OUTLINE section is **not shown** (language
  has no registered LSP server); the divider above Plugin sections sits
  flush against the previous section.
- [ ] Every section header's chevron + label has the **same horizontal
  inset** as the FILES header (10 px left of the chevron). No drifters.

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

### 10. Image preview zoom (45 s)

- [ ] Open an image (PNG/JPG). Confirm it loads fit-to-window and is centered.
- [ ] **Trackpad pinch-out** zooms in; pinch-in zooms out. Zoom anchors at the pinch center.
- [ ] **Cmd + mousewheel up** zooms in; Cmd + wheel down zooms out. Zoom anchors at the cursor — the image point under the cursor stays under the cursor.
- [ ] **Plain wheel** (no Cmd) when the image is zoomed in still pans, doesn't zoom.
- [ ] Clamps at 10× (max) and 0.1× (min) — keep scrolling past either and the % readout pegs.
- [ ] After wheel/pinch zoom, the % HUD in the control bar reflects the new magnification.
- [ ] Switching to another image tab and back resets the zoom to fit-to-window (per-tab zoom is ephemeral by design).

### 11. Bundle hygiene (30 s)

- [ ] `bash scripts/verify-app.sh` exits 0 with all 17 checks green.
- [ ] `codesign -dv dist/MarkdownViewer.app` reports an ad-hoc signature (no errors).
- [ ] `lsappinfo info MarkdownViewer` confirms Launch Services has it registered after a fresh `build-app.sh`.

### 11. LSP — multi-language (5–10 min)

Per-language smoke. Each server is **PATH-discovered** (no bundling) —
when missing, the diagnostics panel shows the install command rather
than crashing.

#### TypeScript / JavaScript (`typescript-language-server`)

```text
npm i -g typescript-language-server typescript
# Verify: typescript-language-server --version
```

- [ ] Open a `.ts` / `.tsx` / `.js` / `.jsx` file inside a folder with
  a `tsconfig.json` / `package.json`. Outline section populates within
  ~3 s. Hover, Cmd-click jump, right-click "Go to Definition" all work.
- [ ] Right-click an identifier → "Find References". Sidebar
  **References** section populates with file:line entries; click a row
  jumps to that file + line.

#### Python (`pyright`)

```text
npm i -g pyright
# Verify: pyright-langserver --help
```

- [ ] Open a `.py` file inside a folder with `pyproject.toml` /
  `setup.py` / `requirements.txt`. Outline + hover + Cmd-click jump
  work within ~2 s.

#### Java (`jdtls`)

```text
brew install jdtls
# Or download from https://download.eclipse.org/jdtls/snapshots/
# Verify: jdtls --help
```

- [ ] **Cold-start is 30–90 s** on a typical Maven / Gradle project.
  The diagnostics panel shows the server in `starting` state during
  this window. Don't kill the app — just wait.
- [ ] Per-workspace data lives under
  `~/Library/Application Support/com.markdownviewer.MarkdownViewer/jdtls-data/<hash>/`.
  Safe to delete to force a re-index; the directory grows large
  (hundreds of MB on big multi-module projects).

#### Problems sidebar (all languages)

- [ ] Introduce a deliberate compile error in any LSP-supported file.
  The **Problems** sidebar section populates within a second or two of
  the server publishing diagnostics. The header shows red/orange pill
  counts. Click a row → file opens, scrolls to the offending line.
- [ ] Fix the error. The Problems row clears within a second (server
  re-publishes an empty diagnostic set for that URL).

#### Workspace symbol search

- [ ] Open the **References / Workspace Symbols** sidebar section.
  The header menu lets you switch to "Workspace Symbols". Type a
  query. Results appear (server-side fuzzy match); click → jump.
### 12. Media preview alignment (45 s)

`MediaPreviewView` content (image / audio / video / PDF / unsupported)
must sit centered — both axes — inside the content pane. Regression
fixed by `CenteringClipView` in `Sources/ViewerUI/MediaPreviewView.swift`
plus the outer `.frame(maxWidth/maxHeight: .infinity)` on the routing
view; SwiftUI / ViewInspector can't see the AppKit-level clip-view
geometry, so this stays manual.

- [ ] Open a **small PNG** (<= a few hundred px each side) on a wide
      window. The image sits **centered** in the preview pane — not
      pinned to the bottom-left corner. Resize the window: the image
      stays centered while the viewport grows around it.
- [ ] Open a **large PNG** that requires `Fit` (press `0`). The
      proportionally-scaled image is centered both axes; pressing `1`
      (1:1) and scrolling shows the full pixel grid.
- [ ] Open an **MP4 / MOV**. The AVPlayerView is centered in its pane.
- [ ] Open a **PDF** with one short page. The page is centered
      horizontally; vertically it sits at the top of the scroll region
      (PDFView's continuous-mode default — that's fine).
- [ ] Open an **MP3**. The AVPlayerView's audio controls row sits
      vertically centered, not pinned to the bottom.
- [ ] After viewing any of the above, switch to HEX (⌃⌘H) and back —
      preview re-appears centered, not stuck in HEX. *(Bug 1 regression.)*

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

---

## Appendix: keyboard shortcut reference

The full set, as wired in `Sources/MarkdownViewer/main.swift`:

| Shortcut | Action |
|---|---|
| `⌘O` | Open File… |
| `⇧⌘O` | Open Folder… |
| `⌘W` | Close Tab |
| `⌘T` | New Tab |
| `⌘1`–`⌘9` | Jump to tab N |
| `⌥⌘→` / `⌥⌘←` | Next / Previous Tab |
| `⌘R` | Reload current file |
| `⇧⌘R` | Toggle Rendered / Source |
| `⌘F` | Find in document |
| `⌘G` / `⇧⌘G` | Find Next / Find Previous |
| `⌘K` | Command Palette |
| `⇧⌘F` | Cross-document search |
| `⌃⌘S` | Toggle Sidebar |
| `⌘\` | Toggle Split View |
| `⌘⇧\` | Swap Split Panes |
| `⌘+` / `⌘-` / `⌘0` | Zoom In / Out / Reset |
| `⌘Q` | Quit |

Git-related menu items (no default shortcuts; add via System Settings → Keyboard → App Shortcuts if needed):

- File ▸ Show File History
- File ▸ Show Repository History

## Appendix: environment variables for testing

Set on the shell before launching MarkdownViewer or `swift test`:

| Variable | Purpose |
|---|---|
| `MDV_BACKGROUND=1` | Force dark/blackground theme regardless of system appearance |
| `MDV_SKIP_WORKSPACE_RESTORE=1` | Skip auto-restore of last workspace on launch (clean-room test) |
| `MDV_ENABLE_BROKEN_RULER=1` | Re-enable the disabled NSRulerView gutter path — useful only when investigating LESSONS.md compositor bug |
| `MDV_NO_RULER=1` | Disable the line-number gutter entirely |
| `MDV_SKIP_VISUAL=1` | Skip visual regression tests (faster local runs; CI always runs them) |
| `BUDGET_MB=<N>` | Override the 25 MB bundle-size cap in `scripts/check-bundle-size.sh` |

These are tested manually; they don't appear in user-facing UI. Don't
ship features gated on them — they're escape hatches for development.

## Appendix: VM smoke testing

`vm-tester@<vm-ip>` is a UTM macOS guest used for headless smoke tests
without contaminating the dev machine's TCC, login keychain, or
Application Support. Sync strategy:

```sh
rsync -av --delete \
  --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/' \
  ./ vm-tester@<vm-ip>:markdown_viewer/

ssh vm-tester@<vm-ip> \
  'cd markdown_viewer && swift test --filter ViewerCoreTests --filter ViewerKitTests'
```

Why exclude `.build/` and `.swiftpm/`: they contain arch-specific
artifacts and absolute paths from the host. Always let the guest
re-resolve and re-build.

Full GUI smoke (build-app.sh + verify-app.sh) on the VM was historically
blocked on WindowServer/keychain/TCC issues — see SSH session notes.
Stick to `swift test` until that's unblocked.

## URL scheme (`markdownviewer://`) containment — security policy

Added 2026-05-25 as part of the `SECURITY_CONCURRENCY_2026-05-25.md`
remediation pass (finding §1.1). The URL scheme handler now funnels
every `path=` / `root=` query argument through `URLSchemePolicy.containedPath`,
which only accepts paths inside `$HOME` or the per-user temp dir.

Manual verification:

1. Build + install the app (`scripts/build-app.sh`).
2. From Terminal: `open 'markdownviewer://open?path=~/Documents/foo.md'`
   should open the file (positive control).
3. From Terminal: `open 'markdownviewer://open?path=/etc/hosts'`
   should be silently dropped (no window, no error toast — by design,
   the URL scheme is fire-and-forget). Verify nothing appears.
4. From Terminal: `open 'markdownviewer://search?root=/private/etc&q=x'`
   should not reroot the sidebar. Verify sidebar root unchanged.
5. From Terminal: `open 'markdownviewer://open?path=~/../../etc/passwd'`
   should be dropped — `..` traversal standardizes outside `$HOME`.

The deliberate behavior change from the pre-patch handler is that
absolute paths outside `$HOME` and `$TMPDIR` no longer open. If a
user reports "my URL bookmark stopped working after the security
patch," the cause is almost certainly a system-folder or other-user
path that was acceptable pre-patch.

## Sidebar padding alignment

After moving FILES to the top of the sidebar and adding
`.sidebarSectionContainer()` to `LSPProblemsPanel`,
`LSPNavigationPanel`, and PROBLEMS, verify every accordion section
terminates with the same bottom breathing room (no section ends
flush with the next divider). Visual check on VM only.

## Large-file read-only source mode (two-tier read cap)

The text loader now uses a two-tier cap: files at/below `readableMaxBytes`
(512 MiB default) load fully; above the `softWarnBytes` watermark
(64 MiB default) the file is tagged `isLargeReadOnly` so the source
view skips per-interaction O(N) overlays (newline index, selection
highlight) and pretty-print. Above 512 MiB the loader still throws
`.tooLarge` (OOM backstop) with a message naming the ceiling.

The acquisition/window/index logic is host-tested
(`TextFileLoaderTests`, `DocumentControllerTests`, `LargeFileOpenTests`).
The live NSTextView render of a genuinely huge file is **VM-only** —
the host test suite cannot observe RSS, scroll frame pacing, or the
gutter compositor blank-sibling bug (only `screencapture`, not
`cacheDisplay`, surfaces it). On the UTM macOS15 VM:

1. Open a real ~200 MB log/JSON/CSV-as-text file. It must open in
   source mode **without** the "File is too large" refusal and without
   a beachball on open (the eager read is routed off-main; the tab
   should briefly show a `.loading` placeholder, then the text).
2. Observe RSS: expect ~1.5–2x file size (e.g. ~400–600 MB for a
   200 MB file). It must be **bounded** by file size and not grow at
   idle (the ~5 MB/s republish-loop RSS-growth bug class).
3. Scroll the file end-to-end — should not drop frames or hang.
4. Confirm the SwiftUI gutter line numbers still render correctly
   (compositor-bug regression — sibling views must not blank). Verify
   via `SourceViewVisualRegressionTests` screencapture, not xctest.
5. Status bar: `Ln/Col` is intentionally **hidden** for a large file
   (the newline index is skipped); `Lines`/`Size`/`Enc` still show.
6. **Huge-line edge case:** open a ~200 MB single-line minified JSON
   (degenerate newline index). Confirm the plain fast path
   (`textView.string = text`) doesn't hang on a no-newline blob.
7. Confirm a >512 MiB file still refuses with the improved ceiling
   message ("exceeds the 512 MB read limit").
8. Editing stays capped: picking Editor mode on a >50 MiB file shows
   the `LargeEditorPlaceholderView` with "View as Source"; the split
   pane shows "File too large for split view" for >64 MiB.
