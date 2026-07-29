# Greenfield Learnings Index — markdown_viewer → rebuild (2026-07-11)

53 batch reports summarizing the `markdown_viewer` codebase + docs, feeding the
greenfield rebuild decision (Swift native UI + Rust portable core: WebUI/TUI/remote,
CM6, tree-sitter, LSP, multi-session, plugins, agent-centric features).

## Sources — `Sources/ViewerCore/` root (Swift core, no UI)

| Report | Files | Top highlight |
|---|---|---|
| [src-core-root-1of5](code/src-core-root-1of5.md) | 51 | Seam-based testability via injected services + closures is pervasive and production-grade — port this pattern everywhere. |
| [src-core-root-2of5](code/src-core-root-2of5.md) | 51 | Immutable-base-plus-overlay pattern (EditableCSVModel, EditorBuffer, HexEditBuffer) is exemplary for cheap dirty tracking and undo. |
| [src-core-root-3of5](code/src-core-root-3of5.md) | 51 | Defense-in-depth security: HTMLDocumentPolicy layers six independent checks; fail-closed trust defaults. |
| [src-core-root-4of5](code/src-core-root-4of5.md) | 51 | Rust migration strategy (gate + fallback + stage-B deletion) is battle-proven; replicate exactly. |
| [src-core-root-5of5](code/src-core-root-5of5.md) | 51 | Pure equality on identity + cheap discriminators (not full content) prevents O(N) SwiftUI tab-strip diffs. |
| [src-core-git-highlight-lsp](code/src-core-git-highlight-lsp.md) | 66 | LSP subsystem exemplary actor-based pool + client architecture (POSIX I/O, per-request timeout, crash recovery); hand-rolled protocol types should adopt SDK instead. |
| [src-core-media-terminal](code/src-core-media-terminal.md) | 55 | Immutable source + replayable ops architecture (image/audio) is the crown jewel — enables lossless history, deterministic render, trivial undo/redo. |
| [src-core-automation-infra](code/src-core-automation-infra.md) | 45 | Tier-based architecture enforcement machine-checks the core/Swift split boundary — a correctness pattern worth porting. |
| [src-core-sessions-review-plugins](code/src-core-sessions-review-plugins.md) | 48 | Abstraction seam pattern (RootContextProviding protocol) enables clean feature toggling without conditional logic. |
| [src-core-dataapps](code/src-core-dataapps.md) | 41 | Archive module exemplifies security-first hardening — zip-slip mitigation, size caps, timeout-guarded subprocesses, zero external deps. |

## Sources — `Sources/ViewerUI/` (SwiftUI/AppKit shell)

| Report | Files | Top highlight |
|---|---|---|
| [src-ui-root-1of4](code/src-ui-root-1of4.md) | 53 | DocumentModel god-object (3586 LOC + 15 extensions) is anti-pattern #1: partition state by domain from the start. |
| [src-ui-root-2of4](code/src-ui-root-2of4.md) | 53 | SRP extension strategy: 53 files carving out of a 6.4k-line monolith, each a cohesive vertical slice with no shared private state. |
| [src-ui-root-3of4](code/src-ui-root-3of4.md) | 52 | Compositor safety (TSK-488): NSViewRepresentable + SwiftUI co-hosting requires `.compositingGroup()` + explicit z-order on EVERY sibling. |
| [src-ui-root-4of4](code/src-ui-root-4of4.md) | 52 | Modular observation via independent channels cuts re-body load by ~90%; every data axis gets independent `@Published` + observation. |
| [src-ui-git-walkthrough-terminal](code/src-ui-git-walkthrough-terminal.md) | 41 | Narrow `@Published` surfaces prevent republish storms — critical for coordinators observing multiple upstream sources. |
| [src-ui-other-subdirs](code/src-ui-other-subdirs.md) | 39 | Narrow-observation pattern prevents ~249× baseline republish cascade on every keystroke/scroll/caret move. |
| [src-small-targets-web](code/src-small-targets-web.md) | 26 | ViewerKit (pure-value foundation) — adopt FileCategory/ViewMode/HighlightLanguage wholesale; zero UI-framework deps. |

