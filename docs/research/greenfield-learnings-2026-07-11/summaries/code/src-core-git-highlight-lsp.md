# ViewerCore: Git, Highlight, LSP — Greenfield Learnings

**Scope:** 66 Swift files across three subsystems (Git, Highlight, LSP) totaling ~13,836 LOC. Analysis dates 2026-07-11.

---

## File-Level Inventory

### Git Subsystem (4,041 LOC across 23 files)

**Sources/ViewerCore/Git/GitClient.swift** (1,414 LOC) — Minimal git shell client via Process; non-throwing read ops (return [] on failure).
- notable: Process env is built from allowlist, not inherited (SEC-005 prevents env-injection); protective flags disable hooks/fsmonitor/editor/pager; protects revision tokens vs option-injection (e.g. `-` prefix guard). Timeout wall-clock cap (`statusTimeout`) separate from CPU RLIMIT. Lossless UTF-8 decode (U+FFFD substitution, not silent drop). Drained stdout/stderr concurrently to avoid pipe-buffer deadlock. Over-aggressive resource caps (512 MB output, 120s CPU, 4096 fds) — production-hardened for untrusted repos. Parses custom separators (unit + record sep) for complex structures (graphlog, blame, shortlog, extension histogram). Test-friendly static pure parsers throughout. `Sendable` final class, not actor.
- carry: **KEEP** — comprehensive, hardened, well-tested. Diff parsing logic moved to Rust (models stay); core git read surface stays Swift (simple, fast, no extra deps).

**Sources/ViewerCore/Git/DiffParser.swift** (66 LOC) — Structured diff model only (Hunk, File, Line); parsing now Rust-only via `RustDiffAdapter`.
- notable: Model is clean, `Sendable` + `Equatable`. `Line.Kind` enum captures unified-diff line types (context/added/removed/noNewline). Tracks old+new line numbers for diff viewer. Parser deleted; adapter maps Rust wire types here.
- carry: **KEEP** — minimal, clean model. Supports forward-compat if Rust engine changes.

**Sources/ViewerCore/Git/DiffGutterFeeder.swift** (71 LOC) — Maps diff marks → CM6 gutter marker payload ("added"|"modified"|"removed").
- notable: Pure logic (no I/O). Routes through `RustDiffAdapter` for parsing. Line numbers deterministic and sorted (dedup check stable). Kind vocabulary centralized so bridge codec tests can pin encoding.
- carry: **KEEP** — minimal, decoupled adapter.

**Sources/ViewerCore/Git/DiffHunkParser.swift** (~170 LOC) — Fall-back Swift unified-diff parser (gate-off when Rust unavailable).
- notable: Regex-based header parsing; fallback only; real parsing is Rust. Tests verify exact parity with Rust (`HighlightParityHarness` pattern).
- carry: **KEEP** — defensive fallback, gated. Trim if Rust is mandatory.

**Sources/ViewerCore/Git/DiffHunkAttributedString.swift** (~130 LOC) — Render unified diff into attributed text for MarkdownViewer (color-coded line marks).
- notable: AppKit-specific (NSAttributedString). Caches `SyntaxTheme` lookups. Recomputes on every `attributedHunk()` call (no caching); could cache if perf issue.
- carry: **KEEP** — specific to macOS app; refactor for WebUI if needed.

**Sources/ViewerCore/Git/BlameHeatmap.swift** (~120 LOC) — Compute color heatmap from blame data (time-decay: recent = hot, old = cool).
- notable: Pure logic. Bins commits by age, scales to heatmap colors. No dependencies on external theme/color library — uses raw RGB tuples.
- carry: **KEEP** — portable, reusable for remote UI.

**Sources/ViewerCore/Git/BlameGutterFeeder.swift** (~130 LOC) — Convert blame line data to CM6 gutter markers + tooltips.
- notable: Similar to DiffGutterFeeder but carries authorship info. Tooltip text formatted from (author, date, summary).
- carry: **KEEP** — minimal adapter.

**Sources/ViewerCore/Git/GitRelativeTime.swift** (~80 LOC) — Format unix timestamps as relative strings ("2 days ago").
- notable: Pure logic. No locale customization (hardcoded English). `Sendable` static only.
- carry: **KEEP** — trivial utility; i18n-proof if ever needed.

**Sources/ViewerCore/Git/GitBranchSwitch.swift** (~100 LOC) — Gate + implement branch checkout (dirty-tree check, stash escape hatch).
- notable: Stateless pure logic. `decide()` checks for uncommitted changes; caller then decides (checkout / stash / abort). `GitClient` does the actual git mutations. Good separation of concerns.
- carry: **KEEP** — clean, testable, decoupled.

**Sources/ViewerCore/Git/GitStageOp.swift** (~80 LOC) — Enum for index mutations (stage/unstage/commit/discard) w/ metadata (requiresConfirm, affectedFileCount, etc).
- notable: Model-only; commands routed to GitClient. Metadata used by UI to gate/warn on destructive ops.
- carry: **KEEP** — minimal model.

**Sources/ViewerCore/Git/TrackedReposStore.swift** (~120 LOC) — @MainActor store for actively-watched repos + their cached status (badges, errors).
- notable: Uses `GitClient` + `RepoStatsCache`. Timeouts preserved on cache misses (frozen badges on timeout rather than blank). Async status refresh off-main, result piped back.
- carry: **KEEP** — solid state management; actor-based concurrency.

**Sources/ViewerCore/Git/TrackedReposReducer.swift** (~100 LOC) — Action reducer for TrackedReposStore events (add/remove repo, refresh status, handle timeout).
- notable: Pure reducer logic; no I/O. Actions map to state mutations. Testable without a store.
- carry: **KEEP** — clean reducer pattern.

**Sources/ViewerCore/Git/RepoStatsCache.swift** (~130 LOC) — Per-repo cached aggregate stats (commit count, author leaderboard, ext histogram, dates).
- notable: Wraps `GitClient.repoStats()`; Sendable payload so it crosses actor boundaries cleanly. Caches results for 30s; cheap refresh. Single key (repoRoot URL). Off-main compute.
- carry: **KEEP** — simple, performant cache.

**Sources/ViewerCore/Git/CommitDiffSummary.swift** (~100 LOC) — Parse commit diff into high-level summary (files changed, insertions/deletions).
- notable: Pure parser; routes through `RustDiffAdapter.diffStats()`. Swift fallback available.
- carry: **KEEP** — lightweight wrapper.

**Sources/ViewerCore/Git/CumulativeDiffSelection.swift** (~150 LOC) — Model for multi-commit range diffs (base/tip resolution, range iterators).
- notable: Stateless pure logic. Computes merge-base for range review scopes; freezes base/head SHAs so review doesn't re-scope when branch moves.
- carry: **KEEP** — clean model; foundational for review v2.

