# ViewerCore Root Files — Slice 2/5 (Alphabetical 52–102)
## File Inventory & Analysis

**Slice scope:** 51 files, ~7,500 total LOC  
**Date:** 2026-07-11  
**Focus:** Mid-range alphabetical band: graph/diagram/document utilities, CSV editing, file I/O, formatting, find, flame charts

---

## File-by-File Entries

**Sources/ViewerCore/DependencyGraphInteraction.swift** (105 LOC) — Hit-testing, pan/zoom transforms, and canvas math for the dependency-graph visualization.
- notable: Pure geometry (CoreGraphics, no AppKit). Deterministic zoom-around-point keeps anchor fixed under scale changes via exact coordinate math. Node cap at 300 for performance.
- carry: **KEEP** — precise, testable math; the zoom formula (`toModel` → scale → new offset) is worth preserving.

**Sources/ViewerCore/DependencyGraphLayout.swift** (147 LOC) — Deterministic force-directed graph layout (Fruchterman–Reingold) seeded from circle placement.
- notable: Fully deterministic (no RNG; fixed iteration count). Nodes clamped to bounds each step. Coincident-node nudge uses index-based tiebreaker so output is bit-for-bit stable across runs. Testable without randomness.
- carry: **KEEP** — textbook force simulation; ports directly to Rust if a rebuild offloads graph layout.

**Sources/ViewerCore/DependencySourceResolver.swift** (256 LOC) — Stateless URL builder for dependency registries (crates.io, npm) and repo normalization.
- notable: Pure string logic, no I/O. Handles scoped npm names (`@scope/pkg`), git-remote-to-https normalization (scp-style `git@host:path`, `git+https://`, etc.), version pinning (rejects ranges/wildcards). Gracefully degrades to nil on malformed input.
- carry: **KEEP** — solid, portable logic; normalize-repo-URL pattern is useful for any dependency viewer.

**Sources/ViewerCore/DiagnoseSchedule.swift** (23 LOC) — Envvar-based scheduling for the `--diagnose` view-tree dump (delays it so `MDV_UI_SCENE` state is captured).
- notable: Minimal, focused. Caps delay at 30s to prevent hangs. Direct tie to the harness's diagnostic-timing contract.
- carry: **KEEP** — lightweight orchestration helper; no rebuild churn.

**Sources/ViewerCore/DiagramRegistry.swift** (331 LOC) — Registry pattern for diagram renderers (Mermaid, DOT, PlantUML). Collision detection, order-independent lookup.
- notable: Thread-safe (NSLock). Extensible protocol; each renderer declares languages & file extensions. Built-in set is pre-populated (standard singleton). Descriptor carries both structural metadata and normalized source. Pure; no UI imports.
- carry: **KEEP** — exemplary registry pattern; extensibility and collision safety are valuable for plugins/future formats.

**Sources/ViewerCore/DiffTextStyle.swift** (46 LOC) — Single source of truth for diff body typography (bridges editor content-font-size to diff rendering).
- notable: Couples diff to editor's effective font size so a line in diff matches the same line in Source view at every zoom/font setting. Small, focused, pure.
- carry: **KEEP** — avoids diff typography drift; teaches the "one font-sizing source" pattern.

**Sources/ViewerCore/DiskConflictResolver.swift** (194 LOC) — Deterministic tiebreaker for external-edit conflicts (when editor & disk were both modified).
- notable: Compares file contents, timestamps, or size; picks the version with the most recent mtime or (on tie) the larger size as the "winner" for UI prompt. Avoids silent data loss by surfacing real conflicts to user.
- carry: **REDO** — conflict resolution UI is domain-specific; the logic is simple enough to inline at call site or move to Rust if needed. Not worth a standalone module in a fresh build.

**Sources/ViewerCore/DisplayDateFormatter.swift** (39 LOC) — Centralized `yyyy-MM-dd HH:mm` date rendering (single locale + timezone).
- notable: Uses `nonisolated(unsafe)` for thread-safe DateFormatter caching; locale pinned to POSIX so no localization drift.
- carry: **KEEP** — strong coupling discipline; worth the same pattern in any new date display surface.

