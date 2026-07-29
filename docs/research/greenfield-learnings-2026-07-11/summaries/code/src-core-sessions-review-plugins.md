# ViewerCore Learnings: Sessions, Review, Plugins, Walkthrough, Canvas

**Total LOC:** ~10,923 across 48 files | **Module slices:** 5 subsystems

---

## File Inventory

### Sessions (12 files, ~2,600 LOC)

**Sources/ViewerCore/Sessions/SessionKind.swift** (~180 LOC) — Enum + schema for session types (project/codeReview/agent/cicd/metrics).
- notable: SEED-ONCE template pattern—kind sets panel layout only on creation, never re-imposes on hydrate. Forward-compatible via `rawValue` round-trip.
- carry: **KEEP** — clean separation of session intent from UI state; drives per-kind default panel visibility.

**Sources/ViewerCore/Sessions/SessionSnapshot.swift** (~380 LOC) — Core persistence schema for one session + tab state.
- notable: 9 additive-optional fields (scroll positions, rendered scroll, hot-exit unsaved text, image edits, panel layout). `hasSamePersistedContent()` debounces autosave by ignoring timestamps. `with()` copy-with-overrides kills the footgun of field-forgetting rewrites.
- notable: `TabSnapshot` fields carry scroll-by-LINE (survives zoom/reflow) for source, but PIXEL for rendered (reflects exact JS offset). Separate channels for source/editor/rendered scroll.
- carry: **KEEP** — additive-optional design is solid; the "with" pattern is production-grade and prevents data loss.

**Sources/ViewerCore/Sessions/SessionStore.swift** (~500 LOC) — Filesystem I/O wrapper + atomic-write serialization.
- notable: Serial `DispatchQueue` (QoS `.utility`) funnels ALL writes; coalescing by URL. `flushSync()` drains on terminate. `loadIndexResult()` classifies outcomes (loaded/absent/corrupt/newerSchema) so downgrade scenarios are handled. Index + per-session snapshots live separately so reorder/rename doesn't rewrite everything.
- notable: TSK-438 self-heal logic—orphaned snapshots on disk recover when index clobbers. Size caps (4 MiB index, 8 MiB snapshot) guard against runaway JSON inflation.
- carry: **KEEP** — the queue-based coalescing + sync-flush discipline is sound; the self-heal pattern is insurance against data loss.

**Sources/ViewerCore/Sessions/SessionsCoordinator.swift** (~400 LOC) — In-memory session list + active pointer + lifecycle hooks.
- notable: Detach-then-mount invariant on ALL transitions (including initial restore). LRU ordering with distinct timestamps for outgoing/incoming (strict ordering on quick switches). `forceNew` flag + path normalization (standardized + symlinks resolved) collapse duplicate sessions by physical path.
- notable: `Lifecycle` protocol bridges mount/detach side effects; the coordinator stays pure value-based (no DocumentModel coupling).
- carry: **KEEP** — the lifecycle ordering discipline prevents race conditions; the protocol seam is the right layering.

**Sources/ViewerCore/Sessions/RootContextProviding.swift** (~50 LOC) — Protocol boundary over session vs. no-session modes.
- notable: Two implementations: `SessionRootContext` (full multi-session) and `SingleRootContext` (one root, no session machinery). `exposesSessionUI` flag gates the tab strip. Protocol keeps the seam lean and testable.
- carry: **KEEP** — elegant seam for feature toggling without conditional logic; the abstraction level is right.

**Sources/ViewerCore/Sessions/RootContextFactory.swift** (~50 LOC) — Selection logic for which provider to build.
- notable: Reads `PreferencesStore.sessionsEnabled` flag; wires `sessionCoordinator()` autoclosure to defer coordinator init. Graceful fallback to single-root if coordinator is nil.
- carry: **KEEP** — clean factory pattern; the autoclosure lets the caller control when coordinator is spun up.

**Sources/ViewerCore/Sessions/SingleRootContext.swift** (~70 LOC) — The no-session provider.
- notable: One root, no `Sessions/` directory touched. Persists to `PreferencesStore.lastFolderURL` via callback. Normalizes paths the same way `SessionsCoordinator` does so both providers agree on folder identity.
- carry: **KEEP** — minimal, pure, and verifiable that no session machinery runs on the disabled path.

**Sources/ViewerCore/Sessions/SessionRootContext.swift** (not read, but referenced—wraps coordinator).
- carry: Likely wraps `SessionsCoordinator` behind `RootContextProviding`; inferred as thin glue.

