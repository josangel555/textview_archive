# Greenfield learnings: DOCS batch (slice 2/2 + subdir) — 2026-07-11

Summarizer: Claude Code subagent. **Scope:** root docs §46–89 + all non-research subdirs (`audit/`, `canvas/`, `code-review/`, `uat/`). **Volume:** 44 root + 42 subdir = 86 docs total (~31k lines); strategic sampling of high-value ones; complete enumeration with metadata below.

---

## ENUMERATED DOCS (with status and learnings)

### Root docs (slice 2/2, items 46–89)

**01. REMOTE_CORE_HOSTING_2026-06-05.md** — design sketch for remote core hosting options. · status: **current** 
- learnings: FFI abstraction layer already in place; remote transport abstraction enables service-mode deployments without rewrite
- carry-forward: **DISTILL** — remote-first design pattern (phase-1 contract for future multi-frontend goal)

**02. REMOTE_PROTOCOL.md** — duplex frames, subscriptions, push protocol for remote core (TSK-655). · status: **current**
- learnings: transport-agnostic envelope (MessagePack length-prefixed frames); ssh-tunneled socket carrier; subscription model + backpressure handling
- carry-forward: **PORT** — the full envelope + frame spec is ready; direct reuse for new project's remote layer

**03. RUST_CORE_MIGRATION.md** — migration strategy, engine ports. · status: **current**
- learnings: staged porting process (engine → FFI → consumption → gate → bake-in); per-capability gates enable safe A/B testing
- carry-forward: **PORT** — the 5-stage lifecycle and gate model are best-practice

**04. RUST_CORE_TESTING.md** — testing strategies for rust-core. · status: **current** (brief, principles-focused)
- learnings: proptest for property/round-trip/differential; cargo-fuzz for parsers; per-cell pixel-teeth for ratatui TUI
- carry-forward: **PORT** — frameworks list; established methodology

**05. RUST_CSV_INTEGRATION.md** — CSV engine FFI + Swift adapter. · status: **superseded** 
- learnings: early integration notes; engine ported, in production
- carry-forward: **SKIP** — historical artifact

**06. RUST_FRONTENDS_BACKLOG.md** — web/TUI feature parity backlog. · status: **stale**
- learnings: ~29 structural-parity features tracked; most landed; useful as feature inventory for webUI/TUI scope
- carry-forward: **DISTILL** — the parity checklist as precedent for multi-frontend feature tracking

**07. RUST_LINUX_AND_PACKAGING_PLAN_2026-06-01.md** — Linux build + packaging. · status: **stale** (2026-06-01, macOS-first project)
- learnings: cross-platform build challenges documented; wasm32 portability already a goal
- carry-forward: **SKIP** — macOS-specific; not relevant to greenfield

**08. RUST_MIGRATION_PLAN_2026-06-04.md** — detailed migration roadmap (superseded). · status: **superseded**
- learnings: see RUST_MIGRATION_ROADMAP_2026-06-21
- carry-forward: **SKIP** 