**Sources/ViewerCore/DocumentController.swift** (194 LOC) — Orchestration for document state transitions (loading, saving, external-edit detection, conflicts).
- notable: Coordinates EditorBuffer state machine (dirty → saved), FileWatcher notifications, and external-edit prompts. Manages the async coordination between UI state and disk I/O.
- carry: **REDO** — document lifecycle is app-specific; worth reimplementing fresh in the Rust/remote-core pattern (this is tight to local AppKit/SwiftUI timing).

**Sources/ViewerCore/DocumentStats.swift** (64 LOC) — Word/line/character counts (pure text analysis).
- notable: CRLF-aware line counting (CR-LF pair is one break, not two). Grapheme-cluster character count (user-perceived). Pure; testable.
- carry: **KEEP** — solid text-stats logic; porting to Rust as a util would be straightforward.

**Sources/ViewerCore/DotGraph.swift** (279 LOC) — Graphviz DOT parser (AST + structural outline, no layout engine).
- notable: Parses DOT syntax to extract graph directedness, nodes, edges, and a declarative outline for rendering (not a layout engine — force layout is separate). Gracefully degrades to nil on invalid input.
- carry: **REDO** — parser should move to Rust-core if the rebuild includes DOT support; SwiftUI-specific outline types should be re-designed for cross-platform rendering.

**Sources/ViewerCore/DotGraphOutline.swift** (91 LOC) — SwiftUI-specific tree outline for DOT graph nodes/edges (used by the expanded node tree in the dependency view).
- notable: Maps DotGraph nodes to SwiftUI Identifiable tree items. Couples to SwiftUI Hashable protocol.
- carry: **AVOID** — couples outline representation to SwiftUI; re-design the outline as a pure model in Rust-core with a SwiftUI adapter at the UI layer.

**Sources/ViewerCore/DoubleTapModifierDetector.swift** (87 LOC) — Gesture recognizer seam for detecting double-tap + modifier key combos on macOS.
- notable: Works around SwiftUI's limited gesture detection by wrapping NSView event handling. TSK-1278 — a platform-specific workaround.
- carry: **AVOID** — platform-specific gesture workaround; rebuild should use SwiftUI 6.1+ native APIs or a cleaner Cocoa bridge if needed.

**Sources/ViewerCore/DropReRootPolicy.swift** (22 LOC) — Pure logic for "should dropping a folder re-root the sidebar?"
- notable: Path-based check (standardized URLs, component-wise descendant detection). Avoids the accidental self/subfolder-drag trap. Pure; host-testable.
- carry: **KEEP** — solid UX logic; small, reusable.

**Sources/ViewerCore/EditableCSVModel.swift** (317 LOC) — In-memory editable cell model for CSV/TSV grids (immutable base + overlay edits).
- notable: **Key pattern: overlay model.** Base is immutable parsed grid; edits live in a `(row, col) → value` overlay. Coalescing: setting a cell back to base drops the overlay entry, so `isDirty ⟺ !overlay.isEmpty`. Undo/redo stack per edit. Serialization folds overlay into base on write. Handles CRLF, quoting, deterministic round-tripping.
- carry: **KEEP** — exemplary immutable-base-plus-overlay pattern; worth porting to Rust as a CSV editing engine for remote/TUI layers.

**Sources/ViewerCore/EditLocationHistory.swift** (96 LOC) — LRU history of editor cursor positions (for back/forward navigation, e.g., clicking a symbol jumps to definition then back).
- notable: Bounded history (e.g. 50 entries); evicts oldest on overflow. Tracks (url, line, column); handles file deletion gracefully (stale entries ignored).
- carry: **KEEP** — simple, useful pattern for nav history in any multi-file editor.

