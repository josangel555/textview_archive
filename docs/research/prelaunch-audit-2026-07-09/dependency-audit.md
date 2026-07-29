# Pre-launch dependency + supply-chain audit

Dimension: full dependency tree (SwiftPM + cargo + vendored JS + dev-machine tooling) —
pinning, health/maintenance, scale of use, advisory exposure, license attribution.

Date: 2026-07-10 · Auditor: automated review agent · Repo: `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

The project's dependency **posture** is unusually strong: every direct dependency on both
the Swift and Rust sides is exact-pinned, `--locked` is load-bearing in every cargo lane,
`deny.toml` restricts sources to crates.io with a deny-by-default license allowlist,
vendored bundles carry provenance manifests with SHA-256 integrity tests, and there are
zero runtime dependency downloads (LSP servers are discovered on `PATH`, never fetched).

The **execution** has three real holes, all found and verified live:

1. **The vendored Mermaid 11.4.1 bundle carries 6 published advisories** — including two
   XSS sanitizer bypasses (CVE-2025-54880, CVE-2025-54881; fixed 11.10.0) and an
   infinite-loop DoS (CVE-2026-41150; fixed 11.15.0). `securityLevel: 'strict'` is set,
   but these are *bypasses of the sanitizer that strict mode enables*, so it does not
   protect. For an app whose core threat model is "open an untrusted markdown file",
   this is the launch-relevant finding. (P1)
2. **The advisory-watch machinery exists but has no executor.** The repo has no GitHub
   remote, so `.github/workflows/nightly-supply-chain.yml` has never run; local runs are
   manual and evidently not happening — proven by the fact that running
   `scripts/rust-supply-chain-audit.sh` today **fails red** on an untriaged advisory
   (`anyhow` RUSTSEC-2026-0190), and by the Mermaid advisories (published from Aug 2025
   onward) sitting unnoticed in the tree for ~11 months. (P1)
3. **License attribution does not actually ship.** `THIRD_PARTY_NOTICES.md` is not copied
   into the bundle (the generator's claim that `build-app.sh` copies it is stale — the
   copy step doesn't exist), and the notices file omits the entire Rust-crate surface
   statically linked into the executable (~28 third-party crates incl. the tree-sitter
   runtime + 22 grammar crates, pulldown-cmark, serde, rmp/rmp-serde, memchr,
   regex-lite). MIT/Apache-2.0 both require the license text to accompany binary
   distributions — a compliance gap for a public launch. (P1)

Everything else is quality-level: a missing npm lockfile for the CodeMirror build
workspace, a currently-red audit lane fixable with a one-line lock bump, a stale ratatui
pin dragging four documented audit exceptions, and a handful of policy inconsistencies.

**Verdict: no P0. Three P1s, all S–M fixes, none one-way-door. The dependency tree itself
is clean against OSV.dev as of today (2026-07-10) apart from the items above.**

---

## Methodology

Examined (all paths absolute under the repo root):

- **SwiftPM**: `Package.swift` (10 direct packages, pin styles, target wiring),
  `Package.resolved` (10 pins incl. 2 transitives), upstream freshness spot-checks.
- **Cargo**: `rust-core/Cargo.toml` (workspace deps + lints + profiles), all 7 crate
  manifests under `rust-core/crates/*/Cargo.toml`, `rust-core/Cargo.lock`
  (187 packages — full reverse-dependency graph computed with a script),
  `rust-core/deny.toml`, `rust-core/.cargo/config.toml`, `rust-core/clippy.toml`.
- **Advisory scanning (live)**: `osv-scanner 2.0.2` over `Cargo.lock`; OSV.dev API batch
  queries over all 23 npm pins in `scripts/codemirror-build/package.json` and over
  `mermaid@11.4.1`; ran the repo's own `scripts/rust-supply-chain-audit.sh`
  (cargo-deny + cargo-audit) and `scripts/swiftpm-advisory-watch.sh` end-to-end.
- **Vendored assets**: `Sources/ViewerUI/Resources/mermaid/` (bundle + VENDOR.md + shim
  config), `Sources/ViewerUI/Resources/codemirror/` (locally built bundle),
  `Sources/CTSPatchJavaScript/` (vendored scanner.c), `Sources/ViewerCore/Highlight/Queries/`
  (vendored .scm), integrity tests (`Tests/ViewerCoreTests/MermaidVendorTests.swift`,
  `Tests/ViewerCoreTests/CTSPatchProvenanceTests.swift`,
  `Tests/ViewerUITests/CodeMirrorBundleTests.swift`).
- **Attribution**: `THIRD_PARTY_NOTICES.md` (all 13 sections), `scripts/gen-third-party-notices.sh`,
  the assembled bundle at `dist/TextView.app/Contents/Resources/`.
- **CI / process**: all 5 workflows under `.github/workflows/`, `scripts/rust-core-gate.sh`,
  `scripts/build-rust-core.sh`, `scripts/build-app.sh`, git remotes.
- **Runtime supply chain**: grep for `URLSession`/download paths in `Sources/` (3 hits, all
  reviewed), LSP server acquisition (`Sources/ViewerCore/LSP/LSPLanguage.swift`,
  `LSPDiscovery.swift`), plugin execution surface (`Sources/ViewerCore/Plugins/PluginSubprocessHost.swift`).
- **Dev-machine tooling**: audit-tool install channels, the npm/esbuild build workspace,
  cbindgen build-dep tree.

Scale-of-use context: of the 187 packages in `Cargo.lock`, the **shipping staticlib graph**
(`default-members` core+ffi+serve, macOS targets) is ~35 crates; the rest are the tui
front-end (ratatui tree), dev/test (proptest), build tools (cbindgen tree), and
wasm-target-only entries that never compile on macOS (lockfiles are target-agnostic).

---

## Findings

### F1 (P1) — Vendored Mermaid 11.4.1 has 6 published advisories, incl. 2 XSS and a DoS

- **Files**: `Sources/ViewerUI/Resources/mermaid/mermaid.min.js` (the 2.45 MB bundle),
  `Sources/ViewerUI/Resources/mermaid/VENDOR.md:4-9` (pins `11.4.1`, fetched 2026-05-17).
- **Evidence** (OSV.dev API query for `mermaid@11.4.1`, 2026-07-10):

  | Advisory | Alias | Class | Fixed in |
  |---|---|---|---|
  | GHSA-8gwm-58g9-j8pw | CVE-2025-54880 | XSS via architecture-diagram `iconText` | 11.10.0 |
  | GHSA-7rqq-prvp-x9jh | CVE-2025-54881 | XSS via sequence-diagram labels | 11.10.0 |
  | GHSA-6m6c-36f7-fhxh | CVE-2026-41150 | Gantt-chart infinite-loop DoS | 11.15.0 |
  | GHSA-ghcm-xqfw-q4vr | CVE-2026-41149 | HTML injection via state-diagram `classDef` | 11.15.0 |
  | GHSA-xcj9-5m2h-648r | CVE-2026-41148 | CSS injection via `classDefs` | 11.15.0 |
  | GHSA-87f9-hvmw-gh4p | CVE-2026-41159 | CSS injection via configuration | 11.15.0 |

- **Mitigations present**: `mermaid-shim.js:38` sets `securityLevel: 'strict'` and
  `flowchart.htmlLabels: false` — good defaults. But the two XSS advisories are
  **sanitizer bypasses** (improper sanitization inside the path strict mode relies on),
  so strict mode does not neutralize them; the DoS is unaffected by security level.
- **Impact**: the app's core use case is opening untrusted `.md` files; a crafted mermaid
  code block executes script inside the rendered-markdown WKWebView (same WebView that
  hosts the document; see `docs/EGRESS.md` for what that context can reach) or hangs
  rendering (DoS).
- **Fix**: re-vendor `mermaid@11.15.0` (or current latest) following the documented
  procedure in `VENDOR.md` (download → diff SHA → update manifest →
  `swift test --filter MermaidVendorTests`), then run the Mermaid render suites
  (`MermaidRenderModelTests`, `MermaidHostingTests`, VM T5 slices) for render regressions.
- **Fix size**: S (procedure is documented and tested). **Fix risk**: careful —
  a major-version-distance bump of a renderer can change diagram output; the existing
  VM render tests are the guard.

### F2 (P1) — Advisory monitoring has no executor: nightly lane never runs, local lane not run

- **Files**: `.github/workflows/nightly-supply-chain.yml` (schedule at line 14),
  `scripts/swiftpm-advisory-watch.sh:75-78` (comment admitting: "This repo has no GitHub
  remote, so the nightly workflow never runs — the LOCAL run is the only live lane"),
  `git remote -v` (only `icloud-backup`, a local CloudDocs mirror).
- **Evidence of consequence** (verified live, 2026-07-10):
  - `bash scripts/rust-supply-chain-audit.sh` **fails**: `error: 1 denied warning found!`
    on untriaged RUSTSEC-2026-0190 (`anyhow 1.0.102`) — see F3.
  - The Mermaid advisories in F1 date from Aug 2025 onward and were never surfaced —
    ~11 months of exposure — because **no lane watches the npm/vendored-JS surface at
    all**: the nightly workflow covers cargo + SwiftPM only, and it never runs anyway.
- **Impact**: the project has three well-built audit lanes (cargo-deny/cargo-audit,
  SwiftPM advisory watch, vendored-bundle SHA tests) that collectively provide **zero
  ongoing coverage** because nothing schedules them, and the one surface with real
  published vulns (vendored npm bundles) has no lane even on paper.
- **Fix**: (a) give the audit scripts a real local scheduler (launchd plist or the owner's
  cron lane) since there is no CI host; (b) add the missing surface — an
  `osv-scanner` (installed at `/opt/homebrew/bin/osv-scanner`) run over
  `scripts/codemirror-build/package.json`'s pins + an explicit mermaid version query, or
  simply extend `swiftpm-advisory-watch.sh`'s pattern to ecosystem=npm for the two
  vendored bundles; (c) make the red-lane output land somewhere the owner/agent loop
  actually reads (e.g. a board ticket filed on failure).
- **Fix size**: M. **Fix risk**: safe.

### F3 (P2) — Rust supply-chain gate currently RED: untriaged `anyhow` advisory (lock-only bump fixes)

- **Files**: `rust-core/Cargo.lock` (`anyhow 1.0.102`),
  `scripts/rust-supply-chain-audit.sh:36-42` (ignore list has only RUSTSEC-2024-0436 and
  RUSTSEC-2026-0002 — not this one).
- **Evidence**: RUSTSEC-2026-0190 — unsoundness in `Error::downcast_mut()`, fixed in
  `anyhow 1.0.103`. Reverse-dep chain (verified from the lock):
  `anyhow ← wit-* ← wasip3 ← getrandom ← tempfile ← cbindgen ← mdvcore-ffi` —
  i.e. **build-tool-only, and the wasip2/wasip3 arm is wasm-target-gated, never compiled
  on macOS**. The shipping staticlib is untouched.
- **Impact**: no shipping-code exposure, but the lane is red, which (a) blocks the lane's
  use as a gate and (b) trains alarm fatigue — exactly what the script's own policy
  header warns against.
- **Fix**: `cargo update -p anyhow --precise 1.0.103` in `rust-core/` (lockfile-only;
  `anyhow` is not a workspace dep so no manifest edit), re-run the audit script to green.
- **Fix size**: S. **Fix risk**: safe.

### F4 (P1) — License attribution does not ship: notices file absent from the bundle

- **Files**: `scripts/gen-third-party-notices.sh:16-18` claims "scripts/build-app.sh …
  copies the generated file into Contents/Resources/ of the assembled bundle";
  `scripts/build-app.sh` contains **no** reference to the notices file
  (case-insensitive grep for "notice": zero hits);
  `dist/TextView.app/Contents/Resources/` (current build) confirms — no
  `THIRD_PARTY_NOTICES.md` present.
- **Impact**: the app bundles MIT/BSD/Apache-2.0 components (cmark, swift-markdown,
  tree-sitter + grammars, Mermaid, CodeMirror 6, …) whose licenses require the copyright
  notice + license text to accompany binary redistribution. Fine while the app is
  local-dev-only; a compliance defect the day a bundle leaves the machine — which is what
  "pre-launch" means.
- **Fix**: add the copy step to `scripts/build-app.sh` (one `cp` + a bundle-presence
  assertion), and wire `gen-third-party-notices.sh --check` into a gate (see F7) so the
  shipped copy can't go stale.
- **Fix size**: S. **Fix risk**: safe.

### F5 (P1) — Notices omit the entire statically-linked Rust-crate surface (the promised "rust-core notices" don't exist)

- **Files**: `THIRD_PARTY_NOTICES.md` — 13 sections total (lines 23–707): 11 SwiftPM
  components + Mermaid + CodeMirror. Zero Rust crates (grep for
  `pulldown|rusqlite|regex-lite|memchr|Rust`: no hits).
  `scripts/gen-third-party-notices.sh:53-54` hand-waves: "(The rust core carries its own
  copy of the full grammar set — those are attributed via the rust-core notices, not this
  Swift-package list.)" — **no such rust-core notices file exists anywhere in the repo**.
- **Evidence of what actually links into the shipped executable**: `rust-core/crates/ffi/Cargo.toml`
  (`mdvcore-highlight` is a `[dependencies]` entry of the staticlib) →
  `rust-core/crates/highlight/Cargo.toml` pins `tree-sitter =0.25.10`,
  `tree-sitter-highlight =0.25.10`, **22 grammar crates** (json, rust, javascript,
  typescript, java, c, cpp, c-sharp, swift, kotlin-ng, lua, python, bash, yaml, html,
  css, go, ruby, md, xml, sequel); plus core's `pulldown-cmark`, `serde`, `rmp`/`rmp-serde`,
  `memchr`, `regex-lite`, `bitflags`, `unicase`, `byteorder`, `streaming-iterator`,
  `tree-sitter-language`, `cc`-built parser objects. All MIT or Apache-2.0 — all require
  attribution, none get it. (CLAUDE.md itself notes most of the ~60 MB exec **is** these
  grammar parse tables — the biggest third-party payload in the product is the one with
  no attribution.)
- **Fix**: extend `gen-third-party-notices.sh` with a cargo section — e.g.
  `cargo deny list -f json` or `cargo metadata` over the `dist`-profile graph of
  `default-members`, emitting name/version/license + license texts (crates ship
  `LICENSE*` files in the cargo registry cache). Keep the fail-loud posture the script
  already has for missing license files.
- **Fix size**: M. **Fix risk**: safe.

### F6 (P2) — CodeMirror build workspace has no lockfile: transitive npm tree floats on every rebuild

- **Files**: `scripts/codemirror-build/package.json` (23 direct deps, all exact-pinned —
  good), `scripts/codemirror-build/.gitignore:1-2` — `node_modules/` **and**
  `package-lock.json` are deliberately gitignored.
- **Evidence**: with no committed lockfile, `npm install` re-resolves the transitive
  closure (`@lezer/*`, `@marijn/find-cluster-break`, `style-mod`, `w3c-keyname`, `crelt`,
  esbuild's per-platform binary packages, …) to *latest-matching* at every rebuild, and
  npm lifecycle scripts run by default. The output `codemirror.js` is a 1.1 MB committed
  artifact whose only regression guard is a size-window check
  (`Tests/ViewerUITests/CodeMirrorBundleTests.swift:26-34` — 100 KB < size < 5 MB), so a
  transitive-dep compromise or drift lands invisibly in the shipped editor WebView.
  This directly contradicts the owner's global pin policy ("Pin versions exactly in
  lockable manifests") — `package.json` **is** the lockable manifest here.
- **OSV status**: all 23 direct pins queried against OSV.dev today — 0 known vulns
  (incl. `esbuild 0.25.0`, which is the first version past GHSA-67mh-4wv8-2f99).
  The floating transitives are the unscanned residue.
- **Fix**: commit `package-lock.json` (drop it from `.gitignore`), rebuild via
  `npm ci --ignore-scripts` in the documented refresh flow, and add the lockfile to the
  osv-scanner lane from F2.
- **Fix size**: S. **Fix risk**: safe.

### F7 (P2) — `gen-third-party-notices.sh --check` is wired into no gate

- **Files**: `scripts/gen-third-party-notices.sh:22-26` (a `--check` mode exists,
  exit 3 on stale); grep across `.github/workflows/*.yml` and
  `scripts/test-headless-gate.sh`: no caller.
- **Impact**: the notices file only changes when someone remembers to run the script;
  a dependency bump (e.g. the F1 mermaid re-vendor) silently strands the attribution at
  the old version. Cheap teeth already built — just not attached.
- **Fix**: add `bash scripts/gen-third-party-notices.sh --check` to `scripts/build-app.sh`
  (it requires resolved checkouts, which a build has) or the headless gate.
- **Fix size**: S. **Fix risk**: safe.

### F8 (P3) — ratatui 0.29.0 pin (Oct 2024) drags 2 triaged advisories + 2 duplicate-version exceptions

- **Files**: `rust-core/crates/tui/Cargo.toml` (`ratatui = "=0.29.0"`);
  `scripts/rust-supply-chain-audit.sh:38-41` (ignores RUSTSEC-2024-0436 `paste`
  unmaintained + RUSTSEC-2026-0002 `lru 0.12.5` unsound, both ratatui-only);
  `rust-core/deny.toml` `[bans].skip` (`unicode-width`, `rustix` dupes, both
  ratatui/crossterm-driven).
- **Impact**: tui-only (not in `default-members`, never in the app staticlib), but four
  standing audit exceptions is drift debt that each future triage has to re-justify;
  `crossterm 0.28.1` is similarly a generation old. The exceptions' own comments say
  "drops when ratatui bumps".
- **Fix**: bump ratatui to the current 0.30-line (pulls newer lru/unicode-width, drops
  paste), delete the four exceptions, re-run the audit script.
- **Fix size**: M (ratatui 0.29→0.30 had API churn in the TUI surface). **Fix risk**: careful.

### F9 (P3) — swift-markdown is the one floating SwiftPM range; transitives pinned only by Package.resolved

- **Files**: `Package.swift:57` — `.upToNextMinor(from: "0.8.0")` (floats 0.8.x patches),
  vs. the repo's own TSK-974 PIN POLICY (`Package.swift:63-74`) that made every grammar
  `exact:` precisely to avoid unreviewed drift. Transitives `swift-cmark 0.8.0` and
  `tree-sitter 0.25.10` (`Package.resolved:5-12,32-39`) are constrained only by the
  committed resolved file — a `swift package update` walks them wherever the direct
  deps' ranges allow.
- **Impact**: low — `Package.resolved` is committed and CI restores from it; this is a
  policy-consistency + `swift package update` blast-radius item, not a live hole.
- **Fix**: change to `exact: "0.8.0"` for swift-markdown (one line); note in the manifest
  that transitive drift is accepted-by-resolved-file (or pin the tree-sitter runtime via
  an explicit dependency entry if stricter is wanted).
- **Fix size**: S. **Fix risk**: safe.

### F10 (P3) — GitHub Actions tag-pinned, not SHA-pinned (currently moot: no remote)

- **Files**: `.github/workflows/*.yml` — 17 `uses:` sites, all `@v4` movable tags
  (`actions/checkout@v4`, `actions/cache@v4`, `actions/upload-artifact@v4`).
- **Impact**: none today (no GitHub remote → workflows never execute), but the moment the
  repo is pushed to GitHub for launch, movable-tag actions are the standard
  supply-chain soft spot. The workflows otherwise show good instincts
  (`nightly-supply-chain.yml:6-8`: "Deliberately NO third-party setup actions").
- **Fix**: pin each action to a full commit SHA with the tag in a comment, when/if a
  remote appears.
- **Fix size**: S. **Fix risk**: safe.

### F11 (P3) — SwiftPM advisory watch covers only ecosystem=swift; C-level vulns in bundled parsers can be filed elsewhere

- **Files**: `scripts/swiftpm-advisory-watch.sh` (matches pins against the GitHub
  Advisory DB `ecosystem=swift` feed — 61 advisories total today, watch PASSED on the
  10 pins when run live).
- **Evidence/impact**: the packages that motivated the watch (grammars, swift-cmark) are
  thin Swift wrappers over C parsers; historical CVEs for cmark-gfm and tree-sitter
  grammars are typically filed against the C project or the crates.io/npm packagings,
  not the Swift ecosystem — the swift feed is near-empty by construction, so a green
  can be a coverage illusion. The Rust side incidentally covers the same grammar C code
  via crates.io advisories (cargo-audit), which softens this — but only for the 22
  grammars the Rust tree also carries, and only if the F2 lane actually runs.
- **Fix**: document the limitation in the script header, and add name-keyed queries
  against the crates.io/npm ecosystems for the C-parser packages (or fold into the F2
  osv-scanner lane, which handles multi-ecosystem naturally).
- **Fix size**: S–M. **Fix risk**: safe.

---

## Positive observations

Worth keeping and worth copying to other projects:

- **Exact-pin discipline, both sides.** All cargo workspace deps `=x.y.z` with
  `default-features = false` + explicit minimal feature lists and per-dep owner-approval
  provenance comments (`rust-core/Cargo.toml:35-73`); all SwiftPM grammar deps `exact:`
  with the rationale codified in-manifest (`Package.swift:63-96`, TSK-974). The
  tree-sitter-swift branch dependency is pinned to a raw revision with a documented
  re-vendor + re-diff procedure — the right call for a generated-files branch.
- **`--locked` is load-bearing** in every cargo lane (`scripts/rust-core-gate.sh:49-53`,
  `scripts/build-rust-core.sh:86-90`), so the committed `Cargo.lock` is authoritative and
  drift fails the gate rather than auto-resolving.
- **`deny.toml` is genuinely tightened**, not init-default theater: sources allowlisted to
  crates.io only (`unknown-registry`/`unknown-git = "deny"`), `multiple-versions = "deny"`
  with each skip individually justified and expiry-conditioned, license allowlist with the
  single MPL-2.0 exception scoped to cbindgen and reasoned, graph pinned to the two
  Apple targets actually built.
- **Vendored-bundle integrity has teeth**: Mermaid ships with a provenance manifest
  (`VENDOR.md`: source URL, SHA-256, fetch date, refresh procedure) and a test that
  re-hashes the vendored bytes against the manifest
  (`Tests/ViewerCoreTests/MermaidVendorTests.swift`); the vendored tree-sitter-javascript
  scanner carries a PROVENANCE banner (upstream URL, revision, license, why-this-exists)
  plus its own drift-hash guard (`Sources/CTSPatchJavaScript/scanner.c:1-27`,
  `Tests/ViewerCoreTests/CTSPatchProvenanceTests.swift`).
- **No runtime dependency acquisition.** LSP servers are discovered on `PATH`
  (`Sources/ViewerCore/LSP/LSPDiscovery.swift`) with install *instructions*, not
  auto-downloads (`LSPLanguage.swift:89`); Mermaid/CodeMirror are vendored, no CDN
  (`docs/EGRESS.md` inventories the egress surface explicitly); rusqlite uses the
  **system** libsqlite3 (no `bundled` → no vendored C database in the supply chain).
- **Scoping keeps heavy trees out of the shipping graph**: `default-members` excludes
  tui/web, so ratatui/crossterm never enter the merge gate or the app link; proptest is
  dev-only; cbindgen is build-only; wasm-arm lock entries never compile on macOS.
- **npm pins are clean against OSV.dev** (all 23, incl. esbuild 0.25.0), and dev-machine
  dep hygiene is an explicit written policy (CLAUDE.md rider: `cargo install` counts as
  supply-chain surface; cargo-mutants was rejected on that basis).
- **Small-dep vendoring policy is satisfied** — there are no <1000-LOC library deps that
  should be vendored: the Swift tree has zero utility packages; the Rust leaf crates
  (memchr, bitflags, unicase, …) are transitive ecosystem staples, and everything small
  (mermaid-shim, canvas.js, the web front-end's HTTP server, the serve envelope codec)
  is already hand-rolled first-party.

---

## Coverage gaps (not examined)

- **Reachability**: OSV/cargo-audit findings were traced to dep-graph position
  (shipping vs build vs target-gated) but no call-graph reachability analysis was run.
- **Package.resolved could not be machine-scanned**: `osv-scanner 2.0.2`'s extractor
  rejects it ("could not determine extractor"); coverage came from the repo's own watch
  script + manual review instead.
- **Vendored bundle SHAs were not independently re-derived from upstream** (no re-download
  of `mermaid@11.4.1` from npm to confirm the recorded hash matches upstream bytes); the
  in-repo hash-vs-manifest test was trusted.
- **Upstream freshness of every pin** was spot-checked (crates.io API for
  tree-sitter-sequel/kotlin-ng — both at newest; GitHub API for swift-markdown was
  rate-limited), not exhaustively diffed against latest for all ~40 direct pins.
- **Homebrew/dev-machine global tool drift** (osv-scanner, cargo-deny versions themselves)
  is out of scope here — the `home-deps-audit` lane covers it.
- **The plugin subsystem's third-party plugin surface** (user-installed executables under
  Application Support, run via `PluginSubprocessHost`) is a runtime-extension trust
  question for the security-review dimension, not a build-time dependency; noted, not
  audited here.
- **The `mdvcore-pm` crate** (rusqlite store) is workspace-membered but outside
  `default-members`; its manifest was reviewed, its usage/linkage depth was not.
- Licenses were reviewed for *attribution shipping*, not for a full compatibility matrix
  (all observed licenses are permissive; deny.toml enforces the allowlist).