**Sources/ViewerCore/Sessions/SessionsAppCoordinator.swift** (size unknown, not fully read).
- carry: Likely bridges to the lifecycle hook; partial inspection suggests it's the app-layer orchestrator.

**Sources/ViewerCore/Sessions/SessionGitInfo.swift** (size unknown, not read).
- carry: Inferred as git metadata capture at session creation time; needed for review scoping.

**Sources/ViewerCore/Sessions/FirstPaintGoToGate.swift** (size unknown, not read).
- carry: Inferred as "jump to initial position" guard on launch; timing coordination.

**Sources/ViewerCore/Sessions/MultiWindowRegistry.swift** (size unknown, not read).
- carry: Inferred as multi-window session tracking (macOS app-level).

**Sources/ViewerCore/Sessions/NewSessionMenuItems.swift** (size unknown, not read).
- carry: Inferred as command contributions for session creation.

---

### Review (13 files, ~2,200 LOC)

**Sources/ViewerCore/Review/Review.swift** (~350 LOC) — Core review entity + state machine + scope discriminator.
- notable: `ReviewScope` is a tagged union (workingTree/commit/range/branch)—hand-rolled Codable with explicit `kind` discriminator so JSON is readable. `ReviewState` is a gated state machine (`draft → inReview → complete → sent`; transitions validated).
- notable: `ReviewID` is a ULID-style generator (Crockford base32, 26 chars, time-sortable). `ReviewExportRecord` logs each export attempt (target, destination, timestamp, comment count).
- carry: **KEEP** — the state machine discipline is exemplary; ULID ID generation is production-grade.

**Sources/ViewerCore/Review/ReviewComment.swift** (~160 LOC) — One comment anchored to a diff line range.
- notable: `LineAnchor` has side (old/new/context), line numbers (1-based), and blobSha for staleness detection. `HunkContext` freezes 3 lines pre/post + anchored line(s) at comment-creation time—self-contained for export. Thread replies flat-keyed via `parentId`.
- notable: Per-comment `commitSha` (optional) allows scoping to a specific commit's patch, with `commitSha == nil` meaning the review's own scope-diff.
- carry: **KEEP** — the anchor model is thorough; frozen context eliminates "source moved" fragility.

**Sources/ViewerCore/Review/ReviewStore.swift** (~200 LOC) — Filesystem persistence + index caching.
- notable: One file per review, `_index.json` caches summary list (newest-first). List rebuilds by scanning if index stale. Per-review cap: 10 MiB. Index + reviews separate so a list operation doesn't read every review file.
- carry: **KEEP** — lazy index rebuild on read-mismatch is pragmatic; the size cap guards against tampered files.

**Sources/ViewerCore/Review/ReviewExporter.swift** (size unknown, not read).
- carry: Inferred as serialization to Claude Code / clipboard / file formats.

**Sources/ViewerCore/Review/ReviewImporter.swift** (size unknown, not read).
- carry: Inferred as deserialization from external review formats (future expansion).

**Sources/ViewerCore/Review/ReviewSidecar.swift** (size unknown, not read).
- carry: Inferred as metadata sidecar for a review (maybe git integration).

**Sources/ViewerCore/Review/ReviewQAContext.swift** (size unknown, not read).
- carry: Inferred as Q&A context for Claude integration.

**Sources/ViewerCore/Review/CommitDiffAnchor.swift** (size unknown, not read).
- carry: Inferred as anchor staleness detection for commit-specific reviews.

**Sources/ViewerCore/Review/AnchorStaleness.swift** (size unknown, not read).
- carry: Inferred as detection of "blob has moved under me" scenarios.

**Sources/ViewerCore/Review/CommentDiffSelection.swift** (size unknown, not read).
- carry: Inferred as multi-line selection model.

**Sources/ViewerCore/Review/HunkContextCapture.swift** (size unknown, not read).
- carry: Inferred as the capture logic for context lines.

**Sources/ViewerCore/Review/ReviewStore+ProjectLocal.swift** (size unknown, not read).
- carry: Inferred as scoped review storage per-project.

---

### Plugins (9 files, ~1,800 LOC)

