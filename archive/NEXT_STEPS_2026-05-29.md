# Next steps — 2026-05-29

A concrete roadmap. Each section is something a future session can
pick up immediately. Items are sized (`S` <1 day, `M` 1-3 days,
`L` >3 days), severity / value tagged, and have a "dispatch shape"
note when an agent run is the natural way to do it.

---

## Tier 1 — fast wins, ready to dispatch

### 1. Perf findings #6–#10 (S each, parallel)

Each is a small focused agent. From `docs/code-review/PERFORMANCE_2026-05-25.md`:

| # | Where | Fix sketch |
|---|---|---|
| #6 | `SidebarView.swift:763` — eager `ForEach` inside `LazyVStack` | Hoist each tree level into its own `LazyVStack` or use `OutlineGroup`. Bench first to confirm symptom on deep trees. |
| #7 | `LSPPositionConverter.swift:70` — "binary search" is linear | Actual binary search on the cached line-start array. Confirm a per-hover cost reduction. |
| #8 | `HexView.buildDump` synchronous on main | Background actor builds the attributed string in chunks; stream into NSTextView via `setAttributedString` on increments. |
| #9 | `CrossFileSearch.lowercased()` per file + per line | Pre-compute lowercased buffer once per scan; pass into the line-match path. |
| #10 | `CSVParser Array(text.unicodeScalars)` | Iterate scalars in place without materialising. |

**Dispatch shape:** one agent per item; can run in parallel (all
touch different files). Brief generic; require a before/after
microbench for the ones where impact is the bar (#8, #9).

### 2. CodeMirror Phase 4 deferred items (M each, sequential)

Some explicitly need user decisions; some don't.

- **Vim mode** (`@replit/codemirror-vim`, MIT, ~210 KB) — needs
  explicit dep approval. After approval, ~1 day to land. See
  `docs/VIM_MODE_OPTIONS_2026-05-23.md` for the full plan + risk
  matrix.
- **Diff/blame gutter Swift wiring** — JS API is in place. Feed
  belongs in `GitService`/`DocumentModel`, not the CM6 layer. Small
  agent: read `GitClient.diff(forFile:)`, push `setGutterMarkers`
  on file open. **M.**
- **LSP hover markdown rendering** — currently plain-text. Two
  approaches: (a) vendor a tiny JS markdown→HTML in the CM6 bundle
  (~5 KB), (b) render to `NSAttributedString` Swift-side then
  serialize as HTML through the bridge. (a) is cheaper; (b) shares
  more code. **M.** Decision needed.
- **`workspaceSymbol/resolve` for URI-only stubs** — rare in
  practice (sourcekit-lsp + pyright inline full Location).
  **Defer unless a user hits it.**
- **`lsp.json` per-workspace override** — designed in
  `docs/LSP_DESIGN.md §11`; not implemented. **M.**

### 3. Security M/L findings (S each, sequential)

Remaining items from `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`:

- **`setrlimit` for LSP/jq/git subprocesses** — only
  `PluginSubprocessHost` has it. Needs a small C bridging layer
  in `ProcessRunner`. Per-request timeouts mitigate but don't
  bound CPU on a single request. **S.**
- **`MCPServer` `DispatchQueue.main.sync` from background thread**
  — refactor to a continuation-based bridge. **S.**
- **Mermaid `mermaidInjected` flag permanence** — reset on document
  change in `MarkdownRenderedView.swift`. **S.**
- Apply `Data(rawBuffer)` defensive pattern to `MCPFraming` and
  any other custom framing code (macOS 26 slice-offset gotcha).
  **S.**

---

## Tier 2 — Test coverage / hygiene

### 4. VM E2E sweep for recent work

Tests authored for the VM (via `MultiScenarioTestCase`) that haven't
been run there:

- `EditorPhase4ScenarioTests` (CM6 Phase 4 — v2 protocol, fold,
  indent guides, 50 MB cap)
- Editor hover popover render
- Cmd-click → definition jump
- NSMenu context-menu pop
- Large-paste confirm prompt
- Recency stripe rendering on file tree
- Sidebar polish — divider planner + light-grey bg + card chrome

**Dispatch shape:** one orchestrator agent that rsyncs to VM,
runs `swift test`, reports failures. No code changes expected;
might surface flakiness or missed pieces to file new BACKLOG items.

### 5. Test infrastructure cleanup (M)

- Pre-existing tests with `_ = result` discards in LSP smoke tests
  (3 left over from the dishonest-tests pass).
- `LSPPool` actor isn't exercised against the FakeLSPServer (only
  `LSPClient` is). Add coverage: idle reaper, restart-on-crash,
  dead-cooldown, concurrent `ensureLive` races. Pattern lives in
  `Tests/ViewerCoreTests/LSP/LSPClientFakeServerTests.swift`.
- Apply `TabKeyedStore<T>` generic to the per-tab dict cleanup
  fan-out on `TabCoordinator`. Currently 6 dicts × 1 hook =
  manual cleanup-by-shape. Generic + protocol would let new
  per-tab subsystems opt in by adopting the protocol. **M.**