**Sources/ViewerCore/Git/DiffFind.swift** (~90 LOC) — Byte-substring search over unified diffs (find all hunks matching query).
- notable: Uses memchr (Rust via FFI) for hot path. Pure logic; no git dependency.
- carry: **KEEP** — perf-critical, owner-approved Rust dep.

**Sources/ViewerCore/Git/DiffFindRuns.swift** (~70 LOC) — Convert DiffFind results into display runs (highlighted search matches in diff viewer).
- notable: Minimal adapter; pure logic.
- carry: **KEEP** — trivial.

**Sources/ViewerCore/Git/DiffLineSelection.swift** (~70 LOC) — Track which diff lines are selected/hidden in the diff viewer (multi-select, range selection).
- notable: Stateless pure logic; selection model orthogonal to diff content.
- carry: **KEEP** — clean model.

**Sources/ViewerCore/Git/DiffStat.swift** (~80 LOC) — Parse shortstat output (files changed, insertions, deletions).
- notable: Pure parser. No external dependencies.
- carry: **KEEP** — trivial.

**Sources/ViewerCore/Git/GraphLayout.swift** (~180 LOC) — Position commits on a 2D graph canvas (topo sort, x/y assignment for ancestry lines).
- notable: Non-trivial algorithm; pure logic. Tested extensively. Handles merge commits, bisects graph into left/center/right columns per ancestry depth. Independent of git data (accepts abstract graph).
- carry: **KEEP** — solid, reusable for any graph renderer (WebUI, TUI, etc). Candidate for Rust port if perf issue.

**Sources/ViewerCore/Git/WorktreeManagerModel.swift** (~120 LOC) — @MainActor model for worktree creation/deletion/pruning.
- notable: Wraps `GitClient` worktree methods. User prompts gate destructive ops. State machine-like (path validation, lock state display).
- carry: **KEEP** — clean wrapper.

**Sources/ViewerCore/Git/ForgeRemote.swift** (~80 LOC) — Detect forge type (GitHub/GitLab/Gitea) from remote URL + generate web links (PR, branch, commit, issue).
- notable: Pure string matching (regex on `ssh://`/`https://` URLs). Hardcoded forge hosts (github.com, gitlab.com, gitea.example). No external API calls. Generates valid links for Cmd-click browser jump.
- carry: **KEEP** — pragmatic, no deps. Extend with more forges as needed.

**Sources/ViewerCore/Git/UnifiedDiff+ClipboardText.swift** (~60 LOC) — Format UnifiedDiff for clipboard (pasteable into GitHub issues, emails, etc).
- notable: AppKit NSPasteboard interaction. Formats unified diff as plain text. Used by Cmd-C in diff viewer.
- carry: **KEEP** — platform-specific; refactor for WebUI.

---

### Highlight Subsystem (2,800 LOC across 23 files)

**Sources/ViewerCore/Highlight/TreeSitterEngine.swift** (409 LOC) — TreeSitter-backed syntax highlighter (parse tree → capture queries → highlight runs). Bundled grammars (JSON, Swift, Markdown); lazy-load remainder.
- notable: Eager static-link (3 grammars); lazy dylib load (XML, JS, TS) at first use. Query compilation cached per language; per-language NSLock serializes the slow compile (prevents race-to-write). No actor — NSLock is deliberate (callers in both sync + async contexts). Predicate evaluation over cached UTF-16 buffer (perf: avoids ObjC dispatch per capture, one allocation vs many). Sweep-line "paintOver" algorithm for overlap resolution — O(K log K) vs old O(textCount) canvas. `highlightMaxBytes` cap (~1 MB) for oversized files. Highlighting is strictly best-effort (never throws, empty array on failure).
- carry: **KEEP** — sophisticated, hardened. Rust highlighter (RustHighlightAdapter) is the production path; TreeSitter survives for code-FOLDS + structural-search. If folds move to Rust, this becomes ornamental and can be archived (but keeping it as a fallback is low-cost).

**Sources/ViewerCore/Highlight/TreeSitterEngine+TestSupport.swift** (23 LOC) — Test hooks for TreeSitter (inject test queries, suppress lazy-load).
- notable: Minimal, test-only.
- carry: **KEEP** — harmless.

**Sources/ViewerCore/Highlight/GrammarLoader.swift** (300 LOC) — Lazy-load tree-sitter grammar dylibs at first use (+ fallback bundled ones).
- notable: Probes `Contents/Frameworks/` for `.dylib` files matching language names. Caches loader state per language. Fallback: if dylib absent, returns bundled grammar if available. @MainActor for consistency (though actually Sendable could work). Defensive error handling; never crashes on missing dylib (degrades to bundled, then no highlighting).
- carry: **KEEP** — robust lazy-load mechanism. Useful pattern for plugin system.

**Sources/ViewerCore/Highlight/HighlightRun.swift** (70 LOC) — One highlight span (NSRange + TokenKind). Wrapper over raw highlighter output.
- notable: Minimal model; `Sendable` + `Equatable`.
- carry: **KEEP** — trivial.

**Sources/ViewerCore/Highlight/HighlightScopeMap.swift** (161 LOC) — Map tree-sitter capture names to TokenKind enums (e.g. "function.name" → `.functionName`).
- notable: Bidirectional map. Regex-based fallback for partial matches (capture name hierarchy, e.g. "type" matches "type.builtin"). Pure logic; static only.
- carry: **KEEP** — clean mapping layer.

**Sources/ViewerCore/Highlight/CaptureMap.swift** (~100 LOC) — Similar to HighlightScopeMap; maps TextMate scope names to TokenKind.
- notable: The ACTUAL active mapping (HighlightScopeMap is legacy/fallback). Hardcoded scope-to-kind dictionary. Pure logic.
- carry: **KEEP** — centralized vocabulary.

**Sources/ViewerCore/Highlight/HighlightParityHarness.swift** (112 LOC) — Test harness comparing Swift + Rust highlighter output.
- notable: Runs both engines on the same input; compares results. Used to verify Rust port parity. Diff output shows which captures diverge. Foundation for "defensive fallback" pattern (if Rust fails, Swift falls back; harness proves equivalence).
- carry: **KEEP** — invaluable quality gate. Use it when Rust engine lands (TSK-854).

**Sources/ViewerCore/Highlight/DiffHighlighter.swift** (~90 LOC) — Apply syntax highlighting to unified-diff hunks.
- notable: Routes through main highlighter. Applies theme to diff lines (added/removed/context colors). Combines syntax highlighting + diff line coloring.
- carry: **KEEP** — minor adapter.

**Sources/ViewerCore/Highlight/FoldRegion.swift** (97 LOC) — One fold region (startLine, endLine, kind: "function" | "class" | etc).
- notable: Minimal model. Immutable. No logic.
- carry: **KEEP** — trivial.

