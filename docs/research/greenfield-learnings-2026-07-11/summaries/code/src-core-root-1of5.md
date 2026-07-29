# ViewerCore Root Files — Codebase Learning (Slice 1/5)

Analysis of `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/*.swift` (files 1–51 of 51)

---

## File Inventory

**ActionHistory.swift** (368 LOC) — Central reversible-command bus + undo/redo stack. Executes actions, records them, coalesces keystroke-grain edits into logical steps.
- notable: Protocol-based `ReversibleAction` contract; `ClosureAction` adapter seam for zero-dependency registration; time-windowed coalescing; size-capped history.
- carry: **KEEP** — Well-scoped, dependency-free undo foundation worth reusing; high-quality signal.

**AgentDiffApply.swift** (67 LOC) — Apply approve/reject decisions over agent-written diffs. Model A: revert rejected hunks from new-side text back to old-side.
- notable: Bottom-to-top application guards line-index shifts; DIVERGENCE guard prevents file-mutation blindness on stale diffs.
- carry: **KEEP** — Robust diff safety logic; model is sound.

**AgentDiffExtractor.swift** (176 LOC) — Turn agent tool calls (Edit/Write/MultiEdit) into unified-diff text for the review UI.
- notable: Faithful, not clever—preserves exact agent mutation (no minimizing hunk). Git-diff preamble for proper file recognition. Handles synthetic line-number sequencing.
- carry: **KEEP** — Transparent agent-audit trail; pure logic.

**AppCacheReset.swift** (176 LOC) — Granular "invalidate stuck things" reset. Never deletes; always moves to timestamped backup (`_reset-backups/`).
- notable: Pure planner (`relativeTargets`) + side-effecting executor; test-injectable base dirs. Separate `CacheDomain` + `AppSupportBase` for multi-subdir state layout.
- carry: **KEEP** — Excellent escape-hatch design; safety-first move-not-delete.

**AppResourceBundle.swift** (59 LOC) — Resolve SwiftPM resource bundles robustly. Fixes a SwiftPM `Bundle.module` bug: resolves `Contents/Resources` before hardcoded absolute `.build` paths.
- notable: Production guards against clean-machine bootstrap failure (M5 crash on missing `.build`). Fallback to `Bundle.module` for swift run/test.
- carry: **KEEP** — Mature workaround for a known SwiftPM footgun.

**AudioMetadataRows.swift** (52 LOC) — Builds Title/Artist/Album/Year tag rows for file-info panel. Pure extraction & display order.
- notable: Handles HTML entity decoding; year extraction from date strings.
- carry: **KEEP** — Minimal, reusable metadata formatter.

**AuditLog.swift** (133 LOC) — Append-only JSONL audit trail (`~/Library/Application Support/MarkdownViewer/audit.jsonl`). Size-rotated at 5 MB.
- notable: Thread-safe (per-event lock), crash-tolerant (append + flush). Privacy-conscious: no contents, only paths/methods/byte counts. Kill-switch via UserDefaults.
- carry: **KEEP** — Production-grade audit foundation.

**BinaryFileLoader.swift** (108 LOC) — Read up to 4 MB of a binary file for the hex viewer. Guards against TOCTOU by resolving symlinks, verifying regular-file type, reading one byte past cap to detect truncation.
- notable: Careful symlink-loop + device-file protection; reads cap+1 to detect truncation without stat drift.
- carry: **KEEP** — Excellent TOCTOU discipline.

**BlockPatchJS.swift** (56 LOC) — JS side of rendered-MD DOM-patch apply. Single source of truth for the WebView route + isolated test validation.
- notable: Inline JS function string ensures both slice A (test) and slice B (live) exercise identical code. Simple, bounds-checked no-op semantics on bad indices.
- carry: **KEEP** — Clean separation of concerns between Swift + JS logic.