## Sources — scripts, rust-core

| Report | Files | Top highlight |
|---|---|---|
| [src-scripts](code/src-scripts.md) | 62 | Dual-capacity size guardrails (total + exec) catch two distinct bloat classes: overall growth vs static-linking regression. |
| [src-rust-core-1of2](code/src-rust-core-1of2.md) | 29 | Pure, deterministic engines (CSV, diff, find, fuzzy, hex, JSON, markdown, transcript, formula) shared across TUI/web/future tiers by construction. |
| [src-rust-core-2of2](code/src-rust-core-2of2.md) | 28 | Chunk/sentinel framing: core emits structure + anchors, host enriches islands — scales to any AST with host-decided rendering. |
| [src-rust-other-crates](code/src-rust-other-crates.md) | 28 | Arc-backed handle registry (TSK-541 UAF fix) + thin-waist envelope dispatch + capability bitmap — production-grade C-boundary patterns. |

## Tests — `Tests/ViewerCoreTests/`

| Report | Files | Top highlight |
|---|---|---|
| [t-core-root-1of7](code/t-core-root-1of7.md) | 76 | XCTest dominates (98.7%); pure-logic tests 100% deterministic via temp-dir isolation + fixture seams. |
| [t-core-root-2of7](code/t-core-root-2of7.md) | 76 | All XCTest headless-unit (zero T4/T5 in root) — correct tier separation; CSV surface mature (650–800 test functions). |
| [t-core-root-3of7](code/t-core-root-3of7.md) | 76 | Zero UI-tier coverage but comprehensive security & data-integrity tests with real teeth (XSS, persistence, encoding). |
| [t-core-root-4of7](code/t-core-root-4of7.md) | 76 | 100% headless-unit; LSP domain heavily instrumented (932 LOC in one file) reflecting protocol error-proneness. |
| [t-core-root-5of7](code/t-core-root-5of7.md) | 76 | Zero false-green findings; every test has observable teeth (preference clamps, ring-buffer eviction order, round-trip preservation). |
| [t-core-root-6of7](code/t-core-root-6of7.md) | 76 | FFI boundary tests have VERY HIGH teeth (UTF-16 offsets, SIGSEGV guards, corruption detection) — port immediately. |
| [t-core-root-7of7](code/t-core-root-7of7.md) | 72 | Pure-logic headless dominance (72/72 T1/T1m, zero T4/T5/AX); teeth proof high across all files, ready to transfer 1:1. |
| [t-core-sub-1](code/t-core-sub-1.md) | 70 | Protocol-injected fakes, temp-dir isolation, Codable schema-versioning guards, frozen-timestamp golden tests are the load-bearing patterns to port. |
| [t-core-sub-2](code/t-core-sub-2.md) | 38 | Plugin registry demonstrates seam-based injection + fake-delegate state-machine testing; strong security-boundary tests (ReDoS, path-escape, symlink audits). |

## Tests — `Tests/ViewerUITests/`