**Sources/ViewerCore/Highlight/FoldLineMap.swift** (187 LOC) — Bidirectional line number mapping (displayed ↔ canonical) for collapsed folds.
- notable: Stateless pure logic. Maps collapsed-away lines to their containing fold's start line. Used by CM6 selection/scroll restoration when folds change. `originalToDisplayed` + `displayedToOriginal` indices. O(1) lookup.
- carry: **KEEP** — elegant, reusable for any fold rendering.

**Sources/ViewerCore/Highlight/FoldDisplay.swift** (173 LOC) — Build displayed text + line map from canonical text + fold state. Inserts ellipsis markers at fold starts.
- notable: Pure logic; one pass over lines + O(N+R) map construction. Fast path (empty fold state) is a no-op. Handles nested/overlapping folds deterministically (outermost wins). Marker is U+2026 (horizontal ellipsis) in braces. AppKit-agnostic; source-view layer converts to NSTextAttachment.
- carry: **KEEP** — clean, efficient; portable.

**Sources/ViewerCore/Highlight/FoldCommands.swift** (90 LOC) — Commands for fold manipulation (toggle fold, toggle all, collapse/expand by level, etc).
- notable: Stateless pure logic. Commands map to FoldState mutations. Used by editor keyboard shortcuts + context menu.
- carry: **KEEP** — clean.

**Sources/ViewerCore/Highlight/SyntaxTheme.swift** (114 LOC) — Color palette + theming (light/dark variants). Maps TokenKind → NSColor.
- notable: AppKit-specific (NSColor). Fallback defaults if a kind isn't in the palette. Theme selection (system, light, dark, auto) persists to UserDefaults. Caches compiled theme to avoid re-lookup on every styled range.
- carry: **REDO** — AppKit-specific; refactor for platform-agnostic (use hex strings / RGB tuples, move AppKit bridge to MarkdownViewer shell). Separate theme loading from color rendering.

**Sources/ViewerCore/Highlight/SyntaxTheme+CMPalette.swift** (46 LOC) — CodeMirror-specific palette (maps themes to CM6 CSS variable names).
- notable: JSON export of theme for consumption by JS bundle. Bridge artifact; ViewerCore → JS.
- carry: **KEEP** — minimal adapter.

**Sources/ViewerCore/Highlight/ThemeDefinition.swift** (211 LOC) — Raw theme model (colors, scopes, inheritance). Used by importer + loader.
- notable: Minimal model; pure logic for inheritance chain merging.
- carry: **KEEP** — clean.

**Sources/ViewerCore/Highlight/ThemeStore.swift** (96 LOC) — Load + cache themes from bundle (VSCode .json files, .plist, custom formats). Per-user overrides.
- notable: @MainActor store. Lazy-loads themes. Persists selection to UserDefaults. Minimal caching (one active theme in memory). Watches `Application Support/MarkdownViewer/` for user theme overrides.
- carry: **KEEP** — solid loader; refactor theme path for WebUI (web-accessible themes, CDN, etc).

**Sources/ViewerCore/Highlight/VSCodeThemeImporter.swift** (246 LOC) — Parse VSCode .json theme files into ThemeDefinition.
- notable: Handles both legacy (tokenColors array) and new (rules object) VSCode formats. Merges inheritance chains. Pure logic; no I/O (caller provides JSON data). Defensive: invalid theme degrades to defaults, never crashes.
- carry: **KEEP** — robust importer. Reusable for any theme ecosystem (Sublime, TextMate, vim, etc).

**Sources/ViewerCore/Highlight/StructuralSearch.swift** (191 LOC) — TreeSitter-backed AST search (query, language, results + error handling).
- notable: Pure logic wrapper around queries. Parses tree; executes user-supplied .scm query; collects captures. Timeouts + bounds checks. Language auto-detect from file extension. Used by "find AST node" feature in dev tools.
- carry: **KEEP** — solid feature. Extensible query language (TreeSitter .scm).

**Sources/ViewerCore/Highlight/StructuralSearchEngine.swift** (165 LOC) — Orchestrator for structural search (resolve language, load grammar, execute query).
- notable: Thin wrapper over TreeSitterEngine + query parser. Error recovery. Per-query cache to avoid recompile on repeated searches.
- carry: **KEEP** — clean orchestration.

**Sources/ViewerCore/Highlight/StructuralQueryParser.swift** (195 LOC) — Parse TreeSitter .scm query syntax (captures, predicates, multi-pattern).
- notable: Pure logic parser. Used to validate + cache queries. Supports .scm comment syntax. Extracts capture names for results display.
- carry: **KEEP** — minimal parser; reusable.

**Sources/ViewerCore/Highlight/StructuralSearchHelp.swift** (90 LOC) — Generate help text + examples for structural search UI.
- notable: Static + hardcoded examples. No logic; documentation artifact.
- carry: **KEEP** — trivial.

**Sources/ViewerCore/Highlight/StickyScrollHeaders.swift** (118 LOC) — Compute which AST nodes ("scope headers") should stick to the top of the viewport during scroll.
- notable: Pure logic; consults fold state + scroll position. Deterministic, testable. Used by CM6 sticky-header rendering.
- carry: **KEEP** — elegant algorithm; reusable.

---

### LSP Subsystem (6,995 LOC across 20 files)