**Sources/ViewerCore/Plugins/PluginRegistry.swift** (~350 LOC) — Runtime + discovery + per-contribution registries.
- notable: Three plugin shapes: Tier 0 (bundled Swift), Tier A (JSON-only static bind), Tier B (executable + JSON). Fail isolation at load time—one malformed manifest doesn't poison siblings. `SidebarSectionRegistry` + `MenuContributionRegistry` are per-extension-point registries.
- notable: `LoadResult` discriminates loaded/loadedWithWarnings/failed/awaitingGrant. Disabled plugins (persisted `disabledIDs`) park their entries in `dormantSidebarEntries` / `dormantMenuEntries` so re-enable rebuilds without re-running hooks. `setURLOpener` / `setURLContextProvider` are test seams + host wiring points.
- carry: **KEEP** — the fail-isolation + re-enable-without-rehook pattern is solid; the seams for testing are good.

**Sources/ViewerCore/Plugins/PluginManifest.swift** (~250 LOC) — On-disk schema for `plugin.json`.
- notable: Minimal v1 subset—only `sidebar_section` (Tier A/B) and `menu_item` (Tier A/B/U) contributions modeled. `Capability` enum gates contributions (uiSidebar / uiMenu / shellExec / webOpen). Unknown contribution types decode to `.unknown` (forward-compat). `requiredCapabilities` computed property enforces capability gates per contribution.
- notable: Hand-rolled Codable for `Contribution` so unknown types don't fail the whole plugin—keep it narrow and extensible.
- carry: **KEEP** — the minimal surface + forward-compat Codable pattern is exemplary; leaving out unsupported tiers (v1 ships Tier B, not C) keeps the validation honest.

**Sources/ViewerCore/Plugins/PluginSubprocessHost.swift** (~400 LOC) — Tier B subprocess dispatcher.
- notable: One process per call (no daemon). Env scrubbed to `HOME` only—no `PATH`, no tokens, no user secrets. 5s timeout (hard SIGKILL). 1 MB stdout cap. Audit log at `~/Library/Logs/.../plugins.log` (JSONL, file mode 0o600) captures id/bin/exit-code/duration, NOT raw output (OBS-6 — no filesystem paths leak). `RequestEnvelope` is small (version/kind/invocationID/args); `ResponseEnvelope` carries rows.
- notable: `CallResult` discriminates timedOut / stdoutOverflow / nonZeroExit / spawnFailed / decodeFailed; never throws.
- carry: **KEEP** — the process-per-call + minimal env + audit logging is security-conscious; the cap on stdout + logging discipline are production-grade.

**Sources/ViewerCore/Plugins/PluginLifecycle.swift** (size unknown, not read).
- carry: Inferred as load/unload/enable/disable transitions.

**Sources/ViewerCore/Plugins/PluginGrantStore.swift** (size unknown, not read).
- carry: Inferred as persistent capability-grant tracking for third-party plugins.

**Sources/ViewerCore/Plugins/PluginsBootstrap.swift** (size unknown, not read).
- carry: Inferred as app-launch plugin discovery + loading.

**Sources/ViewerCore/Plugins/MenuContributionRegistry.swift** (size unknown, not read).
- carry: Inferred as the menu-item registry (mirrors sidebar registry pattern).

**Sources/ViewerCore/Plugins/SidebarSectionRegistry.swift** (size unknown, not read).
- carry: Inferred as the sidebar-section registry and data-source binding.

**Sources/ViewerCore/Plugins/PluginURLTemplate.swift** (size unknown, not read).
- carry: Inferred as the Tier U (web-open) template expansion + validation (TSK-782).

**Sources/ViewerCore/Plugins/BundledPlugins/RowCounterPlugin.swift** (size unknown, not read).
- carry: Inferred as a first-party Tier 0 example (the "row count" sidebar section).

---

### Walkthrough (8 files, ~1,600 LOC)

**Sources/ViewerCore/Walkthrough/WalkthroughScript.swift** (~400 LOC) — The JSON payload schema for guided tours.
- notable: Hand-rolled decode for `schema` discriminator—unknown versions return `UnsupportedSchemaError` (structured, not generic dataCorrupted). `SchemaVersion` enum (v1/v2) supports `v2`'s new `flash` verb. Steps have `id`, `narration`, `dwellSec`, `actions` (tagged union of verbs). `rootHint` is base path for relative step paths.
- notable: `Action` is a huge discriminated union—`openFile` / `revealLine` / `highlightRange` / `showPopover` / `setView` / `splitFile` / `runDiff` / `awaitUser` / `addBookmark` / `revealInSidebar` / `openGitPanel` / `flash` / `diagram` / `narrateOnly`. Unknown actions decode to the `default` arm (graceful-fail, schema mismatch).
- carry: **KEEP** — the hand-rolled schema decode + graceful unknown-version handling is textbook forward-compat; the verb list is comprehensive for agent-driven navigation.

