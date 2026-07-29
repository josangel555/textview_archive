# Dependencies & Tooling — greenfield learnings (markdown_viewer, 2026-05-14 → 07-10)

Dimension: minimal-deps policy outcomes, vendored-asset debt, licensing/attribution pipeline,
the `scripts/` tooling layer, CI shape. Evidence-first; every claim below cites a report,
commit-class, or file.

---

## Taxonomy — the distinct types in this dimension

1. **Dep-hygiene policy decisions (accept/reject)** — exact-pin discipline on both SwiftPM and
   Cargo, `default-features=false` + explicit minimal feature lists, and outright rejections
   (cargo-mutants) on "dev-machine surface counts too" grounds.
   Frequency: policy-level (few decisions, durable effect). Severity: low (worked as designed).
   Evidence: `dependency-audit.md` positive-observations ("exact-pin discipline, both sides");
   CLAUDE.md rider "Dep-hygiene includes the dev machine ... cargo-mutants was REJECTED on this
   basis → DIY mutation-testing"; `BACKLOG.md:235` still lists `1137 cargo-mutants` as an open
   dependency in the DESIGN-FIRST epic queue — i.e. the DIY alternative was never actually built,
   so the capability gap (mutation testing) is still open 2 months later.

2. **Vendored-asset staleness (silent CVE accrual)** — a locally-vendored third-party JS bundle
   (Mermaid 11.4.1) pinned once (2026-05-17) and never re-audited; 6 published advisories
   (2 XSS sanitizer-bypass, 1 DoS, 3 injection) accrued over ~11 months with zero internal
   detection. Frequency: 1 major instance found, but structural (no lane watches vendored-JS at
   all). Severity: P1 — real threat-model relevance (app's core use case is opening untrusted
   `.md`, exactly the trigger surface for a mermaid-code-block XSS/DoS).
   Evidence: `dependency-audit.md` F1 (GHSA-8gwm-58g9-j8pw / CVE-2025-54880,
   GHSA-7rqq-prvp-x9jh / CVE-2025-54881, GHSA-6m6c-36f7-fhxh / CVE-2026-41150, +3 more);
   `Sources/ViewerUI/Resources/mermaid/VENDOR.md:4-9`.

