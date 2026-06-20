# Adversarial review — API design & dependency hygiene (2026-06-18)

The Rust-core dependency posture is genuinely strong: exact `=` pins, `default-features = false`
everywhere, a tightened `deny.toml`, a per-crate no-panic lint wall, a build.rs that fails hard on
header drift, and a FFI boundary that is consistently null-checked, panic-guarded, and OOM-bounded.
The defects below are real gaps that survive that discipline: (1) the **Swift** package manifest
violates the project's own stated exact-pinning policy with caret (`from:`) ranges on every
pre-1.0 grammar — the exact anti-pattern its own comment warns against; (2) supply-chain auditing
runs nightly-only and never gates a PR, so a vulnerable/unapproved dependency can land on `main`
and live there for hours; (3) a sizeable slice of the FFI public surface is dead-but-shipping
(per-method symbols superseded by the envelope, plus the entire CSV-session filter/snapshot family
that no production path reaches); and (4) one grammar is pinned to a bare git revision with no
upstream tag, making it reproducible but unauditable. Each is concrete and would bite in a real
maintenance or incident scenario.

### Swift grammar deps use caret ranges, violating the exact-pin policy the manifest itself documents

**Severity:** high

**Location:** `Package.swift:66-94` (every `from:` line); the contradicted policy comment is at
`Package.swift:57-60`.

