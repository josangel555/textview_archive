# Pre-launch product review — Crash situations + consequences

Date: 2026-07-10 · Reviewer: crash-dimension audit agent · Repo state: `main` @ `304a8290` (+ uncommitted WIP in `main.swift` / `MCPSocketBridge.swift`, reviewed as-is)

## Executive summary

The codebase's crash **discipline is exceptional for its size** (~380K LOC). The Rust core enforces a clippy deny-wall (`unwrap_used`, `expect_used`, `indexing_slicing`, `string_slice`, `panic` all `deny`), every FFI export is wrapped in `catch_unwind` with a dead-handle latch on the Swift side, the shipping profile deliberately keeps `panic = "unwind"` (with a build-script guard that rejects `panic=abort` profiles), and both MessagePack decoders and the JSON parser carry hard depth caps. Swift-side force-unwraps are rare (~122 candidate sites sampled; every one inspected was guarded). Crash **consequences** are equally well-engineered: a 500 ms-debounced + 30 s-periodic autosave persists tabs, scroll, and unsaved editor text (inline ≤1 MiB, sidecar spill up to the 32 MiB editor cap), session files are written atomically with corrupt-index disambiguation and a trash/backup story, and a crashed WKWebView content process re-bootstraps (capped at 3 attempts).

Three real gaps remain, and they compound:

1. **The live (default-ON) Rust formula engine has an unguarded recursive-descent parser** — a CSV cell like `=((((…` with ~10⁴ nesting levels overflows the stack. A stack overflow is *not* an unwinding panic: `catch_unwind` cannot intercept it, so the entire app hard-aborts on opening a crafted/pathological CSV (formula recalc runs automatically per render pass).
2. **There is no crash-loop breaker**: session restore is unconditional (only an env var can skip it), so a document that deterministically crashes the app re-opens on every relaunch — a permanent crash loop with no user-visible escape.
3. **Dirty hex-editor buffers are excluded from every persistence path** — a crash *or a normal Cmd-Q* silently discards unsaved hex edits, with no terminate-time prompt (per-tab close does prompt, so the quit path is inconsistently weaker).

Everything else found is quality-level: image-edit state is captured at quit/switch but not by the crash-recovery autosave; a crash can lose up to 30 s of typing (deliberate, bounded, but tightenable); a pathological DOT file can drive a ~10k-deep Swift recursion.

## Methodology

Static review, no repo modification (report file only), no builds or dynamic runs (constraint: read-only repo, no UI tests; static analysis preferred). Examined:

- **Rust FFI seam**: `rust-core/crates/ffi/src/guard.rs`, `lib.rs`, `Cargo.toml` panic-strategy comments (`rust-core/Cargo.toml:119-150`), profile guard in `scripts/build-rust-core.sh:37-45`.
- **Rust core engines** for recursion/OOB: `formula.rs` (full parser+evaluator read), `json.rs`, `markdown.rs`, `canvas/lower.rs`; workspace lint config (`rust-core/Cargo.toml:90-114`).
- **Swift bridge**: `Sources/RustCore/CoreClient.swift` (dead-handle contract, `positional()` wire validation), `MessagePack.swift` (depth cap), `RemoteTransport.swift` (panic mapping).
- **Crash-consequence machinery**: `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift` (autosave/flush paths, full read of lines 60-600), `SessionState.swift` (snapshot/hydrate), `Sources/ViewerCore/Sessions/SessionStore.swift` (atomicity/corruption), `DocumentModel+ScrollPersistence.swift` (hot exit), `HotExitSpill.swift`, `Sources/MarkdownViewer/main.swift` (terminate path, restore gate).
- **Swift crash-source sweeps**: all `try!` (3 sites), `fatalError`/`preconditionFailure` (6 sites, all `init(coder:)`/startup invariants), `as!` (1 site, type-checked first), `.first!`/`.last!`/`URL(string:)!`/`data(using:)!` (~8 sites inspected), `[0]` direct indexing (~30 sites sampled, guards verified for `CoreClient`, `ScriptRunner`, `AgentDiffApply`, `TmuxControlParser`, `ForgeRemote`), recursive walkers (`DotGraphOutline`, `FileTreeFilter`, `FlameProfile`, `StructuralSearchEngine`).
- **WebView crash recovery**: `webViewWebContentProcessDidTerminate` in `CodeMirrorEditorView.swift`, `MarkdownRenderedView.swift`, `CanvasWebViewHost.swift`.
- **Formula lane wiring**: `FormulaEngine.swift`, `RustFormulaGate.swift`, `RustCoreGates.swift`, `CSVTableView.swift` (trigger + default).