3. **Advisory-watch machinery built but never executed** — three well-engineered audit lanes
   (cargo-deny/cargo-audit, SwiftPM advisory watch, vendored-bundle SHA integrity tests) exist,
   are individually correct, and provide **zero ongoing coverage** because nothing schedules
   them (no GitHub remote → `nightly-supply-chain.yml` never fires; no local cron either).
   Frequency: systemic (the entire CI-scheduled half of the supply-chain story). Severity: P1
   (this is the root cause that let #2 go unnoticed for 11 months).
   Evidence: `dependency-audit.md` F2, quoting the script's own admission
   (`scripts/swiftpm-advisory-watch.sh:75-78`: "This repo has no GitHub remote, so the nightly
   workflow never runs — the LOCAL run is the only live lane") plus the live proof that running
   `scripts/rust-supply-chain-audit.sh` today fails red on an untriaged `anyhow` advisory
   (RUSTSEC-2026-0190) that a scheduled lane would have caught weeks earlier.

4. **License-attribution pipeline exists on paper, doesn't ship** — a generator script
   (`scripts/gen-third-party-notices.sh`) produces a 13-section `THIRD_PARTY_NOTICES.md`
   covering 11 SwiftPM components + Mermaid + CodeMirror, and its own header claims
   `build-app.sh` copies it into `Contents/Resources/`. That copy step does not exist (grep for
   "notice" in `build-app.sh`: zero hits) — the shipped bundle has never contained the file.
   Frequency: 1 finding, but total-surface (100% of shipped attribution is currently zero).
   Severity: P1, ship-blocker-class (MIT/Apache-2.0 both require the notice to accompany binary
   redistribution — fine for local-dev-only, a compliance defect the day a bundle leaves the
   machine).
   Evidence: `dependency-audit.md` F4; `packaging-notarization.md` F4 (independently
   corroborating from a different audit dimension).

5. **Attribution scope gap — the biggest unattributed payload has no notices file at all** —
   even if the copy step existed, the notices content omits the entire statically-linked Rust
   surface: ~28 crates including the tree-sitter runtime + 22 grammar crates, pulldown-cmark,
   serde, rmp/rmp-serde, memchr, regex-lite. The generator hand-waves "attributed via the
   rust-core notices" — no such file exists anywhere in the repo. Per CLAUDE.md itself, most of
   the ~60 MB executable **is** these grammar parse tables — i.e. the single largest
   third-party payload in the shipped product carries zero attribution.
   Frequency: 1 structural gap. Severity: P1.
   Evidence: `dependency-audit.md` F5; cross-referenced against
   `rust-core/crates/highlight/Cargo.toml` (22 grammar pins) and CLAUDE.md's own bundle-size
   note about grammar parse-table weight.

6. **Unlocked/floating manifests inside an otherwise-pinned tree** — the CodeMirror build
   workspace (`scripts/codemirror-build/package.json`, 23 exact-pinned direct deps) deliberately
   gitignores `package-lock.json` and `node_modules/`, so every rebuild re-resolves the
   transitive closure (`@lezer/*`, esbuild platform binaries, etc.) to latest-matching, with npm
   lifecycle scripts running by default. This directly contradicts the owner's own global policy
   ("Pin versions exactly in lockable manifests") — `package.json` *is* the lockable manifest
   here, but the lock output is thrown away. The only guard on the resulting 1.1 MB shipped
   `codemirror.js` is a size-window sanity check (100 KB–5 MB), not a content/provenance check.
   Frequency: 1 instance (contained to one build workspace). Severity: P2 (0 known vulns today,
   but the floating-transitive residue is structurally unscanned).
   Evidence: `dependency-audit.md` F6; `Tests/ViewerUITests/CodeMirrorBundleTests.swift:26-34`.

7. **The `scripts/` tooling layer itself — a production-grade, ~62-file, ~5K-LOC orchestration
   subsystem** covering build, sign/notarize, size caps, VM test orchestration, coverage,
   perf profiling, and supply-chain gates, accreted incrementally under numbered tickets
   (TSK-449, TSK-500, TSK-626, TSK-847/848, TSK-1235, TSK-1257, TSK-1547, …), each ticket a
   real production incident turned into a permanent guard. Frequency: this *is* the tooling
   layer (62 files). Severity: net positive — near-zero "AVOID" findings, almost everything
   rated KEEP.
   Evidence: `summaries/code/src-scripts.md` full inventory + "Patterns Worth Porting" (12 named
   patterns) + "Gotchas & Surprises" (11 named incident classes, each with a ticket).

8. **CI shape mismatched to the actual execution environment** — 5 GitHub Actions workflows
   exist (`pr.yml`, `coverage.yml`, `nightly-perf-floor.yml`, `nightly-supply-chain.yml`,
   `nightly-vm.yml`) with good instincts (e.g. `nightly-supply-chain.yml` explicitly avoids
   third-party setup actions), all using movable `@v4` tags rather than SHA-pins — but the repo
   has no GitHub remote (only a local iCloud-backup mirror), so **none of these workflows have
   ever executed**. The "CI" is aspirational configuration, not a running gate; the real gate is
   the local `scripts/test-headless-gate.sh` invoked by the agent loop.
   Frequency: systemic (100% of the CI surface). Severity: P2 today (moot while no remote
   exists), but a real risk the moment a remote is added (movable tags = standard supply-chain
   soft spot at that point) and a real coverage gap today (the nightly-supply-chain lane exists
   for exactly the CVE class in #2/#3 and has literally never run).
   Evidence: `dependency-audit.md` F2, F10; `git remote -v` → only `icloud-backup`.

---

## What worked — earned its keep

- **Exact-pin + minimal-feature-list discipline, enforced with a documented rationale trail.**
  Every cargo workspace dep is `=x.y.z` with `default-features = false` + an explicit feature
  list + a per-dep owner-approval comment (`rust-core/Cargo.toml:35-73`); every SwiftPM grammar
  dep is `exact:` with the TSK-974 rationale codified in-manifest. `--locked` is load-bearing in
  every cargo invocation (`scripts/rust-core-gate.sh`, `scripts/build-rust-core.sh`), so drift
  fails the gate instead of silently re-resolving. This is the CLAUDE.md dependency-approval
  policy actually showing up in the manifests, not just as prose. (`dependency-audit.md`
  positive observations.)
- **`deny.toml` genuinely tightened, not init-default theater** — crates.io-only sources,
  `multiple-versions = "deny"` with each skip individually justified and expiry-conditioned, a
  license allowlist with a single scoped MPL-2.0 exception (cbindgen, reasoned). This is the
  kind of dep-gate that catches real drift rather than being a box-ticking exercise.
  (`dependency-audit.md`.)
- **Vendored-bundle integrity has real teeth even where the *freshness* story failed.** Mermaid
  ships with a provenance manifest (source URL, SHA-256, fetch date, refresh procedure) plus a
  test that re-hashes the vendored bytes against the manifest
  (`Tests/ViewerCoreTests/MermaidVendorTests.swift`); the vendored tree-sitter-javascript
  scanner carries the same pattern (PROVENANCE banner + drift-hash guard,
  `Sources/CTSPatchJavaScript/scanner.c:1-27`). This is the correct shape — the miss was
  *scheduling a refresh*, not the integrity mechanism itself.
- **No runtime dependency acquisition anywhere.** LSP servers are `PATH`-discovered with install
  *instructions*, never auto-downloaded; Mermaid/CodeMirror are vendored, no CDN; rusqlite uses
  the system libsqlite3 (no `bundled` feature, so no vendored C database enters the supply
  chain). Zero URLSession/download call sites outside 3 reviewed hits.
  (`dependency-audit.md` positive observations, methodology section.)
- **Scoping kept heavy trees out of the shipping graph.** `default-members` excludes the
  ratatui/crossterm TUI tree and the wasm-arm entries from the app link entirely — 187 packages
  in `Cargo.lock` but only ~35 in the shipping staticlib graph. Cheap to design in, expensive to
  retrofit onto a monolithic workspace.
- **The `scripts/` layer as a whole.** Near-unanimous KEEP verdict across 62 files; specific
  patterns worth naming for direct port (see Portable Rules below). The size-guardrail,
  header-staleness, and staleness-guard scripts each map 1:1 to a real production incident that
  recurred until it got a permanent script-level guard — i.e. the tooling layer is a genuine
  institutional-memory artifact, not boilerplate.
- **Dev-machine dependency hygiene applied consistently, including to tooling choices** — the
  cargo-mutants rejection ("an external tool's `cargo install` compiles its full transitive tree
  locally — every build.rs + proc-macro runs, so it is NOT exempt from dep-approval") is a
  correct and unusually disciplined extension of the minimal-deps policy to the *developer's own
  machine*, not just the shipped product. (CLAUDE.md rider; `MEMORY.md`
  `feedback_dependency_hygiene_includes_dev_machine.md`.)

---

## What hurt — costly failures and root-cause mechanism

- **Policy-strength ≠ execution-strength: "the audit lane exists" was treated as equivalent to
  "the audit runs."** The mechanism is a classic automation gap: three independently
  well-designed scanning lanes (cargo-deny/audit, SwiftPM watch, vendor-SHA tests) were each
  validated once at build time, but none had an *owner* — no cron, no CI trigger that actually
  fires (repo has no remote), no board ticket auto-filed on red. The failure mode isn't "we
  forgot to write a scanner," it's "we wrote three scanners and none of them are wired to a
  clock." Root cause: the team conflated "the script exists and passes when I run it by hand"
  with "this is a standing gate" — the same class of gap CLAUDE.md's own automated-guidance
  section warns about elsewhere (headless gate vs render-confirm). Concrete cost: 11 months of
  unnoticed published CVEs in a component that sits directly in the untrusted-input path (open
  a `.md` → render an attacker's mermaid block). (`dependency-audit.md` F1, F2.)
- **The attribution pipeline was built to spec and then the final wiring step was dropped and
  nobody noticed for the life of the project.** The generator's own header describes the
  intended contract ("`build-app.sh` copies the generated file into `Contents/Resources/`");
  that line was never true. This is a "consumption ≠ completion" instance — a close cousin of
  the project's own most-cited anti-pattern (`d-docs-root-2of2`: "engine ported + FFI complete ≠
  feature shipped"), just in the tooling domain instead of the feature domain. Root cause:
  no test asserts the notices file is present in the *assembled bundle* — every test that exists
  checks the *generator's output*, none checks the *bundle's contents*. The verification
  boundary was drawn one stage too early.
- **The rejected-dependency alternative (DIY mutation testing) was never actually built.** The
  cargo-mutants rejection was the right call on dep-hygiene grounds, but the backlog shows the
  DIY replacement (`TSK-1137`) is *still* an open, unstarted item in the design-first epic queue
  two months later (`BACKLOG.md:235`). Rejecting a dependency without following through on the
  in-house alternative leaves a capability gap indefinitely — the policy correctly avoided one
  cost but silently accepted a different one (mutation-testing coverage never actually exists in
  this codebase) without that trade-off being made explicit anywhere.
- **A deliberately-unlocked manifest inside an otherwise-strict pin regime is an inconsistency
  that's easy to miss precisely because everything *around* it looks disciplined.** The
  CodeMirror build workspace's gitignored lockfile survived because reviewers' mental model was
  "this project pins everything" — the one place it doesn't is exactly the kind of local
  exception that erodes a policy's credibility over time, and it directly contradicts the
  owner's own standing instruction. (`dependency-audit.md` F6.)
- **CI-as-configuration vs CI-as-gate drift.** Five workflow files exist with real engineering
  effort behind them (the nightly-supply-chain workflow explicitly documents *why* it avoids
  third-party setup actions), but because there's no GitHub remote, none of it has ever
  executed. This is a subtler cost than "no CI" — it's CI that *looks* present in code review
  and repo browsing, creating false confidence, while providing zero actual coverage. Movable
  `@v4` action tags compound the risk the day a remote does get added.

---

## Design implications for the rebuild

**Do differently from day 1:**

1. **Wire the attribution copy step and a bundle-content assertion together, in the same PR that
   creates the generator.** Never let "generate the file" and "ship the file" be two different
   tickets separated in time — that gap is exactly what let this rot for the project's entire
   life. Add a test that asserts `Contents/Resources/THIRD_PARTY_NOTICES.md` exists in the
   *assembled bundle* (not just that the generator produces a well-formed file), and fail the
   release build if it's stale (`--check` mode wired into the build gate, not left dangling).
2. **Give every vendored non-source-controlled-ecosystem asset (npm bundles, prebuilt binaries)
   an OSV-scanner lane from day 1, not just the ecosystems your package manager natively
   understands.** The Mermaid CVEs were invisible precisely because the existing lanes covered
   cargo + SwiftPM but nothing watches "a `.min.js` blob we downloaded once." Treat "vendored
   asset with a version pin" as its own first-class dependency category with its own advisory
   query, from the first vendor.
3. **A supply-chain/advisory-watch lane needs an actual executor before it counts as built.** If
   there's no CI host yet (pre-remote, pre-launch), that means a `launchd`/cron entry on the
   dev machine, or — better — a standing item in the autonomous loop's checklist that runs the
   audit scripts on every N-th tick and files a board ticket on red. Don't let "the script
   exists and I ran it once" pass code review as equivalent to "this is monitored."
4. **When rejecting a dependency in favor of a DIY alternative, track the DIY work as a real,
   prioritized ticket from the same day — not an indefinitely-deferred backlog line.** A
   rejected dependency is a decision with two halves (avoid the cost, still get the capability);
   shipping only the first half and letting the second rot is worse than not deciding at all,
   because it looks resolved on the board.
5. **Treat "lockable manifest with no committed lock" as a lint, not a judgment call per
   workspace.** If the project's stated policy is exact-pinning, a CI/pre-commit check that
   greps for gitignored `package-lock.json`/`Cargo.lock`/`Gemfile.lock` etc. anywhere in the
   tree catches the CodeMirror-build-style exception before it ships, rather than relying on
   every future contributor remembering the policy.
6. **Design CI workflows against the actual planned execution substrate from day 1** — if the
   project won't have a GitHub remote for a while, either build the "local scheduled gate"
   pattern as the primary mechanism (with GH Actions as a later addition) or explicitly track
   "workflows exist but have never executed" as a known gap in the project's own status doc, so
   it isn't discovered fresh at a pre-launch audit. SHA-pin `uses:` actions at the point they're
   authored, not deferred to "when a remote appears" — it costs nothing extra to do it now.

**Accept as inherent cost (worth the trade, don't relitigate):**

- The `scripts/` layer's ~5K LOC of build/sign/test/VM orchestration is legitimate complexity —
  it earned its size through real incidents (TSK-449 iCloud xattr races, TSK-500 fd exhaustion,
  TSK-626 header staleness SIGSEGVs, TSK-1547 stale-link tooth). Don't try to build a "simpler"
  version of this layer from scratch; port the specific scripts named below nearly verbatim and
  expect to accrete the same incident classes on a new machine/toolchain combination — budget
  time for it rather than assuming a clean rebuild avoids it.
- Static-linking the Rust core (vs dylib) for hardened-runtime/TCC stability, accepting the
  ~3 MB bundle-size cost and needing a dual size-cap (total + exec) to catch static-linking
  regressions — this trade-off was made deliberately and validated; keep it, don't relitigate
  dylib-vs-static without a concrete forcing function (startup time budget, plugin hot-reload
  need).
- Exact-pin + `--locked` discipline has real day-to-day friction (every bump is a manifest edit
  + review) — that friction is the point; don't loosen it for convenience under deadline
  pressure.

---

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **Every vendored non-package-manager asset (min.js bundles, prebuilt binaries, vendored C
   scanners) gets: (a) a `VENDOR.md`/PROVENANCE header with source URL + SHA-256 + fetch date +
   refresh procedure, (b) a test that re-hashes the vendored bytes against that manifest, AND
   (c) an entry in the advisory-watch script's scan list keyed by name+version — not just "on
   the roadmap," wired at the same commit that vendors the asset.**
2. **License-attribution generation and license-attribution *shipping* are the same ticket, not
   two.** Ship a bundle-content assertion test alongside the generator; wire `--check` into the
   build gate before the generator is considered "done."
3. **Any scanning/audit script that isn't triggered by something with a clock (CI schedule,
   cron, autonomous-loop tick) does not count as "we have supply-chain monitoring."** State
   explicitly, in the script's own header or a status doc, who/what runs it and how often — if
   the answer is "nobody, yet," track that as its own P1, not an implicit assumption.
4. **A dependency-rejection decision (e.g. "cargo-mutants is out, we'll DIY mutation testing")
   must ship its replacement capability on a tracked timeline, or explicitly document the gap as
   accepted, not silently deferred.**
5. **Dual size-cap guardrails (total bundle + exec-specific) from day 1 for any bundled-artifact
   app** — a single total cap masks a static-linking regression that a dedicated exec cap
   catches; the marginal cost of the second cap is a few lines.
6. **Port these `scripts/` files/patterns nearly verbatim into the rebuild** (per
   `summaries/code/src-scripts.md`'s file-by-file KEEP verdicts): `build-app.sh`'s resource-bundle
   + codesign-xattr-dance orchestration; `build-rust-core.sh`'s content-hash staleness guard +
   force-relink-on-change pattern; `check-bundle-size.sh`'s dual-cap guardrail; `test-in-vm.sh`'s
   `launchctl asuser` GUI-session bridge + fd-limit raise + root-ownership remediation;
   `test-headless-gate.sh`'s sentinel-based tier-enforcement pattern (`TierGateObserver`);
   `sign-and-notarize.sh`'s inside-out signing order (dylibs with derived identifiers → resource
   bundles → remaining Mach-Os → app last, entitlements only on the app); `lib/restage-header.sh`'s
   ABI-header-staleness-forces-recompile trap; `junit-convert.py` for CI-artifact conversion.
   Treat `coverage.sh` (superseded by `coverage-gate.sh`) and `install-mdv-cli.sh` (folded into
   `install-app.sh --with-cli`) as REDO/consolidate-don't-copy examples of the same layer.
7. **Lockable manifests with a gitignored lockfile are a lint failure, not a per-workspace
   judgment call** — grep for the pattern (any `package.json`/`Cargo.toml`/`Gemfile` whose
   corresponding lockfile is gitignored) as a standing pre-commit or CI check, applied
   uniformly across every build sub-workspace (npm bundler workspaces included), not just the
   primary manifest.
8. **CI workflow files should assume "may never execute for months" is the default state during
   early greenfield work (no remote yet)** — build the actually-running local-gate equivalent
   first (a script invoked by the agent loop / a cron entry), treat the GH Actions YAML as the
   *documentation of intent* until a remote exists, and SHA-pin `uses:` actions at authoring time
   rather than deferring the pin to "when it starts mattering."
