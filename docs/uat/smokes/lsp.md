# UAT smokes — LSP (hover / go-to-def / outline / refs / diagnostics)

**Area:** Language tooling — LSP integration
**App under test:** `dist/TextView.app` (Finder name TextView.app), bundle id `com.markdownviewer.MarkdownViewer`
**Primary surfaces exercised here:**

- Source-view hover popover (`LSPHoverAttachment`, transient `NSPopover`, 300 ms cursor dwell, markdown-rendered body, 380 pt wide / 60–360 pt tall)
- CM6 editor hover tooltip + `Editor` right-click "Go to Definition"
- Source-view right-click `LSP` navigation submenu: Go to Definition / Declaration / Type Definition / Implementation / Find References; plus Cmd-click → first definition
- Outline sidebar section (`mdv.lspOutline`, `textDocument/documentSymbol`, language-gated)
- References / Workspace-Symbols panel (`mdv.lspNav`, mode picker `Refs` / `Symbols`)
- Problems sidebar panel (`mdv.problems`, severity filter All / Errors / Warnings, count pills)
- LSP Diagnostics tool window (Settings → Language servers → Open Diagnostics…; 2 s poll Table)
- Shoulder-rail panel toggles: `mdv.rail.left.lspOutline`, `.references`, `.problems`

---

## Conventions / common preconditions

These apply to every smoke unless overridden in the smoke's own preconditions block.

- **A real LSP server must be PATH-discoverable** for the language under test. None are bundled — discovery walks an augmented PATH (Homebrew, npm prefixes) + `xcrun -f sourcekit-lsp`. The reference matrix used below:
  - **TypeScript / JavaScript** → `typescript-language-server` (fastest cold-start; use as the default fixture language)
  - **Python** → `pyright`
  - **Swift** → `sourcekit-lsp` (via active Xcode toolchain; needs a SwiftPM/Xcode project root)
  - **Java** → `jdtls` (cold-start 30–90 s — avoid for fast smokes; only exercise in the "cold start" edge state)