**Sources/ViewerCore/EditorBuffer.swift** (434 LOC) — In-memory text buffer for a tab in editor mode; tracks dirty state, external edits, and encoding.
- notable: **Conflict detection seam.** Compares `(mtime, size)` fingerprint against disk to detect external writes. Dual-state tracking: `lastSavedMTime/Size` (captured at load/save) vs `hasExternalEdit` (current watcher reading). Read-only flag for extracted text (`.docx`/`.rtf`). UTF-8 default, encoding preserved. Value semantics (cheap COW).
- carry: **KEEP** — teaches the dual-fingerprint pattern (mtime + size) for robust conflict detection. The `hasUnknownDiskState` logic is worth studying for any remote/local conflict handling.

**Sources/ViewerCore/ExternalEditReconciler.swift** (46 LOC) — Bridge for merging external edits detected by FileWatcher into the editor buffer (handles "keep my edits" branch).
- notable: Silences duplicate watcher events when keeping local edits by refreshing the fingerprint without changing the baseline.
- carry: **AVOID** — thin wrapper around EditorBuffer; fold into DocumentController or make it a method on EditorBuffer in a rebuild.

**Sources/ViewerCore/FeedSubscriptionStore.swift** (389 LOC) — RSS/Atom feed subscription model (OPML import/export, URL deduplication, refresh scheduling).
- notable: Immutable feed list + mutable subscription set. OPML parsing/exporting for standards compliance. Refresh scheduling with exponential backoff + jitter. Sendable; pure data model.
- carry: **REDO** — feed logic is orthogonal to the editor; if the rebuild includes RSS, re-implement as a separate module or external service with a simpler contract.

**Sources/ViewerCore/FileFormatMenuState.swift** (53 LOC) — UI state for the "file format" dropdown menu (encoding, line-ending, syntax highlighting picks).
- notable: Ephemeral UI-state model; routes selection changes back to DocumentModel.
- carry: **AVOID** — UI state model; belongs in the view layer in a fresh build, not in ViewerCore.

**Sources/ViewerCore/FileFormatState.swift** (37 LOC) — Persistent file-format preferences (encoding, line endings, syntax language).
- notable: Serializable; syncs to disk via PreferencesStore or per-file metadata.
- carry: **REDO** — preferences belong in a config layer; re-design as a simpler key-value store or per-workspace settings.

**Sources/ViewerCore/FileIconClassifier.swift** (289 LOC) — Icon assignment from filename/extension/UTType.
- notable: Fallback chain: explicit icons for known types (JS/Python/etc.), then UTType query, then generic type icon. Emoji-based on-screen (no external image assets).
- carry: **KEEP** — comprehensive file-type-to-icon mapping; export to Rust-core or keep as a reference table.

**Sources/ViewerCore/FileRenamer.swift** (82 LOC) — Safe file rename with collision detection and undo.
- notable: Checks for naming conflicts before rename; keeps the old path for "undo" (not a real undo, just the old name on error).
- carry: **REDO** — rename logic is thin; better as a pure function in Rust-core or inline in the file-tree handler.

**Sources/ViewerCore/FileResurrection.swift** (83 LOC) — Recovery of deleted files (read from Trash, move back to original path).
- notable: Cross-platform (macOS Trash location varies); gracefully handles missing/moved trash.
- carry: **AVOID** — macOS-specific Trash API; cross-platform file management belongs in OS-agnostic Rust-core + platform adapters.

**Sources/ViewerCore/FileTreeFilter.swift** (71 LOC) — Predicate-based filtering of file tree nodes (hide/show by name/type/hidden-file status).
- notable: Pure filter logic; easily composed (AND / OR combinators could be added).
- carry: **KEEP** — simple, reusable filtering pattern; works in any multi-platform file browser.