**Why:** The project's standing rule (global CLAUDE.md "Dependencies and project setup" — *"Pin
versions exactly… No `latest`, no floating ranges"*) and the manifest's own swift-markdown comment
explicitly reason that `from:` on a pre-1.0 package *"would let SwiftPM walk to any future 0.x that
bumps an arbitrary amount of API"* — yet **every** tree-sitter grammar dependency (and
SwiftTreeSitter, all pre-1.0 0.x) uses exactly that `from:` form. `from: "0.23.0"` on a 0.x package
resolves up to (but not including) `0.24.0` per SwiftPM's caret semantics, so a `swift package
update` silently pulls a new *minor* of a parser grammar — precisely the "arbitrary 0.x API bump"
the comment calls out as the reason to avoid `from:`. The generated `parser.c` of a tree-sitter
grammar is unreviewed C that links straight into the app; a drifting minor can change token
classification, regress highlighting, or (worst case) ship a parser.c with a memory bug, with no
review checkpoint. `Package.resolved` pins the *current* resolution, but it is regenerated on every
`update` and is not the policy gate; the manifest is. The inconsistency also means the codebase's
own documented standard is unenforced — a future maintainer reading the swift-markdown comment
reasonably assumes the same care was applied to the 25 grammars below it.

**Fix:** Replace each `from:` with `exact:` (e.g. `.package(url: …, exact: "0.24.8")`) or
`.upToNextMinor(from:)` matching the swift-markdown line, using the versions already locked in
`Package.resolved`. `exact:` is the closest match to the Rust side's `=` pins and the stated policy;
bumps then become a deliberate, reviewable manifest edit + a re-diff of the regenerated `parser.c`,
exactly as the manifest already demands for the alex-pinkus revision pin.

**VERDICT: CONFIRMED** — every grammar (lines 66-94) uses `from:` while the manifest's own
swift-markdown line (60) deliberately uses `.upToNextMinor`; the `from:` form violates the documented
exact-pin policy. (Caveat: the body's mechanism is wrong — SwiftPM `from:` resolves to the next
*major* (`>= 0.23.0, < 1.0.0`), NOT `< 0.24.0`; verified against SwiftPM docs. This makes the drift
window *wider* than stated — any future 0.x — so the finding strengthens; title/location/fix all hold.)

### Supply-chain audit (cargo-audit / cargo-deny) never gates a PR — vulnerable deps land on `main` until the next nightly

**Severity:** high

**Location:** `.github/workflows/nightly-supply-chain.yml:11-14` (schedule + workflow_dispatch only,
no `pull_request` / `push`); `.github/workflows/pr.yml:97` (PR gate runs the rust-core clippy/test
gate but never `cargo audit` or `cargo deny`).

**Why:** `cargo deny check licenses bans sources` and `cargo audit` run *only* on the 07:23 UTC
nightly cron. A PR that edits `Cargo.toml` / `Cargo.lock` to add a dependency with a disallowed
license, a banned duplicate `-sys` version (a C one-definition-rule hazard the `deny.toml` comment
itself calls a *correctness* issue), a yanked crate, or a crate with an open RustSec advisory will
pass the PR gate and merge to `main`. The violation is not detected until hours later, and by then
it is already on the trunk the owner builds from. For a project whose owner gates *every* new
dependency by hand, the automated backstop that would catch a dependency sneaking in via a
transitive `Cargo.lock` bump (or a contributor ignoring the manual-approval rule) is structurally
absent from the merge path. This is a classic "the check exists, but not where it can stop the
bad thing" gap.

**Fix:** Add a fast supply-chain job to `pr.yml` (or a dedicated workflow) triggered on
`pull_request` with `paths: ['rust-core/Cargo.toml', 'rust-core/Cargo.lock', 'rust-core/deny.toml',
'rust-core/crates/**/Cargo.toml']`, running `bash scripts/rust-supply-chain-audit.sh`. It is a
lockfile-only Linux job (the workflow already notes this) — cheap, and only fires when a dependency
manifest actually changes. Keep the nightly for drift (newly-published advisories against unchanged
deps) but make manifest-touching PRs gate on it.

**VERDICT: CONFIRMED** — `pr.yml` runs `rust-core-gate.sh` (clippy + cargo test) but never
`rust-supply-chain-audit.sh`; `nightly-supply-chain.yml` is `schedule` + `workflow_dispatch` only
(no `pull_request`/`push`). License/bans/sources/advisory/yanked checks are absent from the merge
path. (Partial mitigation, worth noting: `rust-core-gate.sh` runs cargo `--locked`, so an *unintended*
transitive `Cargo.lock` drift fails the PR — but a *deliberate* lock edit adding a disallowed-license /
banned-dup / yanked / advisory-bearing crate still passes. The audit/deny backstop is genuinely
missing from PRs; high severity defensible.)

### Per-method FFI symbols are dead-but-exported after the envelope migration

**Severity:** medium

**Location:** `rust-core/crates/ffi/src/lib.rs:376` (`mdvcore_diff_parse`), `:397`
(`mdvcore_diff_hunk_marks`), `:422` (`mdvcore_highlight_runs`), `:451` (`mdvcore_hex_render`),
`:505` (`mdvcore_hex_search`), `:570` (`mdvcore_indent_detect`). The empty replacement table is
`Sources/RustCore/CoreTransport.swift:60` (`static let exports: [String: FrameFn] = [:]`).

**Why:** Since the TSK-580 thin-waist envelope migration, the Swift production path routes **every**
stateless method through `mdvcore_call(MDV_METHOD_*, …)` (`CoreTransport.swift:44-66`; `exports`
is now empty). The six dedicated per-method `extern "C"` symbols above are no longer called from any
Swift production code — a grep of `Sources/**` finds them only in doc-comments and the A/B test
harness; they are exercised only by Rust unit tests and one `DiffParseABTests.swift`. They remain
`#[unsafe(no_mangle)]` exported, so they are emitted into the shipping staticlib and the committed
C ABI header (`include/mdvcore.h`), each carrying its own panic-guard wrapper and frame-handling
code. This is real dead public-API surface on a contract whose stated invariant is "new methods
land in the envelope, not as new symbols." Dead exports on an ABI header are worse than ordinary
dead code: they look like supported API to any C/remote consumer reading the header, they bloat the
binary (against the documented 26 MB exec sub-cap), and each is a duplicate code path that can
silently diverge from the envelope path it shadows. The code comments call this a "coexistence
window," but there is no tracked sunset and the window has no end condition.

**Fix:** Either (a) delete the per-method symbols now that the envelope is the sole production path
(the Rust/A-B tests can call `dispatch::call` / `mdvcore_call` directly, which is what they actually
validate), or (b) if a deliberate coexistence window is wanted, file a dated sunset task and add a
`#[doc = "DEPRECATED: use mdvcore_call(MDV_METHOD_*)"]` marker plus a cbindgen note so the header
signals the symbol is legacy rather than presenting it as first-class API.

**VERDICT: CONFIRMED** — all six symbols carry `#[unsafe(no_mangle)]` in `ffi/src/lib.rs`;
`InProcessTransport.exports` is `[:]` (line 60) and every stateless CoreClient method
(`mdvCoreParseDiff`/`mdvCoreHexRender`/`mdvCoreHexSearch`/`mdvCoreIndentDetect`/highlight) routes via
`mdvEnvelopeCall`/`mdvEnvelopeCallAux` (`mdvcore_call`). Grep of `Sources/**` finds the symbols only in
doc-comments; their sole callers are Rust unit tests (`ffi/src/tests.rs`) as envelope-parity checks.
Dead-but-exported on the committed ABI header.

### Entire CSV-session filter/snapshot/window FFI family is shipped but unreachable in production

**Severity:** medium

**Location:** `rust-core/crates/ffi/src/lib.rs:720` (`mdvcore_session_set_filter`), `:771`
(`mdvcore_session_snapshot`), `:821` (`mdvcore_session_snapshot_window`), `:868`
(`mdvcore_session_filtered_count`). Swift wrappers: `Sources/RustCore/CoreClient.swift:270-318`
(`setFilter` / `snapshot` / `snapshotWindow` / `filteredCount`). Sole production consumer:
`Sources/ViewerCore/RustCSVAdapter.swift:55-57`.

**Why:** The only production code that ever instantiates a `CsvSession` is `RustCSVAdapter.rustParse`
(`RustCSVAdapter.swift:55-57`), and it calls **only** `CsvSession(bytes:)` + `.table()` — never
`setFilter`, `snapshot`, `snapshotWindow`, or `filteredCount`. The CSV viewer UI
(`Sources/ViewerUI/CSVTableView.swift`) filters with the Swift `CSVParser` result in-memory, not
through the Rust session. On top of that, `RustCSVAdapter` runs only when `RustCSVGate` is enabled,
and that gate is **default OFF** (`RustCSVGate.swift:4`, *"Default OFF — the shipping default is the
existing Swift path"*). Net effect in the shipping default build: the whole CSV-session FFI family
is dead weight; the filter/snapshot/window subset is dead even when the gate is flipped on. That is
four exported ABI symbols, their MessagePack snapshot/window encode paths in `mdvcore-core`, and the
corresponding `Snapshot`/`FilterScope` public Swift types — all shipped, none reachable by a user.
The windowed-snapshot work (TSK-559) was built specifically so "filter-as-you-type on a large table
costs one screen of rows per keystroke" (`CoreClient.swift:289-292` docstring), but nothing in the
UI is wired to use it, so the perf benefit it describes is never realized.

**Fix:** Decide the disposition explicitly. If the windowed Rust CSV path is the intended future,
wire `CSVTableView` to consume `snapshotWindow`/`filteredCount` behind the gate so the surface is
actually exercised end-to-end (and the gate has a reason to ship on). If it is speculative, move the
session/filter/snapshot family behind a cargo feature (e.g. `csv-session`) that the default app
staticlib build leaves off, keeping it compilable for tests without exporting it into the shipping
ABI. Either way, track it so the surface is not indefinitely "shipped but unreachable."

**VERDICT: CONFIRMED** — `RustCSVAdapter.rustParse` (the only `CsvSession(` instantiation in `Sources/`)
calls only `CsvSession(bytes:)` + `.table()`; `setFilter`/`snapshot`/`snapshotWindow`/`filteredCount`
are referenced only by their own CoreClient.swift definitions + tests. `CSVTableView` filters in-memory
via the Swift `CSVFilter.apply(...)` on the parsed `CSVParser.Result` (the `filteredCount`/`snapshot`
hits there are unrelated locals; the MCP `snapshot_window` tool is a window screenshot, not CsvSession).
`RustCSVGate` is default OFF. The filter/snapshot/window family is unreachable even with the gate on.

### `tree-sitter-swift` pinned to a bare git revision with no upstream tag/version

**Severity:** low

**Location:** `Package.swift:77` (`revision: "7b7909f2f6b9414be0958275f4c8e5d69c3bca43"`);
`Package.resolved` `tree-sitter-swift` entry has a `revision` but **no `version`** field
(every other grammar carries a semver `version`).

**Why:** This pin is reproducible (a revision SHA can't float), and the manifest comment correctly
explains *why* a revision rather than a branch (the generated `parser.c` lives only on the
`with-generated-files` branch, and a floating branch would silently rewrite the parser). But a bare
revision with no upstream tag means there is no released version to cross-reference against an
advisory database, no changelog boundary to diff against, and no signal of how stale the pin is —
the resolved entry is the *only* grammar with a null `version`, so it is invisible to any tooling
that keys off semver (the SwiftPM advisory-watch lane queries by ecosystem/version). When the pin is
eventually bumped, "re-diff the generated parser.c" (as the comment instructs) is a manual,
easy-to-skip step with no automated guard. For an unreviewed-C dependency that links directly into
the app, this is a thin auditing posture even though it is not currently exploitable.

**Fix:** Where alex-pinkus publishes a `*-with-generated-files` tag, pin to that tag (still a fixed
generated parser, but now a referenceable version). Failing that, record the pinned revision's date
+ a checksum of the vendored `parser.c` in a tracked note, and add the parser.c diff to the
advisory-watch lane's checklist so a bump can't land without the re-diff the comment already
mandates. At minimum, file a recurring task to re-pin deliberately rather than letting the revision
silently age.

**VERDICT: CONFIRMED** — `Package.swift:77` pins the bare SHA `7b7909f…`; the `Package.resolved`
`tree-sitter-swift` entry (lines 140-146) has only `revision`, no `version` — the lone grammar without
semver (json `0.24.8`, rust `0.24.2` for contrast). (Minor imprecision: `swiftpm-advisory-watch.sh`
does NOT skip it — it emits `ver or rev`, i.e. the SHA — but a bare SHA can't be matched against
semver-keyed advisory ranges, so the substantive gap "no released version to cross-reference / no
semver advisory match" holds.) Low severity, not currently exploitable — verdict stands.
