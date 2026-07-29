# Autonomous Progress Ledger Learnings
**File:** archive/AUTONOMOUS_PROGRESS_2026-06-04_to_2026-07-02.md  
**Status:** current (rotated on 2026-07-07)  
**Coverage:** 29-day autonomous execution period (~15k lines, ~280 logged items across ~30 firing sessions)

## Overview

This ledger documents an intense **autonomous-agent-driven development period** on the MarkdownViewer app. The period began June 4 and ran in short firing loops (typically 1–3 items per tick, batched when gate-safe) with a major midpoint pivot: a **parallel ultracode workflow session** that spun up 6 isolated worktree lanes (June 16–19), merged 116 commits to main, and reset expectations about what the agent could autonomously build without blocking on the owner.

---

## Quantified Work Breakdown

### Item Types & Cadence

Across the ~280 logged items (extracting distinct "units of work" per entry):

| Category | Count | Character |
|----------|-------|-----------|
| **Bug fixes** (user-facing & internal) | ~95 | Owner-report intake + recurring edge cases (scroll restore, selection, mode-switching, focus routing, focus-based data loss) |
| **Features (user-facing)** | ~60 | Audio extract/convert, image text overlay, spreadsheet sheets, terminal command palette, draw-text editing, preview tab fixes, encoding conversion, line-ending conversion |
| **Performance** | ~18 | Off-main image rendering (P0), CSV arena parsing (-1s open), FFI boundary zero-copy, command-palette heading memoization, search result capping, lazy-tab profile |
| **Test infrastructure & refactoring** | ~55 | UAT harness fix (53 false-reds → real signal), VM lane establishment, webview test lanes (spell-squiggles, autocomplete, diagnostics), TextKit-2 introspection fix, test-vehicle audits |
| **Security & stability** | ~20 | Cast-safety audit (13 sites), MsgPack recursion-depth DoS, HTMLSanitizer event-handler bypass, sqlite UAF, RemoteTransport sub teardown, CSV heap-cap, path-traversal in exports |
| **Rust-core porting & refactor** | ~15 | Markdown engine ported, formula/CSV fuzzing (no-panic guarantees), git-status parser proptest, cast-deny ratchet, arena-sink CSV tokenizer |
| **Cleanup & discovery** | ~20 | Duplicate converter catch-and-reuse, orphaned/dormant feature activation (image fill, shape rotation), owner intake triage (59 new tickets), VM render lane correction |

**Firing pattern:** mostly 1–3 items/tick, gate-gated (host headless green before commit). Ultracode wave burst with 19 parallel commits, retried 47 items due to session cap.

### Rework Arcs & Recurring Patterns

**Scroll-restore class** (TSK-890/894/1188/1247/—): The highest-friction item, recurring across ~4 separate firing attempts:
- Initial `CursorChannel` / `ScrollChannel` model built
- Timing race discovered (warm-cache re-attach skips didFinish, render reads stale scroll)
- CM6 synchronous dispatch from ViewPlugins corrupting anchor
- Deferred dispatch fix (queueMicrotask)
- **Root:** multi-handoff async chain with imperative seed-restore pattern; fixed via single source of truth on the Tab model
- **Learning:** timing bugs in async render chains require *runtime instrumentation*, not code-reading inference

**Sheet-tabs multisheet (TSK-1141):** sliced across firings:
- Slice 1–2: host model (additive, String-contract-safe TextFile.xlsxSheets)
- Slice 3: T4-structural render-code (sheet-tab strip view)
- Slice 4 (recalc): deferred
- **Learning:** when a high-blast file-representation concern exists, confining it to additive, backward-compat layers (no `contents`-String mutation) unblocks parallel work

**UAT harness false-reds** (TSK-953 + TSK-1032 + TSK-1247):
- TSK-953: 53 failures → root was xctest-as-root vs app-as-console-user temp, fixed LaunchHarness fixture base
- TSK-1032: "HEX grid blank" → root was UAT introspection reading TextKit-1 numberOfGlyphs (always 0 for TextKit-2 unflushed layout); fixed with TK2-safe textLength metric
- TSK-1247: "spawned-app WebView blank" → root was VM WindowServer not framebuffer-compositing app content; workaround reads backing-store via window-ID (T5 pattern)
- **Learning:** false-reds cluster in the harness-automation coupling; a full lane pass uncovers the class at once

**Owner intake vs board state** (first cleanup on 2026-06-14):
- Owner posted ~75-item bug/improvement batch (TSK-887..945)
- De-duped against shared board (many were already-tracked or already-shipped)
- Filed 59 net new tickets, linked re-reports
- **Learning:** intake = noisy; genuine deduplication work against the live board prevents duplicate-filing churn