Not everything was read (see Coverage gaps). Findings below are cited to exact file:line and verifiable by opening the cited code.

---

## Findings

### F1 (P1) — Rust formula parser: unbounded recursion → uncatchable stack-overflow abort, on the default-ON path

- **Files**: `rust-core/crates/core/src/formula.rs:257-426` (parser), `:413-423` (paren recursion), `:431-` (`eval` recursion); trigger chain `Sources/ViewerUI/CSVTableView.swift:522-526` → `Sources/ViewerCore/FormulaEngine.swift:35-45` → FFI.
- **Evidence**:
  - The recursive-descent `Parser` carries **no depth counter**. `primary()` on `Token::LParen` recurses back into `compare()` (`formula.rs:413-415`), and every nesting level threads ~8 stack frames (`compare → concat → add → mul → unary → power → postfix → primary`). `tokenize()` has no input-length cap.
  - The **recalc** path *is* depth-capped (`MAX_RECALC_DEPTH: usize = 1000`, `formula.rs:2201`) and the **JSON parser** in the same crate is depth-capped precisely to avoid "stack overflow on `[[[[…`" (`json.rs:17,125-135`) — so the hazard class is known in-tree; the formula *parser* just never got the guard. The clippy deny-wall does not catch this class (recursion is not a lint).
  - `catch_unwind` explicitly does **not** catch stack overflow (`rust-core/crates/ffi/src/guard.rs:11-12`: "It does NOT catch aborts (`panic=abort`, double-panic, `abort()`, **stack overflow**, OOM)"). A Rust stack overflow hits the guard page → `abort()` → the whole GUI app dies, regardless of the `dist` profile's `panic="unwind"`.
  - The lane is **live by default**: `RustCoreGates.swift:104` (`case .formula: return true`, flipped 2026-07-04), there is **no Swift fallback arm** (`FormulaEngine.swift:40-44` is `runRustOnly(...)`), and `formulaValuesMap()` (`CSVTableView.swift:522-526`) evaluates every `=`-cell **automatically on each render pass** of an opened CSV (guarded only by no-sort/no-filter). The docstring at `FormulaEngine.swift:33-34` says a bridge fault "degrades to [:] … never a crash" — true for *panics*, false for stack overflow.
  - The evaluator (`eval`, `formula.rs:431`) and the default recursive `Drop` of the `Box`-chained `Expr` tree recurse to the same depth, so the parse-side cap must land before both.
- **Impact**: opening a crafted (or pathologically generated) CSV crashes the app with SIGABRT. Estimated trigger: ~8 frames/level on the main thread's 8 MiB stack ⇒ on the order of 10⁴ nesting levels — i.e. a ~10-20 KB cell of `(` characters (estimate, not measured — the repro is a one-line CSV). Combined with F3 (no crash-loop breaker), session restore re-opens the file at next launch → **permanent crash loop**.
- **Fix**: thread `depth: u32` through the parser's mutually recursive fns (`compare/concat/add/mul/unary/power/postfix/primary/arg_list`) and return `FormulaError::Parse` past a cap (64-128 is far beyond legitimate formulas; mirrors `json.rs`). The cap also bounds `eval` and `Drop` depth, so no separate work there. Add the deep-nesting negative test `json.rs:519-522` already models, and a fuzz corpus seed. **Size: S. Risk: safe** (pure error-path addition; parity: Excel itself caps nesting at 64).

### F2 (P1) — Dirty hex-editor buffers are lost silently on quit AND crash; quit has no dirty prompt

