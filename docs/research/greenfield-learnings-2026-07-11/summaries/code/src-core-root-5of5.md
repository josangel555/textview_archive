# ViewerCore Root Files (Alphabetical 205-255) — Batch 5/5

## File Entries

**Sources/ViewerCore/SessionRename.swift** (66 LOC) — Decision logic for renaming sessions and deriving display names from folder paths
- notable: Single source of truth for session title derivation; auto-relabel decision (TSK-1016) prevents manual renames being clobbered by root-folder changes
- carry: KEEP — clean separation of pure decision logic from UI wiring; no cross-module coupling

**Sources/ViewerCore/SettingsCatalog.swift** (168 LOC) — Canonical settings UI information architecture (sections, kinds, display labels)
- notable: Pure data-driven catalog enabling test-driven IA reorganization; filter() supports case/diacritic-insensitive search
- carry: KEEP — elegant declarative approach to settings; makes the view layer a thin renderer

**Sources/ViewerCore/SettingsRelocation.swift** (80 LOC) — Migration model for relocating JSON settings from Library to ~/.textview/
- notable: Pure migration plan + backward-read resolution; no FileManager calls; injectable existsAt() for testing
- carry: KEEP — exemplary pure-function migration pattern; applies to any file-relocation task

**Sources/ViewerCore/SidebarDataPresence.swift** (83 LOC) — Pure predicate for panel visibility based on workspace state
- notable: Extracted from inline view predicates to prevent divergence between accordion body and shoulder-rail button states
- carry: KEEP — reusable heuristic; prevents subtle UI sync bugs

**Sources/ViewerCore/SidebarPanelHeights.swift** (157 LOC) — Resizable sidebar section height management and jank suppression
- notable: TSK-592 resize-jank fix via `shouldCommitAvailableHeight()` avoids re-bodying the sidebar when geometry doesn't actually change; geometrically proves when a height commit matters
- carry: KEEP — sophisticated optimization that removes garbage commits; demonstrates performance thought leadership

**Sources/ViewerCore/SidebarPanelKind.swift** (161 LOC) — Canonical panel identity enum with stability anchors for persistence
- notable: Pinned appStorageKey and expandedStateKey prevent enum renames from invalidating user settings; isDockable single source of truth
- carry: KEEP — principled enum design; production-grade stability contract

**Sources/ViewerCore/SidebarPanelRegistry.swift** (105 LOC) — Render order registry and visibility persistence for sidebar panels
- notable: SidebarPanelVisibility round-trips as comma-joined encoded string; graceful unknown-case handling on load
- carry: KEEP — minimal persistence design; defensive decode pattern

**Sources/ViewerCore/SidebarResize.swift** (70 LOC) — Sum-preserving divider resize math and accordion height resolution
- notable: TSK-440 fix moves height BETWEEN adjacent panels, not to a flex-fill; AccordionHeightResolver distinguishes "not measured" from "measured empty"
- carry: KEEP — precise mathematical model; unambiguous panel interaction semantics

**Sources/ViewerCore/SidebarSectionPlanner.swift** (82 LOC) — Divider placement planner that drops dividers between hidden panels
- notable: Eliminates stacked hairlines when panels self-hide; pure entry list with drawTrailingDivider flag
- carry: KEEP — solves a subtle visual bug cleanly

**Sources/ViewerCore/SourceAnnotationScanner.swift** (110 LOC) — TODO/FIXME/HACK marker extraction for jump lists
- notable: Language-agnostic by design (marker not required to be in a comment); word-boundary checks prevent false matches; case-sensitive uppercase matching
- carry: KEEP — general-purpose annotation extraction; clean CRLF handling via Unicode scalar walk