**Sources/ViewerCore/LSP/LSPClient.swift** (1,496 LOC) — Minimal JSON-RPC client over stdio. Spawns LSP server subprocess; frames + exchanges requests/responses. Per-request timeout; no cancellation support (PoC). Actor-based concurrency.
- notable: POSIX `write(2)` for stdin (FileHandle write ↔ separate read thread can race on macOS 26; raw fd is reliable). Dedicated `Thread` for blocking stdout read (doesn't starve cooperative pool; FileHandle hazard avoided). Stderr drain to prevent blocking. No automatic restart; crashes propagate to caller (LSPPool handles retries). Minimal error model; timeouts return nil. Position encoding negotiated in `initialize`. Server-pushed diagnostics + crash callbacks. Test-friendly environment override + initializationOptions Data field (crosses Sendable boundary cleanly).
- carry: **KEEP** — sophisticated, hardened. Actor model + exclusive process ownership (one client = one server) keeps concurrency simple. POSIX-level I/O pragmatism (avoid FileHandle traps). Pattern worth studying for remote-core transport. Minimal on purpose (no multiplexing, no cancellation) — PoC scope maintained.

**Sources/ViewerCore/LSP/LSPPool.swift** (951 LOC) — Process pool, keyed by (language, workspaceRoot). Lazy spawn; idle reaper; exponential backoff on crash. State machine: cold → starting → live → idle/dead.
- notable: Actor-based pool management. Per-key restart backoff + dead cooldown (prevent thrashing on persistent errors). Per-file content hashing to skip redundant didChange (PERF-01). File version tracking for server consistency. Concurrent shutdown via TaskGroup (avoids slow sequential reaped-child waits). Idle clients reaped after 5min (configurable). Diagnostics callback wired once at startup; pushed to all future clients. Trust gate for workspace-local binaries (LSPTrustStore prompt → persistent grant). Excellent failure model (binary missing, init failure, crash, wedge, dead cooldown).
- carry: **KEEP** — production-grade pool. State machine clear + testable. Concurrency model (actor + TaskGroup) is exemplary. Per-file hash optimization is pragmatic perf win.

**Sources/ViewerCore/LSP/LSPFraming.swift** (168 LOC) — JSON-RPC message framing (split incoming bytes on `Content-Length` headers; assemble outbound frames).
- notable: Stateful frame reader (accumulates incomplete messages). Decoder error handling (skip malformed frame, keep reading). Pure logic; no I/O. Splitter for test injection (mock frames). CRLF line ending per LSP spec.
- carry: **KEEP** — solid frame codec. Reusable for any LSP transport.

**Sources/ViewerCore/LSP/LSPProtocol.swift** (471 LOC) — Minimal LSP type definitions (Initialize, Hover, Definition, Diagnostic, TextEdit, etc). Struct + Codable.
- notable: No external LSPKit dep; all types hand-defined. Covers only methods exercised by the PoC (no PublishDiagnostics on the request side, for example). Sendable + Equatable throughout. CodableExts for resilience (unknown fields ignored, defaults on missing). Extensible via LSP extensions key.
- carry: **REDO** — incomplete protocol surface. Adopt a proper LSP SDK (langserver-swift or equivalent) for full spec coverage, or systematically expand this as new methods are needed. Hand-rolling types is brittle as the protocol grows.

**Sources/ViewerCore/LSP/LSPConfiguration.swift** (254 LOC) — LSPLanguageRegistry: per-language server discovery + config (executable path, args, workspace root detection).
- notable: Hardcoded Swift + Go servers (sourcekit-lsp, gopls). Workspace root detection (looks for `.git`, `go.mod`, `package.json`, etc). Per-server initializationOptions (loaded from workspace `lsp.json` override). Config is immutable Sendable (read at pool startup, never mutated).
- carry: **KEEP** — pragmatic hardcoding. Extensible via LSPLanguageRegistry subclass or overlay. Workspace root detection heuristics solid.

**Sources/ViewerCore/LSP/LSPLanguage.swift** (548 LOC) — Enum + metadata for supported languages (Swift, Go, …). File extension ↔ language mapping. Scope rules for multi-language files (e.g. code fences in Markdown).
- notable: Comprehensive. `scopeChainForLine` logic for code-fence detection (regex over line prefix). Maps to `.fileTypes` (extensions + globs). Sendable enum. Test-friendly: `HighlightLanguage` integration for consistency.
- carry: **KEEP** — solid language registry. Extensible enum pattern.

**Sources/ViewerCore/LSP/LSPPositionConverter.swift** (260 LOC) — Translate between Swift source positions (line/column) and LSP positions (taking into account UTF-16 vs UTF-8 encoding).
- notable: Protocol.positionEncoding (default UTF-16, can be UTF-8/UTF-32 per server). Conversions handle surrogate pairs + emoji correctly. Swift position = 1-based line, 0-based column; LSP = 0-based both. Pure logic; exhaustively tested.
- carry: **KEEP** — fiddly but correct. Reusable for any LSP client.

**Sources/ViewerCore/LSP/LSPDiscovery.swift** (390 LOC) — Probe filesystem for LSP server binaries (system PATH, Homebrew, workspace node_modules/.bin, custom overrides in lsp.json).
- notable: Multi-path probe strategy (same as git binary search). Workspace-local binary trust gate (RCE-on-browse guard TSK-1129). Per-language discovery (Swift → sourcekit-lsp, Go → gopls). Caches discovered binary paths. Defensive: missing binary returns error, not crash.
- carry: **KEEP** — pragmatic discovery. Mirrors GitClient.gitProbePaths pattern (solid pattern for finding external tools).

**Sources/ViewerCore/LSP/LSPDiagnosticsStore.swift** (102 LOC) — @MainActor store for server-pushed diagnostics (per-file, per-server).
- notable: Minimal state: Map<URL, [Diagnostic]>. Receives updates from LSPClient crash callback + publish notification. UI reads on demand (no direct store observation; diagnostic panel polls). Clean separation: store owns the cache, UI owns subscription/refresh.
- carry: **KEEP** — simple state management.

**Sources/ViewerCore/LSP/LSPNavigationStore.swift** (143 LOC) — Cache recent Go-To-Definition results + their previews (avoid re-request on back-nav).
- notable: Simple LRU (maxSize 50). Per-location cache of preview text + snippet. Invalidated per file on didChange. Works around LSP's lack of back-button support.
- carry: **KEEP** — pragmatic UX bridge.

**Sources/ViewerCore/LSP/LSPDefinitionPreview.swift** (211 LOC) — Render definition response into a rich text preview (heading + context lines + breadcrumb).
- notable: Truncates large files to context window (±10 lines). Uses HighlightScopeMap to syntax-highlight the snippet. Rich formatting (file path, line range, scope breadcrumb). Pure logic; testable.
- carry: **KEEP** — excellent UX detail. Reusable for any language-aware preview.

**Sources/ViewerCore/LSP/LSPTextEditApplier.swift** (56 LOC) — Apply LSP TextEdit[] to source text (bulk replacement via computed ranges).
- notable: Sorts edits descending by range; applies bottom-up to avoid offset drift. Handles overlapping edits (last one wins, documented). Pure logic.
- carry: **KEEP** — trivial but correct.

**Sources/ViewerCore/LSP/LSPProblemsViewModel.swift** (312 LOC) — @MainActor view model for Diagnostics panel (filter, sort, search diagnostics).
- notable: Polls LSPDiagnosticsStore on-timer. Filters by severity/language/path. Search via substring match. Breadcrumb navigation (file → line → diagnostic). Dedup identical errors across servers. Good UX polish.
- carry: **KEEP** — solid view model. Minor: extract pure filter+sort logic into testable statics.

**Sources/ViewerCore/LSP/LSPService.swift** (169 LOC) — High-level service orchestrator (pool + pool settings + diagnostics store wiring).
- notable: Glue code. Owns LSPPool + LSPDiagnosticsStore + config. Start/stop pool. Minimal logic.
- carry: **KEEP** — simple orchestration.

**Sources/ViewerCore/LSP/LSPStatusChip.swift** (206 LOC) — UI status display for LSP connection (health, crash count, latency).
- notable: Reads pool status snapshot. Renders as SwiftUI Chip (green/yellow/red). Shows last error + crash history. Debug info in tooltip.
- carry: **KEEP** — minor UI component; SwiftUI-specific.

**Sources/ViewerCore/LSP/LSPWorkspaceOverrides.swift** (452 LOC) — Load + parse workspace-specific LSP config (lsp.json: server binary, args, initializationOptions, language scopes).
- notable: JSON schema for `lsp.json` in repo root. Supports per-language overrides. Per-server initializationOptions forwarding. File-scope rules (code fences, etc). Comprehensive validation + defaults. Pure logic; JSON Codable.
- carry: **KEEP** — pragmatic extensibility point. Well-documented schema.

**Sources/ViewerCore/LSP/LSPVSCodeExtensions.swift** (241 LOC) — Decode VSCode `extensions` config in LSP initializationOptions (workspace/extensions → per-server config broadcast).
- notable: Maps VSCode-style ext activationEvents to per-server enable/disable flags. Merges per-ext + per-server + workspace-wide settings. Pure logic; defensive against malformed input.
- carry: **KEEP** — interop bridge. Enables workspace sharing across VSCode + MarkdownViewer without manual config duplication.

**Sources/ViewerCore/LSP/CMDiagnosticMapping.swift** (85 LOC) — Translate LSP Diagnostic → CM6 diagnostic format (gutter markers, underlines, tooltips).
- notable: Maps severity/range/message. Pure logic; CM6 codec on JS side consumes output.
- carry: **KEEP** — minimal adapter.

**Sources/ViewerCore/LSP/CMFoldRangeMapping.swift** (67 LOC) — Translate LSP FoldingRange response → CM6 fold regions.
- notable: Maps language + range + collapsedText. Pure logic.
- carry: **KEEP** — minimal adapter.

---

## Module Summary

### Git Subsystem

**Role:** Bridge between the file system's `.git` directory and the editor's diff/blame/history UI. Spawns git(1) subprocess per request; parses output into structured models. All reads are non-throwing (empty results on failure). Mutations (stage/unstage/commit/checkout/stash/worktree) are guarded by UI-level state machines (branch switch gate, stage panel). Author identity + remote URLs are cached. Review v2 scope resolution (base/head SHA freezing) lives here.

**How it fits together:**
- `GitClient` is the low-level git shell interface (minimal, Process-based, defensive).
- Model types (DiffParser, LogEntry, etc.) structure the output.
- Adapters (DiffGutterFeeder, BlameGutterFeeder) convert git data to UI payloads (CM6 markers, gutter annotations).
- Stores (TrackedReposStore, RepoStatsCache) cache results off-main; state machines (GitBranchSwitch, GitStageOp) gate mutations.
- Graph layout is independent pure logic; ForgeRemote is a small utility for link generation.

**Quality signals:**
- Defensive process hardening (env allowlist, protective flags, revision guards).
- Resource limits + concurrent pipe draining (avoid deadlock / runaway on untrusted repos).
- Extensive pure-logic parsers (static, testable without a repo).
- Non-throwing design (graceful degradation on errors).

### Highlight Subsystem

**Role:** Provide syntax highlighting, code folding, and structural AST search. TreeSitter is the parser (queries → capture matches). Highlighting is best-effort (never throws); folds + structural search are stricter (errors surface). SwiftUI + WebView integration via adapters (HighlightRun, FoldDisplay, CMPalette).

**How it fits together:**
- `TreeSitterEngine` lazy-loads grammars (eager: JSON, Swift, Markdown; lazy dylib: XML, JS, TS).
- Query compilation is cached per language + serialized (per-language NSLock prevents races).
- Sweep-line overlap resolution (paintOver) is O(K log K) + elegant.
- `FoldDisplay` + `FoldLineMap` provide deterministic collapsed-text rendering + line mapping.
- Themes (SyntaxTheme, ThemeStore, VSCodeThemeImporter) manage colors. AppKit-specific; refactor for cross-platform.
- Structural search (StructuralSearch, StructuralSearchEngine) leverages TreeSitter queries for AST navigation.
- StickyScrollHeaders computes which scope boundaries should stick during scroll.

**Quality signals:**
- Robust lazy-loading (fallback bundled grammars if dylib absent).
- Sophisticated overlap resolution algorithm (sweep-line + coalesce-contiguous).
- Predicate evaluation over cached UTF-16 buffer (perf optimization, no ObjC dispatch per capture).
- Pure logic throughout (highlight runs, fold display, line mapping).
- Parity harness (compare Swift + Rust highlighters) for defensive fallback.

### LSP Subsystem

**Role:** Bridge to language servers (sourcekit-lsp, gopls, etc.) over JSON-RPC. Spawn server subprocess; frame + exchange requests; push diagnostics to UI; support hover, definition, diagnostics, folding ranges. Trust gate (TSK-1129) blocks untrusted workspace-local binaries.

**How it fits together:**
- `LSPClient` is the low-level JSON-RPC transport (actor-based, POSIX I/O, per-request timeout).
- `LSPPool` manages a cache of LSP clients, keyed by (language, workspace). Lazy spawn; idle reaper; exponential backoff on crash.
- `LSPFraming` handles message framing (Content-Length headers, split incoming bytes).
- `LSPProtocol` defines minimal message types (Initialize, Hover, Definition, Diagnostic, etc). Hand-rolled; incomplete vs full LSP spec.
- `LSPConfiguration` + `LSPLanguage` + `LSPDiscovery` handle server selection, workspace root detection, binary probing.
- `LSPWorkspaceOverrides` + `LSPVSCodeExtensions` manage per-workspace config (lsp.json, VSCode integration).
- `LSPDiagnosticsStore` + `LSPProblemsViewModel` store + present diagnostics.
- `LSPDefinitionPreview` renders Go-To-Definition results with context (rich preview, syntax highlighting).
- `LSPStatusChip` displays server health (green/yellow/red, crash count).

**Quality signals:**
- Minimal PoC scope preserved (no automatic restart, no cancellation, no multiplexing).
- Solid process management (dedicated thread for blocking reads; POSIX I/O to avoid FileHandle traps).
- Excellent failure model (crash recovery, dead cooldown, exponential backoff).
- Per-file content hash optimization (skip redundant didChange notifications).
- Trust gate + discovery pattern borrowed from GitClient (solid pattern).

---

## Patterns Worth Porting

### 1. **Non-throwing read APIs** (Git subsystem pattern)
Approach: Design read operations to return empty results on any error (not throwing exceptions). Exceptions only for unrecoverable programmer errors (missing dep, misconfiguration). This keeps caller code simple + forces graceful degradation on untrusted data.

**File pointers:** `GitClient` (all read methods return [] or ""); DiffGutterFeeder (routes through RustDiffAdapter but surfaces empty payload on parse failure).

**For rebuild:** Use this pattern for all read-side operations in Rust core + WebUI layers. Exceptions for initialization only.

---

### 2. **Static pure parsers with test-friendly signatures** (Git subsystem pattern)
Approach: Factor parsing logic into static `func parse(_ input: String) -> Model` methods so tests can pin parsing semantics WITHOUT spawning git processes or mocking. Makes protocol changes testable independently of I/O.

**File pointers:** `GitClient.parseStatusEntries()`, `GitClient.parseBlamePorcelain()`, `GitClient.parseGraphLog()`, `GitClient.parseShortlog()`, `GitClient.parseExtensionHistogram()`.

**For rebuild:** Apply to Rust core FFI adapters (all marshaling logic should have Swift test hooks that call Rust with serialized JSON input). Makes parity harnesses + regression tests viable.

---

### 3. **Sendable models + actor-based state** (LSP subsystem pattern)
Approach: Make data models `Sendable` (immutable, no class fields). Use actors for mutable state (LSPClient, LSPPool, TrackedReposStore). Cross-actor boundaries only via Sendable values. This enforces the boundary and makes the threading model explicit.

**File pointers:** `LSPClient` (actor), `LSPPool` (actor), `TrackedReposStore` (@MainActor), `LSPDiagnosticsStore` (@MainActor). All model types are `Sendable`.

**For rebuild:** Apply throughout. Actors own I/O + lifecycle; models cross boundaries.

---

### 4. **Per-item timeout + resource limits** (Git subsystem pattern)
Approach: Resource-cap every external-process invocation (CPU time, file size, fd count, wall-clock timeout). Avoid unbounded consumption on untrusted data (hostile repo, malicious input). Use ProcessRunner.ResourceLimits + timeout watchdog.

**File pointers:** `GitClient.runResult()` (120s CPU cap, 512 MB output cap, wall-clock timeout, concurrent stdout drain).

**For rebuild:** Apply to all Rust FFI calls + external processes. Cap Rust core execution time (JSON parsing, large file processing, etc.) via syscall timers or explicit checks.

---

### 5. **Process-level security hardening** (Git subsystem pattern)
Approach: Build git's environment from an allowlist, not inherited parent env. Disable config-driven RCE vectors (hooks, fsmonitor, editor, pager). Validate revision tokens to block option-injection. Use `--` to terminate option parsing. Suppress stdin inheritance.

**File pointers:** `GitClient.runResult()` (protective flags, env allowlist, revision guards, `--` usage, stdin suppression).

**For rebuild:** Apply to all subprocess spawning (LSP server, external tools). Env allowlist is non-negotiable for untrusted workspaces.

---

### 6. **Sweep-line overlap resolution** (Highlight subsystem pattern)
Approach: For overlapping intervals (highlight runs, fold regions), use a sweep-line algorithm: build events (open/close at each boundary), sort, sweep left-to-right tracking active set. O(K log K) vs naive O(textCount). Coalesce contiguous runs of the same kind.

**File pointers:** `TreeSitterEngine.paintOver()`, `FoldDisplay.build()`.

**For rebuild:** Use this algorithm for any overlap problem (code folding, multi-selection painting, diff line markings, diagnostic underlines). Efficient + elegant.

---

### 7. **Lazy dylib loading with fallback** (Highlight subsystem pattern)
Approach: For optional dylib deps (tree-sitter grammars, plugins), probe filesystem at first use; cache result. If missing, fall back to bundled/stub version. Never crash on missing optional dylib.

**File pointers:** `GrammarLoader` (probes `Contents/Frameworks/` for .dylib; falls back to bundled grammars).

**For rebuild:** Use this pattern for plugin system (load .dylib; if missing, skip plugin; cache result). Defensiveness is key.

---

### 8. **Workspace config + per-language override** (LSP subsystem pattern)
Approach: Support a per-workspace config file (lsp.json, etc.) that specifies per-language settings (server binary, args, initializationOptions, scope rules). Merge with global defaults. Parse JSON; validate against schema; default missing fields.

**File pointers:** `LSPWorkspaceOverrides`, `LSPConfiguration`.

**For rebuild:** Generalize this pattern to LSP + other language-aware systems (formatter discovery, debugger config, linter selection). Workspace config becomes a central registry.

---

### 9. **Parity harness for migration** (Highlight subsystem pattern)
Approach: When porting functionality from one engine to another (Swift → Rust, TreeSitter → different parser, etc.), build a test harness that runs BOTH engines on the same input + compares results. This proves parity + lets you gate the switchover on test success.

**File pointers:** `HighlightParityHarness` (compares TreeSitter Swift vs RustHighlightAdapter).

**For rebuild:** Build parity harnesses for every major port (diff parsing, code folding, diagnostics, etc.). Makes incremental switchover feasible.

---

### 10. **Per-file content hash to skip redundant work** (LSP subsystem pattern)
Approach: Cache a hash of the file content last sent to a server. On the next `didChange`, compare the current hash to the cached hash. If identical, skip the notification (common case: tab switch with no edits). Reduces server work + network traffic.

**File pointers:** `LSPPool.Entry.fileHashes` (PERF-01).

**For rebuild:** Apply to any bidirectional sync scenario (remote core, collaborative editing, etc.). Content hash is cheap (SHA-1) and pays for itself.

---

## Anti-patterns / Regrets

### 1. **Hand-rolled LSP protocol types** (LSPProtocol.swift)
**Issue:** Over 470 LOC of manually-defined Codable structs for LSP message types. Incomplete vs. full spec; brittle on spec changes; duplicate of existing open-source LSPKit. Maintenance burden if new methods added.

**Lesson:** Don't reinvent wire protocols. Adopt a well-maintained LSP SDK (langserver-swift, LSPKit, etc.) OR systematically expand types as needed. Hand-rolling only for deeply customized scenarios (which this isn't).