**BookmarksStore.swift** (250+ LOC) — User-pinned files/folders. O(1)-contains via index; removal undo stack; TOCTOU guard via filesystem identity (inode capture at add).
- notable: `BookmarkEntry` + `BookmarkTargetIdentity` (dev/ino tuple); symlink-swap detection at open time; line bookmarks + file bookmarks independent. Deletion → undo stack (bounded depth).
- carry: **KEEP** — Sophisticated file-identity tracking; worth porting.

**BookmarkTargetIdentity.swift** (126 LOC) — TOCTOU guard: snapshot identity (dev, ino, is_dir, realpath) at bookmark-add, re-validate at open-time.
- notable: Uses POSIX `stat(2)` + `realpath(3)` (stable across reboots, unlike `fileResourceIdentifierKey`); validates *resolved* target (symlink-aware).
- carry: **KEEP** — Rock-solid symlink-swap detection; production-grade.

**BreadcrumbPath.swift** (69 LOC) — Splits file URL into clickable breadcrumb segments for footer path bar. Home prefix collapses to "~".
- notable: Context-menu actions per segment (folder verbs vs file verbs); pure path logic, render is VM tail.
- carry: **KEEP** — Clean, reusable breadcrumb model.

**BrowserNavigationPolicy.swift** (181 LOC) — Security policy for localhost browser tab. Allows loopback HTTP(S)/WS(S) top-level; guards against file:// + off-host redirects. Permissive/strict sub-resource modes.
- notable: Host-string parsing (IPv4 127/8 block, IPv6 ::1, localhost). No sanitization—first-party origin assumption. Pure decision logic.
- carry: **KEEP** — Tight, testable security boundary.

**BrowserPreview.swift** (23 LOC) — Temp filename for "Open Rendered in Browser." Filesystem-safe normalization; stable per stem so re-opens overwrite.
- notable: Minimal, reusable naming helper.
- carry: **KEEP** — Trivial but useful.

**ByteSize.swift** (13 LOC) — Format large-file cap banners (%.1f MB).
- notable: Intentionally fixed format for multi-MB files (no localization for ad-hoc binary inspection).
- carry: **KEEP** — Minimal utility.

**CapabilitiesDocument.swift** (37 LOC) — Help ▸ Capabilities page content. Bundles `CAPABILITIES.md` (single source); fallback to embedded text in dev.
- notable: Bundle-resource fallback pattern; dependency-free availability.
- carry: **KEEP** — Clean resource-management pattern.

**CellReference.swift** (167 LOC) — A1-style cell addressing (bijective base-26 conversion). Pure, side-effect-free parsing + formatting.
- notable: Strict parsing (`[A-Za-z]+[0-9]+` only, no `$` markers); overflow guards on column-index conversion.
- carry: **KEEP** — Excellent spreadsheet-formula foundation.

**ChangeClassifier.swift** (116 LOC) — Classify file changes to decide if agent can self-certify on host or must go to VM. Maps paths to `ChangeClass` (hostProvable / renderPath / needsVM / testOnly / nonCode / needsReview).
- notable: Per-file + aggregate verdict; restrictiveness ranking. Encodes project's test-tier map (ViewerCore/Kit/Rust/C = host; ViewerUI = render; WebView = VM).
- carry: **KEEP** — Critical for agent UAT gate; worth porting.

**ClaudeLogParser.swift** (105 LOC) — **STAGE-B DELETED TWIN.** Swift JSONL→event projection was deleted; engine is rust-core's `transcript.rs`. Remnants: `ClaudeEvent` contract types + record-classification statics for `ClaudeSessionIndex`.
- notable: Mirrors transcript-directory convention; cheap "has transcripts" check.
- carry: **KEEP** — Contract types + convenience functions still used.

**ClaudeLogParser+SystemRecords.swift** (160 LOC) — Redaction barrier for transcript records (secrets: `signature` blobs, HTTP `headers`, large image sources). Recursive JSON scrubbing; key-name-driven robustness to version drift.
- notable: Opaque-secret stripping (`[REDACTED]` token); image-source truncation (keep metadata, drop big base64); record classification (user/assistant/thinking/tool/tool_result).
- carry: **KEEP** — Security-critical redaction logic; well-scoped.