- **Files**: `Sources/ViewerUI/DocumentModel.swift:1828` (`hexDirtyBytes: [UUID: Data]`, in-memory only), `:3259-3261` ("HEX edits are not part of the session hot-exit snapshot"), `Sources/MarkdownViewer/main.swift:704-769` (terminate path).
- **Evidence**:
  - Hex edits live only in `hexDirtyBytes` / the `HexView` edit buffer (`HexView.swift:721,879,946` track `buf.isDirty`). They are excluded from `SessionSnapshot` by design and never written by `captureUnsavedTextForAllTabs` (text-only) or `captureImageEditStateForAllTabs` (image-only).
  - The app implements `applicationShouldTerminateAfterLastWindowClosed` (`main.swift:704`) and `applicationWillTerminate` (`main.swift:708`) but **no `applicationShouldTerminate`** — nothing intercepts Cmd-Q to prompt for unsaved hex changes (verified by grep: no `applicationShouldTerminate(` in the target, no `hexDirty` reference anywhere in `main.swift` or the Sessions layer).
  - Per-tab close *does* prompt (`confirmCloseIfDirty`, referenced at `DocumentModel.swift:3312`), so the user is trained to expect protection — and the strictly-more-destructive quit path has none. Text edits survive quit via hot exit, masking the inconsistency.
- **Impact**: user edits bytes in the hex editor, hits Cmd-Q (or the app crashes) → edits silently discarded. Classic data loss; severity tempered only by hex editing being a secondary surface.
- **Fix**: two independent layers — (a) implement `applicationShouldTerminate` returning `.terminateCancel` after a save/discard/cancel sheet when any hex buffer is dirty (protects clean quit); (b) optionally include size-capped hex dirty bytes in the hot-exit snapshot/spill for crash parity with text. **Size: M. Risk: careful** (terminate-flow changes need VM UAT; the prompt must not fire on session *switch*, which correctly discards per the TSK-733 design).

### F3 (P1) — No crash-loop breaker: session restore is unconditional after an unclean exit

- **Files**: `Sources/MarkdownViewer/main.swift:483-487` (restore gated only by `MDV_SKIP_WORKSPACE_RESTORE=1`), `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:138` (same env gate for `bootstrap()`).
- **Evidence**: the only way to launch without rehydrating the previous session is a test/automation env var. There is no launch sentinel ("did the last run exit cleanly?"), no consecutive-crash counter, no safe-mode prompt. Grep for `didCrash|cleanExit|sentinel|safeMode` across `main.swift` + Sessions: no hits.
- **Impact**: any deterministic crash-on-open — F1's formula CSV, a future render-path bug, a corrupt file that trips an OS-framework abort — converts one crash into an **unrecoverable crash loop**: launch → restore tab → evaluate/render → abort → repeat. A non-technical user cannot discover the env var or which `~/Library/Application Support/MarkdownViewer/Sessions/` file to delete. This multiplies the blast radius of every other crash bug in the app, which is why it rates P1 despite being "missing hardening" rather than a bug.
- **Fix**: write a `launch-in-progress` sentinel at didFinishLaunching, clear it in `applicationWillTerminate`; if the sentinel is present at launch, increment a consecutive-unclean-launch counter (reset on clean exit); at ≥2, restore the session but *defer opening the previously-focused tab* (or present "TextView crashed last time — restore tabs?"). Keep the count per-session-id so one bad project doesn't nuke others. **Size: M. Risk: careful** (a force-quit or SIGKILL during normal use also leaves the sentinel — the ≥2 threshold plus restore-with-deferred-focus keeps false positives benign).

### F4 (P2) — Crash-recovery autosave never captures image-edit state (quit/switch-only)

