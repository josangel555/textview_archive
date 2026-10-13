# Overnight session — 2026-05-18

Autonomous run between ~05:00 and ~05:55 PT. Twelve commits, 30 new
tests, multi-agent review sweep with fixes applied. VM-canary final:
**804 tests, 3 skipped, 0 failures.**

## What landed (newest → oldest)

| Commit | Subject |
|---|---|
| `fed8eff` | fix: ModeBar picker overflow at high uiScale; ClaudeTimeline VoiceOver |
| `9f4d41e` | docs: LESSONS — Foundation URL portability + NSViewControllerRepresentable intrinsic-size |
| `4cbbad8` | fix + test: review-agent findings (HIGH MediaPreview, MED engine reentrancy + loader portability, LOW transport perms/bound) |
| `08df588` | docs: BACKLOG — MCP research findings, defer swift-mcp dep |
| `1711f2f` | feat: walkthrough engine + loader + drop transport |
| `df734bd` | ui: polish — file icons, glyph badges, scalable ModeBar picker |
| `49da010` | docs: TreeSitter lazy-load design + CLAUDE.md + BACKLOG |
| `576ebaa` | perf: SourceGutterView digit-count → label size lookup |
| `1564929` | perf: CSV filter pre-lowercased rows cache |
| `b422ee2` | perf: materializeIfNeeded off-main with .loading placeholder |
| `18378c9` | fix: .md opens in narrow source strip on first interaction |
| `b2f6515` | fix: 6 bugs from code-quality audit (continued from prior session) |

## High-impact items

- **`materializeIfNeeded` off-main**: lazy tabs now flip to a new
  `.loading(URL)` state, file read runs on detached Task, swap on
  MainActor. UI no longer freezes when clicking a tab pointing at a
  big log/CSV. New `LoadingStateView` with 100ms grace period before
  the spinner appears.
- **CSV filter pre-lowercased cache**: ~3-10× faster typing in the
  filter bar on multi-MB CSVs. Cache populated in `reparse()`,
  shape-validated at apply time with fallback to live `lowercased()`.
- **Walkthrough engine + loader + transport**: the engine layer of
  the walkthrough player from `docs/WALKTHROUGH_DESIGN_v2.md`. 30
  new tests pass. UI player + popovers + callouts intentionally
  deferred — needs design iteration. Engine isn't wired to anything
  visible yet.
- **`.md` narrow-strip fix**: two compounding causes — source-view
  branch lacked `.frame(maxWidth: .infinity, maxHeight: .infinity)`,
  and `openOrReveal` was preserving stale `.source` viewMode on
  lazy/restored tabs. Both fixed; 2 new TabsStateTests pin the
  lazy-vs-materialized split.

## Review findings + fixes

Parallel review sweep ran 5 agents (security / concurrency / code
quality / perf / regression). Findings applied:

| Severity | Finding | Fix |
|---|---|---|
| HIGH | `MediaPreview.loadSiblings` tautological stale-result guard | Compare against view's live `url` instead of task's own captured `current` |
| MED | `WalkthroughEngine` reentrancy via sync delegate dispatch | Added `applying: Bool` guard + assertion |
| MED | `WalkthroughLoader.pathEscape` Foundation portability | `URL(relativeTo:)` behaves differently on Swift 6.1 (VM) vs 6.3 (host). Switched to `NSString.appendingPathComponent`. **Verified on both.** |
| MED | ModeBar picker overflow at high uiScale | Switched to `.fixedSize()` so segmented control sizes to its actual content |
| MED | ClaudeTimeline glyph badges read SF Symbol names to VoiceOver | Added `.accessibilityLabel` |
| LOW | Drop-dir permissions default 0o755 | Created with 0o700 explicitly |
| LOW | `WalkthroughDropTransport.delivered` set unbounded | FIFO eviction at 1024 entries |
| LOW | Stale `viewMode` captured in materialize completion | Documented as known limit; behavioral impact = HEX-mode binary kick uses stale state, no security/correctness issue |

## Decisions deferred (need your input)

- **TreeSitter +6 langs (Java, C, C++, C#, Rust, Lua — Kotlin
  skipped)**: static link would add ~9.8 MB and blow the 25 MB cap.
  Lazy-load design in `docs/TREESITTER_LAZY_LOAD.md`. **2.5 dev
  days** to implement. Approve to proceed.
- **MCP automation**: research found `modelcontextprotocol/swift-sdk`
  is pre-1.0 with monthly breaking changes; pulls swift-nio
  (+3-6 MB). Adopters tend to ship it as a sidecar exe. Alternative:
  roll our own minimal stdio JSON-RPC server (~500-800 LOC,
  zero deps). Defer the dep until path is decided.
- **Walkthrough UI player**: engine is done; UI needs design
  iteration with you (controller strip layout, callout positioning,
  popover anchoring).
- **Sessions** / **LSP** / **Plugin v2**: still pending features
  from `BACKLOG.md`.

## Tests added

| Suite | Tests | What they pin |
|---|---:|---|
| `WalkthroughEngineTests` | 17 | next/previous bounds, jumpTo, restart, delegate dispatch per Action variant, pause/resume, reentrancy guard |
| `WalkthroughLoaderTests` | 13 + 1 | schema reject, duplicate id, path-escape rejection, relative-path resolves consistently across Foundation versions |
| `CSVFilterTests` | +4 | lowercased-rows nil fallback, count-mismatch fallback, per-row col-count fallback, cache-vs-no-cache equivalence |
| `DocumentControllerTests` | +2 | `.loading(URL)` equatable by URL; cross-case inequality |
| `TabsStateTests` | +2 | openOrReveal preserves viewMode for materialized error / preview tabs |

Plus 2 prior `TabsStateTests` for lazy-vs-materialized adoption.

## Remaining recommendations from agents (not yet applied)

These are real but lower priority / require design discussion:

- Stringly-typed Walkthrough payloads (`SetViewPayload.mode: String`
  where `ViewMode` enum exists). Defense-in-depth — the loader is
  the security boundary. Touch with the UI player work.
- `materializeIfNeeded` cancellation token. Currently a tab close
  drops the result but doesn't cancel the file read. Minor — only
  matters when rapidly cycling through huge files.
- CSV `lowercasedRowsCache` doubles peak memory for big CSVs. Could
  threshold at 256 KB (only build cache for big files) or build
  off-main. Current cost: 500K rows × 10 cols × ~20 bytes per
  String header = ~100 MB on a 100 MB CSV.
- `MediaPreview.loadSiblings` rapid-fire still has no cancellation;
  the live-url guard catches stale results but the task still runs
  to completion. Minor.
- `renderedHTMLCache` keyed on `(url, byteCount)` — pre-existing
  bug, not a regression — could serve stale HTML if a file watcher
  reload preserves byte count.

## Installed

`/Applications/TextView.app` rebuilt and reinstalled. Bundle size:
24 MB (under the 25 MB cap).