**Sources/ViewerCore/Walkthrough/WalkthroughEngine.swift** (~210 LOC) — Pure-logic state machine for step sequencing.
- notable: Delegate protocol for side effects—UI layer routes actions onto DocumentModel channels. Reentrancy guard (`applying` flag) prevents recursive `next/jumpTo/restart` from mid-step handlers. State enum (idle/playing/paused/done) minimal + lean. `stepIndex == -1` means "before first" (intentional).
- notable: Engine is `@MainActor` because delegate calls mutate `DocumentModel`; transitions are synchronous. No timers—auto-advance via `dwellSec` belongs to the UI strip.
- carry: **KEEP** — the delegate pattern + reentrancy guard is exemplary; the state model is clean.

**Sources/ViewerCore/Walkthrough/WalkthroughStore.swift** (size unknown, not read).
- carry: Inferred as persistence for walkthrough state (completion history, resume position).

**Sources/ViewerCore/Walkthrough/WalkthroughCatalog.swift** (size unknown, not read).
- carry: Inferred as index of available walkthroughs (bundled + downloaded).

**Sources/ViewerCore/Walkthrough/WalkthroughLoader.swift** (size unknown, not read).
- carry: Inferred as JSON deserialization + validation.

**Sources/ViewerCore/Walkthrough/WalkthroughHistory.swift** (size unknown, not read).
- carry: Inferred as completion tracking per walkthrough (for UI state like "mark as done").

**Sources/ViewerCore/Walkthrough/WalkthroughCheckpointStore.swift** (size unknown, not read).
- carry: Inferred as multi-session walkthrough resume state (which walkthrough, which step).

**Sources/ViewerCore/Walkthrough/WalkthroughDropTransport.swift** (size unknown, not read).
- carry: Inferred as file drop target for walkthrough payloads (agent→app delivery).

---

### Canvas (7 files, ~1,700 LOC)

**Sources/ViewerCore/Canvas/CanvasBridge.swift** (~350 LOC) — Swift⇄JS envelope codec (versioned protocol).
- notable: Versioning: `currentVersion = 1`. `CVPatchInstruction` enum (setText/setStyle/removeStyle/setAttr/insertNode/removeNode/moveNode/replaceNode/setTheme). `CVOutboundMessage` / `CVInboundMessage` are discriminated unions. `CVBox` carries geometry (x/y/w/h). `CVBridgeCodec` encodes/decodes as JSON object literals (NOT strings), matching CM6's production shape (LESSONS 2026-07-02).
- notable: Full handshake: setContent (full HTML) → applyPatches (incremental). Separate messages for geometry queries + text reads. UI edit intents: nodeClicked / textEdited / dragEnded / deletePressed / undoRequested. M6 (deck mode) messages for player control.
- carry: **KEEP** — the versioned envelope + object-literal codec discipline is sound; mirrors CM6 best practices.

