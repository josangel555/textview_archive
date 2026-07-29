# Supply chain — dedicated inventory (markdown_viewer, as of 2026-07-11)

Dimension: what the app actually ships/builds with — enumerated by ecosystem, with version,
pin quality, update/advisory mechanism, patch-lag evidence, and attribution status. Distinct
from `aspects/deps-tooling.md` (which covers *policy outcomes and process patterns*); this
file is the flat **inventory** those findings were derived from, re-verified against the repo
at HEAD. Primary source: `docs/research/prelaunch-audit-2026-07-09/dependency-audit.md`
(live OSV.dev queries run 2026-07-10); re-checked here against `Package.swift`,
`Package.resolved`, `rust-core/Cargo.toml`, `rust-core/deny.toml`, the audit scripts, and the
vendored-JS manifests directly.

---

## 1. SwiftPM dependencies

Source: `Package.swift` (dependency block), `Package.resolved` (10 pins).

| Package | Pin style | Resolved version/revision | Notes |
|---|---|---|---|
| `swift-markdown` (apple) | `.upToNextMinor(from: "0.8.0")` — the **one floating range** in the manifest | 0.8.0 | Transitively pulls `swift-cmark 0.8.0` (pinned only via `Package.resolved`, no direct manifest entry) |
| `SwiftTreeSitter` (ChimeHQ) | `exact: "0.25.0"` | 0.25.0 | Binding layer, TSK-974 pin policy |
| `tree-sitter-json` | `exact: "0.24.8"` | 0.24.8 | |
| `tree-sitter-swift` (alex-pinkus) | raw `revision:` (40-char SHA), not a tag | `7b7909f2f6b9414be0958275f4c8e5d69c3bca43` | Deliberate: upstream ships `parser.c` only on the `with-generated-files` branch, no tags to track; revision pin avoids silently rewriting the generated parser on branch push |
| `tree-sitter-xml` | `exact: "0.7.0"` | 0.7.0 | |
| `tree-sitter-javascript` | `exact: "0.25.0"` | 0.25.0 | |
| `tree-sitter-typescript` | `exact: "0.23.2"` | 0.23.2 | tsx grammar shares this dylib |
| `tree-sitter-markdown` | `exact: "0.5.3"` | 0.5.3 | |
| `tree-sitter` (runtime, transitive) | pinned only via `Package.resolved` | 0.25.10 | No direct manifest entry — floats with whatever the direct deps' resolution picks unless `Package.resolved` is committed (it is) |

**Pin-quality verdict:** 9 of 10 direct/notable pins are `exact:`/revision-pinned by deliberate
policy (TSK-974, documented in-manifest with the rationale: `from:`/caret ranges on pre-1.0
grammar packages can silently walk a minor version and change tokenization/node-kind names with
no review). The one exception — `swift-markdown`'s `.upToNextMinor` — is itself a considered
choice (capped to patch-level drift within 0.8.x) but is inconsistent with the "everything
`exact:`" story the grammar pins tell; flagged as F9 in the source audit (P3, one-line fix).
`Package.resolved` is committed, so CI/local builds are reproducible regardless of manifest
floatiness — the floating range only matters at the moment someone runs
`swift package update`.

