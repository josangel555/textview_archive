# Test-Suite Audit (TSK-788) — 2026-06-19

Assessment of the TextView/MarkdownViewer test suite: architecture, coverage, gaps, recommendations. Numbers from a 2026-06-19 survey; qualitative findings from the ultracode-wave integration + VM-validation session.

## Architecture (sound, well-tiered)

| Layer | Count | Where it runs | Authority |
|---|---|---|---|
| Pure `XCTestCase` (logic/model/FFI/parser) | **695 classes** | host (merge gate) | fast feedback |
| `HeadlessUITestCase` (T1, UI-model, window-free) | **61 classes** | host (merge gate) | model/wiring |
| `LiveAppTestCase` (T4, spawns `dist/`) | **3 classes** | VM GUI lane only | live behavior |
| `PixelTestCase` (T5, WindowServer pixels) | **7 classes** | VM GUI lane only | **render truth** |
| `#192` in-process WebView suites | **31 files** | VM / nightly (`MDV_RUN_WEBVIEW_TESTS=1`) | WKWebView render |
| Wall-clock bench tests | **21 files** | host (advisory) | perf regression |
| Total | **~7,492 test funcs** | | |

Gates: `test-headless-gate.sh` (host merge gate; heavy tiers self-skip, enforced by `TierGateObserver`/`XCTestObservation` sentinel) · `rust-core-gate.sh` (cargo) · `test-in-vm.sh` (VM lane) · `vm-smoke.sh` / `vm-profile.sh`.

## Strengths

1. **Massive cheap host coverage** — ~99% of test *classes* are host-safe; the merge gate gives fast, window-free, deterministic feedback on logic/model/FFI/parser.
2. **Tier discipline is hard-won and load-bearing** — the host/VM split (+ heavy-tier self-skip + `TierGateObserver` enforcement) directly answers the "headless says rendered, screen says blank" class (terminal-tab-strip miss ×4, the `ImageRenderer`/`cacheDisplay` false-greens — LESSONS.md). T5 WindowServer pixels are the *only* render authority.
3. **VM validation is real** — the full GUI-lane suite runs ~3998/4000 green on the merged wave; the lane is reproducible (`test-in-vm.sh all`, toolchain auto-select, ulimit fix).
4. **Teeth culture** — many guards are demonstrated to go red on the broken state (e.g. RemoteOrphanStore OOM "grows to K", the perf-bundle byte-offset mutation).

## Gaps / weaknesses

1. **Render-path VM coverage is THIN (the biggest gap).** Only **10** T4/T5 classes for a feature-rich app. Many shipped/wave features have a host-tested MODEL but **no VM render test** — image-editor UI, session-tab redraw, scroll-restore, CSV inline-edit, side-by-side preview, tmux split. These sit at `fixed`/`live-validation` indefinitely because nothing automatically proves the render. This is the structural reason the board has a large `live-validation` backlog.
2. **Editor key-input is unreachable from the harness** (TSK-1020) — synthesized CGEvent keydowns don't insert into the CM6 `WKWebView` even when focused (KEY_02 proves event delivery; WebContent only takes hardware/JS input). So `type→editor-model` round-trips can't be T4-tested today.
3. **Perf is not regression-guarded** — perf fixes (e.g. 564 FFI double-copy) have correctness tests, not perf-characteristic asserts; a regression to the slow path stays green. The 21 wall-clock benches are advisory + flaky under machine load (documented re-run discipline).
4. **Latent bad fixtures hide behind swallowed errors** (TSK-1021) — `writeSQLiteFixture` shipped a malformed DB for a long time; only a stricter error-handler exposed it. Fixtures that feed an error-swallowing path can pass falsely.

## Recommendations (priority order)

1. **Grow T5 pixel coverage for the render-path VM-tail features** — the highest-leverage gap. Each wave feature with a host-tested model + a `live-validation` ticket should get one T5 pixel test (capture + assert visible), retiring the open-ended `live-validation` backlog. *Biggest quality ROI; needs VM authoring time.*
2. **A VM render-validation pass per substantive render change** (the owner's standing ask) — keep it; consider wiring a nightly `test-in-vm.sh all` so the ~3998-green baseline catches render regressions without manual kicks.
3. **Resolve the editor-input harness gap (1020)** — add a JS-injection input seam for CM6 (test `type→model` via `evaluateJavaScript`-dispatched input) OR formally accept editor input as host-model-only + document.
4. **Add perf-characteristic guards where a perf fix matters** (single-copy assert, allocation-count, payload-size) so perf regressions fail a test — not just a flaky wall-clock bench. Keep benches advisory/off the merge gate.
5. **Fixture hygiene** — prefer real fixtures (e.g. the new `UATSQLiteFixture` real-`sqlite3` DB) over hand-stamped bytes that can be silently malformed; the new `try`-not-`try?` posture (1008) helps surface them.
6. **New pure-logic tests → Swift Testing** (see TSK-787 hybrid recommendation) — `#expect` + parameterized `@Test` would compress the large table-driven parser/parity/golden suites.

**Bottom line:** the suite's *logic* coverage and tier discipline are strong; the gap is **automated render-truth coverage** (T5 pixels) for the feature surface — that's what keeps a large `live-validation` backlog open and is where the next testing investment should go.
