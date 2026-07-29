# Sources/ViewerUI Root — Slice 2/4 (Files 54–106)

## File Inventory

**Sources/ViewerUI/DocumentModel+EditableHex.swift** (149 LOC) — HEX editor state + dirty-bytes stash + binary save with symlink/IO alerts
- notable: Clean SRP example; test seam (`peekHexDirtyBytesForTest`); stash pattern for unsaved edits
- carry: **KEEP** — excellent separation of concerns; the dirty-bytes buffering + test access are well-designed

**Sources/ViewerUI/DocumentModel+EditorBuffer.swift** (117 LOC) — Text editor buffer forwarders to EditorCoordinator + save with git diff + LSP refresh
- notable: Thin wrapper layer; demonstrates good delegation; coordinates 3 side effects (diff, repo badge, LSP) on save success
- carry: **KEEP** — clean coordination of multiple subsystems on a single chokepoint

**Sources/ViewerUI/DocumentModel+EditorFormatCommands.swift** (39 LOC) — In-editor markdown table alignment via local formatter (no LSP)
- notable: Deliberately not a format VIEW lens (markdown uses Rendered/Source only); direct editor command
- carry: **KEEP** — correctly places format operations at the right layer

**Sources/ViewerUI/DocumentModel+EditorForwarders.swift** (92 LOC) — Editor lifecycle forwarders + snippet tab-stop navigation
- notable: One-shot request routing stamps untargeted requests with active tab (TSK-1483 fix); prevents multi-pane fan-out
- carry: **KEEP** — the stamping pattern is crucial for correctness in multi-pane scenarios

**Sources/ViewerUI/DocumentModel+EditorState.swift** (124 LOC) — Editor state forwarders + mount-time scroll/selection seed resolution
- notable: Complex scroll restore logic (caret wins → scroll line → nil); documents the three-channel scroll problem (editor vs source vs rendered)
- carry: **KEEP** — shows thoughtful state management around view lifecycle; the priority order is well-justified

**Sources/ViewerUI/DocumentModel+FileHistory.swift** (200 LOC) — Git file history + local history viewers + restore path design
- notable: Restore is "open-then-apply, never disk write" (data-safety reviewed); cross-thread currentContent() sync closure
- carry: **KEEP** — excellent safety-first design; the 3-step restore (backup, ensure tab, apply) is defensive and sound

**Sources/ViewerUI/DocumentModel+FileHistoryAvailability.swift** (35 LOC) — Settings extensions inventory + local history gates + repo path helper
- notable: Pure nonisolated repoRelativePath() helper; cache-aware availability check
- carry: **KEEP** — small, focused, testable helpers

**Sources/ViewerUI/DocumentModel+FileOperations.swift** (172 LOC) — Delete/trash, new folder, move + tab follow with content preservation
- notable: Tab retargeting preserves editor buffer (dirty text, undo, fingerprint); move never overwrites; uses ViewerCore primitives
- carry: **KEEP** — model-level orchestration over safe ViewerCore primitives; good example of safe file ops

**Sources/ViewerUI/DocumentModel+FindBarForwarders.swift** (200 LOC) — Find bar state forwarders for rendered/source/editor/PDF + ⌘F deferral to focused field
- notable: Defers ⌘F when a control's field editor is focused (TSK-1248); exception when find bar is already open
- carry: **KEEP** — shows respect for UI focus state; the exception rule is correct

**Sources/ViewerUI/DocumentModel+FindGating.swift** (54 LOC) — Find/Replace menu enablement + size-cap rejection of large files in editor
- notable: Find unavailable in HTML-rendered (no runtime) + editor-over-cap (no CodeMirror); pure decision testable on host
- carry: **KEEP** — good gating discipline; documents why each mode is excluded

**Sources/ViewerUI/DocumentModel+FirstRun.swift** (45 LOC) — Sample tour document + capabilities page writing
- notable: Collision-safe write (OutputNaming); both paths open rendered; embedded fallback content
- carry: **KEEP** — low-friction onboarding; good use of bundled resources

**Sources/ViewerUI/DocumentModel+FocusShortcuts.swift** (63 LOC) — Focus terminal/file-nav/git-panel/document via nonce bump
- notable: Gate on surface visibility; open terminal/sidebar if needed; reuses existing focus plumbing
- carry: **KEEP** — thin, clean command routing

**Sources/ViewerUI/DocumentModel+Folding.swift** (87 LOC) — Fold All/Unfold All dispatched to correct surface (editor vs source) with nonce record
- notable: Routes to either CM6 (editor) or NSTextView (source); both read-only source has folds; dispatch nonce for host testing
- carry: **KEEP** — good multi-surface dispatch pattern; nonce separation is excellent for testability