**Sources/ViewerCore/SourceInvisibles.swift** (128 LOC) — Whitespace marker rendering for the read-only source view overlay
- notable: Avoids NSLayoutManager subclass (compositor bug trigger) by using a SwiftUI Canvas overlay synced to scroll state; color derivation matches CM6 `.cm-invisible`; UTF-16-column-aware
- carry: KEEP — exemplary workaround for a compositor limitation; demonstrates defensive design

**Sources/ViewerCore/SourceWrapPolicy.swift** (48 LOC) — Forced soft-wrap for pathologically long lines (100 KB threshold)
- notable: Defensive against NSTextView horizontal layout superlinearity; early-exit on first long line (O(1) in common case)
- carry: KEEP — performance safety guardrail; simple, effective

**Sources/ViewerCore/SpellCheckEngine.swift** (215 LOC) — Host-testable wrapper over NSSpellChecker with ignore-list support
- notable: Per-call document tag prevents concurrent-caller shared-state pollution; lazy suggestion generation; determinism notes acknowledge OS-controlled dictionary state
- carry: KEEP — production-grade spell-check abstraction; honest about what's pinned vs variable

**Sources/ViewerCore/SpellDiagnosticMapping.swift** (44 LOC) — Convert spelling issues to CM6 inline diagnostics (squiggles)
- notable: Direct UTF-16 offset copy (no document-text translation needed); severity=.info + source="spell" for UI distinction
- carry: KEEP — elegant mapping; reuses LSP diagnostic infrastructure

**Sources/ViewerCore/SpellNavigation.swift** (46 LOC) — Pure cursor stepping and text correction for spell-check navigation
- notable: Wrapping modulo arithmetic; UTF-16-aware replacement; defensive out-of-range/inverted span handling
- carry: KEEP — minimal, correct primitives for spell-check UI

**Sources/ViewerCore/SymbolJump.swift** (142 LOC) — Markdown heading + LSP symbol ranking for palette `@` mode
- notable: Flattens LSP hierarchical tree to flat list with dotted container paths for disambiguation; kind labels map LSPSymbolKind → human-readable keywords
- carry: KEEP — elegant tree flattening; consistent ranking across markdown/code

**Sources/ViewerCore/SyntaxFoldRangeMapping.swift** (69 LOC) — TreeSitter fold regions → CM6 doc-offset ranges
- notable: Mirrors CMFoldRangeMapping exactly so both sources interchangeable; end-of-line positioning (no startCharacter) for consistency
- carry: KEEP — design-agnostic mapping layer; supports multiple fold sources

**Sources/ViewerCore/Tab.swift** (264 LOC) — Tab state model with identity-based equality and persistence metadata
- notable: Equatable on identity + cheap discriminators only (NOT content String, to avoid O(N) SwiftUI diffs); intentionally excludes scroll/hot-exit metadata from equality to prevent republish churn; diskState tracks file modification signals; preview flag for ephemeral VSCode-style tabs
- carry: KEEP — exemplary equality design; production-grade state semantics

**Sources/ViewerCore/TabDragPayload.swift** (24 LOC) — Drag-and-drop payload encoding for tab reorder + session move
- notable: UUID-based (never index-based) so payloads stay valid across mid-drag reorders
- carry: KEEP — simple, correct protocol

**Sources/ViewerCore/TabsState.swift** (250+ LOC) — Ordered tab list + selection management with dedup + cap
- notable: dedupedRestoreTabs() fixes duplicate-ratchet (previous append-all strategy bloated sessions to ~2000 tabs); maxRestoredTabs cap (200); normalizes URLs via standardizedFileURL + symlink resolution; openOrReveal preserves dirty flag on reveal
- carry: KEEP — production-grade session management; learned from real bloat incidents

**Sources/ViewerCore/TerminalCommandHistory.swift** (81 LOC) — MRU terminal command history with search
- notable: Process-wide shared instance (MainActor-isolated); JSON persistence with dedup on load; caps at 500 entries
- carry: KEEP — clean singleton pattern for shared app state