**For rebuild:** Day 1: vet LSP SDKs. If none work, use a code-generator (OpenAPI → Swift) rather than hand-typing.

---

### 2. **AppKit-specific theme system** (SyntaxTheme.swift + ThemeStore.swift)
**Issue:** NSColor bindings + UserDefaults persistence + NSTextAttachment assume AppKit. Not portable to WebUI/TUI/remote. Refactor burden when moving to cross-platform.

**Lesson:** Separate theme LOADING (JSON parsing, inheritance) from theme RENDERING (NSColor, CSS, terminal codes). ViewerCore should own parsing + data; MarkdownViewer shell owns AppKit rendering.

**For rebuild:** Move SyntaxTheme colors to platform-agnostic RGB tuples / hex strings. Move NSColor mapping to MarkdownViewer. Let WebUI/TUI adapt the same theme data.

---

### 3. **NSLock in a would-be-actor context** (TreeSitterEngine.swift)
**Issue:** TreeSitterEngine uses NSLock instead of actor because callers exist in both sync (HTMLRenderer.visit) + async (DocumentModel, Tasks) contexts. Mixing lock + async is brittle (if a caller adds locking overhead, it stalls the async pool). Not a true regret, but worth noting: if sync callers could be eliminated, convert to actor.

**Lesson:** Aim for actors throughout; lock-based code is harder to reason about and easier to deadlock. If you need lock + async, document it heavily + consider async-only refactor in the future.

