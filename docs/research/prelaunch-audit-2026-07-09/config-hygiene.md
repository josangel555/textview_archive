# Pre-launch Product Review — Configuration Hygiene

**Dimension:** Misconfigurations, bad configs, config that should be code, code that should be
config, env-var sprawl, per-machine assumptions in scripts.
**Date:** 2026-07-10
**Reviewer:** config-hygiene lens (static analysis, read-only)
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

The project's *declared-dependency* hygiene is genuinely strong — Swift packages are
`exact:`/`revision:`-pinned with a documented PIN POLICY, `cargo-deny`/`clippy`/`rustfmt`
are tightened past their permissive defaults, LSP server locations are externalized to a
user-editable JSON override file, and a `check-no-secrets` release gate exists. That is
above-average discipline.

The weak spots are in the **build/test tooling config**, not the app's dependency manifests:

1. **The Rust build-cache location migration is half-applied.** The owner moved rust-core's
   `target-dir` OFF the reboot-wiped `/private/tmp` to a durable `~/Library/Caches` path on
   2026-07-04, but the repo-root cargo config and four gate/build scripts still point at the
   old `/private/tmp/mdv-rust-target`. The two locations now coexist → duplicated multi-GB
   target trees, no warm-cache sharing, and the merge gate rebuilds from scratch after every
   reboot. **(P1)**
