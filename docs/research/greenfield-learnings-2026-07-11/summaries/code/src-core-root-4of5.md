# ViewerCore Root Files Slice 4/5: Summary & Learnings

Batch covers files 154–204 (alphabetically): **51 files** analyzed.

---

## File Inventory

**MDVNegativeControl.swift** (23 LOC) — Test harness teeth-proving helper (`MDV_ENABLE_BROKEN_<NAME>` env toggles).
- notable: Pure env reader; unifies all negative-control switches under one idiom for visual/render guard verification.
- carry: **KEEP** — elegant inversion pattern for proving tests go red on broken code.

**MediaCodecName.swift** (61 LOC) — Media codec FourCC → human-readable name mapping (video/audio).
- notable: Hand-coded FourCC table; big-endian decode; defensive fallback to `?` for unprintable bytes.
- carry: **KEEP** — type-safe, minimal, no external codec lookup needed.

**MountedPanesLRU.swift** (82 LOC) — MRU-ordered cache for mounted panes (perf fix #1); LRU eviction + `trim()` for memory pressure.
- notable: Pure value type; no SwiftUI; round-trip-testable eviction logic; idempotent `activate()`.
- carry: **KEEP** — excellent isolation; core logic stays separate from render wiring.

**NewFileCreator.swift** (172 LOC) — Atomic file creation (`O_CREAT | O_EXCL`); collision-safe naming; path-traversal guards; opt-in seed contents.
- notable: Race-free name collision (NUL/path-separator/`..` rejection); best-effort write on empty files; wrap on create-then-write to avoid TOCTOU.
- carry: **KEEP** — careful POSIX hygiene; clipboard paste-scratch seed (TSK-935) is elegant.

**OmniResolver.swift** (96 LOC) — New-tab omnibox classification: path/URL/git-remote/search/empty → pure by shape + injected filesystem probe.
- notable: Git remote detection (ssh: + .git + forge hostnames); scheme validation (letter-first); ~tilde expansion.
- carry: **KEEP** — exemplary pure classifier; injectable `pathExists` seam for testing.

**OpenPanelRecents.swift** (144 LOC) — Recent files accessory for NSOpenPanel; de-dup + existence-filter + cap; pure over newest-first list.
- notable: Path standardization (so `/a` and `/a/` collapse); injectable FileManager probe; `addingOnOpen` for head-update.
- carry: **KEEP** — clean seam; pure derivation; parent-hint label (IntelliJ style) disambiguates same-named files.

**OutlineNavigation.swift** (63 LOC) — Markdown outline: current-heading binary search by line, keyboard next/prev, filter by substring.
- notable: Pure navigation model; case/diacritic-insensitive filter; preserves original indices for click-to-jump.
- carry: **KEEP** — minimal and self-contained; ready to wire to any outline UI.

**OutputNaming.swift** (45 LOC) — Non-colliding output URLs; `<base>-2.<ext>` Finder convention; multi-dot aware; injectable exists probe.
- notable: Reusable for save/extract/convert flows; runaway guard (`maxAttempts`); tolerates absence-of-probe return.
- carry: **KEEP** — elevates a common "don't clobber" pattern to a library; pair with SaveConflictDecision for comprehensive coverage.

**PackageManifest.swift** (383 LOC) — Package manifest parsers: npm package.json + Cargo.toml → `DependencyPackage` + edges for graphing.
- notable: **Bounded TOML reader** (not a general parser); tolerates malformed input gracefully (empty result, never throws); dependency deduplication by (name, kind); git repo detection on Cargo deps.
- carry: **KEEP** — excellent degradation strategy; the "bounded" scope is a lesson for DSL parsing (don't over-engineer).

**PaletteCandidateCache.swift** (55 LOC) — Generation-keyed memoizer for query-independent work (bookmarks + recents merge); single-slot, `@MainActor`-only.
- notable: Decouples expensive rebuild from keystroke-driven queries; `invalidate()` escape hatch.
- carry: **KEEP** — tiny, focused; pattern for any recalc-gated cache.

**PanelDockLayout.swift** (169 LOC) — Persisted per-panel tool-window SIZE (width on right, height on bottom); sparse map; clamped + normalized.
- notable: Persistent storage: comma-joined `kind:edge:size` tokens; NaN/infinity handling; unknown tokens dropped on decode (forward-compat).
- carry: **KEEP** — type-safe persistence pattern; mirrors PanelEdgeAssignment idiom exactly.

**PanelEdge.swift** (192 LOC) — Panel dock edge enum (left/right/bottom); sparse per-panel override map + global default edge; persistence.
- notable: Edge assignment is SPARSE (only deviants stored); re-normalized on default-change so encoding stays canonical; test-pinned storage key.
- carry: **KEEP** — elegant sparse-map + normalization pattern; global default is a clean abstraction for "where new panels land."

**PanelPlacement.swift** (74 LOC) — Placement validation (only non-dockable panels can't leave `.left`); pure move operator.
- notable: Single source of truth for legality; `validate()` + `move()` are idempotent; result enum names the rule violated.
- carry: **KEEP** — dispatch table as enum (not booleans) scales cleanly for future rules.

**PanelResize.swift** (17 LOC) — Panel width clamp: proposed width, available space, minimum content + panel → clamped.
- notable: Trivial but essential; panel never shrinks below usable, content never starves; live window-width passed by gesture handler.
- carry: **KEEP** — pure constraint logic; the model/view split keeps gesture wiring simple.

**PanelVisibilityOverrides.swift** (93 LOC) — Sparse per-panel visibility override map (auto/shown/hidden); persistence.
- notable: `.auto` is the default (deferred to data-presence heuristic); toggle only writes explicit `.shown` / `.hidden` (never snapshotting heuristic state); unknown tokens dropped.
- carry: **KEEP** — three-state enum avoids "freeze heuristic on first toggle" bug; persistence pattern reuses PanelEdgeAssignment.

**PanelVisibilityResolver.swift** (44 LOC) — Truth table: (override, dataPresent) → visible; pure.
- notable: `.auto` keeps heuristic LIVE; `.shown` / `.hidden` freeze intent. Minimal and testable.
- carry: **KEEP** — model/view contract is clear; no state, no side effects.

**ParseMemo.swift** (25 LOC) — Single-slot memoizer keyed by string; recompute only on key change.
- notable: Stops query-independent re-parse on keystroke (e.g., command-palette heading re-parse per character).
- carry: **KEEP** — focused; Main-actor-only by design (not Sendable).

**PasteDispatch.swift** (209 LOC) — Pasteboard type precedence resolver (file > image > table > richText > plainText); injectable HTML-body peek.
- notable: Comprehensive TypeID sets (UTType + legacy NSPasteboard names); case-insensitive matching; TSV-detection for spreadsheet pastes (tab-delimited conservative heuristic).
- carry: **KEEP** — exhaustive table; `htmlContainsTable` substring match is permissive (false-positive → worse display, not data loss).

**PreferencesStore.swift** (300 LOC, partial read) — UserDefaults wrapper for prefs (zoom, sidebar, fonts, window frame, etc.).
- notable: Clamping on both read and write; legacy migration (UIScale → zoom); window-frame as JSON for deterministic layout; test-injectable via init.
- carry: **KEEP** — thin, clear; the JSON window-frame is better than AppKit autosave (testable).

**PristineChrome.swift** (42 LOC) — Deterministic chrome for harness spawns: `MDV_PRISTINE_CHROME=1` empties a process-scoped UserDefaults suite.
- notable: Isolates test harness from shared user settings; prevents leaked terminal layout / zoom / frame from polluting pixels.
- carry: **KEEP** — essential for T5 pixel test reproducibility; pattern should apply to any multi-spawn harness.

**ProcessRunner.swift** (591 LOC) — Subprocess runner with drains, stdin, timeouts, resource limits (CPU/fsize/nofiles), overflow cap + escalation to SIGKILL.
- notable: **Concurrency**: stdout/stderr on separate queues (kills 64 KB pipe deadlock); **Limits**: shell-wrapped ulimit (macOS rlimit reality documented); **SIGTERM→SIGKILL escalation** if child traps SIGTERM; **Output cap** with running byte counter (stops buffering unbounded streams); **SIGPIPE suppression** on stdin close (child-fail resilience).
- carry: **KEEP** — excellent hardening; the decision to document macOS rlimit enforcement gaps (RLIMIT_AS/RLIMIT_DATA NOT enforced) is honest. Reuse for any subprocess; the post-SIGKILL orphan-reaping grace is subtle + correct.

**ReconnectBackoff.swift** (55 LOC) — Exponential backoff + degrade window for remote-core reconnects: base/cap/degradeAfter (nullable).
- notable: Saturating double (overflow-safe); overflow-gated escalation to SIGKILL if child traps SIGTERM.
- carry: **KEEP** — pure policy, injectable into any reconnect loop; degradeAfterMs=nil means "retry forever" (MCP-bridge), Some=30s means local fallback.

**RememberedLensStore.swift** (138 LOC) — Auto-remember last-viewed lens per file; PRODUCT-GATED (TSK-1502, default OFF); keyed by lowercased filename; LRU eviction.
- notable: Explicit lock takes precedence > remembered lens (if gate on) > category default; gate toggle affects precedence, not storage (lens persists across gate flips).
- carry: **KEEP** — good gate example; the "explicit lock wins" contract is sound; evict-on-mutations + cap prevents unbounded growth.

**RemoteCoreAttach.swift** (84 LOC) — App-side remote-core attach (unix socket dialed at launch); fail-safe (attach failure leaves in-process FFI installed); onClose reverts to local.
- notable: Launch-time-only (no reconnect loop in v1, deferred); TSK-1010 catches connection-loss-during-attach edge case.
- carry: **KEEP** — exemplary fail-safe design; the onClose reverts show resilience thinking.

**RenameFollower.swift** (29 LOC) — Follow externally-renamed files by (dev, inode); returns nil for true deletes or moves out of folder.
- notable: FileManager attributes lookup for inode; used to recover open-tab paths on external rename.
- carry: **KEEP** — small, focused; pairs well with scroll/lens memory stores for durable identity.

**RenderedBlockDiff.swift** (448 LOC) — DOM-patch diff layer for rendered markdown: block splitting, LCS matching, minimal patch set, JS payload serialization.
- notable: **Splitting**: depth-tracking tokenizer (not a full parser); void elements + comments as blocks. **Stable IDs**: tag + ordinal (not content) so edited blocks → replace, inserted blocks → insert. **LCS match**: by content-hash (position-independent). **Coalesce**: adjacent remove+insert → replace. **Payload**: JSON wire format for JS `applyBlockPatch`. Host-testable with round-trip proof (`apply(diff(old,new), to:old) == new`).
- carry: **KEEP** — elegant diff design; the "stable ID = structural, not content" is key to the minimal patch set. JS-apply side is the render tail.

**RustCMEditAdapter.swift** (36 LOC, rust-only) — CodeMirror edit apply; Stage-B (Swift twin deleted); bridge fault → `nil` (resync).
- notable: STAGE-B (TSK-649): the Swift CMEditApplier is DELETED — rust is sole engine; no gate. Bridge fault degrades to nil (full resync, observable log).
- carry: **KEEP** — pattern reuse for stage-B deletions; nil is a valid "resync" signal, not a fault.

**RustCoreFallback.swift** (98 LOC) — Generalization of gate + fallback: gate OFF → Swift; gate ON, rust OK → rust; gate ON, rust throws → Swift + log.
- notable: `.panic` escalated to `.error` (FFI corruption signal); everything else `.warn`. `runRustOnly` variant (stage-B twins deleted): rust-only, no fallback, degraded value specified by caller.
- carry: **KEEP** — excellent unification; panic/throw distinction is wise; log levels signal severity.

**RustCoreGates.swift** (157 LOC) — Per-capability feature gates (csv, cmEdit, hex, fuzzy, find, transcript, markdown, highlight, formula, fold); precedence: env > persisted toggle > default.
- notable: Env-only fast path (avoid ProcessInfo.processInfo.environment dict materialization on every FFI call—19µs saved per call!). Shipped defaults vary (stage-A soak set = csv/hex/fuzzy/find/transcript/markdown all ON; later ports OFF initially). Per-gate defaults key + env var for stability.
- carry: **KEEP** — excellent performance thinking (getenv vs dict); the graduated rollout policy is sound.

**RustCSVAdapter.swift** (142 LOC, stage-B, rust-only) — CSV parse routing; big-file windowed assembly (4 MiB chunks); A/B harness entry points.
- notable: Stage-B (Swift CSVParser deleted); bridge fault → empty table (observable log). Windowed assembly for >4 MiB files (FFI frame size capped at 16 MiB). Delimiter sniffed on prefix, then applied to full-text windows.
- carry: **KEEP** — the windowed strategy shows respect for FFI frame caps; excellent scaling design.

**RustCSVGate.swift** (36 LOC) — Gate for CSV (thin shim over RustCoreGates.csv).
- notable: Legacy key `MarkdownViewer.experimental.rustCSV` for back-compat; env `MDV_RUST_CSV`.
- carry: **KEEP** — legacy compat is good stewardship.

**RustDiffAdapter.swift** (89 LOC, stage-B, rust-only) — Unified-diff parsing; Stage-B (Swift DiffParser deleted); bridge fault → empty file list + error log.
- notable: Two FFI entries: `mdvCoreParseDiff` (file/hunk list) + `mdvCoreDiffHunkMarks` (gutter marks). Wires RustCore types to ViewerCore UnifiedDiff model.
- carry: **KEEP** — the dual-entry pattern (parse vs gutter-marks) is modular; worth replicating for other multi-faceted engines.

**RustFindAdapter.swift** (57 LOC) — Whole-document find routing; `.find` gate default-ON; catches `invalidPattern` (ICU-only constructs) as fallback trigger.
- notable: PikeVM is worst-case linear (ReDoS-safe); no wall-clock truncation (timedOut always false on Rust path). Fallback contract: invalid patterns return `[]` (not throwing), mirrors consumer's historical behavior.
- carry: **KEEP** — performance win (ReDoS immunity) + feature parity (no regex-truncation jank).

**RustFoldAdapter.swift** (42 LOC, stage-B) — Code-fold regions; Stage-B (Swift twin deleted); bridge fault → `[]` (no folds this pass).
- notable: `mapRegion` with forward-compat guard (unknown kind → drop); produces next text change retries.
- carry: **KEEP** — graceful degradation (empty gutter is safe); forward-compat via rawValue allows future kinds.

**RustFormulaAdapter.swift** (71 LOC) — Spreadsheet formula evaluation routing; recalc (full-grid cycle with circular-ref resolution); per-cell evaluate path.
- notable: Error code mapping (lowercase Rust strings to Swift FormulaError enum); leading-`=` strip before sending to Rust.
- carry: **KEEP** — enum-based error mapping is safer than string-matching; the recalc design (whole-grid cycle, resolves cycles) is sound.

**RustFormulaGate.swift** (15 LOC) — Gate for formula (default OFF initially, flipped ON 2026-07-07 after parity validation).
- notable: Thin shim over RustCoreGates.formula.
- carry: **KEEP** — consistent gate pattern.

**RustFuzzyAdapter.swift** (57 LOC, stage-B, rust-only) — BATCH fuzzy ranking; Stage-B (Swift FuzzyMatcher deleted); bridge fault → unranked (score 0, input order).
- notable: Unicode-scalar index semantics (noted explicitly for grapheme-heavy strings); empty query fast-path (skip bridge round-trip).
- carry: **KEEP** — the empty-query shortcut is good; backward-compat output (unranked shape) avoids render surprises.

**RustHexAdapter.swift** (39 LOC) — HEX dump render routing; `.hex` gate default-ON; only all-at-once render routed (chunked/streaming stays Swift).
- notable: CallSite entry points (production + A/B harness). Big-file rendering is Rust; incremental WV filling is Swift.
- carry: **KEEP** — boundary between Rust (batch) and Swift (stream) is pragmatic.

**RustHexSearchAdapter.swift** (40 LOC) — HEX search routing (parse + non-overlapping find); `.hexSearch` gate default-ON. Single-byte click → Swift (cheap).
- notable: Mode enum (hex/ascii); cheap click-highlight stays Swift (no FFI overhead).
- carry: **KEEP** — the boundary (batch find vs cheap click) respects FFI cost.

**RustHighlightAdapter.swift** (100 LOC, stage-B, rust-only) — Syntax tokenization; Stage-B (Swift TreeSitterEngine highlight twin deleted); default-ON; `warm()` pre-compile per-language configs.
- notable: Predicate evaluation now WORKS (TSK-410 class fixed); two-phase warm: prioritized langs serial (markdown on main actor), rest parallel. Forward-compat: unknown token kinds dropped. Fallback → empty runs (no highlighting).
- carry: **KEEP** — the warm strategy is excellent for reducing first-open latency; the prioritization (markdown first) is sensible.

**RustIndentAdapter.swift** (34 LOC, stage-B, rust-only) — Indentation detection; Stage-B (Swift IndentDetector deleted); bridge fault → `"—"` unknown sentinel.
- notable: Same sentinel as engine's no-indent value (safe degraded state); observable error log.
- carry: **KEEP** — reuse of the engine's own unknown value is elegant.

**RustMarkdownAdapter.swift** (106 LOC, stage-B, rust-only) — Markdown→HTML rendering; enrich chunks with host security (sanitize/escape raw_html, diagrams via registry, code tokenize via highlight, unknown kinds escape).
- notable: Chunk kinds: `raw_html` (sanitized), `diagram` (registered or escaped), `code` (tokenized), unknown (escaped). Version-skew safety (unknown kinds visible, never raw-injected). Degraded → escaped plain `<pre>`.
- carry: **KEEP** — chunk-based enrichment post-bridge is the right trust boundary; version-skew handling is thorough.

**RustTranscriptAdapter.swift** (79 LOC, stage-B, rust-only) — Claude transcript event projection; non-UTF-8 bytes decode lossily (replacement chars); Stage-B (Swift ClaudeLogParser deleted).
- notable: Two consumers: projection (timeline, search, monitor detail) + classification (statics, separate migration). Bridge fault → `[]` (no events).
- carry: **KEEP** — the lossy UTF-8 decode is pragmatic (equivalent-or-better than deleted per-line Swift path); two-consumer split is clean.

**SaveConflictDecision.swift** (120 LOC) — Pre-write conflict decision: dirty buffer × external edit × unknown disk state → proceed / conflict(actions) / reloadSilently.
- notable: Truth table (5 cases); decision is PURE (injectable current mTime/size). Non-destructive actions first (viewDiff, saveAsCopy), then reload, then overwrite (never default). Mirrors `DiskConflictResolver.classify` so watcher-time + write-time classifiers can't drift.
- carry: **KEEP** — closing a real data-loss class (blind ⌘S overwrite on unproven-clean disk); the action ordering prevents accidental destruction.

**ScratchStore.swift** (partial read, ~150+ LOC) — Disk-backed scratch cache (previews, diffs, jq output) with LRU-eviction + size/count/age caps.
- notable: Centralized `~/Library/Caches/MarkdownViewer/<sub>` resolution; pruning policy (7-day age cap + 200 files + 64 MiB by default); PURE eviction planner. Decision: disk-backed (browser open needs `file://` URL; in-process consumers benefit from unified buffer cache).
- carry: **KEEP** — excellent hygiene upgrade (five copy-pasted callers → centralized); the pruning + eviction design prevents unbounded growth.

**ScrollMemoryStore.swift** (partial, ~150+ LOC) — Durable per-file scroll + zoom memory (survives session switch + relaunch); identity via path + (dev, inode) fallback for renames.
- notable: Keyed by absolute path; fileID fallback for rename-robustness. LRU eviction (cap 500 entries, 1 MiB). Write-gating via `shouldPersist` (only persist when user moved away from restored position).
- carry: **KEEP** — elegant identity handling; the write-gating reduces churn; pairs well with RememberedLensStore.

**SearchResultCap.swift** (23 LOC) — Cap match rows per file in global search results (default 50); shows "+N more — open file" above the cap.
- notable: Tiny, pure; `visible()` and `overflow()` functions.
- carry: **KEEP** — simple, focused; bounds jank from files with hundreds of matches.

**SearchRouter.swift** (150+ LOC, partial) — Unified search routing: bare/`>`/`?`/`#`/`@`/`:` queries → source (recents/commands/globalText/inFile/symbol/line) + submit action.
- notable: Adds missing `?` operator (global cross-file text) + resolves to SearchSource enum (single switch instead of re-deriving which-widget-handles-this). Pure over query string, no I/O.
- carry: **KEEP** — the unified routing table is a good design; `?` for global search is mnemonic + unambiguous.

**SearchScope.swift** (71 LOC) — Search scope enum (activeFile/activeFolder/pickedFile/pickedFolder) + pure resolver.
- notable: Scope is non-modal (user can pick file or folder); resolver is pure (no validation, caller does that at runtime).
- carry: **KEEP** — clean separation; no I/O in the resolver.

**SecretBannerState.swift** (34 LOC) — Secret warn-badge state gate + label generation (redacted counts, no values).
- notable: Pure decision logic (`shouldShow`, `scanEnabled`, `countLabel`); gating + treatment stored as int (0=warn, 1=mask-future, 2=off).
- carry: **KEEP** — minimal and pinned by tests (not pixels).

**SecretDetector.swift** (155 LOC, partial) — Credential pattern detector: literal patterns (AWS/GitHub/Slack/GCP/JWT/PEM) + entropy-guarded generic assignment rule.
- notable: **Literal rules**: hand-coded FourCC; **Assignment rule**: case-insensitive key-end + entropy guard (mixed classes + Shannon ≥3.0 bits/char); dictionary/digest-shape filters (false-positive control). Line-incremental scan; capped at 200 findings. Pure + no value exposure (preview = first 4 chars + "…").
- carry: **KEEP** — honest about limitations (cannot prove absence; pixel-only masking, not secure bytes); the entropy guard + multi-class check is thoughtful.

---

## Module Summary

This slice is dominated by **Rust migration infrastructure**: ~20+ files (RustXxxAdapter/Gate) implement the stage-A/B strategy (gate + fallback for A, rust-only for B). The slice also includes:

1. **UI State Management** (Panel*, Preference*, Scratch*, Scroll*, Remember*, Search*): durable preferences, layout, scroll memory, search routing.
2. **Pure Decision Logic** (SaveConflict, PanelPlacement, OutlineNavigation, SearchRouter): model layers, host-testable, decoupled from render.
3. **Persistence Patterns** (PanelDockLayout, PanelEdge, PanelVisibility, ScratchStore): sparse maps with normalization, stable encoding, forward-compat.
4. **Process/Network Resilience** (ProcessRunner, ReconnectBackoff, RemoteCoreAttach): subprocess hardening, exponential backoff, fail-safe remote attachment.
5. **Security & Safety** (SecretDetector, SaveConflictDecision, NewFileCreator, PasteDispatch): credential detection, write-time conflict guards, atomic file creation, pasteboard precedence.
6. **Rendering** (RenderedBlockDiff): incremental DOM-patch diff for markdown preview (host-testable model, JS-apply is render tail).

---

## Patterns Worth Porting

### 1. **Sparse Map + Normalization Persistence** (PanelEdge, PanelDockLayout, PanelVisibility)
```
Encoded: comma-joined `kind:edge:value` tokens, sorted (stable diff-friendly)
Decode: unknown tokens dropped (forward-compat on field renames/removals)
Normalize: entries equal to default removed (keeps encoding minimal + canonical)
Test: round-trip + stability pinned by tests
```
**Why reuse**: three independent panel-layout systems all use this idiom; it's proven, testable, and upgrade-safe. Apply to any sparse user preference map (themes, keyboard bindings, etc.).

### 2. **Gate + Fallback Pattern** (RustCoreFallback, RustCSVAdapter)
```
Gate OFF         → Swift engine
Gate ON, Rust OK → Rust result
Gate ON, Rust throws → Swift engine + log (fail-safe)
Stage-B (twin deleted): gate omitted, rust-only, degrade to caller's value
```
**Why reuse**: A/B-safe gradual rollout; proven Swift path still wins on Rust faults. Env override (per-run) + persisted toggle (user intent) + default (shipped state) = clean precedence.

### 3. **Pure Decision Tables** (SaveConflictDecision, PanelPlacement, PanelVisibilityResolver)
```
Input: value types (no I/O, no state)
Output: decision or validated action (enum, not booleans)
Proof: round-trip tests, property tests, exhaustive case coverage
```
**Why reuse**: Decisions stay testable + reproducible; model/view split is clean; decisions can be logged/replayed.

### 4. **ProcessRunner Hardening** (resource limits, SIGPIPE suppression, SIGKILL escalation, output capping)
```
ulimit shell wrapper (exec replaces shell, so processIdentifier stays valid)
Concurrent stdout/stderr drain (kills 64 KB pipe deadlock)
SIGTERM → SIGKILL escalation (handles SIGTERM-trapping children)
Running byte counter + overflow termination (bounds memory of chatty subprocesses)
```
**Why reuse**: One battle-tested implementation beats five copy-pasted recipes. The SIGPIPE + SIGKILL escalation are subtle and easy to get wrong.

### 5. **Identity-Keyed Durable Memory** (ScrollMemoryStore, RememberedLensStore)
```
Primary key: resolved absolute path (standardized, symlink-resolved)
Fallback key: (dev, inode) for rename-robustness
LRU eviction: cap count + cap bytes + cap age
Write-gating: only persist on "user moved away from baseline"
```
**Why reuse**: Survives renames + session switches + relaunches. Pairs with SearchScope/RemoteCoreAttach for multi-faceted identity handling.

### 6. **Chunk-Based Host-Side Enrichment** (RustMarkdownAdapter)
```
Rust emits: structural HTML + chunks (raw_html, code, diagram, unknown)
Host enriches: security (sanitize), registry (diagrams), tokenize (code), escape (unknown)
Version-skew: unknown kinds are escaped, never raw-injected
```
**Why reuse**: Trust boundary is clear; host owns security; chunk extensibility is clean for future kinds.

### 7. **Entropy-Guarded Pattern Matching** (SecretDetector)
```
Literal rules: high-precision FourCC/PEM/token shapes
Generic rule: case-insensitive key-end, mixed-class + entropy filter
False-positive guards: dictionary words, digest shapes (hex + length)
```
**Why reuse**: Secrets detection needs both precision (low false-positive) and breadth (unknown formats). The entropy guard + multi-class filter is a sound heuristic.

### 8. **Write-Time Conflict Decision** (SaveConflictDecision)
```
Check: buffer.isDirty + hasExternalEdit + hasUnknownDiskState
Decision: proceed / conflict(actions) / reloadSilently (pure)
Actions: non-destructive first (view, copy), destructive last (overwrite)
Mirror: matches watcher-time DiskConflictResolver so both can't drift
```
**Why reuse**: Closes the "unproven-clean disk" clobber class; decision is pure (injectable stat), testable, replayable.

---

## Anti-patterns / Regrets

1. **Over-Abstraction of Panel State**: Three separate systems (PanelEdge + PanelDockLayout + PanelVisibility) share idiom but stay separate. **Rebuild**: Consider unified `PanelLayout` that bundles all three and co-normalizes. Separate systems invite desync (edge moved but size forgotten, etc.).

2. **Hardcoded FirebaseConfig in PreferencesStore** (would be domain-specific): The window-frame JSON is clean, but no versioning scheme if Frame structure evolves. **Rebuild**: Consider a versioned wrapper (`{version: 1, frame: {...}}`).

3. **ProcessRunner Complexity**: The SIGPIPE + SIGKILL + orphan-reaping logic is subtle and easy to regress. **Rebuild**: Document the invariants or add integration tests (beyond unit tests of the pieces) that verify the end-to-end kill+reap behavior.

4. **RustCoreGates Env Fast-Path**: The `getenv` optimization is good, but creates a second code path (inline fast vs dict slow). **Rebuild**: Profile to confirm the ~19µs wins justify the maintenance cost. If keeping, add a test that verifies both paths yield identical results.

5. **SecretDetector False Confidence**: The "no false negatives" claim is hollow (split strings, encodings pass); the doc is honest ("cannot prove absence") but UI may not be. **Rebuild**: Consider a `confidence` field (high/medium/low) in findings so UI can surface uncertainty.

---

## Gotchas & Surprises

1. **PristineChrome Process Suite Wiping**: Each pristine launch empties the suite (don't rely on per-PID uniqueness). The non-synced TMPDIR approach is needed to avoid iCloud issues. **Lesson**: Stateless test harness isolation is fragile; rely on reset + cleanup, not compartments.

2. **RenderedBlockDiff Tag Stability**: Tags are (name, ordinal), NOT content. A paragraph moved to a different position changes its tag ID (ordinal shifts). **Rebuild clarification**: This is intentional—ensures edited block → replace, inserted → insert. But a document-level reordering (entire section moves) degrades to many ops. Acceptable in practice (such reorderings are rare; the worst case is a full reload anyway).

3. **Fuzzy Adapter GraphemeCluster Indices**: `matchedIndices` are Unicode-scalar offsets, not grapheme clusters. Heavy-emoji text may highlight glyphs shifted from the user's expected selection. **Lesson**: Character indexing is subtle in Swift; always document the unit (scalar/cluster/UTF-16 offset).

4. **Pan elResize No Upper Bound**: The comment says "NO maximum limit" (brief item 2), and the view applies runtime clamp to available-space. The constant `maxSize: 100_000` is purely a "handle corrupt values" guard, NOT a UX cap. **Lesson**: Don't confuse corrupted-value handles with feature constraints; they're different silos.

5. **Markdown HTML Chunk "diagram" Routing Gap** (TSK-713): The rust renderer emits `code` chunks for fence bodies only (the `<pre><code>` wrapper already written). Diagram routing for dot/plantuml via registry happens in the Swift fallback only. The rust path is deferred (a follow-up slice). **Lesson**: A complex union (diff structural + content) can create asymmetry between two paths; document the gap explicitly (this file does).

6. **ScratchStore Eviction Stability**: Newest-first with path tiebreak makes eviction deterministic but observable (same file accessed at same time → arbitrary order). **Lesson**: For critical caches, consider stable total ordering (path first, then mtime) or mark evictions as informational-only.

7. **RememberedLensGate Asymmetry**: Explicit lock always wins (can't auto-remember over it), but toggling lock OFF doesn't auto-switch back to remembered lens. **Design intent**: Explicit intent wins; degradation is conservative. **Lesson**: Asymmetric rules need clear names (lock "pins", auto-remember "suggests").

---

## Rebuild Notes

### Approach
1. **Rust Adapters**: The gate + fallback pattern is production-proven. Replicate the precedence (env > persisted > default) and the Stage-B deletion cleanups (rust-only, observable log on fault, no panic silence).

2. **Persistence**: Adopt the sparse-map + normalization idiom for any user-selectable state. Version the JSON schema if it might evolve. Test round-trips + forward-compat (unknown tokens dropped).

3. **UI State**: Split model (pure, testable, no I/O) from view (wiring, render). Keep all decisions in the model layer so they're replayable + loggable.

4. **Subprocess Harming**: Use ProcessRunner for all external commands (git, jq, linters). The resource-limit shell wrapper and SIGPIPE handling are non-obvious; don't hand-roll.

5. **Write-Time Guards**: Replicate SaveConflictDecision for any save/export flow. The write-time restat (before committing) catches races the watcher misses.

### Boundaries
- **Modal vs Modeless**: SearchScope, PanelPlacement, SaveConflictDecision are examples of pure decision types (no I/O, no side effects). Keep these separate from their controllers.
- **Chunk Enrichment**: If a Rust engine emits chunks (code, diagram, etc.), handle version-skew by escaping unknown kinds (never raw-inject).
- **Gate Scalability**: RustCoreGates works for ~10 capabilities; if >20, consider a registry (but the current table is simpler and performant).

### What to Design Up Front
1. **Rust Adapter Naming**: All 20+ adapters follow `Rust<Engine>Adapter`; keep this consistent so they're grepable and nameable.
2. **Fallback Contracts**: For each gate, decide: does a bridge fault return a "default" value (empty array), or does the caller provide the degraded value? (Current: both patterns used; compat by design.)
3. **Eviction Policies**: If storing LRU state (scroll, lens, scratch), decide the three-axis policy (age/count/size) up front. ScratchStore + ScrollMemoryStore differ (one is files, one is metadata); the policies should match unless there's a reason not to.
4. **Persistence Format**: Comma-joined tokens are human-editable and test-friendly. If you switch to JSON, you lose the simplicity. Consider how upgrades will work (schema versioning, migration paths).