**For rebuild:** HTMLRenderer should compute folds async, not sync. Then TreeSitterEngine becomes a pure actor (no locks).

---

### 4. **Process spawning without a wrapper** (Git subsystem)
**Issue:** GitClient does its own Process + Pipe management. Correct, but repetitive. LSPClient repeats similar logic. A shared `ProcessRunner` exists but has different API.

**Lesson:** Extract a common subprocess wrapper (spawn, resource limits, I/O handling, timeout, result marshaling). Reuse for git, LSP, future tools.

**For rebuild:** Create `ProcessRunner.standardTask()` that centralizes spawn + limit + drain + timeout. Call from GitClient, LSPClient, etc.

---

### 5. **Stateful frame reader for LSP** (LSPFraming.swift)
**Issue:** `LSPFramer` accumulates incomplete frames + reassembles them. Stateful, tricky to test in isolation. Frame boundaries could be handled by the socket layer (TLS framing, etc.) abstracting the Content-Length dance.

**Lesson:** Avoid stateful parsers when possible. If necessary, make them thoroughly tested + document the protocol invariants.

**For rebuild:** For remote-core transport (JSON-RPC over WebSocket or gRPC), delegate framing to the transport layer (WebSocket frames, gRPC messages). Simplify the serialization layer.

---

### 6. **Incomplete error recovery in LSPClient** (LSPClient.swift)
**Issue:** If a client crashes mid-request, the pending continuation is leaked until timeout fires (2 seconds). No graceful abort.