2. **Per-machine `/Users/me` paths are baked into committed config** (`rust-core/.cargo/config.toml`
   hardcodes the build-cache path to one user's home) — non-portable to the VM (`vm-tester`) or
   any other machine. **(P2)**
3. **Two env-var names for the same VM sudo secret** (`MDV_VM_SUDO_PASS` vs
   `MDV_VM_SUDO_PASSWORD`) create a split-brain: exporting the documented one leaves other
   reads silently falling back to the hardcoded `<vm-sudo-password>`. **(P2)**
4. **The CodeMirror bundle build gitignores its `package-lock.json`** — the JS asset shipped
   inside the app bundle is built from a non-reproducible transitive-dependency closure,
   contradicting the project's own pin policy. **(P2)**

The remaining findings are P3 polish: test/fault-injection env flags compiled into release,
static/duplicated version strings, a dead fixture reference, and un-centralized env-flag reads.

No P0 was found in this dimension — nothing here causes data loss or a crash of the shipping
app on a normal launch.

---

## Methodology

**What I examined (static analysis only; no window-opening tests run):**

- All top-level config files: `.cargo/config.toml`, `rust-core/.cargo/config.toml`,
  `rust-core/{Cargo.toml,deny.toml,rustfmt.toml,clippy.toml}`, `Package.swift`,
  `Package.resolved`, `.gitignore`, `schemas/*.json`.
- App/bundle config: `scripts/Info.plist`, `scripts/entitlements.plist`,
  `scripts/com.markdownviewer.mdv-serve.plist.template`.
- The `scripts/` lane (52 scripts) with targeted greps for hardcoded hosts/IPs/paths, sudo
  passwords, env-var defaults, and `killall`; deep reads of `build-app.sh`, `test-in-vm.sh`,
  `vm-smoke.sh`, `vm-diagnose.sh`, `vm-profile.sh`, `stage-frontends.sh`, `check-no-secrets.sh`,
  `reset-tcc.sh`, `rust-core-gate.sh`, `build-rust-core.sh`.
- CI: `.github/workflows/{pr,coverage,nightly-vm,nightly-perf-floor,nightly-supply-chain}.yml`.
- Env-var surface: enumerated every `MDV_*` token across `Sources/`, `Tests/`, `scripts/`,
  `rust-core/` (160 unique tokens; narrowed to 27 genuine runtime env-var *reads* after
  excluding FFI status/method C constants which share the `MDV_` prefix).
- Env-read centralization: counted `ProcessInfo.processInfo.environment` call sites (54 across
  36 files) and looked for a central config/flag module.
- The JS build config `scripts/codemirror-build/{package.json,.gitignore}` for pinning +
  lockfile presence.
- Cross-checked the guard test `Tests/ViewerCoreTests/InfraInvariantTests.swift`.

**Depth:** ~1.5 hours, ~30 tool calls. Read the actual bytes of every file cited below;
every line number was verified against the file at review time.

---

## Findings

### F1 — Rust build-cache `target-dir` migration is half-applied (two live locations)
- **Severity:** P1
- **Evidence:**
  - `rust-core/.cargo/config.toml:11` → `target-dir = "/Users/me/Library/Caches/mdv-rust-target"`,
    with a comment stamped `2026-07-04 (owner): moved OFF /private/tmp (reboot-wiped) to a
    DURABLE non-synced location`.
  - `.cargo/config.toml:9` (repo root) → `target-dir = "/private/tmp/mdv-rust-target"` — the
    exact location the owner abandoned. Its own header says it exists specifically to cover
    `cargo … --manifest-path rust-core/Cargo.toml` run *from the repo root*.
  - `scripts/rust-core-gate.sh:42`, `scripts/build-rust-core.sh:62`,
    `scripts/rust-perf-floor.sh:42`, `scripts/test-headless-gate.sh:74` all default
    `CARGO_TARGET_DIR` to `/private/tmp/mdv-rust-target`.
  - `scripts/stage-frontends.sh:11` documents the target as `~/Library/Caches/mdv-rust-target`
    — the *new* location — so staging looks for binaries where the gate did not build them
    unless `CARGO_TARGET_DIR` is exported to reconcile.
- **Impact:** Cargo picks `target-dir` by walking up from the CWD, so `cargo build` inside
  `rust-core/` writes to `~/Library/Caches/...` while the gate scripts (which set
  `CARGO_TARGET_DIR`) write to `/private/tmp/...`. Result: **two multi-GB target trees that
  never share a warm cache**, plus the `/private/tmp` tree is wiped on every reboot, so the
  headless merge gate does a full cold Rust rebuild after each restart. The owner's own
  durability fix is silently defeated for the gate path.
- **Suggested fix:** Point all five references at the single durable location. Best: introduce
  one non-per-user path (e.g. `${XDG_CACHE_HOME:-$HOME/Library/Caches}/mdv-rust-target`)
  resolved in a tiny shared shell snippet the scripts source, and set the same in *both*
  `.cargo/config.toml` files (cargo config can't interpolate env, so the config files still
  need a literal — see F2).
- **Fix size:** M
- **Fix risk:** careful (build-cache path changes can orphan the old tree; harmless but wastes
  disk until manually reaped).

### F2 — Hardcoded `/Users/me` in committed build config and scripts (per-machine assumption)
- **Severity:** P2
- **Evidence:**
  - `rust-core/.cargo/config.toml:11` hardcodes `/Users/me/Library/Caches/mdv-rust-target`
    as the build cache — a tracked file (`git ls-files` confirms), so it ships to every clone.
  - `scripts/workflows/prelaunch-audit.js:13`, `wf-finish-50.js:10`, `wf-uat-tests.js:11`,
    `wf-feature-readiness.js:11` all hardcode
    `const ROOT = '/Users/me/Documents/workspaces/claude/markdown_viewer'`.
  - `scripts/render-icon.swift:8` hardcodes `file:///Users/me/Downloads/TextView (2)/...`.
  - `scripts/reset-tcc.sh:28` prints `/Users/me/Documents/workspaces/claude/markdown_viewer/...`.
- **Impact:** On the UTM VM (user `vm-tester`) or any other developer's machine,
  `rust-core/.cargo/config.toml`'s cache path silently resolves to a non-existent `/Users/me`
  home — cargo will `mkdir` it if it can, but on the VM this points the durable cache at a home
  dir that isn't the runner's, so cache reuse breaks and (worse) it can't be created under a
  different user, defeating the durability intent. The `.js` workflow ROOTs and `render-icon`
  source are dead on any non-owner machine. This is config that assumes exactly one machine.
- **Suggested fix:** For scripts, derive ROOT from `git rev-parse --show-toplevel` / `$(cd
  "$(dirname "$0")/.." && pwd)` (the shell scripts already do this pattern elsewhere). For the
  cargo config literal, prefer a repo-relative sibling that is `.gitignore`d, or accept the
  per-machine literal but document that each dev must edit it (worst option). The `.js`
  workflow files should read ROOT from an env var or their own path.
- **Fix size:** M
- **Fix risk:** safe (scripts) / careful (cargo config literal — cargo can't expand `$HOME`).

### F3 — Two env-var names for the same VM sudo secret (`MDV_VM_SUDO_PASS` vs `MDV_VM_SUDO_PASSWORD`)
- **Severity:** P2
- **Evidence:**
  - `scripts/test-in-vm.sh:206` **requires** `MDV_VM_SUDO_PASS` (`${MDV_VM_SUDO_PASS:?…}` — hard
    error if unset) for the launchctl-asuser bridge, and CLAUDE.md documents the invocation as
    `MDV_VM_SUDO_PASS=<vm-sudo-password> …`.
  - But `scripts/test-in-vm.sh:335` and `:359` (the `.build` chown steps) read
    `${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}` — a *different* variable, defaulting to the hardcoded `<vm-sudo-password>`.
  - `scripts/vm-smoke.sh:55`, `scripts/vm-diagnose.sh:24`, `scripts/vm-profile.sh:49` read only
    `${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}`.
- **Impact:** A user who follows the docs and exports `MDV_VM_SUDO_PASS=<pw>` leaves
  `MDV_VM_SUDO_PASSWORD` unset, so the chown steps and the three sibling scripts fall back to the
  hardcoded `<vm-sudo-password>`. Today this is masked because the real VM password *is* `<vm-sudo-password>`; the moment it
  is changed, half of `test-in-vm.sh` authenticates and half silently pipes the wrong password to
  `sudo -S` (which fails quietly — the exact "a password is required, buried in the log" footgun
  CLAUDE.md already warns about). Split-brain secret naming.
- **Suggested fix:** Pick one canonical name (`MDV_VM_SUDO_PASS`), make every script read it, and
  add a one-line back-compat shim (`: "${MDV_VM_SUDO_PASS:=${MDV_VM_SUDO_PASSWORD:-}}"`) at the
  top of each. Remove the `:-1234` literal fallbacks so a missing secret fails loudly.
- **Fix size:** S
- **Fix risk:** safe.

### F4 — CodeMirror bundle build gitignores its lockfile → non-reproducible shipped JS asset
- **Severity:** P2
- **Evidence:**
  - `scripts/codemirror-build/.gitignore` contains `package-lock.json` (and `node_modules/`).
  - `scripts/codemirror-build/package.json` exact-pins direct deps (good) but there is no
    committed lockfile, so all *transitive* deps (`@codemirror/*` pull in `@lezer/*`, `crelt`,
    `style-mod`, etc.) resolve fresh on each `npm install`.
  - The build output is `Sources/ViewerUI/Resources/codemirror/codemirror.js` — a minified
    bundle **shipped inside the notarized app bundle**.
- **Impact:** The editor bundle that ships to users is not reproducible: two `npm install` runs
  weeks apart can bundle different transitive-dependency code, with no committed record of what
  was actually shipped. This is a supply-chain gap and directly contradicts the project's stated
  policy ("Pin versions exactly in lockable manifests"; the Swift/Rust manifests follow it). A
  compromised or yanked transitive patch would land silently on the next rebuild.
- **Suggested fix:** Commit `package-lock.json` (remove it from `.gitignore`) and build with
  `npm ci`. If the concern was lockfile churn noise, that is exactly what a lockfile is for.
- **Fix size:** S
- **Fix risk:** safe.

### F5 — Test / fault-injection env flags compiled into release builds (no `#if DEBUG`)
- **Severity:** P3
- **Evidence (all read via plain `ProcessInfo.processInfo.environment`, no build guard):**
  - `Sources/ViewerCore/MDVNegativeControl.swift:17-22` — `isBroken(name)` reads
    `MDV_ENABLE_BROKEN_<NAME>`; deliberate-UI-break switches (`RULER`, `CANVAS_OVERLAY`) that
    intentionally corrupt rendering ship in release.
  - `MDV_UI_SCENE` / `MDV_UI_SCENE_DELAY` (`Sources/ViewerCore/UISceneRegistry.swift`,
    `Sources/ViewerUI/UISceneApplier.swift`) — inject synthetic UI scenes at launch.
  - `MDV_LSP_STATUS_FAKE` (`LSPStatusChip.swift:164`), `MDV_FAKE_LSP_*`
    (`MDVFakeLSPServer/main.swift` + readers), `MDV_PRISTINE_CHROME`,
    `MDV_PRESERVE_RECENT_SOURCE_VIEWS`, `MDV_SKIP_WORKSPACE_RESTORE`, `MDV_DIAGNOSE_DELAY`.
- **Impact:** These test/UAT affordances are present in the shipped binary; anyone launching the
  app with the right env var can force fake LSP status, break the ruler/canvas, skip workspace
  restore, or drive synthetic scenes. Impact is low (local env only, no privilege escalation, the
  user is sabotaging their own instance) but it is a production config surface that should not
  exist in a release, and it enlarges the "what can change behavior" audit surface.
- **Suggested fix:** Wrap the deliberate-break and scene-injection reads in `#if DEBUG`
  (or a single `MDVTestHooks.enabled` gate that is compiled out of release). Keep genuine
  operational overrides (`MDV_APP_SUPPORT`, `MDV_REMOTE_SOCKET`) unguarded.
- **Fix size:** M
- **Fix risk:** careful (must not compile out a flag the VM UAT lane relies on — audit each
  reader's test callers first).

### F6 — Version config is static and duplicated (no build-number derivation; sub-bundle skew)
- **Severity:** P3
- **Evidence:**
  - `scripts/Info.plist` — `CFBundleShortVersionString = 0.1.0`, `CFBundleVersion = 1` (main app,
    copied verbatim into the bundle at `build-app.sh:165`). `CFBundleVersion` is never bumped/
    derived, so every build is version-identical.
  - `scripts/build-app.sh:296-297` stamps resource sub-bundles with a **different**
    `CFBundleShortVersionString = 1.0` / `CFBundleVersion = 1`.
  - macOS minimum is declared twice: `Info.plist` `LSMinimumSystemVersion = 15.0` and
    `Package.swift:14` `platforms: [.macOS(.v15)]` — two sources of truth that can drift.
- **Impact:** Every build reports the same `0.1.0 (1)`, so crash reports, `mdls`, update
  mechanisms, and support triage cannot distinguish builds. Sub-bundles claiming `1.0` while the
  app claims `0.1.0` is internally inconsistent. Low user impact pre-launch but a table-stakes
  gap before shipping.
- **Suggested fix:** Derive `CFBundleVersion` from `git rev-list --count HEAD` (or a CI build
  number) in `build-app.sh` and stamp it into both the app plist and the sub-bundle plists;
  unify the resource-bundle version with the app's `CFBundleShortVersionString`. Keep the macOS
  min in one place (SwiftPM) and generate the plist key, or add an invariant test asserting they
  match.
- **Fix size:** M
- **Fix risk:** safe.

### F7 — Dead config reference: `codemirror-build/package-lock.json` opened as a perf fixture
- **Severity:** P3
- **Evidence:** `scripts/vm-profile.sh:148` runs
  `open-lazy /Users/vm-tester/markdown_viewer/scripts/codemirror-build/package-lock.json` as one of
  its warm-up fixtures, but that file is gitignored (F4) and does not exist in the tree.
- **Impact:** The profiler's "open a JSON file" fixture step opens nothing (or errors and is
  swallowed), so that leg of the perf capture is silently a no-op — measurements taken from this
  script under-represent JSON-open cost. Minor measurement-integrity issue.
- **Suggested fix:** Point the fixture at a file that actually exists (e.g. `Package.resolved`
  or a committed sample JSON), or commit the lockfile per F4.
- **Fix size:** S
- **Fix risk:** safe.

### F8 — 27 runtime env flags read at 54 scattered sites with no central registry
- **Severity:** P3
- **Evidence:** `grep 'ProcessInfo.processInfo.environment' Sources/` → 54 call sites across 36
  files; genuine `MDV_*` env-var reads number 27 distinct keys (`MDV_APP_SUPPORT`,
  `MDV_SESSIONS_DIR`, `MDV_TEXTVIEW_DIR`, `MDV_NOTEBOOKS`, `MDV_RUST_DOCSTORE`, `MDV_RICHTEXT`,
  `MDV_REMOTE_SOCKET`, `MDV_SIGNPOSTS`, … plus the test hooks in F5). There is no single
  `EnvFlags`/`Config` type — each reader inlines its own key string and parsing (`== "1"`,
  `!isEmpty`, etc.). (Total `MDV_*` tokens across the repo: 160, inflated by FFI C constants
  that share the prefix — a naming collision that itself makes auditing harder.)
- **Impact:** No single place answers "which env flags does this app honor, and what are their
  defaults/types" — a real gap for a pre-launch audit and for anyone reasoning about the release
  behavior surface. Inline key strings invite typos (a mistyped `MDV_` read fails silently as
  "flag off"). The prefix collision with FFI status/method constants means `grep MDV_` over-counts
  4-5x, obscuring the true flag list.
- **Suggested fix:** Introduce one `enum MDVEnv` (or `EnvFlags` struct) that declares every key
  as a typed property with a default, and have all readers go through it. Optionally split the
  FFI-constant namespace (e.g. `MDVC_STATUS_*`) so the env-flag grep is clean. This is the
  "code that should reference central config" cleanup.
- **Fix size:** L
- **Fix risk:** safe (mechanical), but touches many files.

---

## Positive observations

- **Swift dependency pinning is exemplary.** `Package.swift:62-96` documents an explicit PIN
  POLICY: every tree-sitter grammar is `exact:`-pinned (not `from:`, which SemVer-widens for
  0.x), `tree-sitter-swift` is `revision:`-pinned to a SHA, and `swift-markdown` uses
  `.upToNextMinor` with a rationale comment. `Package.resolved` is committed.
- **`cargo-deny` config is tightened past defaults** (`rust-core/deny.toml`): `yanked = "deny"`,
  `multiple-versions = "deny"` with individually-justified skips, a scoped MPL-2.0 exception for
  the `cbindgen` build tool only, and `unknown-registry/unknown-git = "deny"`. The graph targets
  are pinned to the two macOS arches actually built, avoiding cross-platform false positives.
- **`clippy.toml` wires determinism lints from day one** — bans `Instant::now`/`SystemTime::now`
  in the pure core to force clock injection (replayability), plus test-only unwrap/expect allows.
- **`rustfmt.toml` deliberately uses stable-only keys** and documents *why* nightly
  `imports_granularity` is omitted (so `cargo fmt --check` works on stable).
- **LSP config is properly externalized**, not hardcoded: `LSPWorkspaceOverrides` loads a
  user-editable JSON (`command`/`args` per language), and `LSPDiscovery` probes `xcrun`/`which`
  with sensible Homebrew search-path fallbacks — config that *is* config, code that *is* code.
- **`check-no-secrets.sh` release gate** uses high-confidence provider regexes with documented
  test/fixture exclusions and a documented rationale for the one intentional local-VM password.
- **`entitlements.plist` is minimal and documented** — every dangerous opt-out
  (`allow-jit`, `disable-library-validation`, `allow-unsigned-executable-memory`) is explicitly
  set `false` with a comment explaining the non-sandboxed-but-hardened stance.
- **The `mdv-serve` launchd template** correctly documents that launchd does not expand `~` in
  `SockPathName` and uses an `install-app.sh`-substituted `__HOME__` token — the right way to
  handle a per-user socket path in a plist.
- **The `killall MarkdownViewer` in `reset-tcc.sh`/`reset-and-launch.sh`** looked like a violation
  of the owner's NEVER-killall rule, but is a *deliberate, tested exemption*:
  `InfraInvariantTests.swift:113-132` bans bare killall in all other scripts and explicitly
  whitelists these two owner-invoked reset utilities. Guard test present and correct — not a
  finding.

---

## Coverage gaps (not examined)

- **Per-crate `rust-core/crates/*/Cargo.toml` feature-flag hygiene** — I read the workspace
  `deny.toml`/root config but did not audit each crate's `[features]` for
  `default-features`/minimal-feature-list compliance beyond the deny gate.
- **`schemas/*.json` content** (`cm-bridge.json`, `html-sanitizer-policy.json`) — confirmed they
  exist and are externalized config (good) but did not validate their schema/consumer contract.
- **UserDefaults key surface** — prefs (zoom/theme/wrap/window) live in UserDefaults per CLAUDE.md;
  I did not enumerate the keys for collisions or missing-default handling.
- **`mdv-serve` daemon runtime arg parsing** — did not read the daemon's own CLI/socket config
  parsing, only its launchd template.
- **CI secret/permission config** — the `.github/workflows` use `macos-15`/`ubuntu-latest`/
  `self-hosted` runners appropriately; I did not audit `secrets.*` usage or workflow token scopes.
- **No tests were run** (constraint) — all findings are static; the `target-dir` split's runtime
  cost (F1) is inferred from the config, not measured.
- **`.build-gate/checkouts/*` vendored tree-sitter package.jsons** were seen but treated as
  vendored dependency artifacts, not project config.