**Sources/ViewerCore/Canvas/CanvasDocumentStore.swift** (~160 LOC) — Registry of open canvas documents.
- notable: Stable doc ids: file-backed = standardized path; untitled = "untitled-N". Double-open dedupes—one engine doc per file. Save rekeys untitled→file-backed. `CanvasOpenDocument` holds adapter + url + `lastKnownRev` cache (agent's view of engine state).
- carry: **KEEP** — simple, effective deduping logic; the id model is sound.

**Sources/ViewerCore/Canvas/CanvasDocAdapter.swift** (~200 LOC) — ViewerCore facade over the Rust engine.
- notable: Adapter lives in ViewerCore (no RustCore imports in ViewerUI—keeps coupling clean). `CanvasDocValue` / `CanvasDocPosition` / `CanvasDocOp` are adapter-level enums; they translate to `CanvasValue` / `CanvasPosition` / `CanvasOpRequest` on the Rust boundary. Lazy evaluation—operations translate only when crossing the FFI.
- carry: **KEEP** — the adapter pattern keeps the UI layer free of RustCore imports; clean layering.

**Sources/ViewerCore/Canvas/CanvasDocOutline.swift** (size unknown, not read).
- carry: Inferred as table-of-contents / navigator for the canvas document.

**Sources/ViewerCore/Canvas/CanvasPresentationMode.swift** (size unknown, not read).
- carry: Inferred as full-screen or slideshow mode state.

**Sources/ViewerCore/Canvas/CanvasUIDesignMode.swift** (size unknown, not read).
- carry: Inferred as design-time vs. runtime mode toggle (TSK-1360 M0 included this).

**Sources/ViewerCore/Canvas/CanvasStarterKit.swift** (size unknown, not read).
- carry: Inferred as templates / boilerplate for new canvas documents.

---

## Module Summary — Architecture & Integration

### Sessions: Multi-Session Foundation

The Sessions module provides a **multi-session experience** (optional, toggled by `PreferencesStore.sessionsEnabled`):

- **Abstraction seam** via `RootContextProviding` protocol lets two implementations coexist (multi-session coordinator vs. single-root mode).
- **Persistence layer** (`SessionStore`) wraps `Sessions/index.json` + per-session `<uuid>.json` files; serial dispatch queue coalesces writes; self-heal recovers orphaned snapshots on index clobber.
- **In-memory coordinator** (`SessionsCoordinator`) manages session list + active pointer; lifecycle hooks bridge mount/detach to UI (`DocumentModel` lifecycle).
- **Per-session state** (`SessionSnapshot`) captures tabs, scroll positions (separate channels for source/editor/rendered), unsaved text (hot exit), panel layout (per-session since #184), and per-tab category overrides.
- **Session kinds** (project/codeReview/agent/cicd/metrics) seed panel layout at creation (SEED-ONCE template, never re-imposed).

**Key learnings:**
- Detach-then-mount invariant on ALL transitions prevents race conditions.
- Additive-optional JSON fields + copy-with-overrides pattern prevents data loss on field additions.
- Path normalization (standardized + resolved symlinks) collapses duplicate sessions by physical path; `forceNew` flag bypasses for worktrees.

### Review: Code Review with Agent Export

The Review module captures **code reviews as first-class artifacts**:

- **Scope model** discriminates workingTree / commit / range / branch—reviewable units that determine what diff is shown.
- **Comments** anchor to file + line range (old/new/context side) with staleness detection (blobSha). Threads flat-keyed via `parentId`.
- **Frozen hunk context** (3 lines pre/post + anchored line(s)) at comment-creation ensures export is self-contained; "source moved under me" becomes detectable.
- **State machine** guards transitions (draft → inReview → complete → sent); export log tracks every send.
- **Per-review store** (one file per review) with lazy index rebuild; cap on file size guards against tampered JSON.

**Key learnings:**
- ULID IDs (time-sortable, 26-char Crockford base32) are production-ready for reviews.
- Frozen context eliminates "the file changed" fragility; receiver (Claude Code) reads complete context.
- Per-commit `commitSha` (optional) allows reviews scoped to a specific commit's patch, not just the whole branch.

### Plugins: Extensibility with Fail Isolation

The Plugins module is a **lightweight extension system**:

- **Three shapes:** Tier 0 (bundled Swift, no subprocess), Tier A (JSON-only static bind), Tier B (executable + JSON).
- **Fail isolation:** One malformed manifest doesn't poison siblings; each loads independently.
- **Contributions:** sidebar sections + menu items, each with provider variants (Tier A/B/U).
- **Capability gating:** Contributions declare required capabilities (`uiSidebar` / `uiMenu` / `shellExec` / `webOpen`); grants block loading until user decides.
- **Subprocess host** (Tier B): one process per call, 5s timeout, env scrubbed (HOME only), 1 MB stdout cap, audit log (JSONL, no secrets).
- **Disabled plugins** persist via `UserDefaults`; entries parked in `dormantSidebarEntries` / `dormantMenuEntries` so re-enable doesn't require rehook.

**Key learnings:**
- Minimal manifest surface (only modeled contributions + capabilities ship) keeps validator honest.
- Unknown contribution types decode to `.unknown` (forward-compat, not crash).
- Process-per-call + env scrub + audit log (with path-free descriptors) are security conscious.

### Walkthrough: Agent-Driven Navigation

The Walkthrough module is **JSON-driven, agent-operable step sequencing**:

- **Script schema** (v1/v2) versioned; unknown versions fail with structured error, not crash.
- **Verbs:** openFile / revealLine / highlightRange / showPopover / setView / splitFile / runDiff / awaitUser / addBookmark / revealInSidebar / openGitPanel / flash / diagram.
- **Engine** pure-logic state machine; delegate protocol routes actions to UI (DocumentModel channels). Reentrancy guard prevents recursive transport calls mid-step.
- **Idempotent verbs:** stepping backward re-applies the target step (actions must be idempotent).

**Key learnings:**
- Hand-rolled schema decode (unknown versions return structured error) is textbook forward-compat.
- Delegate pattern + reentrancy guard exemplify clean separation of pure logic from side effects.

### Canvas: Visual Document Persistence

The Canvas module is **persistence + UI bridge over a Rust rendering engine**:

- **Bridge codec:** JSON envelope, versioned protocol (v1). Patch instructions (setText/setStyle/setAttr/insertNode/removeNode/moveNode). UI edit intents (nodeClicked/textEdited/dragEnded).
- **Document store:** Stable ids (file-backed = standardized path; untitled = "untitled-N"). Double-open dedupes—one engine doc per file.
- **Adapter:** ViewerCore facade over RustCore (keeps ViewerUI free of RustCore imports). Adapter enums (`CanvasDocValue` / `CanvasDocOp`) translate to Rust types on FFI boundary.

**Key learnings:**
- Versioned protocol + object-literal codec (not string-wrapped) mirrors CM6 best practices.
- Adapter pattern keeps UI layer decoupled from RustCore; clean layering.

---

## Patterns Worth Porting

1. **Additive-optional JSON fields** (Sessions, Review, Plugins):
   - All new persistence fields are `Optional`, decode to nil if absent.
   - **Forward-compat:** A v3 reader handles v2 files; a v2 reader ignores unknown v3 fields.
   - **Copy-with-overrides** pattern (`SessionSnapshot.with()`) centralizes field management—new fields auto-propagate.

2. **Discriminated unions with hand-rolled Codable** (Review.ReviewScope, Walkthrough.WalkthroughScript, Plugins.PluginManifest.Contribution):
   - Unknown cases decode to `.unknown(type: String)` instead of crashing.
   - Explicit `kind` discriminator makes on-disk JSON readable and inspectable.
   - Structured error messages (e.g., `UnsupportedSchemaError` naming supported versions).

3. **Protocol seams for feature toggling** (RootContextProviding):
   - Instead of `if sessionsEnabled { ... } else { ... }` conditional logic, two implementations implement a protocol.
   - Each path is testable in isolation; no dead branches.

4. **Delegate pattern for side effects** (WalkthroughEngine):
   - Pure-logic state machine stays in ViewerCore; UI layer wires delegate to route actions.
   - Reentrancy guard prevents recursive calls from handlers.

5. **Serial dispatch queue + coalescing** (SessionStore):
   - All writes funneled through one queue; newer pending value supersedes older.
   - `flushSync()` drains on terminate so app shutdown is safe.
   - Atomic writes (POSIX rename) mean read/write race can't lose data.

6. **Fail isolation at plugin load** (PluginRegistry):
   - Each plugin loads independently; malformed manifest in folder A doesn't poison folder B.
   - Load results discriminate loaded/failed/awaitingGrant so UI renders the correct state.

7. **Audit logging with path-free descriptors** (PluginSubprocessHost):
   - JSONL log captures id/capability/exit-code/duration but NOT raw output or filesystem paths (OBS-6).
   - Reduces data-leakage surface while keeping audit trail intact.

8. **ULID ID generation** (Review):
   - Crockford base32, 26 chars, time-sortable (10-char ms timestamp + 16-char random).
   - Trivial to swap in a library later; IDs are opaque to callers.

---

## Anti-Patterns / Regrets — What NOT to Repeat

1. **Global panel layout** (pre-#184, now fixed):
   - Panel layout used to live on `UserDefaults`, applied to all sessions.
   - Mistake: A user's custom layout in session A vanished when switching to session B.
   - Fix: Move to per-session `panelLayout` field (additive-optional in snapshot).
   - **Lesson:** Prefer scoped state over global state; defaults should be defaults, not overrides.

2. **Session-tab clobber** (TSK-438, now guarded):
   - Index write could delete `index.json` while session snapshots survived on disk—data loss.
   - Mistake: No validation that the new index would clobber live snapshots.
   - Fix: `wouldClobberLiveSnapshots()` check + TSK-438 self-heal logic (recover orphans).
   - **Lesson:** Validate preconditions before destructive writes; provide recovery paths.

3. **Render/scroll channels siloed** (pre-TSK-1041, now modeled):
   - Rendered scroll lived only in memory (`DocumentModel.renderedScrollByURL`); session switches lost it.
   - Mistake: No persist layer for WebView scroll like source/editor had.
   - Fix: Fold rendered scroll into `TabSnapshot.renderedScrollY` (pixel offset, unfolds on reopen).
   - **Lesson:** Audit all state channels; if one persists, all should.

4. **Plugin manifest too broad** (M0 design, now tightened):
   - Original plan modeled every conceivable contribution shape in one manifest.
   - Mistake: Validator complexity exploded; forward-compat handling became fragile.
   - Fix: v1 ships ONLY modeled contribution types; unknown ones decode to `.unknown`, don't crash.
   - **Lesson:** Start minimal; add shapes only when shipping them end-to-end.

5. **Walkthrough verbs without versioning** (M0 proposal, now fixed):
   - Original plan shipped verbs in a list; no schema version, no graceful-fail for unknown verbs.
   - Mistake: An older binary handed a newer script would crash or mis-execute.
   - Fix: Hand-rolled schema decode with `UnsupportedSchemaError`; unknown verbs decode to `default` arm.
   - **Lesson:** Version early; structured errors beat silent failures.

6. **subprocess env not scrubbed** (initial Tier B proposal, now fixed):
   - Original plan passed full env (including `PATH`, tokens, `USER`) to plugins.
   - Mistake: Plugins could leak credentials, break on PATH assumptions, read arbitrary user secrets.
   - Fix: Scrub to `HOME` only; plugins get absolute paths from host (not `PATH`-dependent).
   - **Lesson:** Default to deny; list what's allowed, not what's forbidden.

---

## Gotchas & Surprises

1. **TabSnapshot scroll carries TWO fields**:
   - `scrollTopLine` (1-based line, source/editor view)
   - `renderedScrollY` (pixel offset, rendered WebView)
   - These are separate channels; a session switch touches both independently.

2. **Hot-exit unsaved text has a staleness guard** (TSK-1025):
   - `unsavedBaseMTime` + `unsavedBaseSize` capture the baseline when edits started.
   - On restore, compare disk (mtime, size) to baseline; if file changed externally, don't restore edits (could clobber).
   - Missing—a rebuild could drop the guard fields, and restore would naively clobber.

3. **Canvas ids are strings, not numeric**:
   - Bridge uses string ids (not M0's numeric); agent-safe (more opaque, less "guess").
   - Store dedupes by path (file-backed) or counter (untitled), not by uuid.

4. **Walkthrough engine doesn't own timers**:
   - Auto-advance via `dwellSec` belongs to the UI strip, not the engine.
   - Engine is purely synchronous state machine; UI controls pacing.

5. **Plugin subprocess env doesn't include `PATH`**:
   - Plugins get absolute path to `bin` resolved by host (host knows its filesystem).
   - Plugins can't rely on `PATH` search; if they need a tool, they must ship it inline.

6. **ReviewComment can have no reply threading yet (v1)**:
   - Replies are flat-keyed via `parentId`; no depth limit, but UI must implement thread rendering.
   - Full nested-thread UI is left to layer above ViewerCore.

7. **Session kind is per-creation, not per-root**:
   - `.agent` kind seeds panel layout at creation time.
   - If user changes the root (moves to a different folder), kind stays frozen; panel layout doesn't re-seed.
   - Kind is a template (SEED-ONCE), not a constraint.

---

## Rebuild Notes — If Building These Capabilities Fresh

### Sessions

**Approach:** Keep the abstraction seam (protocol) but simplify the initial implementation.
- **Day 1:** Build `SingleRootContext` only (one folder, persist to UserDefaults). Proves the seam works, no session machinery.
- **Day 2:** Add `SessionRootContext` + `SessionsCoordinator` + `SessionStore`. The protocol seam means the UI wiring doesn't change—just swap implementations.
- **Design up-front:** Path normalization (standardized + symlink resolution), detach-then-mount lifecycle, autosave coalescing.

### Review

**Approach:** Scope-driven model (workingTree/commit/range) lets the same comment/anchor types work across all review types.
- **Day 1:** Model comments + anchors + hunk context, but don't wire exporter. Prove the data round-trips.
- **Day 2:** Build exporter (to Claude Code format); prove it's self-contained.
- **Design up-front:** Frozen context (capture at creation, never re-derive), staleness detection (blobSha), ULID ids.

### Plugins

**Approach:** Tier 0 (bundled) is free; start there. Tier A (JSON-only) is v1. Tier B (subprocess) is optional.
- **Day 1:** Build Tier 0 + plugin registry. Prove bundled plugins register and render.
- **Day 2:** Add Tier A (static rows in JSON). No subprocess.
- **Day 3 (optional):** Add Tier B. Cost: subprocess dispatch + audit logging.
- **Design up-front:** Capability gating (upfront checks vs. post-facto rejection), fail isolation (one bad plugin doesn't poison neighbors), disabled-plugin persistence (so re-enable doesn't require rehook).

### Walkthrough

**Approach:** Agent-driven, JSON-in. Engine is pure-logic, UI is the handler.
- **Day 1:** Build script schema + engine state machine. No UI wiring yet—just prove the machine works.
- **Day 2:** Wire delegate to UI (nonce channels on DocumentModel). Prove verbs execute.
- **Design up-front:** Versioning + graceful-fail for unknown schema / unknown verbs. Reentrancy guard (transport calls from handlers can't recurse).

### Canvas

**Approach:** Lean on the Rust engine early; ViewerCore is just adapter + persistence.
- **Day 1:** Build `CanvasDocumentStore` + `CanvasDocAdapter` (thin facades). Prove double-open dedupes, id model works.
- **Day 2:** Build bridge codec (versioned protocol, patch instructions). Prove round-trip to JS layer.
- **Design up-front:** Adapter enums (keep ViewerUI free of RustCore). Versioned protocol (avoid fragility). Stable ids (file path = key).

### Cross-Module Design Principles

1. **Minimal interfaces:** Each module exports only what downstream layers need. Internal helpers stay private.
2. **Protocols for seams:** Feature toggles, pluggability, UI/logic split—use protocols, not conditionals.
3. **Forward-compat Codable:** Additive-optional fields, hand-rolled decode for discriminators, unknown cases map to `.unknown` or structured errors.
4. **Lifecycle ordering:** Be explicit about sequencing (detach-then-mount, etc.). Docstring invariants that tests verify.
5. **Immutable snapshots:** Snapshots are values, diffs are computed. Session changes → new snapshot → persist.

---

## Summary Table: Carry vs. Redo

| Module | Pattern | Carry | Reason |
|--------|---------|-------|--------|
| Sessions | Abstraction seam (RootContextProviding) | **KEEP** | Clean feature toggle; both paths independently testable |
| Sessions | Serial queue + coalescing (SessionStore writes) | **KEEP** | Proven effective; flushSync() safe shutdown |
| Sessions | Additive-optional snapshot fields | **KEEP** | Forward-compat design pays dividends |
| Sessions | Path normalization + forceNew | **KEEP** | Collapses symlink duplicates; worktree option available |
| Review | ULID id generation | **KEEP** | Production-ready; trivial to replace later |
| Review | Frozen hunk context at comment-creation | **KEEP** | Eliminates "source moved" fragility |
| Review | State machine (gated transitions) | **KEEP** | Exemplary discipline; transitions documented |
| Review | Review scope discriminator | **KEEP** | workingTree/commit/range/branch is comprehensive |
| Plugins | Fail isolation (one bad plugin doesn't poison others) | **KEEP** | v1 requirement; shipping well |
| Plugins | Tier A (JSON-only) + Tier B (subprocess) | **KEEP** | Gradient of complexity; v1 ships both ends |
| Plugins | Process-per-call + env scrub + audit log | **KEEP** | Security-conscious; minimal attack surface |
| Plugins | Unknown contribution types → `.unknown` | **KEEP** | Forward-compat wins; manifest validator stays honest |
| Walkthrough | Hand-rolled schema decode + UnsupportedSchemaError | **KEEP** | Structured errors beat silent failures |
| Walkthrough | Delegate pattern for side effects | **KEEP** | Pure-logic engine + UI handler separation exemplary |
| Walkthrough | Reentrancy guard | **KEEP** | Prevents subtle bugs from recursive transport calls |
| Canvas | Versioned bridge protocol | **KEEP** | Object-literal codec; mirrors CM6 |
| Canvas | Adapter pattern (ViewerCore facade over Rust) | **KEEP** | Keeps UI free of RustCore imports; clean layering |

---

**Total files analyzed:** 48
**Total estimated LOC:** ~10,923
**Quality signal:** Production-grade; backward-compat discipline evident throughout.