**Lesson:** For a PoC, "acceptable" (timeout is short). For production, add cancellation tokens + cleanup on server crash.

**For rebuild:** Add LSP cancellation support ($/cancelRequest). Tie cancellation to Swift Task cancellation.

---

## Gotchas & Surprises

### 1. **FileHandle.write hazard on macOS 26**
Concurrent `FileHandle.read()` on a Pipe's read end AND `FileHandle.write()` on the write end (from separate threads) can wedge the write: bytes never reach the child even though write returns success. LSPClient + ProcessRunner avoid this by using raw POSIX `write(2)` + `read(2)` on bare fds. **In rebuild:** Test any cross-thread FileHandle usage carefully; prefer POSIX I/O for subprocess communication.

---

### 2. **Process.waitUntilExit() is destructive**
Calling `waitUntilExit()` twice on the same (already-reaped) Process busy-spins at 100% CPU forever. LSPClient guards against this with a `didReap` flag. **In rebuild:** Always reap a Process exactly once. Use a guard flag if necessary.

---

### 3. **Git output encoding errors are silent-killing**
If a single non-UTF-8 byte appears in git output (e.g. a Latin-1 author name), strict `String(data: encoding: .utf8)` returns nil, collapsing ALL output to "". GitClient uses `String(decoding: as: UTF8.self)` (lossy) so one bad byte doesn't blank the entire result. **In rebuild:** Use lossy UTF-8 decode for all streaming I/O from untrusted processes.

---

### 4. **TreeSitter query evaluation is lazy**
A query like `((identifier) @type (#match? @type "^[A-Z]"))` won't auto-evaluate the predicate; you must call `resolve(with:predicateContext)` on the cursor to filter captures. Without calling resolve, EVERY identifier matches (wrong captures fire). TreeSitterEngine.tokenize() does call resolve; old code didn't + emitted false positives. **In rebuild:** Always resolve query predicates explicitly.

---

### 5. **NSString.substring(with:) is UTF-16-aware**
SwiftTreeSitter parses UTF-16LE; node ranges are UTF-16 offsets, not byte offsets. TreeSitterEngine.predicateSubstring() must convert to a buffer of UTF-16 code units before extracting text. Mixing UTF-8 vs UTF-16 offsets = crash. **In rebuild:** Document encoding assumptions everywhere. SwiftUI text is UTF-16; WebView JS is UTF-16; Rust is UTF-8: be explicit about conversions.

---

### 6. **GitClient env is constructed from allowlist**
Git inherits only PATH, HOME, GIT_TERMINAL_PROMPT, GIT_EDITOR, GIT_PAGER, GIT_OPTIONAL_LOCKS. ANY parent env var (including `GIT_DIR`, `GIT_SSH`, app-level secrets) is dropped. This is intentional (SEC-005). **In rebuild:** Match this for all subprocess spawning (LSP, formatters, etc.). Env allowlist is non-negotiable.

---

### 7. **FoldLineMap must handle nested folds correctly**
When a line is hidden by multiple nested folds, it maps to the INNERMOST fold's start line (not the outermost). FoldDisplay computes this by processing folds in order-of-span-size and overwrites o2d entries; order matters. **In rebuild:** Test fold mapping on deeply-nested code (class → method → closure → block). Ensure line mapping is deterministic.

---

### 8. **LSP position encoding is negotiated per-server**
Servers can reply `positionEncoding: "utf-8"` or `"utf-32"` in initialize response (default UTF-16). LSPPositionConverter adapts conversions. A mismatch causes off-by-one navigation errors. **In rebuild:** Always honor server-reported position encoding. Test with servers that use non-UTF-16 encoding (Go, Rust tools often use UTF-8).

---

### 9. **Workspace-local LSP binaries are RCE vectors**
An untrusted workspace can include `node_modules/.bin/custom-lsp` that runs arbitrary code when the editor loads. TSK-1129 gates spawn on a one-time user confirm (LSPTrustStore + LSPTrustPrompt). Headless contexts (tests, CI) BLOCK CLOSED (no handler). **In rebuild:** Don't remove this gate. Extend it to all workspace-local spawning (formatters, linters, build tools).

---

### 10. **Diff hunk parsing is migration-critical**
The unified-diff model + parser logic have moved to Rust (TSK-649 Stage B). Swift fallback exists for gate-off. A mismatch between Swift + Rust parsing breaks diffs everywhere (gutter marks, diff viewer, reviews). Parity harness guards against this. **In rebuild:** Lock down diff parsing semantics early. Test with pathological diffs (binary, renames, no-newline, merge conflicts, Unicode).

---

## Rebuild Notes

### If Building This Capability Fresh: Approach, Boundaries, Design Up Front

#### **For the Git subsystem:**

1. **Boundary:** Keep ViewerCore git as a thin Process-based wrapper. Move heavy lifting (diff parsing, merge-base computation, large history walks) to Rust core (mdvcore). Rust core exposes git functions over FFI; ViewerCore calls them.

2. **Design the git FFI surface:** Define Rust `pub fn` signatures for each git operation (status, diff, blame, log, etc.). Serialize input/output as JSON over the C boundary. Version the wire format. Swift adapters deserialize + present as Swift types.

3. **Security first:** Resource limits (CPU, output cap, wall-clock timeout) go in Rust (RLIMIT_CPU, explicit loop counters). Environment allowlist stays in Swift (Process creation is Swift-side). Validate all pathspec arguments in Rust before passing to libgit2.