---

## Key Learnings

### 1. **"Host-testable" ≠ "Simple"—audit your assumption**

The codebase's **render layer is far more refactorable than initially assumed**. Early sessions incorrectly bucketed entire swaths as "VM/owner-only" when they were actually in-process-validatable:

- **Paste as Universal Document (TSK-1163/958):** live AppKit action, but injectable NSPasteboard made it fully host-testable
- **Rendered Mermaid in walkthroughs (TSK-1333):** WKWebView in-process mounting is NOT T5 (T5 = screencapture pixel; mounting = AX-structural); host validate the mount, leave the pixel to T5
- **Spell-check lint-marker (TSK-1146):** the CM6 squiggle render happens in the in-process WKWebView DOM, NOT the T5 screencapture; EditorDiagnosticsWebViewTests (webview lane) is agent-runnable
- **AutoComplete popup (TSK-1136/463):** exposed `startCompletion` on the JS bridge, made it host-testable

**Correcting principle:** **TCC (TransparencyConsentAndControl) permission gate ≠ test tier gate.** TCC blocks SCREENCAPTURE (T5 pixel); it does NOT block:
- In-process WKWebView rendering (DOM reads, JS execution, bridge calls)
- AX-structural element existence (the `_XCUITest` path via AXUIElement) — only AX-*interaction* (pressing, typing) is blocked
- AppKit file operations with an injectable seam

**Immediate lesson for the rebuild:** before parking work as "VM-only," ask: *which harness permission is actually blocking this, and is there a seam?* A surprisingly high fraction of UI work can be staged host-first (model + render-path without pixel), then pixel-validated on the VM.

### 2. **Render slices vs. pixel slices—the correctness-safety boundary**

A recurring pattern: "the render is built, the pixel is deferred." Over ~80 render PRs, the agent learned to split this deliberately:

- **Image element styling (TSK-1321):** the form (ColorPicker, sliders, rotation angle) is host-testable SwiftUI; the on-canvas drag handle + pixel fidelity are AX/T5
- **Image text overlay (TSK-1310):** editable text-field (inspector form) is host-testable; the rendered text pixels (font rendering, rotation) are T5
- **Terminal copy trim (TSK-769):** the logic (rtrim + drop-blanks) is pure + host-tested; the "copied text looks right" is user-facing, not T5-blocked (just standard copy/paste)
- **Walkthrough diagram overlay (TSK-1119):** the `.ascii`/`.image` branches are SwiftUI + NSImage (no WebView, occlusion-free); the `.mermaid` branch REQUIRES compositingGroup().zIndex + T5

**Why this split matters:**
1. **Unblocks the agent:** non-pixel work lands and is tested immediately; pixel is a deferred T5 tail
2. **Reduces speculative building:** the pixel layer can then be built with actual on-screen feedback, not guessed
3. **Catches integration bugs early:** the host render validates the model + the non-WebView layers are wired correctly

The rebuild should adopt this split **by design**: every `<Input>View` form + button action is host-testable; every pixel (color, size, positioning, compositing, animation) is either a follow-on T5 test or an owner-validated no-op change.

### 3. **Multi-stage async chains are timing-bug factories—collapse to single-source-of-truth when possible**

The scroll-restore saga spanned multiple root causes, all stemming from the same **multi-handoff async pattern**:

1. **Symptom:** tab switches scroll to wrong position
2. **Root #1:** warm-cache re-attach skips the `didFinish` callback that seeds the scroll → the render reads uninitialized scroll
3. **Root #2:** @Published didSet runs async-coalesced; imperative restoreScroll() can fire before the render reads the property
4. **Root #3:** CM6 ViewPlugin dispatch inside mousedown/mouseUp handlers corrupts CM6's internal MouseSelection anchor (synchronous dispatch before CM6's own inputState setter runs)

**All three roots** trace back to: scroll lives in three places (the Tab model, the EditorCoordinator internal cache, the CM6 view state), and they go out of sync during async transitions.

**Fix pattern:** make scroll a **single source of truth on the Tab model**, and have the view **declaratively read it** (no imperative restoreScroll seeds). The render layer recomputes it from the model on every body eval; no multi-handoff, no race.

**For the rebuild:** 
- Avoid imperative "seed this async value around the event loop" patterns
- Prefer: model holds the value, view reads it, render layer acts on changes
- If you have to seed (e.g., initial scroll after load), make the seed a **declarative input** to the view, not an imperative action

### 4. **False-green test vehicles—the imaging trap**