**Sources/ViewerUI/DocumentModel+Format.swift** (92 LOC) — Language override (auto-detect vs manual) + pretty-print toggle with format menu title
- notable: Shebang fallback for extensionless files (TSK-901); format detection pure and host-testable
- carry: **KEEP** — shebang heuristic is valuable for scripts without extensions

**Sources/ViewerUI/DocumentModel+GitChip.swift** (143 LOC) — Footer git chip repo-root memo + branch switch with stash offer
- notable: Memoized repo root (keys by URL, recomputed on focus change); dirty-tree refusal + stash escape hatch; off-main git I/O
- carry: **KEEP** — excellent memoization + async pattern; the stash logic is a good UX choice

**Sources/ViewerUI/DocumentModel+GitDiffGutter.swift** (180 LOC) — Off-main git diff/blame computation for source + split gutter
- notable: Debounced 150ms diff, 3s timeout; blame takes precedence when active; split has separate refresh path; Rust adapter (TSK-561)
- carry: **KEEP** — sophisticated async coordination; mounted-pane-aware eviction model in general codebase is worth copying

**Sources/ViewerUI/DocumentModel+GitLog.swift** (121 LOC) — Legacy synthetic-markdown git log (FileHistoryView is modern replacement)
- notable: Caches under ~/Library/Caches; pure markdown generator testable; write failure never opens stale hash
- carry: **KEEP** — safe caching discipline; still live for folder/repo scope

**Sources/ViewerUI/DocumentModel+GitPanelFocus.swift** (26 LOC) — Git panel focus + data-presence gate
- notable: Minimal; mirrors existing focus plumbing
- carry: **KEEP** — thin wrapper

**Sources/ViewerUI/DocumentModel+GoToPath.swift** (95 LOC) — Go-to-path prompt + expand/validate/open + open-panel recents merge
- notable: Resolves tilde; validates absolute-only; merges go-to history + file history; pure GoToPathExpansion for testing
- carry: **KEEP** — good use of pure helpers for testability