| Report | Files | Top highlight |
|---|---|---|
| [t-ui-root-1of6](code/t-ui-root-1of6.md) | 69 | Tiered test strategy (headless-unit → headless-UI → webview → T5-pixel), each layer testing distinct regression classes. |
| [t-ui-root-2of6](code/t-ui-root-2of6.md) | 69 | Isolation pattern (UUID temp-dirs + per-suite UserDefaults) enables parallel test execution with no global-state pollution — mandatory for greenfield. |
| [t-ui-root-3of6](code/t-ui-root-3of6.md) | 69 | State-machine tests dominate (50+ files) but pixel validation is rare (1 T5 file in 69) — mismatch aligns with owner's repeated ImageRenderer false-green burns. |
| [t-ui-root-4of6](code/t-ui-root-4of6.md) | 69 | Compositor-occlusion covered by ONLY one T5 pixel test — highest-ROI pattern; omit it and sibling-blank regressions recur silently. |
| [t-ui-root-6of6](code/t-ui-root-6of6.md) | 70 | Tier pyramid is inverted (81% headless-unit / 16% headless-UI / 9 webview / 1 T5 pixel) — rebuild should flip it, real-render first. |
| [t-ui-harness](code/t-ui-harness.md) | 43 | Tier as explicit type hierarchy (HeadlessUITestCase/LiveAppTestCase/PixelTestCase) enforced at runtime via TierGateObserver — tier membership is machine-checkable. |
| [t-ui-sub-2](code/t-ui-sub-2.md) | 37 | 25-test session suite encodes 8 weeks of learnings on snapshot/hydrate, autosave debounce, dedup invariants, multi-session isolation — port directly. |
| [t-rust-kit-support](code/t-rust-kit-support.md) | 57 | ABI version skew detector + capability-bits constant pinning are foundational gates; every bit position explicitly asserted on both sides. |

## Docs — `LESSONS.md`, `AUTONOMOUS_PROGRESS.md`, `docs/`, `archive/`, `.claude/`

| Report | Files | Top highlight |
|---|---|---|
| [d-lessons-1of2](docs/d-lessons-1of2.md) | 1 | The SwiftUI/NSTextView compositor-occlusion bug is the project's single most expensive, most-referenced lesson; its meta-methodology is the top portable artifact. |
| [d-lessons-2of2](docs/d-lessons-2of2.md) | 1 | The 6-step Rust-core FFI-slice migration template (pure fn → wire seam → FFI shim → Swift bridge → gated adapter → A/B parity test) is the single most reusable artifact for the greenfield Rust-core project. |
| [d-progress-1of3](docs/d-progress-1of3.md) | 1 | 29-day autonomous loop shipped ~280 items; render-slice vs. pixel-slice split unblocked the agent from false "VM-only" brakes on 100+ items. |
| [d-progress-2of3](docs/d-progress-2of3.md) | 1 | Guard teeth must be demonstrated (revert fix → test fails); rework is rare (8/8 sampled prior fixes already remediated) — trust spot-checks. |
| [d-progress-3of3](docs/d-progress-3of3.md) | 1 | Thin-waist FFI envelope (TSK-580) consolidated all Rust methods into one dispatch call — ABI-stable wire-protocol design ready for remote-core. |
| [d-docs-root-1of2](docs/d-docs-root-1of2.md) | 8 | Four major architectural choices lock the system: Rust sans-IO core + Swift UI/FFI/MessagePack; MCP as primary agent surface; 3-tier plugins; Feature Inventory audit (built vs usable). |
| [d-docs-root-2of2](docs/d-docs-root-2of2.md) | 86 | Critical systemic finding: consumption ≠ completion (engine ported + FFI complete ≠ feature shipped) — needs a 5-stage lifecycle for multi-frontend projects. |
| [d-research-1of3](docs/d-research-1of3.md) | 9 | Stateful Rust cores (not stateless snapshots) with coarse-grained message-shaped FFI boundaries are the architectural lesson — design this from commit #1. |
| [d-research-2of3](docs/d-research-2of3.md) | 9 | Threat-model-first design with fail-closed gates and sliced delivery applies to any permission/trust feature; reusable beyond HTML-trust-mode. |
| [d-research-3of3](docs/d-research-3of3.md) | 23 | Sans-IO Rust core is a load-bearing invariant enabling remote-carrier-swap and near-free WASM; must be preserved from day 1. |
| [d-root-md](docs/d-root-md.md) | 22 | The 3-package module boundary (ViewerKit/ViewerCore/ViewerUI, zero UI in Core) made ~80% of logic headlessly testable — the single highest-confidence carry-forward. |
| [d-archive-decisions](docs/d-archive-decisions.md) | 20 | xi-editor post-mortem is the most cited evidence: keep the interactive UI-read-path synchronous/in-process; confine async to coarse remote/crash-prone seams. |
| [d-archive-tracking](docs/d-archive-tracking.md) | 27 | Rust from-the-get-go checklist (panic strategy, error types, time injection, format versioning, breaking-change guards) is impossible to retrofit — build on day one. |
| [d-claude-dir](docs/d-claude-dir.md) | 0 | `.claude/` directory is completely empty — project relies entirely on global defaults + repo-root CLAUDE.md for agent-facing policy. |