- **Files**: `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:549-567` (`fireAutosave` — calls `captureScrollForActiveTab()` + `captureUnsavedTextForAllTabs()` only) vs `:447` (`flushForTermination` additionally calls `captureImageEditStateForAllTabs()`); capture impl `Sources/ViewerUI/DocumentModel+ImageEditPersistence.swift:45`.
- **Evidence**: the TSK-1303 machinery persists in-progress image-editor state onto `Tab.imageEditState` → `TabSnapshot.imageEditState` (`SessionState.swift:252-255`), but only the clean-quit and session-switch/drain paths invoke the capture. The debounced/periodic autosave — the path whose entire purpose is *crash* recovery (`SessionsAppCoordinator.swift:71-78`) — snapshots without it, so the persisted `imageEditState` is whatever the last switch/quit stamped.
- **Impact**: a crash (or force-quit/SIGKILL) discards **all** image edits made since the last session switch or clean quit — potentially an entire editing session — while text edits made in the same window survive. Inconsistent recovery contract.
- **Fix**: add `active.model.captureImageEditStateForAllTabs()` to `fireAutosave` alongside the text capture; the existing `hasSamePersistedContent` equality guard already suppresses no-op writes. Verify capture cost is O(dirty image tabs) so the 30 s tick stays cheap. **Size: S. Risk: safe.**

### F5 (P3) — Crash loses up to 30 s of typing: editor keystrokes never tick the debounced autosave

- **Files**: `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:472-486` (subscribed publishers: `$tabs`, `$rootURL`, `$zoom`, `$sourceWordWrap`, `$themeOverride`), `:119` (`periodicFlushInterval: TimeInterval = 30`), `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:545` (`updateEditorText` mutates `editorBuffers`, not `$tabs`).
- **Evidence**: per the REPUB-1 design comment (`SessionsAppCoordinator.swift:80-87`), typing deliberately does not tick the debounce; unsaved text reaches disk only when some subscribed field changes or the 30 s periodic flush fires. This is a documented, bounded design (VS Code-like), not a bug.
- **Impact**: worst case, a crash discards the final ~30 s of typing even though everything older is recovered.
- **Fix (optional)**: subscribe a heavily-debounced (e.g. 5 s idle) editor-change signal into `scheduleAutosave`, or drop `periodicFlushInterval` while any buffer is dirty. **Size: S. Risk: safe.** Reasonable to WONT-FIX with the bound documented.

### F6 (P3) — `DotGraphOutline`: recursion depth bounded only by `maxRows = 10_000`, with per-level `Set` copies

- **Files**: `Sources/ViewerCore/DotGraphOutline.swift:70-88`.
- **Evidence**: `visit` recurses per edge with a *copied* `Set<String>` path (`nextPath = path`, `:80-81`). A DOT file describing a single 9 999-node chain recurses ~10 k Swift frames and does O(n²) set-copy work. On the 8 MiB main-thread stack this likely survives; if ever moved to a Dispatch worker (512 KiB default stack) it overflows — and Swift stack overflow is an uncatchable crash.
- **Impact**: pathological `.dot` input can hang (O(n²) copies) today and crash if the call site's threading changes.
- **Fix**: convert to an explicit-stack iterative DFS (also fixes the copy churn), or add a depth cap (existing `maxRows` guard makes this an easy sibling). **Size: S. Risk: safe.**

### F7 (P3) — URL-less (untitled) tabs are silently dropped from session snapshots

- **Files**: `Sources/ViewerUI/Sessions/SessionState.swift:222` (`guard let url = t.url else { continue }`), `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:271` ("untitled >1 MiB → drop").
- **Evidence**: the snapshot serializer keys everything by file path, so a tab with no URL cannot persist — its `unsavedText` dies with the process. **Mitigation that keeps this P3**: the app's "New File" flow creates a real on-disk file immediately (`DocumentModel.swift:722-744`, `createNewFile(in:baseName:)` writes `Untitled.txt`), so URL-less dirty tabs are an edge case rather than the mainline new-document flow.
- **Impact**: if any code path opens an editable URL-less tab (scratch buffers, future features), its content is unrecoverable after crash *or* quit, silently.
- **Fix**: none needed today; add a debug assertion (or snapshot-time log) when a dirty URL-less tab is dropped, so a future feature can't reintroduce the loss silently. **Size: S. Risk: safe.**

---

## Positive observations

Genuinely strong crash posture — these deserve to survive any refactor:

- **FFI panic containment is a designed system, not an afterthought**: every export wrapped (`ffi_guard!`/`ffi_frame_body!`, `guard.rs:26-106`), panics become `MdvStatus::Panic`, the Swift `CsvSession` latches `dead` and refuses further calls while ARC still frees the handle exactly once (`CoreClient.swift:252-303`); the contract is pinned by a misuse-matrix test macro (`ffi/src/tests.rs`).
- **The `panic=abort` footgun is actively guarded**: the shipping `dist` profile keeps `panic="unwind"` (`rust-core/Cargo.toml:140-150`) and `scripts/build-rust-core.sh:37-45` *rejects* linking any abort-profile `.a` into the GUI — architecture invariant #4, enforced in the build lane.
- **Rust no-panic lint wall**: `unwrap_used`, `expect_used`, `indexing_slicing`, `string_slice`, `panic` all `deny` workspace-wide (`rust-core/Cargo.toml:96-105`), with truncating casts denied too. This is why the OOB/unwrap sweep came back clean.
- **Both MessagePack decoders and the JSON parser are depth-capped** (`Sources/RustCore/MessagePack.swift:130-135` throws `.tooDeep`; `json.rs:125-126` errors at `MAX_DEPTH` with a fuzz-path test at `:519-522`); canvas instance expansion is depth-capped (`canvas/lower.rs:226`); the markdown engine is event-driven (no input-proportional recursion, `markdown.rs`).
- **Crash-recovery persistence is layered and atomic**: 500 ms debounced + 30 s periodic equality-guarded autosave (`SessionsAppCoordinator.swift:71-113`), hot-exit unsaved text inline ≤1 MiB with sidecar spill up to the 32 MiB editor cap (`DocumentModel+ScrollPersistence.swift:249-285`, `HotExitSpill.swift`), external-change detection baselines (`unsavedBaseMTime/Size`, TSK-1025), atomic session writes with corrupt-vs-newer-schema disambiguation, an empty-index clobber refusal (`SessionStore.swift:248-262`), trash with retention, and a full `flushForTermination` + `JSONFileStore.flushSync()` quit drain (`main.swift:708-726`).
- **WKWebView content-process death is handled in all three hosts** with a re-bootstrap capped at 3 so a deterministic crash can't loop the WebView (`CodeMirrorEditorView.swift:1046-1059`; also `MarkdownRenderedView.swift`, `CanvasWebViewHost.swift`), and the Swift-side buffer mirror (`updateEditorText`) means editor text survives a WebContent crash.
- **Quit teardown is bounded, not hopeful**: LSP pool shutdown races an 8 s deadline and logs instead of hanging quit (`main.swift:755-768`).
- **Swift force-unwrap hygiene**: every sampled `!` site was preceded by an explicit guard (`ForgeRemote.swift:142-144`, `AXUIElementNode.swift:70-72` type-checks before `as!`, `AgentDiffApply.swift:61-64`, `ScriptRunner.swift:105-121`); wire decodes validate arity via `positional()` (`CoreClient.swift:1026-1032`) so a version-skewed daemon degrades instead of crashing.

## Coverage gaps (not examined)

- **Tree-sitter C grammar parsers** (`Highlight/`, rust `highlight` crate): C parse tables executing over untrusted files — memory-safety crashes here are possible and were not audited (would need fuzzing, out of scope for static review).
- **Terminal/PTY subsystem** (`Sources/ViewerCore/Terminal/` beyond `TmuxControlParser` sampling) and child-process signal handling.
- **LSP client robustness** to server crashes mid-request (only the quit path was reviewed).
- **JS side of the WebViews** (CodeMirror/Mermaid/Canvas bundles): a JS exception can blank features but not crash the process; not reviewed.
- **Image decoding** via Apple frameworks (malformed image files → framework-level aborts), `Audio/`, `Plugins/`, `Git/` beyond `ForgeRemote`.
- **`pm` (rusqlite), `serve`, `tui`, `web` crates**: out-of-app-process; a crash there doesn't take the GUI down.
- **MCP socket bridge input validation** (`Automation/`): frames come from local agents; only `MCPFraming.swift` was spot-checked.
- **Dynamic verification**: nothing was compiled or executed (repo treated read-only); the F1 depth threshold is an estimate from frame counting, not a measured repro.
- Scale: ~380K LOC source; this review read the crash-relevant seams in depth and sampled the rest via targeted greps — it is not a line-by-line audit.
