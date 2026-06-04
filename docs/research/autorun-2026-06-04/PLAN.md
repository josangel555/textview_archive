# Autorun 2026-06-04 — synthesized build plan

I have everything I need. The codebase confirms all load-bearing claims and reveals two head-starts: `ClaudeLogParser.swift` (322 lines, structured event model already exists) and `InteractionProfileHarness` (a `MDV_PROFILE`-gated headless interaction-timing harness already wired). The plan below is built on the actual code, not just the reports.

---

# Prioritized Build Plan — markdown_viewer autonomous run

Two corrections to the reports up front, verified against source:
- The perf reports agree, and the code confirms it: `updateDerived()` (`DocumentModel.swift:3987`) unconditionally writes `windowTitle` → one `objectWillChange` → whole `ContentView.body` re-eval. `loadedView` (`ContentView.swift:488`) is a `switch` on `currentViewMode`/`currentState` that renders **only the active tab** — there is **no per-tab view retention**. Confirmed.
- The image-editor report should reuse the **existing `ViewerCore`** module (already AppKit-free, T1 headless) — not stand up a new package. The `~/.claude` viewer already has a 322-line `ClaudeLogParser.swift` in `ViewerCore` with a structured `ClaudeEvent` model — the PoC is an *extension*, not a greenfield.

---

## 1. Perf-cluster fix sequence (ranked)

The two perf reports converge on the same two root causes. Ranked by impact-per-risk, highest first.

### Fix #1 (HIGHEST IMPACT) — Per-tab content-view retention (kills the ~1s close + the A→B→A reload)