---

## Most-cited patterns worth porting

- **3-package / core-vs-UI module boundary (zero UI in core, sans-IO Rust core)** — the single highest-confidence structural decision. Cited by `d-root-md`, `d-research-1of3`, `d-research-3of3`, `d-archive-decisions`, `src-core-automation-infra`, and implicitly by nearly every core-slice report (headless testability of ~80%+ of logic).
- **Narrow-observation / no-republish-storm discipline** (per-domain `@Published`, isolated observable channels instead of one god ViewModel) — cited by `src-ui-root-1of4`, `src-ui-root-2of4`, `src-ui-root-3of4`, `src-ui-root-4of4`, `src-ui-git-walkthrough-terminal`, `src-ui-other-subdirs`, `t-ui-root-6of6`.
- **Compositor-occlusion safety for WebView/NSViewRepresentable siblings** (`.compositingGroup().zIndex()` on every layout branch) + the corollary that ImageRenderer/cacheDisplay are FALSE GREENS for this class, only real WindowServer pixel capture (T5) is authoritative — cited by `src-ui-root-1of4`, `src-ui-root-3of4`, `t-ui-root-3of6`, `t-ui-root-4of6`, `t-ui-root-6of6`, `d-lessons-1of2`, `d-lessons-2of2`.
- **Seam-based testability via injected services/closures/protocols** (fakes over mock frameworks, no UI imports in logic) — cited by `src-core-root-1of5`, `src-core-sessions-review-plugins`, `t-core-sub-1`, `t-core-sub-2`, `t-ui-root-2of6`, `t-rust-kit-support`.
- **Rust migration/port template**: pure fn → wire seam → FFI shim → Swift bridge → gated adapter → A/B byte-equality parity test, with Deleted-Twin (Swift algorithm removed, Rust engine live, adapter seam kept) — cited by `src-core-root-1of5`, `src-core-root-4of5`, `d-lessons-2of2`, `t-rust-kit-support`.
- **Thin-waist FFI envelope / dispatch-by-method-id** (ABI version skew guard, capability bitmap, MessagePack wire boundary) — cited by `src-core-automation-infra`, `src-rust-other-crates`, `src-rust-core-2of2`, `t-rust-kit-support`, `d-progress-3of3`, `d-research-3of3`.
- **Tier-as-type-hierarchy test architecture** (HeadlessUITestCase/LiveAppTestCase/PixelTestCase, sentinel-enforced gate, negative-control switches for teeth-proof) — cited by `t-ui-harness`, `t-ui-root-1of6`, `t-ui-root-4of6`, `src-core-automation-infra`, `d-lessons-1of2`.
- **Immutable-base + replayable-ops / overlay pattern** for cheap dirty-tracking and undo (EditorBuffer, HexEditBuffer, image/audio ops) — cited by `src-core-root-2of5`, `src-core-media-terminal`.
- **Security-first subprocess/archive/SQLite hardening** (env allowlist, resource caps, zip-slip guards, ATTACH/DDL denial) — cited by `src-core-git-highlight-lsp`, `src-core-dataapps`, `src-core-automation-infra`, `src-core-sessions-review-plugins`.
- **Forward-compat Codable discipline** (additive-optional fields, `.unknown` cases, opaque-envelope round-trip preserving unknown keys) — cited by `src-core-sessions-review-plugins`, `src-core-dataapps`, `t-core-sub-1`, `t-rust-kit-support`.

## Most-cited anti-patterns / regrets