**Sources/ViewerCore/FileTreeOps.swift** (153 LOC) — Mutation operations on the file tree (add/delete/move/rename nodes, with parent consistency checks).
- notable: Maintains parent-child invariants (can't add a file as its own ancestor, etc.). Immutable tree structure; returns new tree on mutation.
- carry: **KEEP** — solid tree-mutation patterns; good reference for Rust-core file-tree engine.

**Sources/ViewerCore/FileTreeRecency.swift** (223 LOC) — LRU tracking of recently-opened folders/files (for quick access, breadcrumb history).
- notable: Bounded history; evicts oldest on overflow. Path-based; handles deleted files gracefully.
- carry: **KEEP** — useful pattern for any sidebar history.

**Sources/ViewerCore/FileTreeService.swift** (95 LOC) — High-level file-tree API (enumerate children, get attributes, watch folder).
- notable: Thin wrapper over FileManager + FolderWatcher; provides a unified async interface for tree operations.
- carry: **REDO** — wrapper should be reimplemented in Rust-core as the definitive file-tree service; Swift wrapper should be thin client code at the UI layer.

**Sources/ViewerCore/FileWatcher.swift** (273 LOC) — inotify-style file watcher (DispatchSourceFileSystemObject wrapper).
- notable: **Key pattern: reattach-with-backoff.** On delete/rename, re-opens the path after a delay (atomic writes rename temp over original). Debounce handler calls (FW-13). Tracks consecutive attach failures (FW-5) separately from event count so rapid atomic writes don't exhaust retries. Test seams for deterministic race testing (`attachWindowHook`).
- carry: **KEEP** — exemplary async-resource-lifecycle pattern; the reattach-with-backoff and debouncing teach valuable lessons about file-watching edge cases.

**Sources/ViewerCore/FindEngine.swift** (213 LOC) — Pure regex/literal search engine with complexity guards and line/column tracking.
- notable: **Regex safety.** `RegexComplexityGuard.reject` catches exponential ReDoS patterns at compile time; `boundedMatches` wall-clock-bounds enumeration to catch polynomial backtracking. O(N) line/column calculation instead of O(M·N). CRLF/CR/LF aware (S2-E). Single-slot regex cache to avoid recompiling the same query.
- carry: **KEEP** — exemplary security + perf pattern for user-facing regex; the complexity guard is worth exporting to Rust-core.

**Sources/ViewerCore/FirstRunExperience.swift** (86 LOC) — Walkthrough/onboarding state (has-user-seen-X tracking).
- notable: Serializable; gated on first launch or opt-in later.
- carry: **REDO** — FRX logic should integrate with the plugin/Walkthrough v2 system; re-design as part of a sessions/persistence layer.

**Sources/ViewerCore/FlameInteraction.swift** (92 LOC) — Hit-testing and pan/zoom for flame charts (CPU profile flamegraphs).
- notable: Pure math similar to DependencyGraphInteraction but for vertical stack layout.
- carry: **KEEP** — if rebuilding includes profiling, flame-chart math is useful reference.

**Sources/ViewerCore/FlameLayout.swift** (78 LOC) — Deterministic layout for flame-chart stacks (width ∝ time, y ∝ stack depth).
- notable: Pure geometry; no randomness.
- carry: **KEEP** — reference layout for performance visualization.

**Sources/ViewerCore/FlameProfile.swift** (219 LOC) — In-memory CPU profile model (stacks, frames, time attribution).
- notable: Pure data; supports time-aggregated view (collapse identical stacks).
- carry: **KEEP** — if profiling is in scope for rebuild, this is a solid data model.

**Sources/ViewerCore/FlameProfileDiff.swift** (84 LOC) — Diff of two flame profiles (showed change in time/count per frame).
- notable: Pure diff logic; shows before/after stacks side-by-side.
- carry: **AVOID** — specialized visualization; likely not in scope for initial rebuild; revisit if comparative profiling becomes a feature.

**Sources/ViewerCore/FocusWorkMode.swift** (150 LOC) — "Focus mode" state (hides sidebar, fullscreen editor, distraction-free).
- notable: UI state; serializable (persisted per workspace).
- carry: **AVOID** — UI state; belongs in view layer, not ViewerCore. Re-implement as a workspace preference in the UI layer.

**Sources/ViewerCore/FolderSizeStats.swift** (238 LOC) — Recursive folder size calculation (async + cancellable for big trees).
- notable: Streams progress updates; handles symlink loops (maintains seen inodes). Gracefully skips unreadable dirs.
- carry: **KEEP** — solid recursive-walk pattern with progress tracking; useful for any file browser that shows folder sizes.

**Sources/ViewerCore/FolderWatcher.swift** (342 LOC) — Watches a directory tree for changes (files added/deleted/modified).
- notable: **Key pattern: hierarchical watchers.** One watcher per dir; on new subdir, creates a watcher for it. Coalesces rapid events. Debounce. Handles symlink loops (tracks seen inodes). Root-level collapse.
- carry: **KEEP** — exemplary hierarchical file-watching pattern; the symlink-loop detection and debouncing teach valuable lessons.

**Sources/ViewerCore/FontPreference.swift** (62 LOC) — User's font choice (family, size, ligatures enabled).
- notable: Serializable; tied to NSFont on macOS (platform-specific).
- carry: **REDO** — font preferences should be abstracted as a simpler model (name + size + features) with platform-specific font resolution at UI layer.

**Sources/ViewerCore/Formatter.swift** (988 LOC) — Pretty-printing for JSON/XML/JS/CSS (minify/expand, graceful fallback on parse error).
- notable: **Large, exemplary.** JS/CSS use lexical re-indenters (NOT ASTs) that preserve whitespace outside literals — escape-aware for strings/comments/regex/templates. Rejects `.jsx`/`.ts` (they add syntax the simple lexer doesn't model). JSON sorts keys deterministically. Graceful: any parse failure returns the original unchanged. Minify + pretty-print both covered.
- carry: **KEEP** — comprehensive formatter reference; lexical JS/CSS indenters are worth porting to Rust as standalone tools.

**Sources/ViewerCore/FormulaEngine.swift** (161 LOC) — Simple spreadsheet-style formula evaluator (sum, avg, min, max, cell references).
- notable: Pure; parses `=SUM(A1:A10)` style formulas. Used by CSV grid for computed columns (not yet wired in UI).
- carry: **AVOID** — specialized feature; not clear if computed columns stay in scope for rebuild; revisit after roadmap is locked.

**Sources/ViewerCore/FuzzyMatcher.swift** (20 LOC) — **Marker file.** Swift fuzzy-ranking algorithm deleted; moved to Rust-core (`fuzzy.rs`). Only the result type remains (Match struct with score + matched indices).
- notable: Excellent example of a **staged port**: Step 1 = keep data types, Step 2 = move algorithm to Rust, Step 3 = route calls through FFI adapter.
- carry: **KEEP** — pedagogical; shows how to stage an engine migration without API churn.

**Sources/ViewerCore/GitClonePlan.swift** (59 LOC) — Model for a planned git clone operation (destination, branch, depth options).
- notable: Serializable; used by git-clone dialog to build the invocation.
- carry: **REDO** — git operations belong in Rust-core; re-design as part of a VCS plugin/adapter layer.

**Sources/ViewerCore/GitVersionSource.swift** (103 LOC) — Extracts version string from git tags / commit count (for auto-versioning builds).
- notable: Parses `git describe` output; handles missing git gracefully.
- carry: **AVOID** — build-system tie-in; not needed in a web-first or cross-platform rebuild.

**Sources/ViewerCore/GoToPathHistoryStore.swift** (152 LOC) — History of "Go to Path" dialog entries (for quick re-access of frequently-visited paths).
- notable: LRU history; persisted to disk; handles deleted paths gracefully.
- carry: **KEEP** — useful pattern; simple to reimplement or port to Rust.

**Sources/ViewerCore/GotoQueryParser.swift** (121 LOC) — Parser for "Go to" commands (`file.txt:123` = line 123, `file.txt:5:10` = line 5 col 10).
- notable: Pure parser; graceful on invalid syntax.
- carry: **KEEP** — useful query grammar; small, portable.

**Sources/ViewerCore/HexCaretMap.swift** (129 LOC) — Bidirectional caret position mapping for hex grid (byte offset ↔ row/col in the grid view).
- notable: Handles odd byte counts (last row may be ragged). Pure math.
- carry: **KEEP** — if hex editing is in scope, this geometry is reusable.

**Sources/ViewerCore/HexDumpBuilder.swift** (283 LOC) — Formats binary data as hex dump (16 bytes per row, with ASCII column).
- notable: Customizable column widths, separator styles, offset display. Streaming (processes chunks). Pure formatting.
- carry: **KEEP** — solid hex-dump formatter; useful for any binary viewer.

**Sources/ViewerCore/HexEditBuffer.swift** (315 LOC) — In-memory editable hex buffer (similar shape to EditorBuffer but for binary data).
- notable: Tracks edits in an overlay (per byte, keyed by offset). Undo/redo. Dirty detection. Can grow the buffer (append bytes). Serializes back to binary.
- carry: **KEEP** — exemplary overlay pattern adapted for binary; if hex editing stays, this is solid reference.

**Sources/ViewerCore/HexGridGeometry.swift** (47 LOC) — Grid layout math for hex view (bytes-per-row, row/col to offset).
- notable: Pure; handles ragged last row.
- carry: **KEEP** — if hex editing stays, simple geometry reference.

**Sources/ViewerCore/HexHighlightPlan.swift** (83 LOC) — Determines which bytes to highlight in the hex view (selection, search matches, etc.).
- notable: Merges overlapping highlight ranges so a byte isn't double-highlighted.
- carry: **KEEP** — useful highlight-merge pattern for any multi-layer visualization.

---

## Module Summary

### What This Slice Does

This batch spans **specialized domain engines and data models** across multiple features:

1. **Graph visualization** (Dependency, Flame, DOT): Pure layout + interaction math (force-directed, hit-testing, pan/zoom).
2. **Text & structured-format handling** (Find, Formatter, DocumentStats): Regex complexity guards, lexical re-indenters, pure parsing.
3. **File system & editing**: Conflict detection seams (EditorBuffer), hierarchical watching (FolderWatcher), CSV grid models (EditableCSVModel).
4. **Domain-specific models**: Feed subscriptions, flame profiles, hex dumps, git operations.

### Cross-Cutting Patterns

- **Immutable base + overlay edits** (EditableCSVModel, HexEditBuffer, EditorBuffer): Pure-value foundation + diff layer for undo/dirty tracking.
- **Reattach-with-backoff** (FileWatcher): Graceful recovery from transient resource loss with exponential backoff + test seams.
- **Pure geometry & interaction** (all graph/flame/hex modules): Testable, deterministic math; no randomness or UI dependencies.
- **Security-minded regex** (FindEngine): Compile-time + runtime complexity guards; O(N) not O(M·N) algorithms.
- **Graceful degradation** (Formatter, most parsers): Parse fails → return original unchanged, no exceptions.

---

## Patterns Worth Porting

1. **EditableCSVModel's overlay pattern** — immutable base + sparse `(key → value)` edits for cheap dirty detection and undo. Port to Rust; reuse for any grid/table cell edit.

2. **FileWatcher's reattach + debounce** — exponential backoff on consecutive failures (not event count); debounce handler calls. Textbook async-resource-lifecycle pattern.

3. **FindEngine's regex guards** — compile-time ReDoS rejection + wall-clock-bounded enumeration. Core security pattern; export to MCP tools + any user-facing search.

4. **Dual-fingerprint conflict detection** (EditorBuffer) — `(mtime, size)` pair to detect external edits; `hasUnknownDiskState` distinguishes "proven unchanged" from "can't tell". Essential for robust local/remote sync.

5. **FolderWatcher's hierarchical watching** — per-directory watchers, dynamic child-watcher creation, symlink-loop avoidance. Reference for any cross-platform file monitor.

6. **DependencySourceResolver's URL normalization** — git-remote-to-https conversion (scp-style, git://, ssh://, git+https://), scoped-name handling. Reusable for package management across ecosystems.

---

## Anti-Patterns / Regrets

1. **UI state in ViewerCore** (FileFormatMenuState, FocusWorkMode, FirstRunExperience) — these belong in the view layer; storing UI state in the model layer creates tight coupling to SwiftUI/AppKit.

2. **Platform-specific File I/O** (FileResurrection, FontPreference) — macOS Trash API, NSFont coupling. Should be abstracted to Rust-core + platform adapters.

3. **Tight SwiftUI coupling** (DotGraphOutline) — tree outline wrapped in SwiftUI Identifiable/Hashable. Pure model should remain platform-agnostic; adapter at UI layer.

4. **Gesture workarounds** (DoubleTapModifierDetector) — NSView event handler seam for SwiftUI limitations. Likely obsolete in SwiftUI 6+.

5. **Thin wrappers that don't abstract** (ExternalEditReconciler, FileTreeService) — better inlined or left as methods on the underlying type.

6. **Feature-specific models in ViewerCore** (Feed subscriptions, Flame profiles, Formula engine, Git operations) — orthogonal features that should live in separate modules or external services.

---

## Gotchas & Surprises

- **CRLF handling is subtle** (FindEngine, DocumentStats): Three newline modes (LF, CR, CRLF as one). Tests must cover all three.

- **Regex + wall-clock limits** (FindEngine): Compile-time ReDoS guard is necessary but insufficient; polynomial backtracking bypasses it. SEC-006: always bounded enumeration.

- **Atomic writes trigger reattach** (FileWatcher): Data.write(.atomic) renames temp over target, which fires a rename event; watcher must re-open the path. Reattach delay (50ms default) lets the write settle.

- **Symlink de-symlinking risk** (EditorWriter): Data.write(.atomic) replaces a symlink with a regular file, breaking user's setup. TSK-861 / S5.1 flag to opt-in or reject.

- **Metadata preservation on save** (EditorWriter): Atomic rename loses mode bits, owner, ACLs, xattrs. EDIT-attrs: stat original, replay its metadata onto temp before rename.

- **Encode-specific BOM handling** (EditorWriter): UTF-16LE/BE need explicit BOM prepend; other encodings handled by `String.data(using:)`.

- **Overlay coalescing** (EditableCSVModel): Setting a cell back to its base value drops the overlay entry; so `isDirty` stays in sync with overlay non-empty without explicit tracking.

---

## Rebuild Notes

### For Swift / AppKit rebuild

- **Keep:** all pure-logic modules (FindEngine, Formatter, DependencyGraphLayout, HexDumpBuilder, EditableCSVModel overlay patterns).
- **Migrate to SwiftUI adapters:** UI state (FileFormatMenuState, FocusWorkMode); keep data models, move state to SwiftUI @State/@Published.
- **Abstract:** FileResurrection, FontPreference via protocol/adapters so non-macOS platforms can have stub implementations.
- **Reimagine:** DotGraphOutline as pure model + SwiftUI tree view adapter (decouple Identifiable from data).

### For Rust-core rebuild

- **Highly portable:** DependencySourceResolver, FileTreeOps, FuzzyMatcher (already ported), FindEngine security guards, EditableCSVModel overlay pattern, Formatter lexical indenters.
- **Medium effort:** FileWatcher / FolderWatcher reattach logic (translate DispatchSourceFileSystemObject to inotify / FSEvents / Win32 API), HexDumpBuilder / HexEditBuffer, FormulaEngine.
- **Revisit scope:** Flame profiles, feed subscriptions, git operations (orthogonal to core editor; consider plugin architecture).

### Data model boundaries

- **Keep in core:** file paths, document state (dirty/saved/modified), search queries, grid cell models, hex offsets.
- **Extract to Rust:** dependency resolution, diagram parsing (DOT), fuzzy ranking, regex guards, CSV/hex serialization.
- **Leave to UI:** font preferences, focus mode, UI state, icon assignment (can query UTType on demand).

### Testing strategy

- **Host-testable:** all pure-logic modules (geometry, parsing, validation).
- **Deterministic:** force layouts, graph layouts, regex searches (cache + bounded enumeration).
- **Concurrency:** FileWatcher / FolderWatcher reattach logic (test seams for race conditions; attach-window-hook pattern).
- **File I/O seams:** TOCTOU races, symlink handling (pre-stat, O_NOFOLLOW on open, rename).