### 6. Test-doc gap audit

`docs/UI_TEST_GAPS_2026-05-22.md` is stale relative to recent
work. Regenerate (read-only audit agent) to surface what's still
uncovered after all the recent test landings.

---

## Tier 3 — Architecture follow-throughs

### 7. Further coordinator extractions (M each, sequential)

Three coordinators landed; DocumentModel is now ~1600 LOC. Candidates
for further extraction:

- **`CacheCoordinator`** — `HighlightCacheActor` map +
  `renderedHTMLCache`. Both per-tab-keyed, both subsystem state, both
  currently on DocumentModel. Decision: extract now, or wait for
  a fourth domain to justify a generic? **L.**
- **`PaletteCoordinator`** — command palette state + sidebar key
  monitor + Cmd-K wiring. Currently scattered. **M.**
- **`LSPDocumentCoordinator`** — per-document LSP state (open,
  didChange version, outline cache). Currently the methods are
  on `LSPOutlineModel` + scattered. **M.**

These are nice-to-haves; only worth dispatching if DocumentModel
keeps growing. The current split has captured the big wins.

### 8. `main.swift` further slim (S)

`Sources/MarkdownViewer/main.swift` is 1580 LOC after the
`ScriptRunner` + `Diagnostics` extractions. Remaining inline:

- Menu builder (~500 LOC)
- NSServices registration
- Walkthrough CLI wiring
- MCP startup
- Window setup + autosave
- AppDelegate plumbing

Each is a small, mechanical extraction. Worth doing if `main.swift`
gets touched again.

### 9. Activity-bar UI swap (L)

Groundwork landed (`SidebarPanelKind` enum + `SidebarPanelRegistry`
+ `SidebarPanelProtocol` + `SidebarPanelVisibility`). The UI swap
itself — replace accordion with a vertical icon column that toggles
which single panel is visible — wasn't shipped. **L** (multi-day,
significant UX redesign).

Sequence with the FILES-pane-first decision the user made earlier:
the FILES tree is now the top accordion. Activity-bar UI would
flip that to "FILES is the default single-panel selection."

### 10. Two-viewer-path unification (L+)

`docs/CM6_CAPABILITIES_QNA_2026-05-23.md` Q3 surfaced the open
question: keep both native source viewer and CM6, or unify? Current
plan (Q&A doc): keep both short-term, unify the bridge layer (find
bar, scroll persist, bookmarks), retire NSTextView for ≤50 MB once
a shared-WebView refactor lands. **L+.**

The CM6 capabilities Q&A document this in detail. Don't act on it
until the per-tab WebView footprint becomes a real pain (memory in
20+ open tabs).

---

## Tier 4 — Strategic / open-ended

### 11. LSP roadmap continuation

`docs/LSP_ROADMAP_2026-05-22.md` has more phases beyond what's
shipped:

- Workspace symbol search wired into the unified search panel as
  a 6th mode (the design doc anticipates this; not built).
- LSP `foldingRange` driving CM6 folds — JS API is in place; Swift
  side needs `LSPClient.foldingRange(url:)` to actually be called
  from a fold service.
- Inline diagnostic squiggles — currently lint gutter shows them;
  the inline squiggle itself isn't wired.

Each is **S-M**.

### 12. Distribution (Phase 9)

Task #16 has been [pending] forever. Real distribution requires:

- Developer ID signing (currently local-only)
- Notarization
- A reproducible build pipeline (CI? Bash script?)
- A homepage / install instructions
- Telemetry decision

Out of scope for incremental work; needs a session that intends to
ship.

---

## Suggested first-session-after-handoff priority

If a future session has 2-4 hours and asks "what should I do
first":

1. **VM E2E sweep** (Tier 2 #4) — confirms recent landings work
   end-to-end. The CM6 editor + the coordinator extractions are
   the riskiest pieces; VM is the canary.
2. **Perf #7 + #9** (Tier 1 #1) — both are quick wins with clear
   evidence; bundle into one agent if you want.
3. **Security `setrlimit` + Mermaid flag reset** (Tier 1 #3) —
   small, no design debate.

After that, decisions queue up:

- Vim mode dep approval (yes/no)
- LSP hover markdown rendering approach (bundle JS markdown vs
  AppKit→HTML serialize)
- Whether to extract `CacheCoordinator` now or wait

---

## How to act on this

Use `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/HANDOFF_2026-05-29.md`
to orient. Pick an item, dispatch generically (see DESIGN.md
"Subagent prompt discipline"). Most items are single-agent shape;
parallelism only when items are file-disjoint.

Where applicable, follow the post-merge ritual:
1. `swift build` → assert clean
2. `swift test --filter ViewerCoreTests` → assert green
3. `bash scripts/build-app.sh release && cp -R dist/TextView.app /Applications/`
4. Eyeball-test the change in the installed app

For risky landings (anything touching `DocumentModel` /
`TabCoordinator` / observation chains), require an invariant test
in the agent's brief before merge.