**Sources/ViewerUI/DocumentModel+Highlighting.swift** (59 LOC) — Per-tab syntax highlight cache actor registry + cache-miss async tokenize
- notable: Diff/patch files hand-rolled (no TreeSitter grammar); mtime-keyed cache invalidation; writes to per-tab actor, not DocumentModel
- carry: **KEEP** — excellent cache design; per-tab actor isolation prevents republish on tokenize completion (PERF #5)

**Sources/ViewerUI/DocumentModel+HTMLJavaScript.swift** (132 LOC) — Per-tab raw-HTML JS opt-in + per-document trust + network consent + CSP policy
- notable: DEFAULT-DENY JS; per-tab opt-in OR per-document trust required; network hosts require per-doc consent; fail-closed
- carry: **KEEP** — exemplary security posture; three-layer gating (local, trust-eligible, opted-in)

**Sources/ViewerUI/DocumentModel+ImageEditPersistence.swift** (70 LOC) — Image editor in-progress edits stash + session-switch restore
- notable: Live edit state captured → folded onto Tab.imageEditState at snapshot boundary; seed back on restore (matches rendered-scroll pattern)
- carry: **KEEP** — same pattern as rendered-scroll restoration; good reuse of tested approach

**Sources/ViewerUI/DocumentModel+LazyTabOpen.swift** (130 LOC) — Lazy tab append + multi-file drop/open dispatcher
- notable: Dedup invariant (no 2nd tab for same URL); folder partitioning prevents folder→tab conversion bug (UDC-5); clamps viewMode to available
- carry: **KEEP** — excellent safety checks; dedup invariant is crucial

**Sources/ViewerUI/DocumentModel+LSPEditorCommands.swift** (250+ LOC) — LSP format/rename/codeActions with snapshot guards + workspace-edit cross-file apply
- notable: Snapshot-guarded (keystroke racing formatter wins); rename skip-policy (only open tabs, never disk-write); render tail (VM test expected)
- carry: **KEEP** — sophisticated async coordination; snapshot guards are crucial for correctness

**Sources/ViewerUI/DocumentModel+LSPNavigation.swift** (91 LOC) — LSP go-to (definition/declaration/typeDefinition/implementation) + single-pick
- notable: Resolves at position, jumps to first result; Cmd-click + deliberate verbs both route through `navigateViaLSP`; silent-failure
- carry: **KEEP** — clean command routing; single-pick default until multi-result picker ships

**Sources/ViewerUI/DocumentModel+LSPShared.swift** (25 LOC) — Language-server gate + position encoding conversion
- notable: Thin, shared helpers; CM6 position (1-based line, 0-based UTF-16 char) → LSP (0-based both)
- carry: **KEEP** — position encoding belongs in a shared seam

**Sources/ViewerUI/DocumentModel+Omni.swift** (62 LOC) — Omnibox dispatch + launchpad sections + git clone plan
- notable: Pure OmniResolver classification; paths/URLs/git remotes → actions; handle classification in model layer
- carry: **KEEP** — good separation of classification (pure) from action (model)

**Sources/ViewerUI/DocumentModel+OpenAs.swift** (120 LOC) — Universal "Open As…" menu + category override + magic-byte sniff + per-category defaults
- notable: Every FileCategory viewer (text/binary/preview); sniff 16-byte header (SQLite/PNG/JPEG/GIF/PDF); float sniff to menu top
- carry: **KEEP** — magic-byte sniff is valuable; per-category default pin is good UX

**Sources/ViewerUI/DocumentModel+PerTabDicts.swift** (46 LOC) — CSV filter state + HEX bytes-per-row forwarders
- notable: Type aliases for backward compat; hex width bumps global default as side effect (TSK-467, #234)
- carry: **KEEP** — good backward-compat strategy

**Sources/ViewerUI/DocumentModel+PrintExport.swift** (48 LOC) — Print/export-PDF gates + nonce publishing for render requests
- notable: Only markdown/mermaid/HTML in rendered mode are printable; nonce pattern for fire-and-forget render
- carry: **KEEP** — good gating; nonce pattern for async render requests is standard here

**Sources/ViewerUI/DocumentModel+RenderedCache.swift** (145 LOC) — Rendered-markdown HTML cache with mounted-aware LRU eviction
- notable: Cache key = (tabID, byteCount, mtime); mounted tabs retained; evict oldest non-mounted first; cold render off-main (TSK-611)
- carry: **KEEP** — sophisticated eviction logic; mounted-awareness prevents dismantling retained panes (TSK-108 regression)

**Sources/ViewerUI/DocumentModel+Resurrection.swift** (86 LOC) — Recover deleted files from Local History + version picker
- notable: Full tracked-path scan (not just recents); backup-before-restore; create via FileResurrection.recreate (O_EXCL); toast outcomes
- carry: **KEEP** — data-safety-first design; excellent use of ViewerCore primitive

**Sources/ViewerUI/DocumentModel+SaveCopy.swift** (114 LOC) — Save-a-Copy side write + close-dirty forwarder
- notable: Hierarchy: HEX-dirty > editor-dirty > on-disk; encoding-aware (no silent UTF-8 fallback); atomic writes
- carry: **KEEP** — three-priority hierarchy is correct; encoding respect is crucial

**Sources/ViewerUI/DocumentModel+ScriptConsole.swift** (43 LOC) — Script Console seeding + output application
- notable: Seed from active buffer or disk; infer default format from extension; write output to temp JSON file
- carry: **KEEP** — small, focused companion feature

**Sources/ViewerUI/DocumentModel+ScrollPersistence.swift** (200+ LOC) — Per-file scroll capture at boundaries + render restoration + editor channel routing
- notable: Sample at focus-loss/close (never per-tick); read from correct channel (editor vs source vs rendered); restore with priority (caret > scroll > nil)
- carry: **KEEP** — excellent performance-aware design; boundary sampling is the right approach

**Sources/ViewerUI/DocumentModel+SidebarReveal.swift** (84 LOC) — Reveal-in-sidebar with optional root switch + follow-mode within-root variant
- notable: Locked sidebar refuses cross-root navigation; follow-mode on tab-select; path walk (no FS traversal)
- carry: **KEEP** — clean reveal logic; locked-state respected

**Sources/ViewerUI/DocumentModel+SourceScroll.swift** (24 LOC) — Source-view scroll-to-line forwarders
- notable: Lives on narrow SourceViewChannel; nonce + line together drive scroll (dedup)
- carry: **KEEP** — channel pattern for scroll is excellent (no republish DocumentModel)

**Sources/ViewerUI/DocumentModel+Spelling.swift** (126 LOC) — Spell check with nav/fix/learn/ignore/language + report to panel
- notable: Per-tab nav; decision-layer host-testable; fix routes through CM6 bridge; full-doc report (rows clickable)
- carry: **KEEP** — good verb family; CLI/automation-friendly

**Sources/ViewerUI/DocumentModel+Split.swift** (90 LOC) — Split-pane open/close/toggle/swap + text resolver (unsaved edits)
- notable: Split URL independent from main; swap flips files between panes; text resolver prefers dirty editor buffer in split's own tab
- carry: **KEEP** — split is cleanly isolated; text resolver pattern is correct

**Sources/ViewerUI/DocumentModel+StructuralSearch.swift** (28 LOC) — Structural Search panel seeding + language resolution
- notable: Seed from active buffer + effective language; thin model glue
- carry: **KEEP** — companion feature

**Sources/ViewerUI/DocumentModel+TabCloseVariants.swift** (92 LOC) — Close current/others/to-right with dirty-prompt loop + descending-order processing
- notable: Process indices descending so cancel mid-batch leaves coherent state; dirty-prompt per tab; shared settleSelection + purgeCaches
- carry: **KEEP** — excellent iteration order discipline

**Sources/ViewerUI/DocumentModel+TabLoading.swift** (85 LOC) — Async binary/text file loaders with latest-switch-wins guard
- notable: Latest-switch-wins (Bug C): rapid HEX↔text toggle must not commit superseded load; mode-check before update
- carry: **KEEP** — guard pattern crucial for correctness in mode-switching scenarios

**Sources/ViewerUI/DocumentModel+TabMaterialize.swift** (119 LOC) — Lazy placeholder → .loading → final state with closed-meanwhile guard
- notable: Cooperative cancellation (can't interrupt sync read, but completion checks `Task.isCancelled`); category override honored; scroll/unsaved-text restore
- carry: **KEEP** — excellent async guard pattern; category override carry-through is correct

**Sources/ViewerUI/DocumentModel+TabNavigation.swift** (36 LOC) — Tab reorder/cycle (next/previous with wrapping)
- notable: Thin forwarders to TabCoordinator
- carry: **KEEP** — simple, clean

**Sources/ViewerUI/DocumentModel+TaskRunner.swift** (19 LOC) — Task Runner panel discovery from active root
- notable: Minimal; discovers from sidebar root or active file directory
- carry: **KEEP** — companion feature

**Sources/ViewerUI/DocumentModel+TerminalCommandPalette.swift** (20 LOC) — Terminal Command Palette seeding from favorites + history
- notable: Minimal; reuses existing history infrastructure
- carry: **KEEP** — companion feature

**Sources/ViewerUI/DocumentModel+TerminalFavoritesEditor.swift** (18 LOC) — Terminal favorites management editor
- notable: Replaces raw-JSON-file edit; fresh model each open mirrors current state
- carry: **KEEP** — companion feature

**Sources/ViewerUI/DocumentModel+TerminalLaunch.swift** (47 LOC) — Open terminal cd'd to file/folder + insert favorite at prompt
- notable: Falls back to shell home when no focused file; inserts WITHOUT trailing newline (user confirms)
- carry: **KEEP** — small, focused

**Sources/ViewerUI/DocumentModel+Theming.swift** (41 LOC) — Active-theme derivation from theme override/ID + CM6 palette + extra stylesheet composition
- notable: Pure compositions; theme-selected CM6 palette or nil (appearance-keyed legacy); mermaid shim always
- carry: **KEEP** — clean theme resolution logic

**Sources/ViewerUI/DocumentModel+ToolResults.swift** (73 LOC) — Shared tool-results panel + check-links/lint/stats/csv-summary entry points
- notable: One panel for all four tools (replaces NSAlert); click-to-line, dismiss; same path for menu + verb + automation
- carry: **KEEP** — excellent consolidation; shared panel pattern

**Sources/ViewerUI/DocumentModel+ViewHosting.swift** (77 LOC) — Hosted view tabs (HTTP client, feed reader) + canvas controller lifecycle
- notable: Hosted views stored by UUID; canvas controller teardown on tab close; feeds persist via FeedSubscriptionStore
- carry: **KEEP** — clean hosting pattern; canvas lifecycle separation correct

**Sources/ViewerUI/DocumentModel+ViewModeControl.swift** (150+ LOC) — UX-A presentation layer over ViewMode + available modes resolution + mode upgrade on deferred load
- notable: Pure ViewModeControl mapping (no new modes); honors "Open As" override; deferred-load text-discovery upgrade (HEX→Source)
- carry: **KEEP** — clean presentation layer; mode upgrade on load is correct

**Sources/ViewerUI/DocumentModel+ViewModeLock.swift** (48 LOC) — Per-file view-mode lock toggle + file-nav "Lock View As" affordance
- notable: Lock survives reopen; lock indicator in file-nav; per-file (not global)
- carry: **KEEP** — simple, clean UX

---

## Module Summary

This slice (54 files, ~6,200 LOC) comprises **focused feature expansions and sophisticated async/state coordination** carving out of the original monolithic `DocumentModel.swift`. Every file is a self-contained **SRP slice** with one cohesive responsibility:

- **Editor/file lifecycle:** buffer forwarders, lazy load/materialize, scroll/selection restore, tab close variants
- **Git integration:** diff gutter (with blame), file history (modern + legacy paths), branch switch, chip
- **Find/Navigation/LSP:** find bar forwarding, LSP go-to (definition/declaration/typeDefinition/implementation), references, format, rename, code actions
- **View modes & lenses:** render/source/editor/hex control, Open As, format, folding, view-mode lock
- **Persistence & state:** scroll memory, unsaved-text restore, image edits, rendered-HTML cache (mounted-aware LRU), layout presets
- **Async patterns:** off-main file loads (binary/text), git diff/blame, HTML render, syntax highlighting, mail-actor hops with cancellation guards
- **Safety & gating:** data-loss prevention (backup-before-restore), dirty-file prompts, snapshot guards on LSP edits, HEX symlink handling, permission prompts

**Key architectural insights:**
1. **Narrow channels** (SourceViewChannel for scroll, per-tab HighlightCacheActor) prevent high-frequency state from republishing DocumentModel
2. **Nonce patterns** enable idempotent async requests (scroll, render, go-to-line, find)
3. **Boundary sampling** (scroll capture at tab-select/close, not per-tick) sidesteps hot-path performance issues
4. **Latest-wins guards** ensure rapid mode/file switches don't commit superseded loads
5. **Mounted-pane awareness** in cache eviction prevents dismantling retained views
6. **Three-layer state restoration** (caret > scroll line > nil) respects viewport layout timing
7. **Off-main async + main-actor hop + closed-meanwhile checks** handle concurrent user action safely

---

## Patterns Worth Porting

### 1. **Narrow Channels for High-Frequency State** (SourceViewChannel, per-tab HighlightCacheActor)
- **Where:** ScrollPersistence, Highlighting extensions
- **Why:** Scroll ticks on every wheel event; syntax tokenize completes asynchronously. Publishing to @Published DocumentModel would re-evaluate every SwiftUI body.
- **How:** `SourceViewChannel` is a separate Combine publisher (accessed via `sourceView.sourceScrollState`). Per-tab `HighlightCacheActor` is a per-UUID ObservedObject that bumps its own `version` on tokenize completion.
- **For rebuild:** Create narrow channels for any high-frequency (>frame-rate) updates. Keep the main model's @Published surface for low-frequency (user action) level.

### 2. **Boundary Sampling for Persistence** (ScrollPersistence capture pattern)
- **Where:** DocumentModel+ScrollPersistence.swift
- **Why:** Per-scroll-tick sampling would write to disk 60x/sec and thrash the memory store. Sample at intent boundaries (tab-select, close, snapshot).
- **How:** `captureScroll(forTabAt:)` is called at focus-loss / visible-tab-close / snapshot fire, never per scroll event.
- **For rebuild:** Identify the persistence boundaries (session save, tab close, pane demount). Capture there, not on the event hot path.

### 3. **Nonce Patterns for Idempotent Async Requests** (go-to-line, find, scroll, render)
- **Where:** EditorForwarders, FindBarForwarders, ScrollPersistence, RenderedCache, ToolResults
- **Why:** SwiftUI value-blind publish dedupes identical values. A repeat "scroll to line 100" is swallowed; a nonce (never same twice) guarantees fire.
- **How:** Pair a request parameter with an `Int` nonce. Increment nonce on every request, even if the parameter is unchanged.
- **For rebuild:** Use nonce for any request channel where a repeat of the same logical request must be honored.

### 4. **Latest-Wins Async Guards** (mode-switch load supersession)
- **Where:** TabLoading, TabMaterialize extensions
- **Why:** User rapid-clicks HEX↔Source↔Editor. First load (HEX) lands 1s later; by then user is in Editor mode. Committing HEX would clobber the editor picker.
- **How:** Before swapping the loaded state, check `if self.tabs.tabs[idx].viewMode == .hex` (or != .hex). If superseded, drop the result.
- **For rebuild:** Any async operation touched by user action should guard against supersession by re-checking intent (currentViewMode, currentURL, etc.) before committing.

### 5. **Mounted-Pane-Aware Cache Eviction** (RenderedCache LRU)
- **Where:** DocumentModel+RenderedCache.swift (`storeRenderedHTML`)
- **Why:** Evicting a cached markdown page whose pane is retained in `MountedPanesLRU` dismantles the WKWebView and re-renders (loses focus, scroll, video state). TSK-108 regression prevention.
- **How:** When capacity is exceeded, evict the oldest non-mounted tab first. Only evict mounted tabs if overflow can't otherwise be cleared.
- **For rebuild:** If caches are shared across retained views, make eviction aware of which views are pinned in a LRU.

### 6. **Off-Main Async + Closed-Meanwhile Checks** (file loads, git operations)
- **Where:** TabLoading, TabMaterialize, GitDiffGutter extensions
- **Why:** `controller.open(url:)` reads the full file synchronously; large files block the main thread. Kick off-main; re-locate tab by ID on completion.
- **How:** Task.detached(priority:.userInitiated) { let state = controller.open(…); if Task.isCancelled { return }; await MainActor.run { guard tab still exists && is still pending else { return }; commit state } }
- **For rebuild:** For any sync operation >10ms, detach to background, check cancellation before main-actor hop, re-locate by ID before committing.

### 7. **Three-Layer State Restoration** (scroll priority order)
- **Where:** DocumentModel+EditorState.swift (`editorMountSelectionSeed`)
- **Why:** A tab can restore on three separate channels: editor caret, text scroll line, or nil (top of file). Caret moves itself into view; don't scroll separately.
- **How:** (1) if restored caret exists ⇒ seed at caret (CM6 will scroll it into view); (2) else if restored scroll line exists ⇒ seed collapsed selection at that line start; (3) else nil.
- **For rebuild:** When multiple persistence channels converge (caret + scroll), establish priority order and apply only the highest-priority one.

### 8. **Snapshot Guards on Async Edits** (LSP format/rename)
- **Where:** DocumentModel+LSPEditorCommands.swift
- **Why:** User types while formatter runs. The stale response lands and overwrites the new edits.
- **How:** Capture buffer.text at dispatch, store on main actor. When response lands, check `if editor.editorBuffers[tabID]?.text == snapshot` before applying edits.
- **For rebuild:** For any round-trip server call that modifies local state, snapshot the state at dispatch and verify it hasn't changed before applying the response.

---

## Anti-patterns / Regrets

### 1. **The LOADBUG: Model Republish on TabCoordinator Replace** (DBV-01 / PERF #1)
- **Found:** TabMaterialize completion (line 100), explicit `updateDerived()` call added post-hoc
- **Root:** TabCoordinator.replace() fires the coordinator's @Published, but the decoupling (TSK-1110) severed the forwarding. ContentView observes DocumentModel, not coordinator.
- **Lesson:** When extracting extensions into separate files, check what @Published signals cross the boundary. The old inline code republished the model automatically; the extracted extension had to re-add it.
- **For rebuild:** Keep @Published signals on the primary model. Consider whether child coordinators should republish to parent, or if the parent needs explicit re-publishing after coordinator mutations.

### 2. **Scroll Restoration Split Across Three Channels** (TSK-1037 / TSK-1041 / TSK-1047)
- **Found:** EditorState + ScrollPersistence, three separate plumbing paths (editor channel, source channel, rendered channel)
- **Issue:** The split was forced by architecture (CM6 reads editorScrollByTab; NSTextView reads sourceView scroll; WebView reads renderedScrollByURL). But each channel has its own restore timing + guards.
- **Lesson:** Multiple transport channels for the same semantic concept (scroll position) invite bugs at restore/switch boundaries.
- **For rebuild:** Unify scroll restore into ONE path early. Require all surfaces to read from the same source of truth, even if the underlying surfaces have different scroll plumbing.

### 3. **The Mounted-Pane Eviction Discovery** (TSK-621 / TSK-108 regression)
- **Found:** Rendered-HTML cache eviction naïvely evicted LRU; tests didn't catch dismantling retained panes
- **Issue:** The test that "verified" green but shipped the regression (ImageRenderer + cacheDisplay false-green trap).
- **Lesson:** Cache eviction rules are subtle when views are retained. A headless test of cache eviction in isolation doesn't prove it won't dismantle a real pane.
- **For rebuild:** When caching views, make retention explicit (MountedPanesLRU) and eviction aware of it. Add a specific test that evicts while a pane is mounted and confirms the pane isn't dismantled.

### 4. **Encoding Silently Fallback (Save-a-Copy regression)**
- **Found:** SaveCopy extension guards encoding; older code silently fell back to UTF-8
- **Issue:** User "Save a Copy" of a Shift-JIS buffer would land as UTF-8, silently data-corrupted
- **Lesson:** Default-fallback behavior is data-loss. Require explicit encoding respect or explicit re-encode offer.
- **For rebuild:** Never silently re-encode without user awareness. Surface the encoding choice or fail honestly.

### 5. **Latest-Wins Guard Omission (mode-switch clobbering)**
- **Found:** Early TabLoading didn't check `viewMode != .hex` before committing a text load from a HEX→text toggle
- **Issue:** User toggles HEX→Source; picker says Source; pane shows HEX (1s-later load clobbered the mode)
- **Lesson:** Rapid toggling is a common user pattern (testing a view, switching back). Every async operation must defend against it.
- **For rebuild:** Audit every `Task.detached` that mutates tab state. Add a before-commit guard re-checking that the intent is still current.

---

## Gotchas & Surprises

### 1. **Shebang Fallback for Extensionless Files** (TSK-901)
- **Found:** DocumentModel+Format.swift effectiveLanguage()
- **Behavior:** A file named `foo` (no extension) defaults to .plainText. But if it starts with `#!/usr/bin/python`, the shebang is scanned and .python is inferred.
- **Surprise:** This path is expensive (reads file header on every mode inference). But it's gated: only runs when extension is uninformative, so .py files (fast path) pay nothing.
- **For rebuild:** Shebang detection is valuable for scripts. Keep it gated to extensionless files.

### 2. **Mounted-Pane Memoization + Eviction Hysteresis**
- **Found:** RenderedCache `storeRenderedHTML`
- **Behavior:** Mounted tabs are NEVER evicted (pinned by pane retention). Cache may grow beyond cap if many panes are mounted.
- **Surprise:** The cap (12) is higher than the pane LRU (4), so transient over-cap is bounded. Older logic (drop-to-2/3 hysteresis) was removed; now evict only to cap.
- **For rebuild:** Make cache eviction explicit about over-capacity windows. Document the bounds.

### 3. **View-Mode Lock ≠ "Open As…" Override**
- **Found:** ViewModeControl + ViewModeLock files
- **Behavior:** Lock (TSK-811) pins a per-file view mode for future reopens. Override (Open As, WAVE 2b item 6) forces a different FileCategory lens.
- **Surprise:** They're orthogonal. A .db forced open as CSV can still be locked to .rendered (showing the CSV preview). Reopening applies the lock (→ .rendered lens of the CSV category).
- **For rebuild:** Keep override (category) and lock (mode) separate. Lock applies within the current category; override changes category.

### 4. **Per-Tab Actor Prevents Republish Storm**
- **Found:** HighlightCacheActor per TabID
- **Behavior:** When a tokenize completes, the per-tab actor bumps its own `version`. ContentView reads `@ObservedObject highlightCacheActor`, which republishes only THAT tab.
- **Surprise:** Without per-actor isolation, DocumentModel.highlightRuns would need to publish every completion, re-evaluating every body in ContentView.
- **For rebuild:** Use per-entity actors for high-frequency completions. The per-tab pattern is excellent.

### 5. **HEX Edit-Arm ≠ DirtyState**
- **Found:** EditableHex + ViewModeControl extensions
- **Behavior:** HEX has two orthogonal flags: `.hex` ViewMode + `hexEditArmedTabs` Set. Viewing HEX (readonly) doesn't arm it; re-arm enables editing.
- **Surprise:** The mode picker says `.hex` either way. The "View Only" toggle controls the armed flag, not the mode. (TSK-467, #234)
- **For rebuild:** HEX is read-only by default; editing is an explicit opt-in per tab. This is defensible but unintuitive.

### 6. **Symlink Prompt on HEX Save** (EditableHex)
- **Found:** saveHexEdits function
- **Behavior:** Writing to a symlink prompts the user to confirm de-symlink (replace link with regular file).
- **Surprise:** Same prompt exists on text save (Editor). Both use the same safety gate.
- **For rebuild:** Consistent symlink handling across all write paths.

---

## Rebuild Notes

### Architecture Recommendations

#### 1. **Preserve the Extension Split Strategy**
The original 6,400-line `DocumentModel.swift` is now 53 extension files (~6,200 LOC + ~200 LOC in the main class). This works **because**:
- Each extension is a self-contained SRP slice with no shared private state
- Public surface stays stable (ContentView / SessionState / verbs don't need to change)
- Hot files (scroll, diagnostics, syntax highlighting) use narrow channels, not DocumentModel republish

**For rebuild:** Start with a smaller monolith and eagerly carve out cohesive slices. Don't wait until 6,000 LOC to split.

#### 2. **Narrow Channels for High-Frequency State**
Scroll ticks per-frame, syntax highlighting completes asynchronously, CM6 gestures fire rapidly. Publishing every tick to DocumentModel would create unmanageable re-render load.

**Strategy:** Create Combine publishers that bypass the main model:
- `SourceViewChannel` for scroll position (NSTextView ticks it)
- Per-tab `HighlightCacheActor` for syntax highlights
- `editorScrollByTab` dict on EditorCoordinator (CM6 ticks it, reads via forwarders)

These are read-only from the model; mutations on the narrow channel, republish to model only at boundaries.

#### 3. **Three-Phase State Restoration** (capture → fold → seed)
Session-switch persistence has three phases:
- **Capture** at boundary (tab close, session save): sample live scroll, image edits, unsaved text → fold onto Tab snapshot
- **Fold** into snapshot (serializable): Tab stores scrollTopLine, renderedScrollY, imageEditState, unsavedText
- **Seed** on restore: re-inject from snapshot into live dicts (renderedScrollByURL, imageEditStateByURL, etc.) and restore surfaces read from those dicts

This pattern scales across scroll, image edits, unsaved text, rendered scroll.

#### 4. **Mounting-Aware Cache Lifecycle**
If a cache stores views that can be retained in a LRU (e.g., rendered markdown pages in MountedPanesLRU), make eviction aware:
- Track which cache entries correspond to mounted views
- Never evict a mounted entry (it would dismantle a retained WKWebView)
- Evict the oldest non-mounted first; allow transient over-capacity if all entries are mounted

#### 5. **Async Operation Safeguards**
Every off-main operation needs:
- **Cancellation check** before main-actor hop (`if Task.isCancelled { return }`)
- **Re-locate by ID** on the main actor (the tab may have closed)
- **State re-validation** before committing (the user may have switched intent)
- **Latest-wins guard** for mode/file switches (check viewMode / currentURL against dispatch-time value)

#### 6. **Snapshot Guards on Round-Trip Edits**
Any edit that round-trips to a server (LSP format, rename, code action):
1. Snapshot the current buffer text at dispatch
2. Capture the tab ID and dispatch-time buffer reference
3. On response, verify the snapshot hasn't changed before applying edits
4. Apply edits to the CURRENT buffer (may be a different tab if a rename affects multiple files)

#### 7. **Encoding Respect in File Writes**
- Never silently fall back to UTF-8 (data corruption risk)
- Always write using the buffer's own encoding
- Surface encoding-mismatch errors so the user can choose a compatible encoding
- Exception: when a new file is created without a loaded encoding, use UTF-8

---

### Key Design Decisions to Make Early

#### 1. **Scroll Restore Architecture**
- Will all surfaces (editor, source, rendered) use the same persistence channel, or separate ones?
- If separate, document the three-layer priority (caret > source line > rendered offset > nil) and restore timing.
- Consider unifying around a single scroll channel early to simplify restore.

#### 2. **Cache Eviction Policy**
- If any cache stores retained views, make retention explicit and eviction aware of it
- Decide: cap strict (never exceed) vs. hysteresis (evict down to cap on overflow)?
- For markdown rendering: decide whether to retain renderers in memory or re-render cold

#### 3. **LSP Edit Workspace Application**
- Does rename/code-action edit all open tabs, or only the dispatching tab + tabs explicitly marked?
- Decide upfront: "never write to disk behind the user's back" (current) vs. "if open, apply; if not, skip"
- Document the snapshot-guard contract (keystroke racing the server wins)

#### 4. **View-Mode Lock Scope**
- Per-file lock (current: TSK-811) or per-category global default + per-file override?
- Current model is flexible (any file can lock to any mode it supports); consider if complexity is warranted

#### 5. **HEX Edit-Arm Behavior**
- Current: HEX mode always read-only; separate opt-in flag arms editing (TSK-467)
- Alternative: .hex includes edit, .hexReadOnly is the locked variant
- Current design is safer (default off); decide if the two-flag complexity is acceptable

---

### Testing Coverage Expected

1. **EditorBuffer / text write paths:** all three encoding conditions (buffer encoding, encoding mismatch, UTF-8 fallback)
2. **Latest-wins guards:** rapid mode/file switches, verify superseded loads don't clobber
3. **Scroll restore:** all three channels, priority order, boundary timing
4. **Mounted-pane cache eviction:** confirm pane isn't dismantled when cached entry is evicted
5. **LSP snapshot guards:** keystroke racing formatter/rename/code-action, stale responses dropped
6. **HEX symlink handling:** prompt shown, de-symlink confirmed, safe to commit
7. **Spell check:** language/ignored-word change invalidates cache, re-spell runs

---

## Summary

This slice exemplifies **sophisticated async coordination** and **boundary-aware state persistence**. The extension split is not arbitrary split-for-split's-sake; each file is a **vertical slice** (EditableHex owns binary save; TabMaterialize owns lazy→final transition; ScrollPersistence owns the capture→fold→seed cycle). The rebuild should:

1. **Start simple** — don't split prematurely, but be ready to split early
2. **Use narrow channels** for high-frequency updates (scroll, syntax, cache completions)
3. **Boundary-sample persistence** (capture at tab-close, not per-tick)
4. **Guard every async operation** (cancellation, re-locate, latest-wins, snapshot)
5. **Make cache retention explicit** — eviction rules are subtle around retained views
6. **Respect encoding at write boundaries** — no silent re-encode
7. **Document timing and priority** — three-layer scroll restore, three-layer HEX arm, etc.

The pattern is **production-grade**, addressing real issues (PERF #1, TSK-108, TSK-621) and hard-won insights (symlink safety, encoding respect, mounted-pane awareness). Adopt the patterns, avoid the regrets.