This is the single highest-impact change. Both the perf-hotpath report (rank #1: "pool/cache WebViews") and the explorer (P1 #5: "no per-tab content-view retention") independently land here. The ~1s close stall and the tab-switch flash are the *same* root cause: closing/switching tears down a `WKWebView`/CM6 mount and cold-bootstraps the revealed tab's.

**Change:** retain a bounded LRU (cap ~4, matching the existing `renderedHTMLCache` cap) of realized per-tab content panes. Keep inactive tabs' panes mounted behind a `ZStack` + `.opacity(0)`/`.allowsHitTesting(false)` keyed by `tab.id`, instead of letting the `switch` in `loadedView` dismantle the branch. Bound memory (each WebContent ~50 MB) by evicting the LRU tail → cold-mount only on a true cache miss.

**Why first:** directly removes the ~1s (the dominant felt-latency complaint) and the switch flash, and it's the prerequisite that makes Fix #2 safe to attempt (narrowing observation is lower-risk once switches no longer remount).

**Automated validation (no human-staring):**
- **Headless timing** — extend `InteractionProfileHarness` (`Tests/ViewerUITests/InteractionProfileHarness.swift`, already `MDV_PROFILE`-gated, host-safe). Add a `hammerOneInteraction` case `tabSwitchBackAndForth`: open 3 tabs, drive A→B→A→B N times through `model.selectTab(at:)`, record wall-time per switch into the existing `$MDV_PROFILE_OUT` JSON artifact. Assert median switch time after warm-up drops below a regression threshold (capture the baseline first, then assert `< baseline * 0.5`). Gate keeps it out of the bare sweep.
- **Mount-count assertion (the real correctness gate, runs in the headless merge gate)** — add a test-only `makeNSView`/`dismantleNSView` counter (an `@MainActor` static counter behind `#if DEBUG`, or an injected probe closure on `CodeMirrorEditorView`/`MarkdownRenderedView`). Assert that A→B→A produces **zero** additional `makeNSView` calls for tab A after the first mount, and that close-active-tab triggers **exactly one** dismantle (the closed tab) and **zero** new mounts for the revealed neighbor when it's in the LRU. This is a pure-logic invariant — runs in `bash scripts/test-headless-gate.sh`, no window.
- **Live footprint** — run the `mem-profile` skill before/after across the same fixture-set; assert resident growth stays within the LRU bound (cap × WebContent floor), i.e. it does **not** scale linearly with total open tabs.

### Fix #2 (HIGH) — Narrow ContentView observation off the god-object

Stop routing focus changes through `updateDerived()`'s `windowTitle` republish. Have `ContentView` observe `tabCoordinator` directly for `tabs`/selection (the codebase already does exactly this for `sidebar`/`find`/`panelLayout`/`terminalPane` — the pattern and its rationale are documented inline at `ContentView.swift:7-33`). Then a switch re-bodies the content subtree, not all chrome.

**Risk:** medium — must re-audit which chrome genuinely needs the tick. The codebase has a documented history of "dead toggle" regressions from exactly this (the `setCurrentViewMode` note). Do it *after* Fix #1 and behind the mount-count gate so a missed republish surfaces as a test failure, not a visual one.

**Automated validation:**
- **Republish-count test (headless gate)** — instrument `DocumentModel.objectWillChange` with a test-observable counter. Assert a plain `selectTab(at:)` on a same-mode warm tab fires **0** `DocumentModel.objectWillChange` (only `tabCoordinator`'s). Today it fires ≥1 (the `windowTitle` write). This is the precise, automatable proof the fix landed.
- **Anti-regression for "dead toggle"** — keep the existing `PanelLayoutResolutionTests`-style derived-state tests green; add assertions that window title, mode bar, and status bar still update on switch (i.e. the chrome that *does* need the tick is re-wired to observe the right source). Headless.

### Fix #3 (MED-HIGH) — Collapse the double-republish on lazy materialize

Confirmed at `DocumentModel.swift:3699` — `materializeIfNeeded` completion calls `updateDerived()`, and `selectTab` already called it immediately. For an `.empty` tab, skip the immediate `updateDerived` and let the completion own the single republish.

**Validation (headless gate):** republish-count test — selecting an `.empty` (lazy) tab fires **exactly one** `DocumentModel.objectWillChange`, not two. Pure-logic, no window.

### Fix #4 (MED, slow-volume only) — Move `refreshDiskStateForActiveTab` stats off-main

The synchronous `FileManager.fileExists`/`attributesOfItem` at `DocumentModel.swift:3186` (and the `fileExists` in `startWatchingCurrentFile`) are sub-ms locally but stall on network volumes. Wrap in the same `Task.detached` + main-hop pattern `refreshDiffMarks` already uses — it's a signal, not a blocking dependency.

**Validation (headless gate):** inject a `FileManagerProtocol` seam with an artificial-latency stub; assert `selectTab` returns to the caller in `< ε` even when the stub `stat` sleeps 200 ms (proves the stat no longer blocks the focus path). Pure-logic with a fake clock.

### Fixes #5–#6 (LOW-MED, defer) — memoize git-root/relPath per `(tabID, url)`; always-defer the `openResolved` read off-main. Lower leverage; do after #1–#4 land. Validate via the same republish/timing harness.

**Do NOT touch:** git-diff shell, `repoFocus.recompute`, LSP warm — verified already async/debounced/equality-guarded. Both perf reports explicitly correct the brief's hypothesis here. Leave them.

---

## 2. Image-editor PoC — first slice + automated validation

**First slice (engine spine, zero UI, lands in existing `ViewerCore`):**
> Load JPEG → apply `[crop, resize]` op-list → export JPEG at chosen quality → bytes to disk.

Deliverable in `Sources/ViewerCore/` (no `import AppKit/SwiftUI` — CoreGraphics/CoreImage/vImage/ImageIO are headless-safe, T1 tier):
1. `ImageDocument` value type (`Sendable`, `Codable`) + `EditOp.crop`/`.resize`/`.orient` + `ExportSpec` (format/quality/strip/profile). Quality is **export-only, never an `EditOp`** — so revert is always lossless.
2. `Renderer.render(_ doc) -> CGImage` — crop via zero-copy `cropping(to:)` *before* resize via `vImageScale_ARGB8888`, with a one-time `vImageConverter` normalizing all inputs to premultiplied RGBA8 sRGB (this normalization removes ~80% of "crashes on your image" bugs).
3. `Exporter.encode(_ img, _ spec) -> Data` — single ImageIO `CGImageDestination` path; format is the destination UTI (PNG/HEIC are one-line additions later).
4. Append/undo/revert as pure `ImageDocument` transforms (history *is* `ops`).

**Why this slice:** it exercises every architectural seam (immutable model, pure render, ImageIO export, history) on the simplest ops, and slots straight into the project's existing tier discipline.

**Automated validation (all T1 headless, in `bash scripts/test-headless-gate.sh`, fixtures programmatically drawn — no binary blobs in git):**
- `resize(800×600 → 400×300)` ⇒ rendered `CGImage` is exactly 400×300; aspect-fit 1000×500 into 400×400 ⇒ 400×200 (rounding pinned).
- Portrait-EXIF source ⇒ rendered W/H swapped vs raw pixel W/H (orientation baked).
- Crop top-left quadrant of a 4-color synthetic ⇒ center pixel sample == that quadrant's color (±ε, resamplers drift ±1 LSB across OS).
- Solid-fill resize ⇒ corner samples unchanged (no edge bleed, ±ε).
- Export JPEG @ {0.3, 0.6, 0.9} ⇒ byte sizes **strictly increasing** (property, not exact bytes — codec versions drift).
- Export PNG ⇒ `decode(encode(img)) == img` **exactly** (lossless colorspace canary).
- Re-open exported `Data` ⇒ `CGImageSourceGetType == expected UTI`, dims preserved.
- Model laws: `render(doc+op−op) == render(doc)`; revert ⇒ `ops.isEmpty` and render == orientation-normalized source; `decode(encode(doc)) == doc` (persistence).

---

## 3. `~/.claude` agent-monitoring PoC — first slice + automated validation

**Head-start:** `Sources/ViewerCore/ClaudeLogParser.swift` already exists (structured `ClaudeEvent` with `userMessage`/`assistantMessage`/`thinking`/`toolUse`/`toolResult`, forgiving line-by-line parse, resource caps). The PoC extends it, not replaces it.

**First slice = a headless session-index + transcript-event reader over the real on-disk layout:**
1. **`ClaudeSessionIndex`** — enumerate `~/.claude/projects/*/*.jsonl` **top-level only** (skip sibling `<uuid>/` sidecar dirs and `subagents/`). For each: stream line-by-line (123 MB / 29K-line files exist — **never slurp**), extract title = last `custom-title` → last `ai-title` → first user-prompt text (append-and-last-wins; scan whole file), first/last `timestamp`, real `cwd` from records (project-dir name is **lossy** — never reverse it).
2. **Session key = filename stem**, not in-record `sessionId` (they diverge on resume/fork; multiple files can share one `sessionId`). Confirmed gotcha in the report.
3. **Byte-offset line index** per file for lazy random-access in a future detail view.
4. **Extend `ClaudeLogParser`** to handle the `system`/`subtype` records the report enumerates (`turn_duration`, `api_error`, `compact_boundary`) and `thinking.signature` stripping.
5. **Hard redaction layer** — never read `.credentials.json`/`stats-cache.json`; strip `thinking.signature`, `system.api_error.error.headers` (contains `set-cookie`!), and large `image.source` blobs. Open everything read-only.

**Automated validation (all T1 headless, fixtures = synthetic `.jsonl` written to `FileManager.temporaryDirectory` per project rules):**
- **Title resolution** — fixture with `ai-title` then a later `custom-title` ⇒ index returns the `custom-title` (last-wins). Fixture with neither ⇒ first user-prompt text.
- **Session-key divergence** — fixture file `aaaa.jsonl` whose records carry `sessionId: "bbbb"` ⇒ index key is `aaaa` (filename stem), not `bbbb`.
- **Sidecar exclusion** — fixture project dir with a top-level `.jsonl` + a `<uuid>/subagents/agent-*.jsonl` ⇒ index lists exactly one session; subagent surfaces as a child, not a top-level row.
- **Streaming bound** — feed a fixture with a single pathologically long line (> cap) ⇒ parser skips it, doesn't OOM, doesn't throw (forgiving-parse contract); assert peak allocation stays bounded.
- **Redaction (security gate)** — fixture `assistant` record with `thinking.signature` and a `system.api_error` with `error.headers.set-cookie` ⇒ parsed/rendered output contains **neither** string. Assert by substring search on the serialized event. This is the must-pass gate before any UI.
- **Polymorphic content** — fixture `user` record with `content` as a string AND one with `content` as a block-array carrying `tool_result` ⇒ both parse (`Array.isArray` branch).

---

## 4. Hooks integration — recommendation

**Adopt the passive JSONL logger, but as the *write path* feeding the §3 viewer — not a standalone.** The hooks report's design is sound and matches Jos's existing `~/.claude/hooks/` conventions (`set -uo pipefail`, `input=$(cat)`, `jq`).

Concrete recommendation:
- **Wire only the passive seven events** (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `SubagentStop`, `Notification`). **Never `exit 2`** from a monitor — it blocks the agent. Always `exit 0`, emit nothing.
- **Flag to surface to Jos:** his `~/.claude/settings.json` currently has **no `hooks` key** — the two existing scripts (`backup-on-write.sh`, `block-edit-fullfile-rewrite.sh`) are **on disk but unregistered/dormant**. He may believe they're active. Surface this before adding the monitor block, since wiring hooks means a session restart (no hot reload) and he may want the existing two registered too.
- **One file per `session_id`** under `~/.claude/monitor/` (avoids cross-session/parallel-subagent interleave; lines > 4096 B `PIPE_BUF` on macOS can interleave otherwise). Don't re-inject full `raw` payloads if secrets are a concern — cherry-pick fields + byte-lengths.
- **The hook log is redundant-but-cheaper-to-tail** vs the canonical `transcript_path` `.jsonl`. Recommend the viewer (§3) read the **canonical transcripts** as source of truth and use the hook log only for the **live-tail / real-time feed** (the report's `UserPromptSubmit`→`Stop` latency-diff use case). Don't fork the schema — `transcript_path` is in every hook payload, so the hook line can just be a pointer + timestamp.

**Automated validation:** a shell test (in `Tests/` or `scripts/`) that pipes each event's sample stdin JSON into `monitor-log.sh` and asserts: (a) exit code 0, (b) empty stdout, (c) exactly one well-formed JSON line appended to the per-session file, (d) `jq` round-trips the line. Run it for an oversized `tool_input` payload to confirm no crash. This is a pure bash+jq test — runs anywhere, no GUI.

---

## 5. From the blank-slate explorer — what to elevate

Three items the perf/feature reports didn't cover, elevated because they hit *trust* and *first-impression* at low cost:

1. **Live Light/Dark switch doesn't update syntax highlighting / editor theme (P0).** Verified: `DocumentModel.swift:2307` reads `NSApp?.effectiveAppearance` inside a *computed* `activeTheme`, and `grep` confirms **no `effectiveAppearance` KVO, no `colorScheme` reader anywhere** in `Sources/ViewerUI/`. Markdown CSS flips instantly via `prefers-color-scheme` but the adjacent code panes stay stale until an unrelated republish — which makes it *look* broken. **Fix:** observe `AppleInterfaceThemeChangedNotification` (or KVO `NSApp.effectiveAppearance`) and bump a `@Published`. Cheap, high visibility.
   - **Validation (headless gate):** inject the appearance via a seam (don't depend on live `NSApp`); assert that flipping it fires `objectWillChange` and `activeTheme.name` changes. Pure-logic.

2. **Editor "dirty dot" never appears (BUG-001, S2).** The single most important "is my work safe?" signal now that the app has drifted into a real CM6 editor. **Validation:** headless — `model.updateEditorText(...)` on a clean buffer ⇒ `isDirty == true` and the tab's dirty-indicator state flips; save ⇒ back to false. The `EditorBuffer`/`isDirty` plumbing already exists in `ViewerCore`.

3. **Bare empty state (P3 #10).** First thing every user sees with no restored session. The recents data already exists on the model and `.onDrop` (`handleDrop`, `ContentView.swift:435`) is already wired but invisible. **Fix:** recents/bookmarks grid + explicit drag-drop hint. **Validation:** headless snapshot of `EmptyStateView` view-tree — assert it contains the recents collection and a drop-hint accessibility identifier when `recents` is non-empty.

**Not elevating now:** WebView find DOM-rewalk (P1 #6 — real but lower felt-impact than tab retention), `--mcp-stdio` EOF leak (P2 #7 — operational, fix opportunistically), DocumentModel god-object size (P3 #12 — trajectory is right, no urgency). The explorer's own one-week pick — tab retention + appearance + dirty dot + empty state — aligns exactly with elevating #1 (Fix #1 above) plus these three.

---

### Build order across all five workstreams
1. **Perf Fix #1** (tab retention) — highest felt impact, unblocks Fix #2. Mount-count invariant test is the gate.
2. **Explorer P0 #1 + #2** (appearance + dirty dot) — cheap, trust-critical, pure-logic gated.
3. **Image-editor v0 spine** in `ViewerCore` — fully parallel (no UI overlap), self-contained T1 gate.
4. **`~/.claude` index + redaction** extending `ClaudeLogParser` — parallel; redaction test is the must-pass security gate.
5. **Perf Fix #2/#3/#4**, then hooks wiring (after flagging the dormant-hooks state to Jos) and empty-state polish.

Every item above has a named headless/automated validation; nothing relies on human observation. Heavy T4/T5 (live app, pixels) stay on the VM lane and are not part of any gate here.