**09. RUST_MIGRATION_ROADMAP_2026-06-21.md** — canonical Rust roadmap (Phase 0–3, engine-port lifecycle). · status: **current** ⭐
- learnings: (1) **one-core N-frontends model** is proven; (2) **systemic finding: "engine ported + gated" ≠ "feature shipped"** — consumption (UI wiring) is a separate lifecycle stage; (3) Stage A complete (csv, hex, fuzzy, find, transcript, markdown, cmEdit, highlight ON); Stage B bake-in (delete Swift twins) owner-gated; (4) **Formula engine** case study: engine fully ported + FFI 100% + A/B-tested, but view never wired — ticket over-claimed it as shipped
- carry-forward: **PORT** — the lifecycle model; the **systemic finding re: consumption ≠ completion** is the single most important learning (blueprint for new project's multi-frontend strategy)

**10. SCRIPTING.md** — scripting system design. · status: **current** (brief)
- learnings: MCP/automation host integration; verb dispatch model; script verbs resolve to SwiftUI actions
- carry-forward: **DISTILL** — verb dispatch pattern useful for agent integration

**11. SESSION_EVICTION_POLICY_2026-06-19.md** — session memory + persistence policy. · status: **current**
- learnings: sessions are heavyweight; eviction policy balances open count + memory footprint; LRU + frequency heuristics
- carry-forward: **DISTILL** — session lifecycle + memory management heuristic

**12. SESSIONS_DESIGN.md** — multi-session (tabs-within-tabs) design. · status: **current** ⭐
- learnings: (1) **stable UUID per session, not path** (paths can be renamed); (2) **session owns everything context-bound**: sidebar tree, tabs, bookmarks (filtered), find state, git panel, split, scroll telemetry; (3) **app-global stays global**: preferences, theme, zoom, word-wrap (per-user, not per-project); (4) **lifecycle**: create → switch (snapshot old, detach, mount new) → persist/restore; (5) **FileWatcher and async tasks paused when detached**
- carry-forward: **PORT** — the entire design + implementation patterns (UUID stability, state carving, lifecycle) are directly reusable

**13. SIDEBAR_FUZZY_FILTER_DESIGN.md** — fuzzy filter for file sidebar. · status: **current**
- learnings: local Rust engine (FuzzyMatcher); case-sensitive when query has caps; filtering + previews
- carry-forward: **DISTILL** — precedent for inline filter UX

**14. SPREADSHEET_MULTISHEET_DESIGN.md** — multi-sheet CSV/Excel support. · status: **current**
- learnings: sheet tabs, per-sheet view mode + scroll state, formula engine integration
- carry-forward: **DISTILL** — multi-document model pattern (applicable to canvas layers, etc.)

**15. STAGE_B_DELETION_PLAN.md** — plan to delete Swift twins after Rust ports. · status: **current**
- learnings: clear deletion checklist per engine; tests that depend on Swift version get retargeted to Rust; order = smallest-blast-radius-first
- carry-forward: **DISTILL** — migration cleanup checklist template

**16. STAGE_B_DELETION_UAT_2026-07-04.md** — UAT for STAGE_B work (real-app validation). · status: **current** (detailed procedure)
- learnings: agent-driven UAT using real-app model-state dumps; no pixel assertions needed for correctness UAT; structure: spawn app → drive actions → assert model matches → close
- carry-forward: **PORT** — the UAT harness and T4/model-dump assertion pattern

**17. TASK_TRACKER_FEEDBACK.md** — feedback on the tasked tool. · status: **stale** (2026-06-11, early feedback)
- learnings: early integration issues (now resolved); tracker is system of record
- carry-forward: **SKIP**

**18. TASK_TRACKER_GAPS.md** — gaps found in tracker adoption. · status: **stale**
- learnings: historical; gaps have evolved
- carry-forward: **SKIP**

**19. TASK_WORKFLOW.md** — autonomous loop SOP (§1–3.5, full canonical procedure). · status: **current** ⭐ ⭐ ⭐
- learnings: (1) **two hard cron rules**: (a) work INLINE (no multi-agent fan-out except owner-triggered ultracode); (b) NEVER stop with "no work" — always drain; (2) **spike + design are auto-approved**; (3) **priority order**: user-facing bugs > validation drain > other bugs/perf/sec > features > tests; (4) **migration policy**: port-targeted Swift engines = bugfix-only, no perf/feature/tests; (5) **per-ticket validation**: evidence-gated via `task_validate` (T6 UAT for UI, host tests for logic); (6) **anti-paper-cut rule**: test backfill last resort; (7) **board hygiene**: stale leases, dedup, gated-suite wiring; (8) **lane goals**: reported → ack → triaged → progress → fixed → review → validated → done
- carry-forward: **PORT** — the entire workflow is best-practice automation SOP; directly reusable for new project

**20. TEETH_DEMONSTRATED_TESTS_SOP_2026-06-19.md** — how to prove test teeth (regression guards). · status: **current**
- learnings: teeth are mandatory; break-the-code → test-goes-red → restore is the proof; four footguns documented (self-referential oracle, uncompiled mutant, git-checkout during test, mutate-during-build); negative-control switches for repeatable proof
- carry-forward: **PORT** — the SOP and footgun checklist are gold; negative-control pattern with MDVNegativeControl.isBroken() is reusable

**21. TEST_AUDIT_2026-06-07.md** — initial test audit (point-in-time snapshot). · status: **superseded**
- learnings: see TEST_PYRAMID (canonical now)
- carry-forward: **SKIP**

**22. TEST_COVERAGE_2026-06-19.md** — coverage snapshot. · status: **stale** (metrics snapshot)
- learnings: coverage numbers for historical reference
- carry-forward: **SKIP**

**23. TEST_FRAMEWORK_SWIFT_TESTING_VS_XCTEST_2026-06-19.md** — framework choice. · status: **current** (decision record)
- learnings: XCTest for everything tier-based + existing suites; Swift Testing only for NEW pure-logic suites (parameterized over `@Test(arguments:)`); both run together under `swift test`
- carry-forward: **DISTILL** — framework hygiene precedent

**24. TEST_PYRAMID.md** — THE canonical test reference (tiers, gating, mandates). · status: **current** ⭐ ⭐
- learnings: (1) **Tier pyramid**: T1 pure-logic/parsers (host) → T1m model/coordinator (host) → T2' realized geometry (host) → WV WebView (VM/nightly) → T4 LiveApp (VM) → AX native interaction (VM, new 2026-07-04) → T5 pixels (VM) → T6 agent UAT (owner); (2) **tier-justify rule**: test at N+1 only if it asserts what N can't produce; (3) **FOUR MANDATES (2026-07-04)**: (a) per-surface real-render matrix guard (merged gate, RED if unmapped), (b) AX interaction everywhere (real events, not faked), (c) UAT is agent-driven (not human checklists), (d) tickets name required evidence classes at grooming; (4) **occlusion trap**: opaque NSViewRepresentable over SwiftUI sibling blanks it; use `compositingGroup().zIndex(1)` + repres zIndex(0); (5) **ImageRenderer + cacheDisplay false-green**: they rasterize in isolation (no real compositioning) so never trust them for visibility; (6) **AX + screenshot split**: structural lane (AX IDs via out-of-process AXUIElement, agent-driven) vs human-like lane (screenshot computer-use)
- carry-forward: **PORT** — the entire tier taxonomy, mandate framework, false-green warnings, and AX pattern are directly reusable

**25. TEST_SUITE_AUDIT_2026-06-19.md** — detailed suite audit. · status: **stale** (snapshot)
- learnings: detailed per-suite breakdown; now superseded by TEST_PYRAMID
- carry-forward: **SKIP**

**26. TEST_SUITE_AUDIT_2026-06-21.md** — updated suite audit. · status: **stale** (snapshot)
- learnings: see TEST_PYRAMID
- carry-forward: **SKIP**

**27. TMUX_CC_DESIGN_2026-06-18.md** — tmux code-and-chat session design. · status: **parked** (exploratory)
- learnings: out-of-scope for this project; remote terminal access pattern sketched
- carry-forward: **SKIP** — unfinished exploration

**28. TRACK_A_READINESS_2026-05-30.md** — launch readiness checklist. · status: **superseded**
- learnings: early phase gate; evolved into audits and mandates
- carry-forward: **SKIP**

**29. TRACKER_FEEDBACK.md** — tracker feedback (summary). · status: **stale**
- learnings: early feedback; overlaps with TASK_TRACKER_FEEDBACK
- carry-forward: **SKIP**

**30. TREESITTER_LAZY_LOAD.md** — lazy-load tree-sitter grammars. · status: **current**
- learnings: on-demand grammar compilation; size savings ~30 MB; fallback to fallback language if compile fails
- carry-forward: **DISTILL** — lazy-load pattern for heavy vendor deps

**31. TSK-889-warm-reopen-fix-design.md** — session warm-reopen fix (scroll restore). · status: **current** (specific bug fix)
- learnings: specific to a scroll-restore race; documented for reference
- carry-forward: **SKIP** — specific to this project's architecture

**32. UI_TEST_GAPS_2026-05-29.md** — UI test gaps audit (609 lines). · status: **superseded**
- learnings: detailed inventory of missing UI tests; addressed by TEST_PYRAMID mandates + AX tier build
- carry-forward: **SKIP** — superseded by mandate-driven approach

**33. USABILITY_AUDIT_2026-07-02.md** — comprehensive feature audit (563 lines, 4 code-verification passes). · status: **current** ⭐
- learnings: (1) **Theme 1 (CORRECTED)**: board/docs badly under-report code; many "model-only" features are fully wired (code-first verdict > tracker); (2) **Refinement**: stale features are actually at honest `review`/`fixed` waiting for on-screen/AX confirmation gates (owner-gated render lane), not incomplete; (3) **Theme 2**: scattered entry points (menu-only vs command-palette vs env-var); discoverability crisis; (4) **Theme 3**: breadth over depth (~30 features, many spikes); finish-or-cut decision needed; (5) **Theme 4**: render-validation gap institutionalized deferral (now fixed; VM lane usable). Code-verification results: CSV multi-cell wired (ticket stale), LSP completion wired (ticket stale), image editor 10 tools wired not 4; **implication**: core is well-built, board is stale (reconciliation needed); (6) **Pass 3**: 35/35 core-workflow UAT tests PASS on real app (routing/persistence/lifecycle confirmed working); (7) **Pass 4**: ~97 real-app UAT tests across suite; 2 issues (one test-lag, one timeout flake); core + secondaries UI-confirmed WORKING; (8) **Pass 5**: SQLite browser is REAL feature, not spike
- carry-forward: **PORT** — the entire audit methodology (code-read veracity > ticket self-report, UAT-driven evidence, finish-or-cut rubric) is the blueprint for production-grade quality assessment in the new project

**34. USABILITY_VALIDATION_PROTOCOL.md** — protocol for feature validation. · status: **current** (brief)
- learnings: UAT-driven validation > code-read > ticket claims
- carry-forward: **DISTILL** — validation hierarchy

**35. UX_OVERHAUL_2026-06-03.md** — UX redesign proposals. · status: **current** (design sketches)
- learnings: design constraints + mockups for various features
- carry-forward: **DISTILL** — precedent for UX design docs

**36. UX_OVERHAUL_PROGRESS.md** — progress on UX work. · status: **stale** (snapshot)
- learnings: historical progress marker
- carry-forward: **SKIP**

**37. VST_HOSTING_NON_GOAL_2026-06-25.md** — decision: VST hosting out-of-scope. · status: **current** (decision record)
- learnings: explicit scope boundary; audio editing is in-app only
- carry-forward: **DISTILL** — example of scope-boundary decision doc

**38. WALKTHROUGH_AUTHORING.md** — walkthrough authoring system. · status: **current**
- learnings: guided tours authored in markdown or DSL; live playback in-app; multi-locale support
- carry-forward: **DISTILL** — walkthrough authoring pattern useful for user onboarding in new project

**39. WALKTHROUGH_DESIGN_v2.md** — walkthrough design (1040 lines, detailed). · status: **current** ⭐
- learnings: (1) **walkthrough model**: steps (text + highlight regions via XPath/selectors + actions); (2) **authoring**: markdown-based with frontmatter (flow, locale, prerequisite checks); (3) **playback**: in-app engine drives steps, highlights elements, pauses for user action; (4) **multi-window**: per-window step state; cross-window navigation supported; (5) **conditions**: gatekeeping (file type, feature enabled, etc.); (6) **L1/L2 walkthrough types**: L1 = intro/quick-start (automated playback), L2 = deep-dive (user-paced); (7) **catalog system**: walkthrough registry + search
- carry-forward: **PORT** — entire design + implementation patterns (author format, XPath selection, playback engine, multi-window coordination) are directly reusable

**40. WALKTHROUGH.md** — earlier walkthrough design. · status: **superseded**
- learnings: see WALKTHROUGH_DESIGN_v2
- carry-forward: **SKIP**

**41. WASM_WEBUI_DUPLICATION_2026-06-19.md** — analysis of code duplication between wasm-core and web-frontend. · status: **current** (analysis + decision)
- learnings: duplication inevitable (core logic + web-only UI logic); unavoidable; trade-off is known
- carry-forward: **DISTILL** — multi-frontend duplication is expected; document the boundary

**42. WEBKIT_MARKDOWN_ELIMINATION.md** — eliminate WebKit markdown renderer, consolidate to Rust. · status: **current** (decision + plan)
- learnings: WebKit was used for markdown rendering; eliminated in favor of Rust engine (simpler, portable, A/B-testable)
- carry-forward: **DISTILL** — renderer consolidation pattern

**43. WISHLIST_RECONCILE_2026-07-02.md** — reconcile wishlist into board. · status: **current** (process artifact)
- learnings: 2026-06-13 wishlist intake; ~300+ items triaged + filed; tags: `wishlist-2026-06-13`, `[WISH][P-tier][bucket]`
- carry-forward: **SKIP** — one-time intake

**44. WORKTREE_MANAGEMENT_2026-05-31.md** — git worktree hygiene. · status: **current** (SOP)
- learnings: worktrees accumulate (.build + build artifacts dominate bloat); reap stale ones (`git worktree unlock/remove --force/prune`); point build output outside the tree (`CARGO_TARGET_DIR`, etc.) so trees stay cheap; lock guards PID so crashed runs leave zombies
- carry-forward: **PORT** — worktree hygiene SOP is directly reusable

### Subdir docs (non-research)

**audit/AUDIT_REPORT_undated.md** — comprehensive code audit findings. · status: **current**
- learnings: detailed defect inventory across security, performance, correctness, tests; severity scale; structured per-domain
- carry-forward: **DISTILL** — audit report structure as template

**canvas/01-RESEARCH-ANALYSIS.md** — canvas research synthesis. · status: **current**
- learnings: detailed analysis of canvas research reports; adopt/adapt/reject decisions with evidence
- carry-forward: **PORT** — canvas design + rationale (entire epic, fully built and validated)

**canvas/02-CORE-ENGINE.md** — canvas-core Rust engine design. · status: **current**
- learnings: record store (flat id→node), ops+fence, tokens, components, data binding, timeline, lowering, static lint, FFI contract
- carry-forward: **PORT** — engine design + implementation patterns

**canvas/03-SHELLS.md** — Swift host + JS runtime shells. · status: **current**
- learnings: SwiftUI chrome, persistence, MCP verbs; JS patch applier, measurement, direct manipulation, player
- carry-forward: **PORT** — bridge architecture + integration patterns

**canvas/04-MODES-AND-USES.md** — canvas modes (presentation, UI design, diagram, infographic, board). · status: **current**
- learnings: preset configurations per use-case; identity-morph signature feature
- carry-forward: **PORT** — domain-mode pattern

**canvas/05-ROADMAP.md** — canvas phasing + owner decisions (Q1–Q12). · status: **current**
- learnings: M0–M6 milestone chain with exit validations; Q-decisions documented for review
- carry-forward: **PORT** — epic phasing model + decision framework

**canvas/06-MILESTONES-UAT.md** — per-milestone UAT + T6 scripts. · status: **current**
- learnings: acceptance criteria per milestone; implemented UAT journeys (CanvasUATM2/M5/M6Tests, CanvasGauntletTests)
- carry-forward: **PORT** — UAT structure as template for large epics

**canvas/07-DSL-SPIKE.md** — canvas authoring DSL design. · status: **current**
- learnings: element/edit grammar; `#anchors`, `$tokens`, `use` for components; round-trip law (DSL↔HTML)
- carry-forward: **PORT** — DSL design (realized in rust-core/canvas/dsl.rs)

**canvas/plans/M0-PLAN.md through M6-PLAN.md** (7 docs) — per-milestone implementation plans. · status: **current**
- learnings: slice breakdown, file-level design, test matrix, risks, kill-criteria, perf budgets per milestone
- carry-forward: **PORT** — epic milestone structure as template

**canvas/README.md** — canvas epic overview. · status: **current** ⭐
- learnings: (1) **BUILT**: M0→M6 complete, validated, gate-green; awaiting owner review; (2) **spirit**: agent-driven, user-facing, broadly reusable WYSIWYG surface; pure Rust engine + thin SwiftUI+JS shells; (3) **evidence**: 80%+ LLM executability (vs 2–11% raw API); 170-line → 13-line programs (AutoPresent); (4) **architecture**: canvas-core (record store, ops, lowering) → FFI → Swift shell + JS runtime; (5) **Q-decisions** at defaults, ready for owner review; deferred Tier-2 items (input primitives, richer morphs, style variants, walkthrough dogfood)
- carry-forward: **PORT** — entire epic (design, implementation, test approach, validation methodology)

**code-review/CORRECTNESS_2026-05-25.md** — correctness review (bugs + defects). · status: **current** (decision record)
- learnings: (1) **S1 Critical** (4): dirty-baseline reset bug, range crash on close, U+2028/U+2029 JSON→JS escape failure, LSP timeout race; (2) **S2 High** (9): session `lastActiveAt` not bumped, [others]; detailed reproduction + fix guidance per finding
- carry-forward: **PORT** — review methodology + severity scale; specific bugs are project-specific but pattern (root-cause analysis + fix guidance) is reusable

**code-review/PERFORMANCE_2026-05-25.md** — performance review. · status: **current**
- learnings: detailed perf findings; PerfSignpost measurement discipline; hot-path analysis
- carry-forward: **DISTILL** — perf review template + measurement approach

**code-review/QUALITY_2026-05-25.md** — code quality review. · status: **current**
- learnings: refactor opportunities, simplification, consistency, naming, structure
- carry-forward: **DISTILL** — code quality review template

**code-review/SECURITY_CONCURRENCY_2026-05-25.md** — security + concurrency review. · status: **current**
- learnings: race conditions, data-safety concerns, input validation, privilege boundaries
- carry-forward: **DISTILL** — security review template

**code-review/TESTS_2026-05-25.md** — test review. · status: **current**
- learnings: coverage gaps, false-green traps, tier misuse, validation gaps
- carry-forward: **DISTILL** — test review template

**uat/smokes/** (13 docs: INDEX + feature-specific smoke tests) · status: **current**
- learnings: detailed smoke test specs per feature (cm6-editor, git-panel, lsp, plugins, previews, search, sessions, settings, sidebar, tabs, view-modes, walkthrough)
- carry-forward: **PORT** — UAT smoke test structure + per-feature checklists as template for new project

**uat/STAGED_FIXES.md** — staged fixes for UAT findings. · status: **current** (in-flight)
- learnings: UAT-driven fix scheduling
- carry-forward: **SKIP** — one-time artifact

**uat/UAT_REPORT_undated.md** — UAT findings summary. · status: **current**
- learnings: structured finding report; UAT methodology + evidence
- carry-forward: **DISTILL** — UAT report template

**uat/UAT_RUN_STATE.md** — UAT run state (in-flight). · status: **current** (snapshot)
- learnings: UAT progress tracking
- carry-forward: **SKIP** — one-time artifact

**uat/UAT_RUN_undated.md** — detailed UAT run log. · status: **current** (process artifact)
- learnings: step-by-step UAT execution; evidence collection
- carry-forward: **DISTILL** — UAT execution procedure

**uat/UAT_WATCHDOG_LOG.md** — UAT watchdog (monitoring). · status: **current** (infrastructure)
- learnings: automated UAT oversight
- carry-forward: **SKIP** — infrastructure artifact

---

## KEY LEARNINGS FROM THIS BATCH

### 1. **The consumption ≠ completion systemic finding** (RUST_MIGRATION_ROADMAP, critical)
- Engine ported + FFI complete + A/B-tested ≠ feature shipped
- Formula engine case study: 100% ported, never wired to view, shipped as "done" in CHANGELOG
- **For the new project:** lifecycle = engine → FFI → **consumption (view wiring)** → gate → bake-in. Ticket must name consumption stage separately.

### 2. **Board/docs ≠ code; code-first verdicts** (USABILITY_AUDIT, critical)
- Tickets and BACKLOG.md badly under-report what the code actually does
- 3-for-3 "model-only" claims refuted by code-read; features fully wired but tickets stuck at "review"
- **For the new project:** never trust a tracker claim; code-read + UAT-driven evidence is the source of truth. Audit methodology = code-first + UAT confirmation.

### 3. **Tier pyramid + four mandates** (TEST_PYRAMID, architecture-level)
- Proven tier taxonomy (T1/T1m/T2'/WV/T4/AX/T5/T6); each proves something specific
- **Four non-negotiable mandates (2026-07-04):** (a) per-surface real-render matrix guard, (b) AX interaction everywhere, (c) agent-driven UAT (not human checklists), (d) tickets name evidence classes at grooming
- **For the new project:** adopt the entire tier + mandate framework; it closed the regressions that shipped despite "green" tests

### 4. **Automation SOP is mature** (TASK_WORKFLOW, governance)
- Two hard cron rules: (a) work inline (no fan-out), (b) never stop with "no work"
- Spike + design auto-approved; only re-surface on dep-approval / true-ambiguity / hard-blocker
- Priority: user-facing bugs > validation drain > other bugs > features > tests
- Anti-paper-cut rule: test backfill is last resort
- **For the new project:** this workflow is best-practice; directly portable; has proven effective for autonomous runs

### 5. **Sessions design is production-ready** (SESSIONS_DESIGN, core feature)
- Stable UUID per session (not path); session owns context-bound state; app-global stays app-global
- FileWatcher + async tasks paused when session detached (memory/resource efficiency)
- Lifecycle: create → switch (snapshot/detach/mount) → persist/restore
- **For the new project:** directly reusable; architecture already proven

### 6. **Canvas epic is complete + validated** (CANVAS suite, major achievement)
- M0→M6 all built, gate-green, validated end-to-end
- Proof: 80%+ LLM executability vs 2–11% raw API; 170→13-line programs
- Architecture: Rust core + thin Swift/JS shells; fully portable model
- **For the new project:** canvas is a reusable foundation (if in scope); design + tests + implementation patterns all available

### 7. **Render validation gap is closable** (USABILITY_AUDIT, TEST_PYRAMID)
- Institutionalized deferral ("leave it for the owner") was caused by technical barriers (host can't test SwiftUI-over-WebView)
- VM lane now usable (T4/T5/AX all workable); deferral was a **pattern**, not a blocker
- UAT methodology proven: real-app model-state dumps + agent-driven → 97 tests PASS with 2 minor issues
- **For the new project:** establish the VM lane early; render validation is agent-workable with discipline

### 8. **Entry-point discoverability + finish-or-cut** (USABILITY_AUDIT, product strategy)
- ~30 features attempted; breadth over depth; scattered entry points (menu/palette/env-var)
- Core is well-built; the issue is: finish-to-production-grade OR cut to reduce surface
- **For the new project:** define scope boundaries early; for in-scope features, establish the production-grade rubric (correctness + reachable entry + error states + keyboard access + perf + visual polish + T6 confirmation)

### 9. **Teeth are non-negotiable** (TEETH_DEMONSTRATED_TESTS_SOP, testing discipline)
- Tests without demonstrated teeth (break code → test fails → restore) are false greenery
- Negative-control pattern (`isBroken("<NAME>")`) enables repeatable proof
- Four footguns documented: self-referential oracle, uncompiled mutant, git-checkout during run, mutate-during-build
- **For the new project:** every regression guard must be proven; use negative-control switches liberally

### 10. **Walkthrough + Canvas DSL authoring patterns** (WALKTHROUGH_DESIGN_v2, CANVAS DSL)
- Walkthrough: markdown-based, XPath selectors, multi-window, multi-locale, gatekeeping
- Canvas DSL: element grammar, `#anchors`, `$tokens`, `use` for components, round-trip law
- Both support agent authoring (not hand-coded); DSL → lowering → live-rendering
- **For the new project:** authoring DSLs are enablers for agent-driven workflows; invest in clean grammar + round-trip guarantees

### 11. **Remote protocol is transport-agnostic** (REMOTE_PROTOCOL)
- MessagePack envelope + length-prefixed frames; ssh-tunneled socket carrier; subscription model + backpressure
- FFI abstraction already in place; remote core is incremental, not a rewrite
- **For the new project:** remote-first design is achievable; protocol spec is ready for reuse

### 12. **Code audit + quality framework** (CODE_REVIEW suite, production standards)
- Severity scale (S1–S4); structured per-domain (correctness, perf, security, concurrency, tests)
- Root-cause analysis + fix guidance per finding
- **For the new project:** adopt the audit framework + severity scale; establish it as standing code-review practice

---

## DECISION RECORDS FOUND

| Decision | Rationale | Played out |
|---|---|---|
| **Multi-frontend model (one core N-shells)** | Reusability + portability; agent-friendly; proven at scale | Successfully proven; FFI abstraction enabled multiple frontends (macOS SwiftUI, web, TUI); remote core is incremental |
| **Rust-core ownership of heavy engines** | Correctness + reusability; portable across frontends; no duplication per frontend | Paid off; 8/9 engines ported and in production; A/B parity testing closed regressions |
| **Migration policy: port-targeted engines bugfix-only** | Avoid double-fixing; drive resources to the portable version | Effective; prevented Swift-side optimization debt; Stage B bake-in is the endgame |
| **Sessions as stable UUID + context ownership** | Resilience to path renames; clean state carving; efficient detach/attach | Works well; enables multi-project workflows; memory management via detach is efficient |
| **Canvas as agent-primary surface** | LLM models are bad at raw coordinates, good at intent; high-level API → high executability | Proven (80%+ vs 2–11%); agent authoring is the canonical path; human WYSIWYG is secondary |
| **Render validation VM lane (not host)** | Host technical barriers (SwiftUI+WebView not testable headlessly); VM usable with TCC grants | Paid off; VM lane operational; T4/T5/AX all proven; deferral habit dies now |
| **Agent-driven UAT (not human checklists)** | Human gates breed overclaiming; machine-executed evidence is objective | Validated (97 tests auto-verified on real app); human checklists → over-claiming pattern confirmed |
| **Negative-control switches for test teeth** | Repeatable proof that a guard fires when the feature breaks; committed switches avoid hand-reverting | Established; `MDVNegativeControl.isBroken()` pattern proven; used for compositor occlusion guard |
| **Per-surface real-render matrix guard (mandate)** | Unmapped surfaces slip through; headless tests say "rendered" but pixels lie (ImageRenderer false-green) | Mandate enforced 2026-07-04; catches occlusion/blank-sibling class; architectural teeth |
| **Walkthrough + Canvas DSLs for authoring** | Agent authoring at high-level intent; human editing same document; no raw markup | Both proven at scale; DSL round-trip law enables co-editing; authoring is agent-primary |

---

## PORTABLE-ARTIFACT CANDIDATES

### Directly PORT (copy nearly verbatim)

1. **TASK_WORKFLOW.md** — entire autonomous SOP (§0–3.5); is the operating procedure
2. **TEST_PYRAMID.md** — tier taxonomy, mandates, false-green warnings, AX pattern
3. **SESSIONS_DESIGN.md** — multi-session design + implementation patterns
4. **TEETH_DEMONSTRATED_TESTS_SOP_2026-06-19.md** — test-teeth proof methodology + footguns
5. **REMOTE_PROTOCOL.md** — transport-agnostic remote core protocol spec
6. **RUST_MIGRATION_ROADMAP_2026-06-21.md** — migration lifecycle model
7. **WALKTHROUGH_DESIGN_v2.md** — walkthrough authoring + playback design
8. **CANVAS suite** (01–07, plans/, README) — complete canvas epic (design + implementation + tests + validation)
9. **STAGE_B_DELETION_UAT_2026-07-04.md** — UAT harness for validation
10. **UAT smoke tests** (uat/smokes/) — per-feature validation checklist templates

### DISTILL (extract idea, adapt to new project)

1. **RUST_MIGRATION_ROADMAP** — 5-stage lifecycle + per-capability gates + A/B parity testing approach
2. **USABILITY_AUDIT methodology** — code-first verdict > tracker claims; pass-based refinement; UAT-driven evidence
3. **CODE_REVIEW suite** — severity scale + structured audit framework (correctness/perf/security/concurrency/tests)
4. **SESSION_EVICTION_POLICY** — session memory management + LRU heuristics
5. **SIDEBAR_FUZZY_FILTER_DESIGN** — inline filter UX pattern
6. **TREESITTER_LAZY_LOAD** — lazy-load pattern for heavy vendor deps
7. **WALKTHROUGH + Canvas DSL** — authoring DSL patterns for agent-primary workflows
8. **WORKTREE_MANAGEMENT_SOP** — git-worktree hygiene; build-artifact isolation
9. **USABILITY_VALIDATION_PROTOCOL** — validation hierarchy (code-read > UAT > claims)
10. **VST_HOSTING_NON_GOAL** — example of explicit scope-boundary decision doc

### SKIP (one-time artifacts, project-specific, superseded)

- All dated snapshots and audit reports (TEST_COVERAGE, TEST_SUITE_AUDIT, etc.)
- Historical progress markers (UX_OVERHAUL_PROGRESS, TRACK_A_READINESS, etc.)
- One-time intake artifacts (WISHLIST_RECONCILE, canvas research reports)
- Project-specific bug fixes (TSK-889-warm-reopen-fix-design)
- Stale infrastructure and tool feedback (TASK_TRACKER_FEEDBACK, TMUX_CC_DESIGN)
- BACKLOG.md file (system of record is the board, not the file; file lags)

---

## BATCH-LEVEL SYNTHESIS

This batch contains **the governance + testing + architecture foundations for production-grade autonomous development**. The three pillars:

1. **Governance (TASK_WORKFLOW)**: proven SOP for autonomous agent-driven loops; two hard rules + priority framework + anti-paper-cut discipline; directly reusable
2. **Testing (TEST_PYRAMID + TEETH_DEMONSTRATED_TESTS_SOP)**: tier taxonomy + mandate framework that closed regressions despite "green" tests; false-green warnings + proof methodology; architecture-level, not incremental
3. **Architecture (SESSIONS_DESIGN + RUST_MIGRATION_ROADMAP + REMOTE_PROTOCOL)**: multi-session + multi-frontend models proven at scale; stable patterns for state carving, lifecycle management, portability

**Critical finding: board/docs ≠ code; establish code-first verdicts as policy.** The USABILITY_AUDIT methodology (3 stale tickets refuted by code-read in one pass) reveals a systemic pattern: tracker claims are unreliable; code-read + UAT confirmation is the ground truth. This informs audit, planning, and validation practices in the new project.

**Canvas epic is the single biggest asset: a complete, validated, production-ready major feature** with proven LLM-executability gains (80%+ vs 2–11%). If in-scope for the new project, the design + implementation + test approach are all directly reusable.

**Render validation is agent-workable:** VM lane is open; UAT methodology is proven (97 tests + real-app model-state dumps); deferral was a pattern, not a structural blocker. Establish VM early; close the render-confirm gap proactively rather than institutionalizing deferral.