4. **Process vs. library:** Consider whether spawning git binary is the right choice for Rust core. If you own the git implementation (libgit2 FFI), do it in Rust. If you shell out to git(1), the current Swift model is fine (avoids linking libgit2, simpler security model, easier to version-skew tolerance).

5. **Testing:** Write Rust unit tests for each FFI function (with a local git repo, or mock). Write Swift parity tests comparing Rust output to git CLI. For performance-critical paths (large diffs, deep histories), measure both and gate on regressions.

---

#### **For the Highlight subsystem:**

1. **Boundary:** ViewerCore owns tree-sitter parsing + query evaluation. View layers (AppKit, WebUI, TUI) own rendering (colors, fonts, attachments, styling). Data flows one-way: source → parser → highlight runs + fold regions → view layer.

2. **Design the theme abstraction:** Themes should be platform-agnostic (RGB tuples or hex strings, not NSColor). ViewerCore loads themes (JSON parsing, VSCode importer, inheritance). MarkdownViewer converts colors to NSColor/NSAppearance. WebUI converts to CSS. TUI converts to terminal codes.

3. **Folds + lazy-loading:** If code folding moves to Rust, keep TreeSitterEngine as a cache of queries (used only for structural search). Fold computation (FoldDisplay, FoldLineMap) can stay Swift (pure logic, no parser needed). Lazy dylib loading stays for plugins.

4. **Structural search:** TreeSitter queries are the search language. Keep it; don't switch to AST walking. It's the de facto standard for language-agnostic node selection.

5. **Testing:** Parity harness is non-negotiable. Test on large files (~1 MB) to catch perf issues (O(K log K) paintOver vs naive canvas). Test deeply-nested folds + overlaps. For themes, test light/dark adaptation + missing theme graceful fallback.

---

#### **For the LSP subsystem:**

1. **Boundary:** ViewerCore owns JSON-RPC framing + server lifecycle (spawn, retry, heartbeat, crash recovery). Views own presentation (diagnostics panel, Go-To-Definition preview, hover bubbles). Config lives in ViewerCore (server discovery, workspace overrides). Trust decisions live in ViewerCore (untrusted binary prompt).

2. **Adopt an LSP SDK:** Don't hand-roll protocol types. Use langserver-swift or a code-generator. Saves 500+ LOC, stays in sync with spec, gains free bug fixes.

3. **Remote transport:** Design LSPClient to be agnostic to transport (Process stdio today; WebSocket/gRPC tomorrow). Framing should be pluggable. If you're building remote-core, make this Day 1 refactor (avoid re-architecting later).

4. **Cancellation:** Add LSP cancellation ($/cancelRequest) from the start. Don't rely on timeouts. Tie to Swift Task cancellation for clean abort semantics.

5. **Multi-server + multiplexing:** LSPPool scales to N servers (one per language per workspace). If a future design needs one server handling multiple languages, refactor Key to (workspace) only and track language ↔ capability mapping inside LSPClient.

6. **Testing:** Mock server (fake LSP responses) is essential. Build a test server harness that speaks LSP. Test crash recovery, timeout, workspace config override, trust gate. Test position encoding edge cases (emoji, surrogate pairs, CRLF vs LF).

---

#### **Cross-subsystem design principles:**

1. **Defensive I/O everywhere:** Assume untrusted input (user's repo, user's workspace, user's LSP config). Resource-cap every subprocess. Validate all option-like arguments. Use allowlist env, not inherited.

2. **Sendable data models:** All data crossing actor/thread boundaries must be Sendable (immutable structs). Avoid `class` for models. Makes threading explicit + enforceable.

3. **Pure logic, no side effects:** Factor parsing, filtering, transformation into static methods (no I/O, deterministic, testable in isolation). I/O happens at the actor/subprocess boundary.

4. **Platform-agnostic core:** ViewerCore must not import AppKit/SwiftUI (except behind protocol adapters). Use RGB tuples, raw strings, platform-neutral types. Shells (MarkdownViewer, WebUI, TUI) own platform-specific rendering.

5. **Graceful degradation:** On errors, degrade to empty results or defaults. Never crash on malformed input. Errors surface in logs + status indicators, not exceptions.

6. **Parity testing:** Whenever two implementations exist (Swift + Rust, TreeSitter + Rust parser, Live + Test), build a harness that compares results on the same input. Gate feature toggles on parity.

7. **Versioning + marshaling:** If moving logic to Rust, version the FFI wire format. Start with JSON (easy to debug, schema-less, resilient to unplanned fields). Migrate to compact binary (protobuf, msgpack) only if perf demands it + add thorough codec tests.

---

### Specific File-by-File Decisions for a Rebuild

| Subsystem | Rebuild strategy |
|-----------|------------------|
| **Git** | Keep GitClient mostly as-is (Process-based shell). Migrate parsers (diff, blame, log, shortlog) to Rust FFI adapters. Keep models (LogEntry, GraphCommit, UnifiedDiff) in Swift. Test-friendly parsers stay Swift (static, pure). Stores + state machines (GitBranchSwitch, TrackedReposStore) stay Swift. |
| **Highlight** | Keep TreeSitterEngine for queries (fold regions, structural search). Migrate highlighting to Rust if perf needed (RustHighlightAdapter pattern already works). Decouple theme colors from AppKit (refactor SyntaxTheme). Keep FoldDisplay + FoldLineMap (pure, elegant). Lazy-load stays for plugins. |
| **LSP** | Adopt langserver-swift (or equivalent SDK). Keep LSPClient architecture (actor, dedicated thread, POSIX I/O) but simplify protocol types. Keep LSPPool (excellent state machine). Expand LSPLanguage + LSPConfiguration as servers added. Keep workspace overrides + trust gate. Refactor to support remote transport (WebSocket) in parallel with Process. |

---

### Hand-off Checklist for Rebuild

- [ ] Threat model: document security assumptions (untrusted repos, untrusted workspace config, untrusted LSP binaries).
- [ ] I/O bottlenecks: profile on large repos (1000+ commits, 100k-line files). Identify any slow git/LSP calls. Consider caching strategies.
- [ ] Error handling: audit all subprocess spawning. Ensure resource limits + timeout + graceful degradation.
- [ ] Concurrency: map all actor + Thread + Task usage. Document critical sections. Run ThreadSanitizer on multi-threaded scenarios.
- [ ] Platform-agnostic core: audit ViewerCore imports. Remove AppKit/SwiftUI dependencies (OK in MarkdownViewer shell only).
- [ ] Test coverage: parity harness for every major port (diff, blame, folding, highlighting). Headless gate must pass. VM tier 4/5 tests for UI integration.
- [ ] Migrations: if moving parsers to Rust, gate on parity tests before switchover. Gradual rollout (feature flag, canary).