- **God-object coordinators** (DocumentModel 3586 LOC + 15 extensions; AppDelegate 4.4 KLOC) — cited by `src-ui-root-1of4`, `src-small-targets-web`, `d-lessons-1of2`. Fix: partition by domain from day one, not as incremental refactor.
- **"Engine tested/ported ≠ feature shipped"** — a green model-layer test suite never proves a view/route reaches the engine or that pixels render correctly — cited by `d-lessons-1of2`, `d-docs-root-2of2`, `d-progress-1of3`, `t-ui-root-3of6`, `t-ui-root-4of6`.
- **Inverted test pyramid** — heavy headless-unit coverage, near-zero real-render (T5 pixel) coverage, despite render/compositor bugs being the costliest recurring class — cited by `t-ui-root-3of6`, `t-ui-root-4of6`, `t-ui-root-6of6`, `d-research-1of3`.
- **ImageRenderer / cacheDisplay / headless-frame-walk false greens** for SwiftUI+AppKit compositing — cited by `d-lessons-1of2`, `d-lessons-2of2`, `d-progress-1of3`, `t-ui-root-3of6`.
- **Split/fragmented engines across Swift and Rust** (CSV split, transcript readers fragmented, scroll channels split) — cited by `src-core-root-1of5`, `src-ui-root-2of4`.
- **Global singletons for cross-module state** (PreferencesStore passed as singleton instead of struct) — cited by `src-core-root-1of5`, `src-core-root-2of5` (UI state leaking into ViewerCore).
- **Hand-rolled wire protocols where an SDK exists** (LSP protocol types incomplete) — cited by `src-core-git-highlight-lsp`.
- **Board/docs process tax and mislabeling** — TSK-#NNN mismatch trap (closing wrong ticket by number collision), stale tracking docs causing paralysis, 36.5% of commits being tracking-doc churn — cited by `d-progress-3of3`, `d-progress-2of3`, `d-research-2of3`, `d-archive-tracking`.
- **killall-by-shared-exec-name footgun** recurring at multiple call sites despite being fixed once — cited by `d-lessons-2of2` (and the project's own CLAUDE.md/MEMORY.md).
- **Stateless/snapshot-shaped persistence and FFI contracts that don't survive a remote/multi-frontend boundary** — cited by `d-research-1of3`, `d-research-3of3`, `d-archive-decisions` (STATE_ARCHITECTURE ownership split not yet implemented).

## Coverage note

Coverage is **53/53 batches — complete** (all 39 `code/` reports + 14 `d-`/doc reports
present on disk). One batch (`t-ui-root-5of6`, Tests/ViewerUITests slice 277-345) failed
only its structured ACK, but its report WAS written to `code/t-ui-root-5of6.md`
(23.9 KB) — it is just not reflected in the pattern tallies above. Downstream readers
should include it from disk.

**Mechanical file-level audit (GAPS §4, `COVERAGE_AUDIT.md`):** batch-complete does not
mean file-complete. Diffing every filename actually named in the 39 `code/` reports
against a fresh on-disk enumeration (2,159 Swift/Rust/scripts/web-asset files) found
**20 files with zero mentions anywhere in the corpus** (11 Swift incl. the 813-LOC
`CommandPaletteView.swift` and a 132-LOC security-relevant SIGSEGV regression test
`MsgPackDecoderDepthCapTests.swift`; 1 Rust — the 1,715-LOC FFI test module
`rust-core/crates/ffi/src/tests.rs`, the single largest gap; 8 scripts, mostly
templates/READMEs/audit scripts) plus **9 files mentioned only via a grouped wildcard
or incidental prose**, never individually profiled (8 `rust-core/crates/core/src/canvas/*.rs`
modules — chart/deck/dsl/io/lint/lower/tokens/vocab — named once in a parenthetical;
`scripts/install-app.sh`, cited 4× but never given its own inventory line despite being
on the critical build→install path). Effective individual-file coverage: **98.3%**
(2,122/2,159); at-least-mentioned: **99.1%**. See `COVERAGE_AUDIT.md` for the full
per-file list, method, and per-corpus breakdown.