**Update/advisory mechanism:** `scripts/swiftpm-advisory-watch.sh` (TSK-628) — queries the
GitHub Advisory Database (`ecosystem=swift`) for all pins in `Package.resolved`, matches by
repo-URL tail. Real, tested (`AdvisoryWatchScriptTests`, a hermetic fixture-driven seam), and
honest-by-design: an unreachable API **fails** the run under `MDV_ADVISORY_STRICT=1` (no silent
pass-when-offline). **Coverage caveat (F11 in the source audit):** it only queries
`ecosystem=swift`. The packages it watches are thin Swift bindings over C parsers (tree-sitter
grammars, swift-cmark); historical CVEs for that class are typically filed against the
upstream C/crates.io/npm packaging, not the Swift ecosystem wrapper — so a green result here can
be a coverage illusion for the actual vulnerable code. The Rust side's `cargo-audit` run
incidentally covers the same grammar C code via crates.io advisories for the grammars also
carried in `rust-core` — but only for the 22 grammars present there, and only if that lane
actually executes (it doesn't — see §5).

**Patch-lag evidence:** live run confirmed the swift advisory feed had 61 total advisories at
audit time and the watch PASSED (no hits) against the 10 current pins — i.e. no known-lagging
CVE on the Swift side today. This is a point-in-time result from a script that has **no
scheduled executor** (§5), so "PASSED once" is not equivalent to "monitored."

**Attribution status:** `THIRD_PARTY_NOTICES.md` covers all SwiftPM packages (11 sections,
generator reads each checkout's real `LICENSE`/`NOTICE` file rather than hand-maintaining text)
— the one part of the attribution story that is actually correct on the generation side. It
still fails to *ship* (§4).

---

## 2. Cargo dependencies (rust-core)

Source: `rust-core/Cargo.toml` (workspace deps), `rust-core/Cargo.lock` (187 packages total),
`rust-core/deny.toml`.

**Scale of use:** 187 packages resolved in the lockfile; the **shipping staticlib graph**
(`default-members = ["crates/core", "crates/ffi", "crates/serve"]`, macOS targets only) is
roughly 35 crates. The remainder is the `tui` front-end's ratatui/crossterm tree (never built by
the default members or the app link), `proptest` (dev-only), `cbindgen`'s build-time tree, and
wasm-target-gated lock entries that never compile on macOS (lockfiles are target-agnostic, so
they still appear).

### Direct workspace deps (`[workspace.dependencies]`)

| Crate | Version pin | Feature posture | Why it's here |
|---|---|---|---|
| `serde` | `=1.0.228` | `default-features=false`, `["derive","alloc"]` | core serialization |
| `rmp-serde` | `=1.3.0` | default | MessagePack envelope |
| `cbindgen` | `=0.29.3` | `default-features=false` | build-dep only, generates the C header; never linked into shipping code |
| `regex-lite` | `=0.1.8` | `default-features=false`, `["std","string"]` | zero-transitive-dep, structurally-linear-time regex (ReDoS-immune by construction) — owner-approved 2026-06-12 for the find-engine port |
| `pulldown-cmark` | `=0.13.4` | `default-features=false` (drops `html`, `simd`, the `getopts` bin dep) | CommonMark+GFM parser for the markdown-engine port; iterative (no C-stack-overflow class) |
| `memchr` | `=2.8.1` | `default-features=false`, `["alloc"]` | SIMD substring scan; zero *new* transitive surface — already in-tree via pulldown-cmark/regex-lite, this just promotes it to direct |
| `proptest` | `=1.9.0` | `default-features=false`, `["std"]` | dev-only property-test lane, never shipped |
| `rusqlite` | `=0.39.0` | `default-features=false` (no `bundled`) | project-management store; uses the **system** libsqlite3 — deliberately avoids vendoring a C database into the supply chain |

Every entry is exact-pinned (`=x.y.z`), carries an inline owner-approval comment with date and
ticket, and states the *explicit minimal feature list* rather than accepting defaults — this is
the CLAUDE.md dependency-approval policy actually present in the manifest, not just prose
elsewhere.

### Notable transitives (shipping graph, from the source audit's reverse-dependency walk)

`tree-sitter =0.25.10`, `tree-sitter-highlight =0.25.10` (pulls `regex`, `regex-automata`,
`regex-syntax`, `aho-corasick`, `streaming-iterator`), `tree-sitter-language =0.1.7`,
**22 grammar crates** linked into `mdvcore-highlight` → `mdvcore-ffi`: json, rust, javascript,
typescript, java, c, cpp, c-sharp, swift, kotlin-ng, lua, python, bash, yaml, html, css, go,
ruby, md, xml, sequel. Plus `bitflags`, `unicase`, `byteorder` pulled in by the above. All
MIT/Apache-2.0.

### Feature hygiene

`--locked` is load-bearing in every cargo invocation the project makes
(`scripts/rust-core-gate.sh`, `scripts/build-rust-core.sh`) — a lockfile/manifest mismatch fails
the build rather than silently re-resolving. `deny.toml` is a genuinely tightened config, not
`cargo deny init` defaults:
- `[graph].targets` scoped to `aarch64-apple-darwin` + `x86_64-apple-darwin` only (avoids
  flagging Windows/Linux-only duplicate-version noise the project never builds).
- `[bans] multiple-versions = "deny"` with a `skip` list of exactly 3 crates
  (`unicode-width`, `hashbrown`, `winnow`, `rustix`), each with a dated justification tied to a
  specific upstream package's lag and a "re-check on bump" note — not a blanket allowance.
- `[licenses] allow` is a closed list (MIT, Apache-2.0, BSD-2/3-Clause, ISC, Unicode-3.0, Zlib)
  with exactly one scoped exception (`cbindgen` → MPL-2.0, reasoned: build-tool-only, never
  linked).
- `[sources] unknown-registry/unknown-git = "deny"`, `allow-registry` restricted to
  crates.io — no unvetted git/registry sources can enter silently.

### Update/advisory mechanism

`scripts/rust-supply-chain-audit.sh` — pairs `cargo deny check licenses bans sources` with
`cargo audit --deny warnings` (cargo-deny 0.18.x cannot yet parse the RustSec DB's CVSS-4.0
entries, so advisories duty is deliberately split to cargo-audit). Two triaged ignores
(`RUSTSEC-2024-0436` paste-unmaintained, `RUSTSEC-2026-0002` lru-unsound), both scoped to the
`tui` front-end and verified via `cargo tree -i` to be absent from the shipping graph — an
actual reachability check, not a blind ignore.

### Patch-lag evidence (live, re-verifiable)

The source audit ran this script live on 2026-07-10 and it **failed red**: `anyhow 1.0.102`
carries `RUSTSEC-2026-0190` (unsoundness in `Error::downcast_mut()`, fixed in 1.0.103),
untriaged (not in the ignore list). Reverse-dependency trace: `anyhow ← wit-* ← wasip3 ←
getrandom ← tempfile ← cbindgen ← mdvcore-ffi` — a **build-tool-only** path (cbindgen's own
dependency tree), and the wasip2/wasip3 arm is wasm-target-gated, never compiled on macOS. So:
zero shipping-code exposure, but the gate itself is currently red on `main` for anyone who runs
it — a one-line `cargo update -p anyhow --precise 1.0.103` fix that nobody has landed, because
nothing runs the script on a schedule (§5). This is direct, dated evidence of exactly the failure
mode the "advisory watch" mechanism exists to catch, sitting unfixed.

**Separately:** `ratatui =0.29.0` (Oct 2024, `tui` front-end only) drags the two triaged
advisories above plus the two `deny.toml` duplicate-version exceptions — four pieces of standing
audit debt attributable to one stale pin, each re-justified rather than resolved.

### Attribution status

**Zero.** No Rust crate — direct or transitive, including the ~35-crate shipping graph and
specifically the 22 grammar crates that make up most of the shipped executable's size — appears
anywhere in `THIRD_PARTY_NOTICES.md`. The generator's own comment claims these are "attributed
via the rust-core notices" — no such file exists anywhere in the repository. This is the single
largest unattributed payload in the shipped product (CLAUDE.md's own bundle-size notes confirm
most of the ~60 MB executable *is* grammar parse tables).

---

## 3. Vendored JS/web assets

### Mermaid

- **File:** `Sources/ViewerUI/Resources/mermaid/mermaid.min.js` (2,571,900 bytes, UMD minified
  build).
- **Version:** 11.4.1, per `Sources/ViewerUI/Resources/mermaid/VENDOR.md`.
- **How it got there:** manual download from `https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js`
  (or `npm pack mermaid@11.4.1`), fetched 2026-05-17, recorded with SHA-256
  (`a43bc1af...d6ddb6f9e`) in `VENDOR.md`. **Not** produced by an in-repo build step — it is a
  one-time manual vendor with a documented refresh procedure (re-download → diff SHA → bump
  manifest → `swift test --filter MermaidVendorTests`).
- **Pin quality:** strong at the *integrity* layer — `MermaidVendorTests` re-hashes the vendored
  bytes against the manifest's recorded SHA-256 on every test run, so silent tampering or an
  unintentional swap fails CI. Weak at the *freshness* layer — nothing checks whether 11.4.1 is
  still current; the manifest is a point-in-time snapshot with no expiry or re-check trigger.
- **Update/advisory mechanism:** **none.** No script watches npm/OSV advisories for this
  package. It is invisible to both `swiftpm-advisory-watch.sh` (Swift-ecosystem only) and
  `rust-supply-chain-audit.sh` (Cargo-ecosystem only) — a vendored `.min.js` blob sits in a gap
  between the two existing lanes.
- **Patch-lag evidence (live, OSV.dev query 2026-07-10):** **6 published advisories** against
  11.4.1, unfixed in the vendored copy for up to ~11 months:

  | Advisory | CVE | Class | Fixed in |
  |---|---|---|---|
  | GHSA-8gwm-58g9-j8pw | CVE-2025-54880 | XSS via architecture-diagram `iconText` | 11.10.0 |
  | GHSA-7rqq-prvp-x9jh | CVE-2025-54881 | XSS via sequence-diagram labels | 11.10.0 |
  | GHSA-6m6c-36f7-fhxh | CVE-2026-41150 | Gantt-chart infinite-loop DoS | 11.15.0 |
  | GHSA-ghcm-xqfw-q4vr | CVE-2026-41149 | HTML injection via state-diagram `classDef` | 11.15.0 |
  | GHSA-xcj9-5m2h-648r | CVE-2026-41148 | CSS injection via `classDefs` | 11.15.0 |
  | GHSA-87f9-hvmw-gh4p | CVE-2026-41159 | CSS injection via configuration | 11.15.0 |

  `mermaid-shim.js` sets `securityLevel: 'strict'` and `flowchart.htmlLabels: false`, but the two
  XSS entries are *sanitizer bypasses* (defects inside the path strict mode relies on) — strict
  mode does not neutralize them. This is directly relevant to the app's threat model: opening an
  untrusted `.md` file with a crafted mermaid fenced block runs inside the same rendered-markdown
  WKWebView the document itself renders in.
- **Attribution status:** one blanket entry in `THIRD_PARTY_NOTICES.md` ("Mermaid 11.4.1 … MIT …
  Copyright (c) 2014-2024 Knut Sveidqvist"). The minified bundle is a fat build embedding
  DOMPurify 3.2.1 (confirmed via its `@license` banner, Apache-2.0/MPL-2.0 dual-licensed,
  © Cure53 — a distinct copyright holder with non-MIT terms), plus cytoscape, dagre, katex,
  lodash, and the d3 family (confirmed by string-count grep) — none of these sub-libraries or
  their licenses are reproduced. No copyleft-only code is present (elkjs/EPL-2.0 is confirmed
  **not** bundled; DOMPurify's dual license lets Apache-2.0 be elected), so this is an
  under-attribution gap, not a license-compliance violation in the license-*choice* sense.

### CodeMirror 6

- **Files:** `Sources/ViewerUI/Resources/codemirror/codemirror.js` (1,105,942 bytes, minified),
  `codemirror.css`, `codemirror.html`.
- **How it got there:** a real build step, not a manual vendor —
  `scripts/codemirror-build/entry.js` + `scripts/codemirror-build/package.json` (23 direct
  `@codemirror/*` / `@replit/codemirror-vim` / `esbuild` deps, every one exact-pinned e.g.
  `"@codemirror/view": "6.43.0"`) run through `esbuild --bundle --format=iife --minify` into the
  Swift resource directory. Documented in `Sources/ViewerUI/Resources/codemirror/BUILD.md`.
- **Pin quality — the one real gap in an otherwise-pinned tree:**
  `scripts/codemirror-build/.gitignore` deliberately excludes **both** `node_modules/` **and**
  `package-lock.json`. All 23 *direct* deps are exact-pinned in `package.json`, but with no
  committed lockfile, every rebuild re-resolves the full transitive closure (`@lezer/*`,
  `@marijn/find-cluster-break`, `style-mod`, `w3c-keyname`, `crelt`, esbuild's per-platform
  binaries) to latest-matching, and npm lifecycle scripts run by default on install. This
  directly contradicts the project's own stated pin policy ("pin versions exactly in lockable
  manifests") — `package.json` *is* a lockable manifest here, and the lock output is thrown away
  rather than committed.
- **Update/advisory mechanism:** none automated. The only regression guard on the shipped
  artifact is a size-window sanity check (`Tests/ViewerUITests/CodeMirrorBundleTests.swift:26-34`,
  100 KB–5 MB), which would not catch a transitive-dependency compromise or a semantically
  different build.
- **Patch-lag evidence:** the source audit queried all 23 direct pins against OSV.dev live
  (2026-07-10) — **0 known vulnerabilities**, including `esbuild 0.25.0` (past
  GHSA-67mh-4wv8-2f99). The floating, unlockfiled *transitive* closure is the structurally
  unscanned residue — clean today by luck/recency, not by a mechanism that would catch drift.
- **Attribution status:** one blanket entry in `THIRD_PARTY_NOTICES.md` ("MIT, © 2018-2021
  Marijn Haverbeke and others") covering all `@codemirror/*` + `@lezer/*` + legacy-modes
  packages. Broadly accurate (all packs genuinely MIT, under the CodeMirror org's umbrella
  license) but doesn't enumerate the ~15 distinct packages or their individual copyright lines —
  polish-level gap, not a violation.

### Vendored C scanner (tree-sitter-javascript patch)

- **File:** `Sources/CTSPatchJavaScript/scanner.c` — a vendored external-scanner source the
  upstream `tree-sitter-javascript` Package.swift only includes via a `FileManager.fileExists`
  check that doesn't resolve correctly in this build setup.
- **Pin quality:** carries a PROVENANCE banner (upstream URL, revision, license, why-vendored)
  plus a drift-hash guard test (`Tests/ViewerCoreTests/CTSPatchProvenanceTests.swift`) — the same
  integrity pattern as Mermaid's `VENDOR.md`, applied consistently to a second vendored-C asset.

---

## 4. Tree-sitter grammars — cross-ecosystem duplication

Grammars ship through **two independent paths** that were not designed together:

1. **SwiftPM path** (§1): 6 grammar packages — json, swift, xml, javascript, typescript,
   markdown — each an `exact:`/revision-pinned SwiftPM package, wrapped as lazy-loaded dylibs
   (`TreeSitterXMLLazy`, etc.) that `GrammarLoader` dlopens at runtime. Used for code-fold +
   structural search only (TSK-854 removed the highlight-only Swift grammar packages).
2. **Rust path** (§2): 22 grammar crates linked directly into `mdvcore-highlight` →
   `mdvcore-ffi`, used for all syntax highlighting. Includes the same json/swift/xml/javascript/
   typescript/markdown grammars *again* (different packaging, same upstream project in most
   cases) plus 16 more (rust, java, c, cpp, c-sharp, kotlin-ng, lua, python, bash, yaml, html,
   css, go, ruby, sequel — none of which have a Swift-side equivalent, since highlighting moved
   fully to Rust).

**Consequence for this inventory:** a grammar CVE could need triage against *two* separate pins
(the SwiftPM package version and the crates.io crate version) for the 6 overlapping grammars,
watched by *two* separate, differently-scoped advisory mechanisms (§1, §2) — neither of which
currently executes on a schedule (§5). The 16 Rust-only grammars are covered *only* by
`cargo-audit`/`cargo-deny` (when run) and have **zero** attribution anywhere (§2, §5).

---

## 5. Does the advisory mechanism actually run? — verified NO

`.github/workflows/nightly-supply-chain.yml` exists, is well-designed (cron `23 7 * * *`,
deliberately no third-party GitHub Actions to avoid widening the supply chain further, installs
`cargo-deny`/`cargo-audit` via `cargo install --locked`, runs `rust-supply-chain-audit.sh` +
`swiftpm-advisory-watch.sh` with `MDV_ADVISORY_STRICT=1`), and **has never executed once**:

```
$ git -C /Users/me/Documents/workspaces/claude/markdown_viewer remote -v
icloud-backup   .../CloudDocs/Documents/workspaces/claude/markdown_viewer (fetch)
icloud-backup   .../CloudDocs/Documents/workspaces/claude/markdown_viewer (push)
```

There is no GitHub remote — only a local iCloud-folder mirror. GitHub Actions workflows require
a GitHub-hosted repo to trigger; a `schedule:` cron on a workflow file that lives only in a local
git tree is inert configuration, not a running gate. The script's own author documented this
explicitly in-line (`scripts/swiftpm-advisory-watch.sh:75-78`, unauthenticated-fallback comment):

> "This repo has no GitHub remote, so the nightly workflow never runs — the LOCAL run is the
> only live lane and must work without gh/credentials."

Same fact holds for `pr.yml`'s `supply-chain-gate` job (which mirrors the nightly lane and would
otherwise be the PR-blocking check) and all 5 workflow files under `.github/workflows/` — 100%
of the CI surface is aspirational. The real, currently-enforced gate is the local
`scripts/test-headless-gate.sh` invoked by the agent loop, which does **not** include the
supply-chain scripts.

**Net effect, demonstrated live:** three individually well-engineered scanning lanes (cargo-deny
+ cargo-audit, SwiftPM advisory watch, vendored-bundle SHA-integrity tests) provide zero ongoing
coverage. This is the direct root cause of both patch-lag findings above (the untriaged `anyhow`
advisory sitting in `Cargo.lock`, and 6 Mermaid CVEs accruing over ~11 months) — not a tooling
failure, a *scheduling* failure. All 17 `uses:` action references across the 5 workflow files use
movable `@v4` tags rather than SHA pins — moot today (nothing executes them) but the standard
supply-chain soft spot the moment a remote is added.

---

## 6. Attribution/notices pipeline — exists on paper, doesn't ship

- **Generator:** `scripts/gen-third-party-notices.sh` produces `THIRD_PARTY_NOTICES.md`
  (13 sections, 735 lines) by reading each SwiftPM checkout's real `LICENSE`/`NOTICE` file —
  source-of-truth-driven, not hand-maintained prose, for the part it covers.
- **Coverage:** 11 SwiftPM components + one blanket Mermaid entry + one blanket CodeMirror entry.
  **Zero** Rust crates (§2), **zero** of the 16 Rust-only grammars, **incomplete** sub-library
  attribution for the Mermaid bundle (§3).
- **Does it ship?** No. The generator's own header and in-script comment both assert
  `scripts/build-app.sh` copies the file into `Contents/Resources/` of the assembled `.app`;
  `build-app.sh` contains zero references to "notice" (case-insensitive grep), and the built
  `dist/TextView.app/Contents/Resources/` directory contains no notices file. Every shipped build
  to date has carried **zero** third-party attribution, despite every observed license
  (MIT/BSD/ISC/Apache-2.0) requiring the license text to accompany binary redistribution.
- **Gate teeth:** `Tests/ViewerCoreTests/ThirdPartyNoticesTests.swift` asserts a hardcoded
  12-name substring list exists in the *repo* file and that it's >2000 chars — it never reads
  `Cargo.lock`, the grammar manifest, or (critically) the *assembled bundle*. A dependency could
  be added or removed on either side without this test ever going red; the missing bundle copy
  (the actual ship-blocker) is invisible to it by construction, since it checks the generator's
  output, not the packaging step's output.

---

## 7. Rebuild's supply-chain policy

The pin discipline and integrity-testing *patterns* here are worth keeping verbatim (see
`aspects/deps-tooling.md` §Portable rules for the full list — exact-pin + `--locked`,
`deny.toml` tightened beyond init-defaults, VENDOR.md + SHA-guard-test per vendored asset). What
this inventory adds is: **pin quality was never actually the weak link — execution was.** Every
concrete failure found (6 unpatched Mermaid CVEs, a red-and-ignored `anyhow` advisory, zero
shipped attribution) traces back to a mechanism that was built once, validated once, and then had
no clock attached to it. The rebuild's policy should therefore be stated as an operational
contract, not just a manifest-hygiene checklist:

1. **Pin + attest + advisory-watch from the FIRST dependency, and "attest" is scoped to include
   vendored non-package-manager assets from day one.** Any dependency added to the project —
   whether it arrives via `Package.resolved`, `Cargo.lock`, a committed npm lockfile, or a
   manually-vendored `.min.js`/binary — gets, in the *same commit that adds it*: an exact version
   pin, a provenance record (source URL + hash + fetch date for vendored assets; the manifest
   pin for package-managed ones), and an entry in whichever advisory-watch script covers its
   ecosystem. "We'll wire up scanning later" is exactly how the Mermaid gap happened — the lane
   for npm/vendored-JS was never built at all, not merely unscheduled.
2. **An advisory-watch script does not count as "built" until it has a clock.** Before any
   scanning lane is marked done on the board, it must name its executor explicitly: a CI schedule
   *on a repo that actually has a remote*, a `launchd`/cron entry on the dev machine, or a
   standing step in an autonomous-loop's per-tick checklist. If the honest answer at build time is
   "nobody runs this yet," track that gap itself as a P1 ticket with an owner, not an implicit
   assumption buried in a script comment. Concretely for this project's situation (no remote yet):
   default to the local-cron/loop-tick mechanism as PRIMARY, and treat the GitHub Actions YAML as
   documentation-of-intent until a remote exists — don't let "the workflow file exists" read as
   "the workflow runs" in any status doc or board ticket.
3. **The license/notices pipeline is a build gate, not a generator you remember to run.** Three
   things ship together as one unit of work, in one PR: (a) the generator, reading real
   `LICENSE`/`NOTICE` files rather than hand-typed text; (b) the packaging step that copies the
   generated file into the shipped bundle; (c) a test that asserts the file's presence *inside the
   assembled bundle* (not just that the generator's own output looks well-formed) and fails the
   release build on staleness (wire `--check` mode into the same gate). Never let "generate" and
   "ship" be separable tickets — that gap is precisely how this project's notices file went
   unshipped for its entire life without anyone noticing.
4. **Every ecosystem present in the shipping graph gets its own named advisory-watch scope, and
   the inventory of "which ecosystems are present" is itself re-derived from the build graph, not
   hand-maintained.** This project's SwiftPM watch and Cargo watch each work correctly within
   their own scope but neither was extended to cover vendored JS, and neither is cross-checked
   against what's actually linked into the shipping binary (e.g. the Rust-linked grammar crates
   have no watch at all despite being the largest attributed-nothing payload). Generate the
   "what ships" list from `cargo metadata --filter-platform <target>` / `swift package
   show-dependencies` / a grep of committed vendor manifests, rather than trusting a document that
   can silently fall out of sync with the manifests.
5. **A lockable manifest with a gitignored lockfile is a lint failure, not a per-workspace
   judgment call**, enforced the same way whether it's the primary `Cargo.toml`/`Package.swift` or
   a secondary npm build workspace three directories deep (this project's CodeMirror-build
   `package.json` is exactly that secondary case, and it slipped past review because reviewers'
   mental model was "this project pins everything").
6. **Cross-ecosystem duplication (the same upstream grammar shipped via both SwiftPM and Cargo)
   should be a deliberate, documented decision with a single source of truth for triage** — not an
   emergent property of two subsystems evolving independently. If the rebuild's architecture keeps
   grammars in both a native-UI package manager and the portable Rust core (plausible, given the
   stated remote-core/multi-UI goal), decide up front which ecosystem is authoritative for
   licensing/advisory purposes for the overlapping set, and document the other as "also present,
   watched via ecosystem X."