**ClaudeMonitorListState.swift** (80 LOC) — Monitor list state + refresh fingerprint. Why is it empty? Fingerprint = count + newest mtime + total size for cheap change detection.
- notable: Catch adds/removals/appends without content reads; O(files) stats.
- carry: **KEEP** — Lightweight, effective debounce logic.

**ClaudeMonitorLog.swift** (250+ LOC) — Parse the passive Claude Code hook-monitor JSONL. One event per lifecycle hook (PostToolUse, UserPromptSubmit, SessionEnd, etc.). Flat, privacy-conscious envelope (no tool_input/response, only sizes; prompt preview 200 chars max).
- notable: Per-session files (`~/.claude/monitor/<session_id>.jsonl`); streaming reader; per-file + project-scoped aggregations.
- carry: **KEEP** — Privacy-first audit model worth copying.

**ClaudeSessionIndex.swift** (250+ LOC) — Index `~/.claude/projects/*/*.jsonl` (top-level transcripts only). Streaming JSONL reader; never slurps file whole; lazy random-access via byte-offset table.
- notable: Per-line cap (4 MB), per-record cap (1M), per-title cap (200 chars). Title resolution: last custom > last AI > first prompt. Memory bounded by read-chunk size.
- carry: **KEEP** — Excellent bounded-streaming pattern for large transcripts.

**ClaudeTranscriptSearch.swift** (211 LOC) — Transcript search (substring or ICU regex). Per-file + total match caps; snippet extraction.
- notable: Matcher compiled once; regex ReDoS guard (shared with CrossFileSearch); case-sensitive toggle.
- carry: **KEEP** — Solid search + snippet logic.

**CLILauncher.swift** (80 LOC) — Generate + install `textview` shell wrapper. Preferred install to `/usr/local/bin`, fallback to `~/.local/bin` (per-user).
- notable: Pure script generation (no I/O); injectable install dirs; shell-single-quote escaping for app paths with spaces.
- carry: **KEEP** — Reusable CLI-launcher pattern.

**ClipboardTableExtractor.swift** (250+ LOC) — Detect + extract tabular HTML/TSV from clipboard. Forgiving tag-walker (no DOM); cell text = stripped markup + entity-decoded + whitespace-collapsed.
- notable: HTML table detection; colspan/rowspan ignored (safe; rows ragged); TSV via Rust CSV adapter. Bounds: max rows/cells/chars per cell.
- carry: **KEEP** — Robust clipboard-paste universal-table logic.

**CodeMirrorBridge.swift** (250+ LOC) — CM6 versioned wire protocol (v1 + v2). Enums for inbound (JS→Swift) + outbound (Swift→JS) messages. Forward/backward-compatible envelope.
- notable: Negotiated version down to peer's floor; old JS bundles can keep talking to freshly-bumped Swift. Detailed spec in `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md`. Pure encode/decode (no UI imports).
- carry: **KEEP** — Excellent versioning discipline for long-lived protocols.

**CommitClipboard.swift** (20 LOC) — Clipboard text for git-commit context-menu actions. Short SHA + commit reference.
- notable: Trivial, reusable.
- carry: **KEEP** — Minimal utility.

**ContentActionMenu.swift** (75 LOC) — Dynamic, content-specific menu model. Maps `FileCategory` to candidate actions (title + verb token). Runtime gate by capability; verbs self-gate.
- notable: Pure mapping; render tail wires NSMenu rebuild per tab-switch. Verb tokens route through `ScriptVerbCatalog`.
- carry: **KEEP** — Clean content-action mapping.

**ContentFontSizing.swift** (31 LOC) — Content text-size model. Base point size × zoom factor. Markdown CSS uses `--mdv-content-scale` for intrinsic px scaling.
- notable: Splits font-size and zoom (both matter).
- carry: **KEEP** — Minimal, reusable.

**ContentTypeSniffer.swift** (55 LOC) — Conservative content-type detection for misnamed files. JSON = valid parse (leading bracket + real parse). CSV = consistent delimiter + field count across rows.
- notable: Strict (false positive > miss); strict guards against treating prose as data.
- carry: **KEEP** — Good heuristics.

