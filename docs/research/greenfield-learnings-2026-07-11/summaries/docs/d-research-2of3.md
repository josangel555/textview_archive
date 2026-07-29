# Research Docs Batch 2/3 Summary (items 11-19)

**Date:** 2026-07-11  
**Scope:** Investigation docs from `docs/research/`, items 11–19 (html-trust-mode → rust-core-audit)  
**Status assessments:** judge from dates, conclusions, and follow-up status

---

## Enumerated docs with carry-forward guidance

**html-trust-mode-2026-06-20/** — Trust-local-HTML render mode security design (owner-approved build-it)  
- **status:** current (owner decision 2026-06-20, design final)
- **learnings:** 
  - Threat model driven design (script injection vs. file-exfil): relax #1, bound #2 fully.
  - Fail-closed gate (L-trust): per-document opt-in, unspoofable, keyed to exact path.
  - Bounded relaxation by layer: sanitization + CSP + subresource policy; anti-exfil fence NEVER relaxed (connect-src none, file-fenced, no universal access).
  - Sliced delivery (gate-first, then relaxation, then failure-surfacing) de-risks the high-risk change.
- **carry-forward:** DISTILL — the threat-model-first + fail-closed + layered-relaxation + slice-to-de-risk pattern is reusable for any trust/permission model; the specific HTML policy is less portable but the methodology is gold.

---

**image-editor-parity-2026-06-20/** — Image Editor → MS Paint parity audit, research, plan  
- **status:** current (audit final 2026-06-20, plan filed as epic TSK-1048)
- **learnings:**
  - Shipped editor is a photo-adjustment PoC (7 tonal sliders), not a paint program (~4 MS-Paint-style capabilities wired).
  - Large raster/paint MODEL layer exists (`Sources/ViewerCore/ImageEditing/`) but is NOT wired to UI — parity is mostly surfacing existing tested code.
  - Image creation (blank canvas) entirely absent — no model entry point.
  - **Worst sync/clunk offenders: every slider tick re-decodes source from disk, replays all ops, allocates fresh CIContext per op, recomputes full histogram on main-thread, no debounce.**
  - Filed 42 child tickets (TSK-1049…1090) phased: Phase 0 (perf foundation + creation), Phase 1–5 (tools/selection/color/formats), Phase 6 (layers).
- **carry-forward:** PORT — the phased plan, the sync/clunk hot spots (file:line evidence), and the dual nature (model-done-UI-missing) are exact architectural knowledge for greenfield image work.

---

**loose-ends-audit-2026-06-06/** — Multi-agent loose-ends audit (9 agents, 31 findings post-dedupe)  
- **status:** current (audit final 2026-06-06, findings filed as tasks)
- **learnings:**
  - Backend-not-surfaced cluster (5): image editor, LSP completion, formatting/didSave, initializationOptions, CM6 indentGuides/foldingRanges — highest-leverage feature work.
  - Incomplete (2): HEX 'View Only' toggle non-functional (edit path wired but toggle doesn't gate), LSP teardown leaks (async cleanup + shutdown budget).
  - Unfinished (11): LSP References button disabled, Tier A plugin placeholder, zoom split deferred, invisible-character styling compositor-blocked, MCP.Value.int trap, MessagePack untrusted-count OOM, nested-blockquote SIGSEGV, plugin subprocess timeout leaks, HexView HighlightKey O(matches) per update.
  - Redundant (5): triplicate byteString, isSameDocumentFragment, readXattrs, relativeTime (with stash variant bug).
  - Stale docs (5): Mermaid listed pending but shipped; DESIGN.md non-goals outdated; PLUGINS_DESIGN_v2 header false.
  - **Health read:** codebase in strong shape; 90% of security/perf deep-audit already fixed; genuine remains are feature-surface + cleanup.
- **carry-forward:** DISTILL — the dual-audit pattern (code path verification + design-doc staleness check) + the six-category taxonomy are reusable; the specific findings are codebase-specific but the methodology (grep for surface, verify against current tree) is portable.

---

**lsp-and-plugin-boundary-2026-06-13/** — LSP own-vs-external + plugin/core decomposition boundary  
- **status:** current (spike findings 2026-06-13, both tickets design-approved)
- **learnings:**
  - **LSP:** Own the *client* (JSON-RPC framing + process supervision + protocol types), rent *servers* (external, user-installed).  
  - Current posture is already correct: `LSPClient` is production-grade (~59 KB, battle-scarred, dedicated thread for stdout read).
  - Operational risks (not architectural): discovery friction (PATH issues for GUI apps), spawning untrusted binaries, zombie/lifecycle hazards (already handled), jdtls JVM heft.
  - LSP-as-plugin-contribution: cleanest long-term expression is Tier-A/B manifest declaring language + command + args + initializationOptions.
  - **Plugin/core boundary principle:** Core owns determinism + identity + perimeter; plugins own optional + IO-bound + domain-specific (all behind process boundary).
  - Determinism test (pure sans-IO): → **CORE** (Rust engines, document/tab model).
  - Perimeter test (security fence): → **CORE, always** (HTMLSanitizer, URLSchemePolicy, PluginSubprocessHost).
  - Optionality test (IO/domain-specific/replaceable): → **PLUGIN** (SQLite browser, AWS, formatters, image editing, media, terminal, extra languages).
  - **Terminal exception:** Cannot fit Tier-B contract (one-shot, env-scrubbed, 5s/1 MB capped) — either stays core or needs new Tier D (long-lived interactive PTY). Owner decision parked.
- **carry-forward:** PORT — the ownership principle (own determinism/perimeter, plugin optional/IO), the three operational tests (determinism/perimeter/optionality), and the per-subsystem table are exactly the architectural framework for the next greenfield app. The specific LSP/plugin manifest design is reusable template.

---

**next-priorities-2026-05-31/** — Pre-PoC implementation plan, dependency DAG, tiered phased work  
- **status:** stale (dated 2026-05-31, pre-PoC superseded by later audits; many items landed, many deferred)
- **learnings:**
  - **Foundational ordering principle:** Build observability sink + session-runtime value type FIRST (they unblock the widest downstream).
  - Dependency DAG: 0a (ObservabilitySink) root → 0b (SessionRuntimeState) unblocks crash-recovery/per-session-independence → higher tiers.
  - Standing constraint: **Never `model.objectWillChange` wholesale; narrow `@Published` streams + equality guards + debounce** (the REPUB-1 trap).
  - Tier 0 foundations (S–M): ObservabilitySink, SessionRuntimeState (session-runtime value type, incremental/debounced persist), Tooltip model, Per-tab disk-staleness.
  - Tier 1 quick-wins (S, ~6 items): tab-dedup symlink, session-goto stray prompt, source mode for binaries, shoulder buttons 4/5/6, row-count tool window, right-click refresh.
  - Tier 2 medium (S–M, ~9 items): status-bar stats, recent tool, pin/follow, SQLite category-override, SQLite UI-scale, tab UX, ModeBar relocation, git file-history, folder stats.
  - One-way-door guardrails: state in core not SwiftUI, observability event FFI-shaped from day one, one command bus, terminal behind protocol, no republish amplification, all persisted shapes versioned.
  - **Already done:** DocumentState.{loading,error} + off-main file loading (commit e5e659b, 2639656) — do NOT rebuild.
- **carry-forward:** DISTILL — the foundational-ordering principle (observability + session-state as roots), the dependency DAG pattern, the tiered phasing (0/1/2/PoC-out), and the one-way-door guardrails are architectural best practices reusable in any major refactor.

---

**perf-latency-explore-2026-06-14/** — Measured app latency exploration (release-build signpost traces on VM)  
- **status:** current (measured 2026-06-14 via `vm-profile.sh`, findings ranked by felt impact × confidence)
- **learnings:**
  - **Headline:** Model/logic layer is fast (tabSwitch 1.4–12.6 ms, openResolved 9.6–20.5 ms, load/decode 1–5 ms). Felt latency is downstream: WebView paint + CA stalls + launch grammar warm.
  - **Top 3 measured findings:**
    - #1 Rendered-MD WebView `loadToFinish` = 2–9 s (measured trace), reloads overlap into storm. Single highest felt impact. Fix: persistent page + incremental DOM patch vs. full reload.
    - #2 Every nav action → 30–366 ms main-thread CA commit stall (43 stalls / 3.35 s / 17 s sweep, 12×>100 ms). Root of "navigation is slow" complaints. Need Time-Profiler stack under stall to attribute.
    - #3 Launch grammar warm: single-threaded 231 ms CPU (15 compiles) serialized, colliding with first paint 283 ms stall. Fix: parallelize + prioritize (S-effort, high confidence).
  - Other ranked findings: 64 MiB sync-read cliff (S-fix, knob change), FFI memcpy (18 MB→Swift Array), ContentFingerprint O(N) utf8.count recomputed, lazy-tab materialize (45–92 ms), TreeSitter substring per predicate, sidebar FileRowState per-row make O(visible), cursor stack churn per hover.
  - **What's already good:** LineNumberRuler byte-scan fixed, cold MD render off-main, plain→highlight 2nd apply cheap, refreshDiffMarks off-main + debounced, lazy-tab off-main + guarded, flatVisibleRows memoized.
- **carry-forward:** PORT — the methodology (capture release-build signpost traces on real VM, parse for measured intervals vs. suspected findings, rank by felt impact, identify the critical path) is gold. The specific findings are codebase-specific but the top-3 pattern (multi-second WebView + CA stalls + launch burst) is likely recurring in any SwiftUI+WKWebView macOS app.

---

**prelaunch-audit-2026-07-09/** — Comprehensive prelaunch audit (30+ dimension audits, v1 + v2 revisions)  
- **status:** current (audit final 2026-07-09, comprehensive scope, many items filed for later)
- **learnings:**
  - **Scope:** 30+ dimensions (accessibility, attack-surface, automation, bugs, code-quality, comment-drift, concurrency, config, crash-analysis, dependency, dual-ui-refactor, editor-stability, entitlements, error-recovery, FFI-safety, hidden-gotchas, inefficiencies, i18n, license, magic-numbers, memory-leaks, packaging, perf, privacy, read-write-consistency, regressions, scaling, security-core, subprocess-safety, tech-debt, test-coverage, test-quality, UI best practices, consistency, liveliness, UX best practices, webview security).
  - **Dimension topics:** each audit has identified issues at security, stability, performance, usability, and standards levels.
  - **V1 + V2 iteration:** many topics have two passes (v1 initial, v2 refined with more depth or owner feedback).
  - **Key issue clusters found:** accessibility gaps, attack surface (git config, network policy), concurrency/race conditions, code quality + tech debt, crash recovery gaps, FFI safety, memory leaks/retention, performance bottlenecks, security core (sanitization, policy), subprocess safety, test gaps, UX/UI consistency, webview bridge security.
- **carry-forward:** DISTILL — the audit methodology (30+ independent dimensions, each probed by separate agents, v1+v2 iteration for refinement) and the topic catalog are reusable for any full-system prelaunch audit. The specific findings are codebase-specific but the dimensional approach (not just "find bugs" but "audit each system layer") scales.

---

**project-meta-analysis-2026-07-04/** — Repo + board archaeology, cross-checked against session-jsonl study  
- **status:** current (analysis final 2026-07-04, convergent with owner's separate jsonl study)
- **learnings:**
  - **Process tax quantified:** 36.5% of all commits are doc-only; 17% of entire history is appends to ONE file (docs/AUTONOMOUS_PROGRESS.md: 14,987 lines, 1,031 touches). Six of top-ten-churn files are tracking docs. **Interpretation:** cost of having no durable execution substrate.
  - **Board shape:** review (284 = 48% of open) + validated-awaiting-done (735) dominate; 83 live-validation blockers + deprecated owner-decision blockers form the same re-formation-in-front-of-human pattern.
  - **Re-fix loops vs. buildouts:** Epic buildouts (TSK-1110 ×63, 1213 ×35) healthy; re-fix loops (TSK-1046 ×13, TSK-1243 ×21) match densest-interrupt clusters. Root cause: wrong hypothesis repeated, not single bugs. Needs SOP: hold ≥2 candidate causes until discriminating check.
  - **Quality discipline real, coverage gap:** Test LOC > source LOC; 68 teeth-reverts; board honesty clean. But real-UI apex held only 24 T4/T5 fns for ~30 surfaces — pixels went unguarded while tests were headless. **Codified fix:** Four MANDATES (per-surface render matrix, AX interaction everywhere, agent-driven UAT, required-evidence-classes named in tickets).
  - **v4 PM assessment:** Design is unusually well-grounded, mechanisms map 1:1 to measured pathologies. Gaps: groomed-contract schema with required_evidence, model-tier routing table, named serial resources (VM GUI lane singleton), quota-window awareness, doc-corpus disposition.
- **carry-forward:** DISTILL — the process-tax quantification (tracking-doc burden as a sign of missing substrate), the four MANDATES (especially "evidence classes named in tickets"), the re-fix loop diagnostic (hold 2+ hypotheses + discriminating checks), and the v4 PM gaps are architectural/process learnings reusable in the next project's design and governance.

---

**rust-core-audit-2026-06-09/** — Rust-core PoC → production decision (9-agent, 43 adversarially-verified findings)  
- **status:** current (audit final 2026-06-09, recommendation: build on it, freeze the contract first)
- **learnings:**
  - **Verdict:** Genuine production-grade core (forbid unsafe, no-panic gate enforced, panic boundary correct, wire hygiene, parity tests). Zero S1 findings; 43 confirmed, 0 refuted; severity adjusted *downward* on 5.
  - **What is NOT production-grade:** Contract + edges (design debts, not algorithm bugs).
  - **Top risks (confirmed S2s):**
    - R1 (16 MiB frame cap vs. 256 MiB CSV limits): ~20 MB CSV opens, every pull fails forever. Fix: decouple decode guard from encode, distinct TooLarge status, windowed snapshot.
    - R2 (git status on untrusted dirs executes config): `core.fsmonitor` RCE on browse (TUI/web only, not shipping). One-line fix: neutralize config.
    - R3 (cbindgen header silently stale): ABI drift undetected → memory corruption. Fix: rerun-if-changed=src, fail-hard, gate-time check.
    - R4 (No ABI/protocol version): No version export, promised error-channel dead code. Fix: mdvcore_abi_version() + WireError frames in out-buf.
    - R5 (8,300 LoC outside gate): highlight/tui/web never compiled/linted/tested; rot measurable. Fix: add to default-members, gate workspace-wide.
    - R6 (Handle/buffer lifetime safety convention-only): Free-vs-in-flight UB, poisoned-lock recovery, MdvBuf double-free by construction. Fix: CoreRuntime registry, DocId model (kills UAF class).
    - R7 (Hostile-input exhaustion): CSV cell-count decoupled from memory (~120× amplification), hex width unvalidated, hunk_marks i64 overflow, web slow-loris/panic-leak.
    - R8 (Efficiency debt): cm_apply full-doc both directions, Vec<Vec> table storage, char-at-a-time CSV tokenizer, per-line String alloc in find, repeated key text in MessagePack.
  - **Target architecture:** mdvcore-core (sans-IO) + mdvcore-highlight (unsafe C quarantined) + mdvcore-host + mdvcore-app (TUI). FFI thin-waist: ~7 symbols (abi_version, call, call_rt, buf_free, last_error, runtime_new/free). Envelope-dispatch with u16 method-ids, aux-bytes side channel, version check at startup, error model v2.
  - **Roadmap:** Phase 0 (fix-before, ~1-2w: fsmonitor, cbindgen, TooLarge, hex-width, gate-workspace), Phase 1 (contract freeze, ~3-5w: abi_version, error v2, windowed snapshot, thin-waist envelope), Phase 2 (structure, ~4-6w: registry, mdvcore-host, editor doc, table store, perf batch), Phase 3 (hardening, ongoing: fuzzing, property tests, Miri, cargo-deny, mutants, WASM).
  - **Dependency decisions needed:** memchr (defer), cargo-fuzz (approve Phase 3), proptest (approve), cargo-deny (approve), nightly Miri (approve), cargo-mutants (approve), wasm target (approve).
- **carry-forward:** PORT — the audit methodology (9 primed + 2 unprimed agents, adversarial verification, severity adjustment), the top-risk taxonomy (R1–R8), the target architecture (thin-waist envelope + sans-IO core + unsafe quarantine), and the Phase 0/1/2/3 roadmap are exactly reusable for any major Rust subsystem in the next project. The specific findings (16 MiB cliff, git config RCE) are codebase-specific but the pattern is portable.

---

## Key learnings from this batch

1. **Threat-model-first + fail-closed design (HTML trust-mode):** Start with what you're defending against, express it as a model, design fail-closed gates, relax only specific layers, and slice to de-risk. Reusable pattern for any permission/trust feature.

2. **Phased feature work with visible models (image editor + next-priorities DAG):** Build the MODEL layer first (tested in core, correct logic), then surface through UI in slices. Use dependency DAG to identify true foundations (observability, session-state) that unblock the widest set. Defer later items without blocking foundations.

3. **The ownership principle for architecture (LSP + plugin/core):** Core owns determinism (pure sans-IO), identity (document/tab model), and perimeter (security fences). Plugins own optional, IO-bound, domain-specific work across a process boundary. Apply three operational tests (determinism, perimeter, optionality) to classify any subsystem. Reusable framework for the next app.

4. **Measured perf work beats guessing (perf-latency-explore):** Capture real traces on the target platform (VM for UI work), parse for measured intervals vs. suspected paths, rank by felt impact × confidence. Top finding (WebView 2–9 s) dwarfs everything else and becomes the target. The methodology is portable; findings are codebase-specific.

5. **Process tax is architectural debt (project-meta-analysis):** 36.5% doc commits, single file with 1,031 touches = sign that tracking-doc burden exists because the execution substrate is stateless. The Four MANDATES (per-surface render matrix, AX interaction, agent-driven UAT, evidence classes named in tickets) are mechanical fixes. Metadata schema (required_evidence[]) makes it load-bearing in the next project.

6. **Contract freeze before adding surface (rust-core-audit):** A PoC's core can be production-grade (zero S1s, enforced gates, parity tests) but contract + edges need intentional design first. Phase 0 (fix-before, ~1-2w) + Phase 1 (contract freeze, ~3-5w) before any new FFI methods. The thin-waist envelope (abi_version + call + dispatch + method-ids + error v2) survives additive surface indefinitely. Cheap to do now, expensive after.

7. **Audit methodology scales (loose-ends + prelaunch):** Six-category taxonomy (backend-not-surfaced, incomplete, unfinished, redundant, stale) catches architecture gaps. 30+ independent dimensions (accessibility, attack-surface, FFI-safety, etc.) each probed separately, then v1+v2 iteration for refinement. Reusable audit catalog and dimensional approach.

---

## Decision records found

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| **HTML trust: fail-closed + bounded relaxation** (html-trust-mode) | Threat model (script injection vs. file-exfil) → relax script only, bound exfil fully. Slice delivery (gate → relax → surface) de-risks high-risk change. | Owner-approved build-it; sliced delivery into production. |
| **LSP: own client, rent servers** (lsp-and-plugin-boundary) | No dimension (speed, maintenance, bundle, correctness) favors owning a language server. External servers already state-of-art; client is small, security-sensitive. | Ratified and continue (already implemented). LSP-as-plugin-contribution is future expression. |
| **Plugin/core boundary: determinism + perimeter + optionality tests** (lsp-and-plugin-boundary) | Three operational tests classify any subsystem. Rust engines + document model + security fences are immovable core; IO-bound/optional are pluggable. | Ratified and continue; terminal exception parked for owner. |
| **Observability + session-state as root foundations** (next-priorities) | Observability sink + session-runtime value type unblock the widest downstream (crash-recovery, per-session independence, metrics, instrumentation). | Owner confirmed; constraint: never `model.objectWillChange` wholesale; narrow `@Published` + equality guard + debounce. |
| **Rust-core: build on PoC, freeze contract first** (rust-core-audit) | Core discipline is production-grade (forbid unsafe, enforced no-panic, correct panic boundary). Contract + edges are design debts, not algorithm bugs. Phase 0 fix-before + Phase 1 contract freeze prevent later migration debt. | Recommendation adopted; Phase 0+1 prioritized before new FFI surface. |
| **Four MANDATES for test coverage** (project-meta-analysis) | Per-surface render matrix (TSK-1539), AX interaction everywhere (TSK-1543), agent-driven UAT, required-evidence-classes named in tickets. Kills "headless green, pixels unguarded" pattern. | Codified in TEST_PYRAMID.md §MANDATES; evidence schema needed in groomed-contract. |
| **v4 PM architecture (stateless cells, runner-walked states, merge-queue, evidence schema)** (project-meta-analysis) | Mechanisms map 1:1 to measured pathologies (amnesia → stateless; lifecycle → runner; false-done → probe+rerun; serializer → merge-queue). | Assessed as unusually well-grounded; gaps to add: evidence schema in contract, model-tier routing, named serial resources, quota-window awareness. |

---

## Portable-artifact candidates — sections/docs to copy into next project

| Artifact | Source | Why portable | Copy as |
|----------|--------|-------------|---------|
| **Threat-model-first HTML trust design** | html-trust-mode-2026-06-20/README.md | Pattern (threat model → fail-closed → bounded relax → slice) applies to any permission/trust feature. | Template in project docs: `TRUST_DESIGN_PATTERN.md` or fold into security-design SOP. |
| **Image editor phased plan + sync/clunk hotspots** | image-editor-parity-2026-06-20/ | Dual-nature pattern (model exists, UI missing) + perf hot-spot evidence (file:line) is exact knowledge for greenfield image subsystem. | Port the phased plan structure (Phase 0 perf foundation, Phase 1–5 features, Phase 6 polish) + the sync/clunk checklist. |
| **LSP ownership principle + plugin/core boundary tests** | lsp-and-plugin-boundary-2026-06-13/FINDINGS.md | Framework (own client+deterministic core, plugin optional+IO) + three tests (determinism/perimeter/optionality) + per-subsystem table are reusable. | Copy §A (LSP decision) + §B.0–B.2 (ownership principle + tests + table) into project `ARCHITECTURE.md`. |
| **Foundational-ordering dependency DAG + one-way-door guardrails** | next-priorities-2026-05-31/ (DAG section) | DAG pattern (0a–0d foundations, then Tier 1–2) + guardrails (state in core, FFI-shaped events, one command bus, no republish) scale to any major refactor. | Port the DAG structure + guardrails list into greenfield `ROADMAP.md` or `ARCHITECTURE.md`. |
| **Perf methodology: measured traces + felt-impact ranking** | perf-latency-explore-2026-06-14/ | Methodology (capture release traces on real platform, rank by felt impact × confidence, identify critical path) is hardware-independent and reusable. Top-3 pattern (multi-second WebView, CA stalls, launch burst) likely recurring. | Add to project `PERFORMANCE_METHODOLOGY.md`: "capture release-build signpost traces on VM, rank findings by felt impact, identify the critical path before fixing." |
| **Six-category + 30-dimension audit taxonomy** | loose-ends-audit-2026-06-06/ + prelaunch-audit-2026-07-09/ | Six-category (backend-not-surfaced, incomplete, unfinished, redundant, stale, cleanup) catches gaps. 30+ dimensions are reusable audit checklist. | Create `AUDIT_CHECKLIST.md` with both taxonomies; reference in startup checklist. |
| **Process-tax quantification + Four MANDATES** | project-meta-analysis-2026-07-04/ | Tracking-doc burden (36.5% commits) signals missing execution substrate. Four MANDATES (per-surface render, AX interaction, agent-driven UAT, evidence classes) are mechanical governance fixes. | Copy Finding 1 (process-tax analysis) + Finding 4 (quality discipline gap) + Four MANDATES into project `GOVERNANCE.md` or `TESTING_MANDATES.md`. Add evidence schema to ticket contract. |
| **Contract-freeze roadmap (Phase 0–3)** | rust-core-audit-2026-06-09/synthesis.md | Phase 0 fix-before (~1-2w) + Phase 1 contract freeze (~3-5w) pattern + FFI thin-waist design (abi_version, call, dispatch, method-ids, error v2) scale to any major Rust subsystem. | Port Phase 0–3 roadmap structure + thin-waist principles into Rust subsystem design doc. Reference risk R1–R8 taxonomy for Rust-specific audit dimensions. |

---

## Open questions / items parked for owner

- **Terminal tier (lsp-and-plugin-boundary):** Current Tier-B contract (one-shot, env-scrubbed, 5s/1 MB capped) cannot support long-lived interactive PTY. Either terminal stays host-owned core, or design new Tier D contract. Owner decision parked (TSK-779).
- **Session types scope + ordering (next-priorities):** Types are presets on per-session panel layout (which doesn't exist yet). Build independence (R1) → per-session storage (R3) → types (R4) or defer types entirely. Owner decision needed.
- **Compressed-files-as-folder security (next-priorities):** Naive sidebar-trick is security hole (zip-bomb, zip-slip, symlink, eager extract). Done right is VFS over archive. Recommend defer to PoC-territory. Owner decision needed.
- **Evidence schema in groomed-contract (project-meta-analysis):** Gaps to add to v4 PM: `required_evidence[]` field in ticket schema, derived from surface catalog; runner refuses `green` without evidence classes. Needs schema design.
- **Rust eviction policy (rust-core-audit):** CoreRuntime registry ships enumeration/size/close-idle hooks; who decides eviction of open-tab state? UX call, not engineering. Owner decision.

---

## Status summary

**Current / actively used:**
- html-trust-mode (owner-approved design, implemented)
- image-editor-parity (epic filed TSK-1048, phased plan active)
- loose-ends-audit (30 findings filed, active triage)
- lsp-and-plugin-boundary (spike findings ratified; LSP-as-contribution future work)
- perf-latency-explore (findings filed; top 3 prioritized)
- prelaunch-audit (comprehensive scope; items triaged and filed)
- project-meta-analysis (convergent evidence; v4 PM design informs next project)
- rust-core-audit (Phase 0 + 1 prioritized; roadmap active)

**Stale / superseded:**
- next-priorities-2026-05-31 (dated pre-PoC; many items now landed or deferred; observability + session-state + per-session-independence goals remain foundational but implementation details have evolved)