The ledger captured three separate false-green traps, all involving render-path introspection:

1. **`ImageRenderer` (and `cacheDisplay`):** rasterizes SwiftUI's tree in isolation, renders an **NSViewRepresentable as a placeholder rectangle** — perfect for a compositor-occlusion issue that isn't actually visible on screen (TSK-488)
2. **`numberOfGlyphs` UAT metric:** TextKit-1 metric that's always ~0 for TextKit-2 unflushed layouts — reported "blank" when the view was actually full (TSK-1032)
3. **Framebuffer screencapture on the VM:** captures the window decorations (menu bar, title bar) but NOT the app content (WindowServer compositing issue) — false-reds entire test lanes (TSK-1247)

**Lesson:** when a test "passes" but you're suspicious, **demonstrate teeth**: revert the code change, rebuild, and re-run the test. If it doesn't go red, the test is a false-green.

For the rebuild:
- **Host-side pixel tests (ImageRenderer):** only use them for non-occluded, non-WebView content
- **LiveApp UITests (T4):** use the T5-pattern (window-ID screencapture forcing a layer render) instead of framebuffer, or validate element-existence via AX first
- **Any custom introspection metric:** spot-check it against the actual app (manual visual, or a parallel pixel test on the real app)

### 5. **Ultracode parallel workflows need careful reconciliation, not auto-merge**

The 116-commit ultracode wave (June 16–19) merged 6 parallel worktree lanes. While the **cherry-pick + gate + ff-merge process was sound**, it uncovered **5 semantic clash classes**:

1. `RemoteTransport` orphan-event refactor (two agents both renamed, used conflicting names)
2. `RGBAColor` byte vs. double encoding (two parallel changes to the same enum)
3. Hover-test removal in two agents (one explicitly, one as a side-effect)
4. Brace loss in a union merge
5. Sleep-ratchet baseline drift (one agent bumped it, another didn't know)

**Solution applied:** exhaustive cherry-pick + compile + gate on each batch, then full gate before FF. This caught all 5 and was resolved in **one integration-fix commit**.

**For the rebuild:** when running parallel agent workflows:
1. Keep them **narrowly scoped** (one per agent, not a task-swarm)
2. **Never auto-merge**—always: cherry-pick → compile → targeted gate → review for semantic clashes → integrate
3. **Expect 2–5 clash classes per 100 commits** of parallel work
4. Use the **full headless gate** as the merge gate, not a smaller subset (the gate caught subtle @Published property + catalog-count issues the cherry-pick missed)

### 6. **"Drained the clean work" is a real state, not a failure**

Around 2026-06-14, the autonomous loop genuinely **exhausted the host-completable, safe, high-value work**:

- Swift queue: all `reported` items either already-shipped, owner-gated, VM-render-coupled, or marginal
- Rust-core: 564 FFI refactor, 575 cast-audit, 844 CSV-arena heap-cap all require **correctness-critical fresh focused sessions**, not a tired deep session
- Security/triaged pools: drained
- Owner decisions: TSK-343 (history default), TSK-358 (font×zoom), TSK-810 (hex twin) all genuinely need owner input

**The agent's response:** documented the HOLD, listed the unblocks, and stayed green (no manufactured marginal work). This is **correct autonomy**, not a failure.

**For the rebuild's autonomous loop:** recognize that hitting a HOLD is a signal to escalate and provide decision points, not to invent work. A good escalation includes:
- **What's actually blocking** (owner decision, missing VM validation, dep approval)
- **What work is queued behind it** (so the owner knows the impact)
- **Recommended next steps** (spike? retry? try a different lane?)

### 7. **Spike + design are auto-approved; re-surface only for true blockers**

The 2026-06-13 owner directive ("spike + design auto-approved") had profound impact. Agents no longer stalled on design uncertainty:

- **TSK-1310 (draw-text editing):** spiked → realized frugal extend-VectorShape design → self-approved → built slices 1–4 in one firing
- **TSK-1333 (walkthrough mermaid):** spiked render path → confirmed feasible + no unknowns → scoped the atomic unit (component + occlusion-safe wiring + PixelTestCase) → ready to build
- **TSK-588 (perf-floor bench):** spiked the ratchet approach → self-approved → shipped hand-rolled bench (no external dep needed)

**What this unblocked:** features that would have queued on "is this the right design?" now flow through: spike → design → build → test → land in one batch.

**For the rebuild:** embed this in the loop from day one. Give the agent authority to:
- **Spike** (scope / survey existing code / list options / estimate) — auto-approved
- **Design** (pick an approach, write a design doc, break into slices) — auto-approved
- **Build** (implement the slices) — standard gate
- Only re-surface for: **dependency approval, true undifferentiated ambiguity (what is actually being asked?), or a hard blocker** (something is broken that must be fixed before proceeding)

---

## Portable Decision Records

### Pattern: Host Model + Render Tail

**Decision:** Build features in slices: (1) pure model/logic host-testable, (2) render-code non-pixel (WebView, AppKit, SwiftUI wiring), (3) pixel-level (screencapture, animation, compositing).

**Rationale:** unblocks parallel work (model can land immediately, render tail doesn't block), catches integration bugs early, and provides a clear seam for "what needs VM/owner validation."

**How it played out:** 
- 100+ items followed this pattern
- Features shipped model + render path to `review`, then owner-validated pixel behavior
- Avoided the "render is VM-only, wait for owner" false brake

**For the rebuild:** enforce this at PR review level. A render PR should declare its slice (e.g., "model ✅, render-path ✅, pixel-tail pending T5").

---

### Pattern: Comprehensive UAT Harness Audit

**Decision:** When UAT lanes report failures, audit the harness first before assuming product regression.

**Rationale:** false-reds in automation cause cascading mistrust (owner assumes real bugs, agent assumes flaky tests). A single harness bug can fire 50+ false failures.

**How it played out:**
- TSK-953: 53 false-reds traced to xctest-as-root temp inaccessibility → one LaunchHarness fix → 20/20 green
- TSK-1032: HEX-grid "blank" traced to TK2 numberOfGlyphs introspection → swapped metric → resolved
- TSK-1247: spawned-app blank traced to VM WindowServer compositing → workaround known

**For the rebuild:** 
- Build a comprehensive harness health suite (proof that introspection metrics are trustworthy)
- Isolate harness bugs from product bugs by running the same test in isolation vs. full sweep
- Document each false-red's root (create a living FAQ of "why did this test fail?")

---

### Pattern: Owner Intake Deduplication

**Decision:** When owner posts a feature/bug batch, synchronize against the live board before triaging.

**Rationale:** avoids filing duplicates, and surfaces which owner feedback was already tracked vs. genuinely new.

**How it played out:**
- 75-item owner batch → 59 net new tickets (16 already tracked or shipped) → prioritized & slotted into WORK_QUEUE

**For the rebuild:** 
- First filter: is this already on the board?
- Second filter: is this already shipped (check git log / CHANGELOG)?
- Third filter: is this a duplicate of another item in the batch?
- Only file if all three say "no"

---

### Pattern: Rust-Core Correctness-Critical Work Requires Fresh Focus

**Decision:** FFI refactors, security-critical rewrites, and unsafe-code audits are not appropriate for tired deep sessions. Schedule them in focused, separate runs.

**Rationale:** these are correctness-sensitive (a typo = memory corruption / UAF); tired agents make mistakes.

**How it played out:**
- TSK-564 (FFI zero-copy boundary): scoped but deferred (correctness-critical)
- TSK-575 (cast-safety audit): executed in a fresh focused session with full instrumentation
- TSK-844 (CSV arena heap-cap): scoped but deferred

**For the rebuild:** have a **correctness-audit tier** that's scheduled separately from the main loop, runs when the agent is fresh, and gets a full gate + owner review.

---

## Portable Artifacts & Techniques

### 1. **Settle-to-Quiescence Test Harness Pattern**

**What:** `settle()` helper for async tests that pumps the event loop until no new bodies/network traffic for 2 consecutive cycles (bounds checked at 24 cycles max).

**Why:** SwiftUI body re-evaluation is async + coalesced; fixed-cycle pumping misses residual async work under load.

**Where used:** `ChromeBodyEvalCountTests`, parallel gate load-testing

**Portable:** Yes. Reusable for any SwiftUI async test that needs to wait for quiescence.

---

### 2. **TextKit-2 Introspection Metric (textLength)**

**What:** diagnostic that reads `textStorage.length` instead of `layoutManager.numberOfGlyphs` (the latter is ~0 for TextKit-2 unflushed layouts).

**Why:** UAT harness was false-reporting "blank" for populated TK2 views.

**Where used:** `DiagnosticDump`, UAT element-mount checks

**Portable:** Yes. If you're building TextKit introspection, use `textLength` not `numberOfGlyphs`.

---

### 3. **Frugal VectorShape Extension (Avoiding Parallel Types)**

**What:** instead of adding a parallel `.textShape` type, extend the existing `VectorShape` enum with `.text` kind + optional `text: String?`, `fontSize: Double?`.

**Why:** reuses 100% of the selection/move/restyle/inspector machinery for free; low risk (optional fields decode unchanged for existing overlays).

**Where used:** image editor text overlay (TSK-1310)

**Portable:** Yes. Whenever adding a new shape variant, ask "can I extend the existing enum?" before adding a parallel type.

---

### 4. **ParseMemo Single-Slot Cache (Query-Independent Parses)**

**What:** tiny cache that memoizes a parse by input text; recompute only on text change, not on query change.

**Why:** CommandPalette re-parsed the whole file on every keystroke in `@`-mode, even though the parse (headings list) is independent of the query.

**Where used:** MarkdownOutline parsing (TSK-887), and broadly reusable for any query-independent computation

**Portable:** Yes. This pattern (single-slot memoization by input, not by query) applies to any feature that rebuilds a large result set per keystroke.

---

### 5. **Perf-Floor Ratchet Bench (Not Criterion)**

**What:** deterministic, clock-free baseline-comparison bench (no wall-clock thresholds). Runs a fixed workload, compares against a saved baseline, diffs tolerances, exits 1 on regression.

**Why:** criterion + wall-clock asserts are flaky under machine load; ratchet is stable.

**Where used:** rust-core performance gate (TSK-588)

**Portable:** Yes. If you're adding a perf-regression gate, use a ratchet (committed baseline + compare-vs-baseline), not wall-clock assertions.

**Code location:** `mdvcore-core::bench` module + `mdvcore-serve bin perf_floor` + `.github/workflows/nightly-perf-floor.yml`

---

## Pitfalls to Avoid in the Rebuild

1. **Don't over-block on "VM is the owner's lane."** The VM is agent-workable except for AX-driven tests. If work is blocked on pixel validation, build the render-path and queue the pixel test for the VM.

2. **Don't audit casts / cast-safety / unsafe code in a tired session.** These require fresh eyes and full instrumentation. Schedule them separately.

3. **Don't silently manufacture marginal work instead of escalating.** If the queue is empty or only owner-gated items remain, document the HOLD and ask for unblocks. This is correct behavior.

4. **Don't trust a single test metric (numberOfGlyphs, ImageRenderer render-check, framebuffer screencapture).** Always cross-check with the real app or a parallel validation tier.

5. **Don't merge parallel agent workflows without a full gate.** Cherry-pick + compile + full gate + manual clash-review, every time.

6. **Don't build render features without a clear pixel-vs.-non-pixel boundary.** The rebuild should have a standard template: "this PR includes [model ✅, render-path ✅, pixel-tail at TSK-NNNN]".

---

## Carry-Forward Recommendations

### PORT (reuse nearly verbatim)

- **Perf-floor ratchet infrastructure** (bench core module, compare function, baseline file, nightly workflow)
- **Settle-to-quiescence harness pattern** (the 2-pump cycle + bounds check)
- **TextKit-2 textLength introspection metric**
- **Parse-memoization pattern** (single-slot cache by input)
- **Security-scan scripts** (`check-no-secrets.sh` patterns)

### DISTILL (the idea, apply to the new codebase)

- **Spike + design auto-approved** directive (embed in loop SOP)
- **Render-slice vs. pixel-slice split** (make it a standard PR template)
- **Host-completable audit before declaring VM-only** (question every assumption about which harness gate is blocking)
- **Owner intake deduplication flow** (filter board, shipped, duplicates-in-batch)
- **Autonomous loop HOLD recognition** (when the queue is exhausted, escalate, don't invent)

### SKIP

- **Ultracode workflow parallel-lane merging** (specific to this codebase's scale; the rebuild may be smaller or use different strategies)
- **Specific TSK tickets & routing** (historical to this project)
- **VectorShape `.text` extension trick** (applicable only if the rebuild has vector shapes; generalize the principle: extend before paralleling)

---

## Summary

This 29-day period was a **masterclass in what autonomous agents can do when given clarity, authority, and unblocked queues.** The key insight: **split render-path work into host-validatable (model + render-code) and pixel-deferred (T5 screencapture or owner UX validation).** This unblocked the agent from a constant "waiting on the owner for VM validation" pattern and allowed ~280 items to flow through in parallel.

For the rebuild, the playbook is:
1. **Design spike authority** (auto-approved, no blocker on "what should we build?")
2. **Host-render split** (model + render-path host-testable; pixel deferred)
3. **Harness health** (comprehensive introspection metrics, false-green traps documented)
4. **Escalation clarity** (HOLD = owner decision needed, not agent failure)
5. **Freshness for correctness-critical work** (async chains, unsafe code, security audits in dedicated sessions)

The rebuild can ship faster and with higher confidence by applying these patterns from day one.