**CoreDocShadow.swift** (181 LOC) — Shadow-mode differential net (TSK-1518). Mirrors CM6 edits into Rust core; compares post-apply len_utf16 every batch, full text every Nth batch + on save.
- notable: Stateful mirroring; divergence counter (S5/S6 exit gate metric); resyncs on mismatch. Host stays authoritative (shadow = proof-of-concept for core authority flip).
- carry: **KEEP** — Sophisticated verification harness for stateful core.

**CrossFileReplace.swift** (228 LOC) — Project-wide find-and-replace. Pure core (`replacedText`) + side-effecting `apply` (re-read + atomic write). Preview-before-write safety gate.
- notable: Matcher semantics mirror `CrossFileSearch` (literal substring or regex with `$1` groups, `.anchorsMatchLines`). Files with zero matches skipped (no needless rewrite).
- carry: **KEEP** — Excellent replace-with-preview safety.

**CrossFileSearch.swift** (250+ LOC) — Grep across folder tree (skip binary, oversized, VCS/build dirs). Regex ReDoS guard. Per-file + total caps. Cancellation polling every K entries.
- notable: Parallel per-file matching (concurrent batch fold); symlink-loop guard; cost budget (`maxEntriesScanned`); incremental cancellation (SCALE-5).
- carry: **KEEP** — Sophisticated, bounded search with parallelism.

**CSVCellCursor.swift** (137 LOC) — Spreadsheet cell-navigation model. Clamped, non-wrapping cursor. Supports arrow keys, page/home/end, arbitrary jump.
- notable: Pure movement logic; returns whether cursor moved (key-event consumption decision).
- carry: **KEEP** — Clean cursor model.

**CSVClipboard.swift** (15 LOC) — Parse tab/newline-delimited clipboard strings into cell grid.
- notable: Trivial.
- carry: **KEEP** — Minimal utility.

**CsvConvert.swift** (115 LOC) — CSV → Markdown table, JSON, CSV (round-trip). Table column padding for alignment; JSON preserves column order as objects.
- notable: Pure consumers of parsed CSV; migration-safe (not modifying the Rust engine).
- carry: **KEEP** — Reusable export converters.

**CSVCopy.swift** (24 LOC) — Clipboard text for multi-cell copy (row TSV, column newline-delimited).
- notable: Trivial.
- carry: **KEEP** — Minimal utility.

**CSVEditingGate.swift** (48 LOC) — Feature gate for editable-CSV grid. Env override (`MDV_CSV_EDIT=1`) + UserDefaults toggle. Default OFF.
- notable: Staged feature-flag discipline; env overrides persistent config.
- carry: **KEEP** — Clean gate pattern.

**CSVEmptyState.swift** (25 LOC) — Empty-table message logic. Distinguishes "empty file" from "filtered to nothing."
- carry: **KEEP** — Pure UX logic.

**CSVFilter.swift** (189 LOC) — Row-filtering for parsed CSV. Global query (all columns or one) + per-column expressions (=, !=, >, <, >=, <=, contains). Case-insensitive substring or numeric comparison.
- notable: Operator-prefix parsing; numeric/lexical fallback. Lowercased-row cache to skip per-keystroke `String.lowercased()` overhead.
- carry: **KEEP** — Reusable filter engine.

**CSVFind.swift** (150 LOC) — Find-in-table matcher. Returns cell coordinates (row == -1 for header). Reading order (header, then top→bottom left→right). Step next/prev with wraparound.
- notable: Distinct from `CSVFilter` (keeps table, highlights matches); same substring semantics for mental-model unity.
- carry: **KEEP** — Solid find model.