- Discovery is **cached for the process lifetime** — installing a server requires an app relaunch to be picked up. Confirm the server resolves before relying on a pass: `which typescript-language-server` from a login shell.
- **Fixtures are project-scoped.** LSP roots are discovered per language (e.g. `tsconfig.json` / `package.json`, `pyproject.toml`, `Package.swift`). Create scratch fixtures under `FileManager.default.temporaryDirectory` (per-user `/var/folders/...`) — **never** under `~/Documents`, `~/Desktop`, `~/Downloads`. Open the fixture **folder** as the session root so the server gets a workspace, then open the file from the sidebar.
- The **Outline / References / Problems sections are language-gated**: for a file with no registered server (`.md`, `.txt`) Outline renders `EmptyView()` (absent, not empty). Forced-shown via the shoulder rail it renders the placeholder `No language server for this file.`
- Known silent-failure traps to watch for (these are *expected current behavior*, log don't fail unless the spec line says "fail"): go-to-definition that returns nothing is **silent** (no toast / no "nothing found" UI); multi-result definition **silently picks the first** (no picker); the install hint claims a toast but **no toast is wired**; `publishDiagnostics` inbound notifications are **dropped** (diagnostics flow via the CM6 editor push path / pull, not server-pushed); Outline caches per `fileURL` and **does not track edits** (stale until reload).
- App actions below use the real UI verbs (hover-dwell, right-click, Cmd-click) — there is **no LSP script verb** in `ScriptVerbDispatch`, so headless/T4 companions must drive these through AppKit event injection or assert at the model/store layer (`LSPOutlineModel`, `LSPNavigationStore`, `LSPDiagnosticsStore`, `LSPPool.snapshot()`).

---

## LSP-01 — First-touch TS file: server cold-start drives Outline + hover + Problems together

**Combines:** server discovery & spawn · Outline section population · hover popover · Problems panel · LSP Diagnostics window state · shoulder-rail panel toggles

**Preconditions**

- `typescript-language-server` is PATH-discoverable (verify with `which`).
- A scratch TS project under temp: `proj/` containing `tsconfig.json`, `package.json`, and `src/app.ts` with a few exported functions/classes, at least one **deliberate type error** (e.g. `const n: number = "str";`) and one valid symbol with a JSDoc/inferred type to hover.
- App freshly launched (so discovery cache is cold and the pool has no live server yet).

**Steps**

1. Open the `proj/` folder as the session root (Open Folder… ⇧⌘O or `session-open-folder`).
   → Sidebar roots at `proj/`. Outline / References / Problems sections not yet populated (no file open).
2. Click `src/app.ts` in the FILES tree to open it in Source view.
   → File loads, syntax-highlighted. The **Outline** section appears (it is language-gated — visible only because `.ts` has a registered server). Header shows a `ProgressView` / `Loading symbols…` placeholder while the server cold-starts.
3. Wait for the server to come live (TS is sub-second to a few seconds).
   → Outline populates with the document's symbols (functions/classes shown with per-kind SF Symbols, count chip in the header). `mdv.lspOutline` is present and non-empty.
4. Hover the cursor over a typed identifier (a function name or typed const) and hold ~300 ms without moving.
   → A transient `NSPopover` appears anchored at the identifier, markdown-rendered (signature / inferred type / doc), ≤ 380 pt wide, height clamped 60–360 pt. Moving the cursor away dismisses it.
5. Open the **Problems** panel (shoulder rail `mdv.rail.left.problems`, or it auto-presents via `SidebarDataPresence` once diagnostics exist).
   → The deliberate type error appears as a row: red `exclamationmark.octagon.fill`, `app.ts:<line>`, `[ts]` source chip, the message. Header shows a red count pill ≥ 1.
6. Open Settings → Language servers → **Open Diagnostics…**.
   → The LSP Diagnostics Table window opens with a row for `TypeScript` / root = `proj/` / State = **live** (green check) / Reqs ≥ 1 / a numeric Last-ms / Crashes 0 / Last error `—`. The 2 s poll keeps it fresh; Refresh re-pulls.

**Expected end state:** Outline populated, hover works, the type error is in Problems with a red count pill, the diagnostics window shows one live TS server, zero crashes.

**Variations / edge states**

- **Server missing:** rename/PATH-hide `typescript-language-server`, relaunch, repeat. Outline shows (language is registered) but renders `No symbols.` / `LSP unavailable` after the request fails; **no crash**. (Note: the "install hint toast" is NOT wired — absence of a toast is expected, not a bug.)
- **jdtls cold start:** repeat steps 1–3 with a Java fixture. Expect Outline stuck on `Loading symbols…` for 30–90 s with no further progress UI — log the dwell, don't fail unless it never resolves or crashes.
- **Idle reap:** leave the server idle > 5 min, then re-open the file — server is re-spawned; diagnostics window should show it transition starting→live again, Reqs reset behavior acceptable.
- **Outline staleness:** edit the file in **Editor** mode (add a function), switch back — Outline is cached per `fileURL` and does **not** reflect the edit until reload (`reload()` / re-open). Confirm this is the current behavior; log it.

---

## LSP-02 — Navigate by symbol: Cmd-click definition + right-click nav submenu + Outline jump in one flow

**Combines:** Cmd-click go-to-definition · right-click `LSP` submenu (Definition/Declaration/Type Def/Implementation/Find References) · Outline click-to-jump · cross-file tab open + scroll-to-line · multi-result first-pick behavior

**Preconditions**

- `typescript-language-server` discoverable, server live (run LSP-01 first or open + wait).
- Scratch TS project with **two** files where `src/app.ts` imports and calls a symbol declared in `src/lib.ts` (so definition crosses a file boundary). Include at least one identifier whose definition has **multiple results** (e.g. an overloaded function or a re-exported symbol) to exercise the silent first-pick path.
- `src/app.ts` open in **Source** view, Outline populated.

**Steps**

1. Click an Outline row for a symbol defined in `app.ts`.
   → Source view scrolls to that symbol's line; the line is selected/visible. (`mdv.lspNav` not involved — this is the Outline `onJump`.)
2. Place the cursor on a call-site identifier that resolves to `lib.ts`, then **Cmd-click** it.
   → A new (or existing) tab for `lib.ts` is opened/selected and scrolled to the definition line. (First result is taken silently — no picker even if multiple.)
3. Back in `app.ts`, **right-click** the same identifier → `LSP` submenu → **Go to Definition**.
   → Same target: `lib.ts` tab opens/selects, scrolls to the definition.
4. Right-click the identifier → **Go to Type Definition** (and separately **Go to Implementation**, **Go to Declaration**).
   → For a typed symbol, Type Definition jumps to the type's declaration. Declaration/Implementation jump where the server returns a location, or are **silently inert** when the server returns nothing (expected — no error UI). Log which sub-verbs returned a location.
5. Right-click the identifier → **Find References**.
   → The sidebar **References** panel (`mdv.lspNav`) switches to `Refs` mode, header reads `REFERENCES · <origin context>`, lists every reference as rows (kind icon, name, container, monospaced preview line), with a count chip. Each row is tappable.
6. Click a References row pointing into `lib.ts`.
   → `lib.ts` tab opens/selects and scrolls to that reference line.

**Expected end state:** definition reachable via Cmd-click *and* the right-click submenu (consistent target), References panel populated and click-navigable across files.

**Variations / edge states**

- **Multi-result definition:** on the overloaded/re-exported identifier, confirm exactly one target opens (first result, silently) — document that no picker appears (`#` deferred behavior, not a bug).
- **Definition returns nothing:** Cmd-click / right-click Definition on a keyword or whitespace — nothing happens, **no error UI** (silent). Confirm no crash, no stuck spinner.
- **Find References with no refs:** invoke on a unique private symbol → References panel shows `No references.` (loading → empty), count chip absent.
- **Mode picker:** open the References panel mode picker (`mdv.lspNav.modePicker`); confirm `References` entry is **disabled** (you reach Refs only via the source context menu, not the picker) and `Workspace Symbols` is selectable.
- **Editor parity:** open the file in **Editor** (CM6) mode, right-click → `Editor` menu → **Go to Definition** — same jump behavior as Source. Hover an identifier in the editor → CM6 hover tooltip (plain-text + fenced-code, ~300 ms dwell, 2 s safety timeout).

---

## LSP-03 — Workspace symbols + Problems severity filtering + cross-file diagnostic navigation

**Combines:** Workspace-Symbols search mode (`workspace/symbol`) · References↔Symbols mode switch · Problems severity filter (All/Errors/Warnings) · count pills (error red + warning orange) · click-to-jump from Problems across files · in-flight query cancellation

**Preconditions**

- `typescript-language-server` (or `pyright`) discoverable + live.
- Scratch project with **multiple files**, each containing a distinctly-named exported symbol (for workspace-symbol search), and seeded diagnostics across ≥ 2 files at **mixed severities**: at least one error (red) and one warning (orange) — e.g. a type error + an unused-variable / `noUnusedLocals` warning in a different file.
- All seeded files have been opened at least once (so the server has them in its workspace / `didOpen` + `didChange` have fired and diagnostics are populated).

**Steps**

1. Open the References/Symbols panel mode picker (`mdv.lspNav.modePicker`) → **Workspace Symbols**.
   → Panel header reads `WORKSPACE SYMBOLS`, a search field (`mdv.lspNav.symbolField`) appears with placeholder/empty hint `Type a query above to search.`.
2. Type a query matching a symbol in another file, press Return.
   → `onSearchWorkspaceSymbols` fires; while in flight a `Searching…` placeholder shows, then rows list matching symbols (name, container, kind icon) with a count chip. A no-match query shows `No symbols match.`.
3. Click a workspace-symbol row in a not-yet-focused file.
   → That file opens/selects and scrolls to the symbol.
4. Quickly type a second query, then immediately a third before the second resolves.
   → Only the newest query's results land; the prior in-flight request is cancelled (no stale rows from an older query). The clear (`xmark.circle.fill`) button empties the field and clears rows (`store.clear()`).
5. Open the **Problems** panel (`mdv.problems`). With filter on **All**, confirm both the error and warning rows are present and the header shows **both** a red error pill and an orange warning pill.
6. Open the filter menu (`mdv.problems.filter`) → **Errors**.
   → Only error-severity rows remain; the list re-filters. Switch to **Warnings** → only warning rows. Switch back to **All** → both return.
7. Click a Problems row whose `url.lastPathComponent` is **not** the active tab.
   → `onJump(url, line)` opens/selects that file's tab and scrolls to `range.start.line + 1` (1-based — verify off-by-one is correct, the row line and the caret line match).

**Expected end state:** workspace-symbol search returns and navigates across files with newest-wins cancellation; Problems filters correctly by severity with accurate red/orange count pills; cross-file Problems navigation lands on the right 1-based line.

**Variations / edge states**

- **Filtered-empty vs truly-empty:** with diagnostics present but all errors filtered out under **Warnings** when there are zero warnings → `No problems match this filter.`. With no diagnostics at all → `No problems detected.`. Confirm the two distinct messages.
- **Pill visibility:** a file with only warnings (zero errors) → no red pill, orange pill only; only errors → red pill only.
- **Symbols on a server that lacks workspace/symbol:** query against a language whose server returns nothing → `No symbols match.` (graceful, no error string).
- **Empty / 2-char query:** very short or empty query — the panel should not spuriously search; empty field shows the type-a-query hint.

---

## LSP-04 — Resilience: server crash/restart, position-encoding correctness, language-gating, and diagnostics-window honesty

**Combines:** LSP Diagnostics window crash/restart accounting · position-encoding correctness (UTF-8/16 offsets on multi-byte content) · language-gated section visibility (`.md` vs `.ts`) · forced-shown placeholders via shoulder rail · per-workspace `lsp.json` override · hover/definition accuracy under non-ASCII

**Preconditions**

- At least two languages discoverable (e.g. `typescript-language-server` + `pyright`), one server killable.
- A scratch TS file containing **multi-byte / non-ASCII content** before an identifier on the same line — e.g. a comment with emoji or accented chars, then `const café = computeTotal();` — so hover/definition must land on the right column despite UTF-16 surrogate / multi-byte offsets.
- Optionally a per-workspace `lsp.json` present at the project root (override loader), and a `.md` file in the same root.

**Steps**

1. Open the TS file; let the server go live. Open Settings → Language servers → **Open Diagnostics…**.
   → Diagnostics window lists the TS server: State **live**, Crashes 0.
2. Hover the `café` identifier (the one *after* the multi-byte content on the line) and Cmd-click it.
   → Hover popover anchors on the correct identifier (not shifted left/right by the multi-byte chars); Cmd-click definition lands on the correct symbol. (Validates `LSPPositionConverter` UTF-8↔UTF-16 negotiation + clamp.)
3. From a terminal, `kill` the live server process (PID visible via the running app's child processes, or kill all `typescript-language-server`).
   → Within the 2 s poll, the diagnostics window reflects the death: State **dead** (red ✕) or a re-spawn with **Crashes** incremented and possibly a `Last error` string. No app crash, no UI freeze.
4. Trigger a new request (re-hover, or re-open the file) so the pool re-spawns.
   → Server transitions starting → live again; Reqs increments; Outline/hover resume working. Crashes count is retained (honest accounting).
5. Open the `.md` file in the same root.
   → **Outline / References / Problems sections are absent** for `.md` (language-gated — Markdown has no registered server; sections render `EmptyView()`, they do not appear empty).
6. Force-show the Outline panel via the shoulder rail (`mdv.rail.left.lspOutline`) while `.md` is active.
   → The forced section renders the placeholder `No language server for this file.` (not a spinner, not blank).

**Expected end state:** position-accurate hover/definition on multi-byte lines; the diagnostics window honestly reflects death/restart with a retained crash count; LSP sections hide themselves for unsupported files and show an explicit placeholder when force-shown.

**Variations / edge states**

- **`lsp.json` override:** with a per-workspace `lsp.json` at root, confirm it is parsed (loader runs). Note the known gap: `initializationOptions` from `lsp.json` are parsed but **NOT forwarded to `initialize()`** and the file is re-read per cold spawn — verify the override at least doesn't break spawn; log that init-options have no effect.
- **Repeated crashes:** kill the server several times in a row — Crashes count climbs monotonically; no unbounded respawn storm (idle-reap / backoff behavior should hold).
- **Two roots / two languages:** open a TS file and a Python file from different roots — the diagnostics window shows two distinct rows (`TypeScript`/`Python` with their own roots), each with independent live/dead state.
- **Position clamp:** place the cursor at the very end of a line / past the last char and hover/definition — request position is clamped, no crash (S2-H position clamp).
- **`publishDiagnostics` dropped:** for a server that pushes diagnostics as notifications rather than on the pull path, confirm those server-pushed diagnostics do **not** appear in Problems (known: inbound `publishDiagnostics` handler not wired). Log it; do not fail.
- **Hover safety timeout:** hover and immediately move away repeatedly — in-flight hover requests are cancelled (`$/cancelRequest`); no popover storm, no leaked popovers (the 2 s safety timeout closes any orphan).