**Sources/ViewerCore/TerminalCommandSearch.swift** (59 LOC) — Unified ranking over pinned favorites + auto-recorded history
- notable: Favorites-first, deduped by command text; case-insensitive search on both stores
- carry: KEEP — elegant composition of two stores

**Sources/ViewerCore/TerminalCopyTrim.swift** (22 LOC) — Terminal copy hygiene (strip trailing whitespace + blank lines)
- notable: Mirrors Terminal.app/iTerm behavior; preserves interior blank lines (real content)
- carry: KEEP — small, correct utility

**Sources/ViewerCore/TerminalDropFormatter.swift** (31 LOC) — File URL → POSIX-quoted shell paste string
- notable: Single-quote escaping via '\'' (the only metachar single-quotes don't neutralize); safe-char detection for readability
- carry: KEEP — production-grade shell quoting

**Sources/ViewerCore/TerminalFavoritesStore.swift** (138 LOC) — Persisted user-curated terminal command shortcuts
- notable: Hand-editable JSON; MRU dedup (re-adding moves to front); 100-entry cap; search() over command + title
- carry: KEEP — clean persistent store pattern

**Sources/ViewerCore/TerminalHeader.swift** (45 LOC) — Terminal pane header formatter ("Terminal — <name> [<cwd>, pid <n>]")
- notable: Home-path abbreviation to ~; injectable for testing
- carry: KEEP — pure formatter

**Sources/ViewerCore/TerminalInputLineAccumulator.swift** (61 LOC) — PTY keystroke → command-line accumulator for history capture
- notable: Deliberately conservative (never records garbage); drops lines after ESC/Tab; handles CR/LF/Backspace/Ctrl chars
- carry: KEEP — pragmatic conservative design for history

**Sources/ViewerCore/TerminalPanelEdgeBridge.swift** (39 LOC) — Bijection between terminal's own TerminalPaneEdge and unified PanelEdge
- notable: Clean bridge for settings matrix picker + unified placement arbiter
- carry: KEEP — minimal enum translation

**Sources/ViewerCore/TestStateRedirect.swift** (87 LOC) — Test hermeticity guard: XCTest redirects to per-process tmp
- notable: TSK-1288 prevents tests from polluting dev's real Application Support; isUnderXCTest detects XCTest linkage (not just env var); per-process base avoids parallel-runner collision
- carry: KEEP — essential testing infrastructure; prevents data pollution

**Sources/ViewerCore/TextCleanup.swift** (67 LOC) — Whitespace trimming and final-newline normalization (preserves line endings)
- notable: CRLF-safe Unicode scalar walk; preserves each line's existing terminator (no normalization side effect unless caller wants it)
- carry: KEEP — careful line-ending preservation

**Sources/ViewerCore/TextFileLoader.swift** (367 LOC) — Comprehensive text file loading with encoding detection and format extraction
- notable: Two-tier caps (512 MiB hard read ceiling, 64 MiB soft "large" watermark for graceful degradation); BOM → UTF-16 → UTF-8 → CP1252 → Latin-1 decoding ladder; RTF/DOCX/XLSX/ODS extraction to Markdown/TSV; off-main deferral threshold (4 MiB); per-file byte counts for cache invalidation
- carry: KEEP — production-grade loader; handles edge cases gracefully; comprehensive format support

**Sources/ViewerCore/TextLineGeometry.swift** (45 LOC) — 1-based line/column geometry for selection spans
- notable: UTF-16-aware; derives end-line from selection start+length
- carry: KEEP — clean math for UI coordinate transforms

**Sources/ViewerCore/TextToolRunner.swift** (81 LOC) — Clipboard entry point for text tools (SHA256, Base64, UUID)
- notable: PasteboardIO protocol for testability; separates clipboard IO from the transform logic
- carry: KEEP — exemplary abstraction for clipboard access

**Sources/ViewerCore/TextTools.swift** (250+ LOC) — Pure text transforms: SHA256, Base64, URL encoding, line operations, case transforms
- notable: Line-transform splits preserve all newline flavors (LF/CRLF/CR); `splitLines` lossless on trailing newlines; editor line-ops return ClosedRange for selection re-placement; strict Base64 decode (no `.ignoreUnknownCharacters` divergence); Rec. 601 luminance for marker-color selection
- carry: KEEP — comprehensive toolkit; careful encoding/linebreak handling throughout

**Sources/ViewerCore/TextTransform.swift** (118 LOC) — TextEdit-style case transforms for CM6 editor
- notable: UTF-16 offsets (CM6 convention); empty selection → whole-document transform (TextEdit semantics); returns CMEdit (undoable, preserves selection) or nil (no-op); validating UTF-16 decode (no U+FFFD substitution)
- carry: KEEP — exemplary editor command design

**Sources/ViewerCore/ThreeWayMerge.swift** (250+ LOC) — Pure diff3 merge engine with conflict regions and resolution
- notable: Classic LCS DP + backtrack (Khanna/Kumar style); line-oriented; stable span + unstable chunk classification; conflict markers (git-compatible); TSK-1171 resolution model (ours/theirs/base/both/custom)
- carry: KEEP — sophisticated merge algorithm; production-ready conflict representation

**Sources/ViewerCore/ToolResults.swift** (98 LOC) — Tool result rows for shared results panel (replacing modals)
- notable: Builders for lint issues, stats, CSV summaries; plainText export for copy button
- carry: KEEP — clean result aggregation

**Sources/ViewerCore/TreemapLayout.swift** (97 LOC) — Squarified treemap layout algorithm (Bruls/Huizing/van Wijk 2000)
- notable: Greedily minimizes aspect ratio; O(n·m) space/time (fine for UI); generic over item ID
- carry: KEEP — production-grade treemap; used for folder-stats visualization

**Sources/ViewerCore/UIClickSpec.swift** (67 LOC) — Parsed `ui-click` / `ui-double-click` test verb (AX interaction)
- notable: Fraction-based positioning (0…1) for layout-resilience; strict grammar (typos fail, not silently degrade)
- carry: KEEP — clean test DSL specification

**Sources/ViewerCore/UIKeySpec.swift** (261 LOC) — Parsed `ui-key` / `ui-type` test verb (keyboard interaction)
- notable: Modifier enum (OptionSet); KeyStroke carries keyCode + modifiers + baseCharacter; dual grammar (literal text vs chord syntax); hardcoded HIToolbox virtual keycodes; strict chord parsing
- carry: KEEP — comprehensive keyboard testing infrastructure

**Sources/ViewerCore/UISceneRegistry.swift** (378 LOC) — Deterministic UI-scene catalog + resolution for pixel-reproducible testing
- notable: SceneSpec fully declarative (no randomness/timestamps); Fixture enum for abstract paths; static scenes + parametric families (terminal-*, tabs-*, preview); TSK-492 consolidates ad-hoc string parsing into one enumerated registry
- carry: KEEP — exemplary test infrastructure design; eliminates brittle string matching

**Sources/ViewerCore/UnifiedDiffGenerator.swift** (250+ LOC) — Line-granularity unified-diff text generation
- notable: Hunt–Szymanski LCS DP; groups into hunks with configurable context (default 3); round-trip with RustDiffAdapter.parse() for interop; git-compatible markers + "No newline at end of file" output
- carry: KEEP — production-grade diff implementation; dependency-free

**Sources/ViewerCore/UniversalPastePlan.swift** (92 LOC) — Materialization plan for resolved paste targets
- notable: Abstraction over pasteboard representation choice (data/string/fileURL) and file extension; humanDescription() for toast feedback
- carry: KEEP — clean paste dispatch encapsulation

**Sources/ViewerCore/URLFragmentPolicy.swift** (25 LOC) — Same-document fragment detection for navigation
- notable: Field-by-field comparison (avoids Foundation reserialize bugs on scheme-only URLs)
- carry: KEEP — defensive URL comparison

**Sources/ViewerCore/URLSchemeRouter.swift** (70 LOC) — Custom-scheme URL parser (`markdownviewer://` / `textview://`)
- notable: Typed routes (open/search/walkthrough/session); containedPath() policy (S1.1 hardening: home/temp only); strict unknown-host rejection
- carry: KEEP — security-conscious URL routing

**Sources/ViewerCore/VersionSource.swift** (92 LOC) — Backend-agnostic protocol for Local History + Git version browsing
- notable: VersionRef carries id + metadata (timestamp, author, subject, byteSize); protocol unifies list/content/diff/cumulativeDiff operations
- carry: KEEP — elegant abstraction for dual-backend viewer

**Sources/ViewerCore/ViewModeLockStore.swift** (222 LOC) — Per-file view-mode locks (pins which lens to open each file in)
- notable: Exact-filename key (precedence over extension key); lenient Codable decode (unknown modes dropped, not fatal); cap at 2048 entries; coalesced write via JSONFileStore
- carry: KEEP — defensive persistence; addresses real UI state problem

**Sources/ViewerCore/WebSourceViewGate.swift** (30 LOC) — Gate for CM6 WebView source lens (TSK-1530)
- notable: Controlled flip via MDV_WEB_SOURCE=1 env + UserDefaults default; ships OFF pending VM render validation
- carry: KEEP — clean feature gate pattern

**Sources/ViewerCore/WindowGeometry.swift** (233 LOC) — Window frame resolution against screen layout
- notable: Handles minimum size, oversize clamping, off-screen recovery, partial-off-screen nudging; sceneCaptureFrame() for deterministic UAT geometry; primary-screen fallback when none visible
- carry: KEEP — sophisticated window placement; defensive against display changes

**Sources/ViewerCore/WorktreeOverlap.swift** (83 LOC) — Cross-worktree semantic overlap detection for dispatch sequencing
- notable: whoTouches() per file; overlaps() aggregates ≥2-branch collisions; excludes merged worktrees; report() for dashboard
- carry: KEEP — solves real parallel-dispatch coordination problem

**Sources/ViewerCore/XattrIO.swift** (62 LOC) — POSIX extended-attribute read/replay for file preservation
- notable: Extracted from copy-paste in EditorBuffer + HexEditBuffer; flistxattr/fgetxattr wrapper; setxattr best-effort replay (per-attr independence)
- carry: KEEP — small, focused utility; eliminated code duplication

## Module Summary

This batch (205-255, alphabetically S–X) contains 51 files spanning **settings management** (catalog, relocation, locks), **sidebar UI state** (panel registry, heights, resize math, visibility), **source view enhancements** (annotations, invisibles, wrap policy), **spell-check** (engine, diagnostics, navigation), **terminal integration** (history, favorites, commands, header, edge bridge), **text processing** (cleanup, loading, geometry, tools, transforms), **three-way merge conflict resolution**, **tree visualization** (treemap), **UI testing infrastructure** (click/key specs, scene registry), **diff generation**, **paste handling**, **URL routing**, **version control backends**, and **window/worktree management**.

Common patterns throughout:
- **Pure decision logic extracted from views**: Settings catalog, sidebar predicates, panel heights, terminal edge bridge, text transforms, URL routing
- **Defensive persistence**: Lenient Codable decoding (unknown values dropped), caps on entry counts, per-process test-state isolation
- **Encoding/linebreak precision**: Consistent UTF-16 for CM6 interop, CRLF-safe Unicode walks, never-failing fallback chains
- **Security-conscious boundaries**: containedPath() hardening, strict URL grammar, careful enum stability contracts
- **Performance thought leadership**: Resize-jank suppression via geometric proof, early-exit patterns, off-main deferral thresholds
- **Testability by design**: Pure enums, injectable dependencies, separable concerns (PasteboardIO, VersionSource protocol)

## Patterns Worth Porting

1. **Equality on identity + cheap discriminators, not full content** (Tab.swift):
   - Mirrors SwiftUI's diffing needs; full String compare defeats O(1) tab-strip diffs
   - Explicitly exclude persistence-only metadata from Equatable
   - Apply to any large-content value type

2. **Per-call resource isolation in OS wrappers** (SpellCheckEngine):
   - Allocate unique `NSSpellChecker.uniqueSpellDocumentTag()` per call
   - Prevents concurrent-caller shared-state pollution of process-global services
   - General pattern for AppKit / system-service wrappers

3. **Declarative scene specification for pixel-determinism** (UISceneRegistry):
   - SceneSpec fully value-typed, no randomness/timestamps
   - Eliminates brittle string parsing in views
   - Makes test fixtures reproducible across resolutions

4. **Field-by-field URL comparison, not round-trip** (URLFragmentPolicy):
   - Defensive against Foundation reserialize bugs
   - Explicit semantic comparison (scheme, host, path, query)

5. **Encoding-detection ladder with dependency-free fallback** (TextFileLoader, TextDecoder):
   - BOM → UTF-16 (no BOM) → UTF-8 → CP1252 → Latin-1
   - Never fails (Latin-1 is total)
   - Exact ordering matters (I18N-01/02 precedence)

6. **Lossless line-ending preservation** (TextCleanup, TextTools):
   - Split on all three flavors (LF/CRLF/CR), rejoin with target terminator
   - Distinguish "document ends in newline" from "last line has no terminator"
   - Prevents silent normalization side effects

7. **LCS line-diff without external dependencies** (UnifiedDiffGenerator):
   - Hunt–Szymanski DP; O(n·m) fine for editor use cases
   - Output git-compatible unified-diff text
   - Enables round-trip with parser for interop

8. **Two-tier read caps with soft watermark** (TextFileLoader):
   - Hard cap (512 MiB): refuse to load
   - Soft watermark (64 MiB): tag for graceful degradation (skip overlays, use fast paths)
   - Allows legitimate large-file viewing without OOM risk

## Anti-Patterns / Regrets

1. **Conflating enum renames with user-data compatibility**: Fixed in SidebarPanelKind via pinned appStorageKey/expandedStateKey; this pattern was likely learned from prior settings-loss incidents

2. **Implicit assumption that "no selection == whole document"** (TextTransform): Requires explicit comment that this is TextEdit semantics, not obvious

3. **Index-based tab drag payloads** (fixed by TabDragPayload using UUID): Tab indices become stale mid-drag; UUID-based payloads solve this cleanly

4. **Tab restoration without dedup or cap** (fixed by TabsState.dedupedRestoreTabs): Prior unconditional append bloated active sessions to ~2000 tabs; now dedups on load + caps at 200

5. **Ad-hoc string parsing for test scenes** (now UISceneRegistry): Scattered inline checks in views, no enumeration, typos silently default; replaced by typed registry

## Gotchas & Surprises

1. **NSTextView horizontal layout superlinearity**: Lines >100 KB hang the main thread; forced soft-wrap is a performance safety feature, not a preference

2. **Compositor layer occlusion of SwiftUI siblings** (SourceInvisibles): SourceGutterView pattern (Canvas overlay) avoids NSLayoutManager subclass that would trigger compositor bugs

3. **Concurrent NSSpellChecker document-tag pollution**: Process-global service; must allocate unique tag per call to prevent cross-caller interference

4. **Foundation URL reserialize bugs on scheme-only URLs**: macOS 15.6.1+ reserializes e.g. `about:blank`; field-by-field comparison more robust than round-trip

5. **SwiftPM staleness after cross-module public type layout changes**: Stale test objects can SIGSEGV; touch callers when enum cases are added

6. **Terminal copy includes trailing-whitespace padding**: Cell grid pads each row to column count; must trim (matching Terminal.app/iTerm)

7. **Preview tabs (VSCode-style) are ephemeral in-memory only**: Not persisted; relaunch rehydrates as permanent (natural dedup safety)

## Rebuild Notes

### Settings & Preferences
- **Approach**: Declarative catalog (SettingsCatalog) + per-file locks (ViewModeLockStore) + relocation helper (SettingsRelocation)
- **Design upfront**: Stability anchors (appStorageKey, expandedStateKey) for enum evolution; JSONFileStore coalesced writes for scale
- **Consider**: Two-tier defaults (category-level + per-file lock with availability guard)

### Sidebar Layout
- **Approach**: Pure predicates (SidebarDataPresence), geometry (SidebarPanelHeights), resize math (SidebarResize), divider planning (SidebarSectionPlanner)
- **Design upfront**: Distinguish "not measured" from "measured empty" (AccordionHeightResolver); prove height-commit necessity via geometric predicate (TSK-592)
- **Gotcha**: Resize-jank comes from re-bodying on every frame; suppress via shouldCommitAvailableHeight()

### Text Processing & Transformations
- **Approach**: Pure transforms (TextCleanup, TextTools, TextTransform, SyntaxFoldRangeMapping), lazy-load wrappers (TextFileLoader with encoding chain)
- **Design upfront**: Line-ending preservation (not normalization); UTF-16 coordinate system for CM6 interop; dependency-free diff + encoding
- **Consider**: Two-tier read caps + soft watermarks for graceful large-file handling

### Terminal Integration
- **Approach**: Separate stores (CommandHistory, FavoritesStore) + unified search (CommandSearch), pure formatters (Header), keystroke accumulator (InputLineAccumulator)
- **Design upfront**: Shared MainActor instance for unified history; defensive keystroke parsing (never record garbage)
- **Consider**: Hand-editable JSON for favorites enables power-user workflows

### Test Infrastructure
- **Approach**: Typed scene specs (UISceneRegistry), keyboard/click DSL (UIKeySpec, UIClickSpec), test-state redirect (TestStateRedirect)
- **Design upfront**: Scene specs fully value-typed (no randomness); fraction-based click positioning; strict grammar (typos fail)
- **Consider**: Deterministic frame constants (WindowGeometry.sceneCaptureFrame) for reproducible pixel captures

### Three-Way Merge
- **Approach**: Pure diff3 algorithm + region classification + resolution model (ThreeWayMerge)
- **Design upfront**: Line-oriented (matches git merge-file); conflict markers (git-compatible); resolution enum supports custom hand-edits
- **Boundary**: 3-pane resolve UI is the VM tail; this is the engine only

### File I/O & State Preservation
- **Approach**: Extended-attribute preservation (XattrIO), window geometry resolution (WindowGeometry), version backend protocol (VersionSource)
- **Design upfront**: Defensive frame clamping (minimum size, oversize caps, off-screen recovery, nudging); xattr best-effort replay (per-attr independence)
- **Gotcha**: Off-screen frame recovery (display disconnected) ⇒ center default, don't nudge invisible anchor

### URL Routing & Dispatch
- **Approach**: Typed routes (URLSchemeRoute), security-hardened parsing (URLSchemeRouter.route with containedPath), fragment policy (URLFragmentPolicy)
- **Design upfront**: Reject unknown hosts (never silently default); home/temp-only paths (S1.1 hardening)

---

**Batch 5/5 covers the final third of ViewerCore root files (S–X alphabetically). Together with Batches 1-4, this completes the ~280-file inventory of production-grade core logic: decision engines, persistence abstractions, testing harnesses, and UI state management. The rebuild should prioritize the pure-logic extraction patterns (especially equality design, encoding chains, and scene specification) as foundations for scaling.*