**CSVParser.swift** (46 LOC) — **STAGE-B DELETED TWIN.** RFC-4180 tokenizer algorithm deleted (engine = rust-core's `csv.rs`). Only `Result` contract remains. All calls route through `RustCSVAdapter`.
- notable: Marks the boundary of the Swift-to-Rust port.
- carry: **KEEP** — Contract types + adapter seam still used.

**CSVRectSelection.swift** (48 LOC) — Rectangular multi-cell selection (anchor + focus). TSV extract for pasteboard.
- notable: Normalised ranges; clamp away out-of-bounds. Clamped-cell extract safe on ragged CSV.
- carry: **KEEP** — Reusable selection model.

**CSVRowWindowSource.swift** (136 LOC) — Windowed data source backed by Rust core's `CsvSession`. Pages surviving set O(window); filteredCount sizes scrollbar without projecting rows. Absolute-row indices stable across re-filters.
- notable: Fail-safe by construction (throw on init → fall back to full-materialize). Header cached from zero-width probe window.
- carry: **KEEP** — Excellent pagination seam for large CSVs.

**CsvSort.swift** (56 LOC) — Sort rows by column (type-aware: numeric if all non-empty cells parse as numbers, else string). Empties sort last. Stable.
- notable: Column past range = no-op. `nextState` toggles direction if tapping same column.
- carry: **KEEP** — Reusable sort logic.

**CsvSummary.swift** (94 LOC) — Profile CSV (per-column counts, min/max/mean for numeric columns). Pure consumer of parsed CSV.
- notable: `isNumeric` = all non-empty parse; `numericCount` = how many did. Report generation for menu alert.
- carry: **KEEP** — Useful analytics.

**CSVViewportPager.swift** (94 LOC) — Decide which window to fetch for a given viewport. Visible range + buffer slack avoids refetch on small scrolls within cache.
- notable: Cache-hit detection (visible range within cached bounds); miss → fetch with buffer. Zero-row/zero-visible handling.
- carry: **KEEP** — Elegant paging decision logic.

**DateTimeStamp.swift** (25 LOC) — Format current date + time for "Insert Date & Time" command. Locale + timezone injected for full testability.
- carry: **KEEP** — Reusable, testable formatter.

**DefaultAppRegistration.swift** (177 LOC) — "Make TextView the default for these types" flow. Enumerates registered type groups, checks current handler, flips via LaunchServices. Model + injected service seam.
- notable: Pure status computation; `RoleHandlerService` seam for testability. `LiveRoleHandlerService` wraps deprecated-but-functional LS C API.
- carry: **KEEP** — Excellent LS integration pattern.

**DependencyGraph.swift** (250+ LOC) — Builds module/file dependency graph. Import-graph (parse `import`/`require`/`use`, resolve project-internal to edges, external as leaf nodes) + package-graph (parse `Package.swift` deps).
- notable: Bounded walk (max file size, entry cap, skip dirs, symlink-loop guard—mirrors `CrossFileSearch`). Language-detection by extension (swift/python/js/ts/go/rust). Pure extraction + serializable model.
- carry: **KEEP** — Reusable, bounded graph extraction.

---

## Module Summary

**ViewerCore root** is a **foundational, dependency-free library layer** of pure logic, value types, and host-testable models. It partitions into six loosely-coupled domains:

1. **Undo/History** (ActionHistory) — reversible-command bus + coalescing.
2. **Agent Integration** (AgentDiffApply, AgentDiffExtractor) — agent-audit + diff review.
3. **Persistence** (BookmarksStore, BookmarkTargetIdentity, AppCacheReset, AuditLog) — stateful stores with TOCTOU guards + safety-first reset.
4. **Claude Monitoring** (ClaudeLogParser+SystemRecords, ClaudeMonitorLog, ClaudeSessionIndex, ClaudeTranscriptSearch, ClaudeMonitorListState) — Claude transcript indexing, search, + redaction.
5. **CSV/Table** (CSVParser, CSVFilter, CSVFind, CSVSort, CsvSummary, CSVCellCursor, CSVRectSelection, CSVRowWindowSource, CSVViewportPager, CSVClipboard, CSVCopy, CsvConvert, CSVEditingGate, CSVEmptyState) — spreadsheet-like table model + pagination.
6. **Utilities** (ContentTypeSniffer, CrossFileSearch, CrossFileReplace, DependencyGraph, ContentActionMenu, BrowserNavigationPolicy, CodeMirrorBridge, DefaultAppRegistration, etc.) — single-purpose tools.

**Key architectural signals:**
- **Rust-ported engines** (CSV, Transcript) follow the **deleted-twin pattern**: Swift algorithm deleted, Rust engine live, Swift contract + adapters remain (`RustCSVAdapter`, `RustTranscriptAdapter`).
- **Seams everywhere**: injected services (`RoleHandlerService`), closures for time/environment, pure planners + side-effecting executors.
- **Bounded, safe**: streaming readers (line caps, byte caps), symlink-loop guards, TOCTOU identity snapshots, cost budgets (`maxEntriesScanned`), crash-tolerant append-only logs.
- **Single sources of truth**: `CodeMirrorBridge` JS string in Swift, `ActionHistory` as canonical undo bus, `BookmarkTargetIdentity` (dev, ino, realpath).

---

## Patterns Worth Porting

### 1. **Seam-Based Testability — Injected Services + Closures**
Files: `BookmarkTargetIdentity`, `DefaultAppRegistration`, `AppCacheReset`, `CSVRowWindowSource`, `DateTimeStamp`

```swift
// Service seam for testability
protocol RoleHandlerService: Sendable {
    func defaultViewerHandler(forContentType: String) -> String?
}

// Pure logic takes the seam
public static func status(using service: RoleHandlerService) -> [GroupStatus] {
    // no FS calls, fully testable
}

// Production: `LiveRoleHandlerService` wraps real LS API
// Tests: inject a fake
```

**Rebuild value:** Decouples logic from I/O; every complex decision becomes host-testable.

---

### 2. **Bounded Streaming Readers — Memory-Safe Large-File Processing**
Files: `ClaudeSessionIndex`, `BinaryFileLoader`, `CrossFileSearch`

```swift
// Read in chunks, never slurp whole
let readChunkBytes = 256 * 1024
let maxLineBytes = 4 * 1024 * 1024
// Streaming scan: fold state per line, drop per-line buffer after use
```

**Rebuild value:** Process gigabyte files on mobile memory budgets.

---

### 3. **TOCTOU Guards via Filesystem Identity (dev, ino, realpath)**
Files: `BookmarkTargetIdentity`, `BinaryFileLoader`, `DefaultAppRegistration`

```swift
// Capture at add-time
public static func capture(at url: URL) -> BookmarkTargetIdentity? {
    let stat = Darwin.stat()
    stat($0, &st)  // POSIX stat(2), not lstat
    return BookmarkTargetIdentity(
        device: UInt64(st.st_dev),
        inode: UInt64(st.st_ino),
        resolvedPath: realpath(path, nil)
    )
}

// Validate at open-time
public static func validate(url: URL, against identity: ...) -> BookmarkValidation {
    let current = capture(at: url)
    return (current == recorded) ? .ok : .identityChanged(...)
}
```

**Rebuild value:** Symlink-swap detection; proves the user got what they pinned.

---

### 4. **Deleted-Twin Pattern for Engine Ports**
Files: `CSVParser`, `ClaudeLogParser`

When migrating a pure engine to Rust:
1. **Delete** the Swift algorithm; preserve the contract type.
2. **Route all callers** through a **Rust adapter** (`RustCSVAdapter`, `RustTranscriptAdapter`).
3. **Host-test** adapter + contract; Rust engine tested in Rust.

**Rebuild value:** Enables incremental engine ports without rewriting all call sites.

---

### 5. **Three-Part Decision Logic: Plan + Execute + Validate**
Files: `CrossFileReplace` (preview + apply), `CSVViewportPager`, `ActionHistory` (coalesce decision embedded in execute)

```swift
// Pure planner
static func plan(filteredCount: Int, visibleRowCount: Int, cached: CachedWindow?) -> Plan {
    // Returns (offset, limit, needsFetch)
}

// Side-effecting executor
@discardableResult
static func apply(toFiles files: [URL], ...) -> [FileOutcome] {
    // Reads + writes
}

// Preview (read without write) for safety
static func preview(toFiles files: [URL], ...) -> [FileOutcome] {
    // Identical read/decode/count, no write
}
```

**Rebuild value:** Testable decisions, safe-by-default apply.

---

### 6. **Versioned Wire Protocols with Negotiation**
File: `CodeMirrorBridge`

```swift
public enum CMProtocol {
    public static let currentVersion: Int = 2
    public static let oldestSupportedVersion: Int = 1
}

// Encoder negotiates DOWN to peer's floor
// Decoder accepts [oldestSupportedVersion ... currentVersion]
// On unsupported-version (too new), return `.unsupportedVersion(Int)` so caller can downgrade
```

**Rebuild value:** LiveUI ↔ WebView protocol can evolve without forcing bundled app updates.

---

### 7. **Redaction-Conscious Audit Logging**
Files: `AuditLog`, `ClaudeLogParser+SystemRecords`

```swift
// Redact keys everywhere they appear (not path-driven, key-name-driven)
// Recursive JSON scrubbing with `[REDACTED]` token
// Image-source truncation (keep metadata, drop base64)
// Append-only JSONL + size-rotation
```

**Rebuild value:** Privacy by design; logs safe for external audit.

---

## Anti-Patterns / Regrets

### 1. **Deleted-Twin Documentation Debt**
Files: `CSVParser`, `ClaudeLogParser`

The comment "`/// STAGE-B DELETED TWIN`" marks the engine port, but the Swift algorithm is gone. Future developers don't know what the Rust engine *replaced*.

**Lesson:** Keep a `PORTED_FROM.md` stub in each module, pointing to the Rust implementation + the design doc.

---

### 2. **Fragmented Transcript Reading — Two Separate Index Types**
Files: `ClaudeSessionIndex`, `ClaudeMonitorLog`

Two independent JSONL readers for overlapping data:
- `ClaudeSessionIndex` reads transcripts (`~/.claude/projects/*/*.jsonl`).
- `ClaudeMonitorLog` reads hook-monitor logs (`~/.claude/monitor/<session>.jsonl`).

Both have independent streaming logic, caps, offset tables.

**Lesson:** Unify on a single **streaming-reader harness** with pluggable record handlers.

---

### 3. **CSV Engine Split Still Pending — Rust Ported, But Swift Adapter Inline**
Files: `CSVParser`, `ClipboardTableExtractor`, `CsvConvert`, etc.

The CSV *parser* is in Rust (via `RustCSVAdapter`), but CSV *operations* (filter, sort, summary, viewport paging) are still split Swift/Rust. No single-source-of-truth for CSV semantics.

**Lesson:** Phase 2 should move the *operations* layer into Rust as a single module (CSV engine library), so the host just calls it.

---

### 4. **Module Coupling via `PreferencesStore` + `TestStateRedirect` Global Access**
Files: Many files call `PreferencesStore.defaultContentFontSize`, `TestStateRedirect.markdownViewerDir()` directly.

No injected preference/environment model; all call sites reach for a global singleton. Hard to test in isolation; environment changes become implicit.

**Lesson:** Rebuild should pass `Preferences` + `Environment` as parameters, not `@Sendable` closures + singletons.

---

### 5. **Reactive CSV Filter Sweep — O(rows × cols × queries) Per Keystroke**
File: `CSVFilter`

Every keystroke runs a full table sweep. Lowercased-row cache helps, but the architecture assumes full materialization. For million-row CSVs, this is unbounded latency.

**Lesson:** Move filter evaluation into Rust as a lazy iterator; Swift requests windows post-filter.

---

## Gotchas & Surprises

### 1. **BookmarkTargetIdentity uses `stat()` (follows symlinks), NOT `lstat()`**
```swift
let rc = path.withCString { stat($0, &st) }  // not lstat
```

Intentional: the user pinned the *resolved* file; a symlink swap changes the inode. This is correct, but non-obvious.

---

### 2. **CSVFilter + CSVFind Have Identical Substring Semantics (Case-Insensitive)**
By design — users have one mental model across views. Filter removes rows; find highlights cells. Both case-insensitive substring (or regex for find, literal-only for filter).

---

### 3. **CrossFileSearch Parallelism: Per-File Matching Concurrent, Result Folding Serial**
```swift
DispatchQueue.concurrentPerform(iterations: urls.count) { i in
    (p + i).pointee = Self.matchFile(urls[i], ...)  // race-free per-index write
}
// Then serial fold under global maxResults cap (reproduces old loop exactly)
```

Elegant: avoids file-read bottleneck while preserving deterministic ordering.

---

### 4. **CoreDocShadow — Stateful Mirroring of CM6 Edits into Rust Core**
Proof-of-concept for authority flip. Catches divergences between Swift mirror + Rust core, but never surfaces them to the user (shadow mode only). Counter = S5/S6 exit gate metric.

---

### 5. **AuditLog Append-Only + Size-Rotated, But Only One Generation Kept**
```swift
if bytesWritten >= Self.maxBytes {
    rotateLocked()  // audit.jsonl → audit.1.jsonl, start fresh
    // .jsonl file is gone; no .2 backup
}
```

Intentional: audit ≠ archive. Only the current + one rotated generation. Prevents runaway bloat.

---

## Rebuild Notes

### 1. **Unify Streaming Reader Harness**
Create a **base streaming-reader class** (configurable chunk size, line caps, byte caps, record handlers). Use it for transcripts, monitor logs, and any future bounded reads.

```
StreamingJSONLReader<T: Decodable> {
    init(url: URL, readChunkBytes: Int, maxLineBytes: Int, maxRecords: Int)
    func scan<S>(_ handler: (Int, T) -> S) -> S  // returns accumulated state
}
```

---

### 2. **Move CSV Operations Into Rust**
Port `CSVFilter`, `CSVSort`, `CsvSummary`, `CSVViewportPager` into the Rust CSV library. Leave Swift to call `window()` + render. Unifies semantics; eliminates million-row sweeps.

---

### 3. **Centralize Preferences + Environment**
Pass `Preferences` struct + `Environment` struct to every component instead of calling `PreferencesStore.defaultContentFontSize` globally. Better testability, fewer surprises.

---

### 4. **Explicit Agent-Audit Trail**
Keep `AgentDiffExtractor` + `AgentDiffApply`, but add a **diff review log** (session-scoped, persisted) so the agent's changes are always recoverable + reviewable even after edits.

---

### 5. **Bookmark Security Remains as Is**
The TOCTOU guard (`BookmarkTargetIdentity`) is production-ready. Keep it. Its only peer is Finder's `Bookmark` (CFURLCreateBookmarkData), which is opaque. POSIX (dev, ino) is more transparent + testable.

---

### 6. **Claude Monitoring — Separate from Main App**
`ClaudeSessionIndex`, `ClaudeTranscriptSearch`, `ClaudeMonitorLog` are optional (for agent integration). Move them to a separate `ViewerMonitoring` module so the app can ship without the monitor.

---

## Summary

**ViewerCore root is mature, well-disciplined code.** It demonstrates:
- Excellent **testability discipline** (pure planners, injected services, closure-based environment).
- **Bounded safety** (streaming, TOCTOU guards, cost budgets, redaction).
- **Architectural clarity** (deleted-twin ports, protocol versioning, seam-based extensibility).

The rebuild should **port the patterns wholesale** (seams, streaming, identity guards, decision/execute split) and **refactor the regrets** (unify CSV operations in Rust, centralize prefs/env, document engine ports). The result will be **more testable, more scalable, and easier to evolve** than starting from scratch.

---

**Analysis Date:** 2026-07-11  
**Analyzer:** Codebase Learning Fleet  
**Files Covered:** 51 / 51 (ViewerCore root)  
**Stage:** Greenfield rebuild guidance
