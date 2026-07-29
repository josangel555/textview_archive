# Day-One Repo-Scaffolding Checklist

Copy this file into the new repo on day 1. It is the concrete week-1 build-out list distilled
from a prior mature project (agent-driven, ~8 weeks, 3,700+ commits). Every item cites the
one-line reason it earned a place here — most are lessons paid for once already; don't re-pay.

Work top to bottom within each section; sections are roughly priority-ordered. Check items off
in place (this is a living doc, not a report) and delete the "why" parenthetical once the item
is done if you want a leaner steady-state file.

---

## 0. Before writing any app code

- [ ] Decide the FFI/module-boundary strategy (if multi-language: e.g. Rust core + native UI
      shell) and commit to **additive-only, versioned boundary types** from the first commit
      (learned: cross-module enum/type-layout staleness causes SIGSEGVs that look exactly like
      FFI bugs — wastes root-cause time every time it recurs).
- [ ] Decide sandbox posture (App Sandbox vs. non-sandboxed hardened runtime) as a deliberate,
      documented call — don't default into it (learned: retrofitting sandboxing after the
      file-access model is built is a one-way-door, much more expensive later).
- [ ] Decide Rust-staticlib-vs-dylib (or equivalent static/dynamic link choice for any
      cross-language core) up front; default to **static** for hardened-runtime/TCC stability
      unless you have a concrete startup-time or plugin-hot-reload forcing function.

## 1. Signing — get this right before you write feature code

- [ ] **Sign with a real (non-ad-hoc) identity from the very first build**, in every
      environment (dev machine, CI, VM) — never ad-hoc, not even temporarily. Run
      `scripts/setup-signing.sh`-equivalent (self-signed local dev cert) on day 1.
      (learned: ad-hoc signing is keyed on `cdhash`, which changes every rebuild, so TCC grants
      for Documents/Desktop/Screen-Recording/etc. re-prompt on every rebuild forever — a real
      identity keys on `(bundle-id, cert-leaf-hash)` and is stable across rebuilds.)
- [ ] Ensure **every automated signing lane (CI, VM, local dev) uses the exact same signing
      recipe as the ship path** — same hardened-runtime flags, same entitlements application.
      Flag any lane that can't get the real cert as "not representative," don't silently trust
      it. (learned: ad-hoc CI/VM signing skipped `--options runtime`'s library-validation
      Team-ID check, silently hiding a dlopen-denial bug that only bit the owner's real signed
      build — invisible in every automated lane by construction.)
- [ ] Whenever you flip a hardened-runtime / entitlement / signing flag to fix one problem,
      **write and run an empirical probe of the new combined configuration** — don't reason
      "should be equivalent." (learned: the TCC-churn fix silently created a dlopen-denial
      wall; nobody probed the combination until an audit did, months later.)
- [ ] If you plan to ship publicly, **acquire the Developer ID membership and run one real
      notarize → staple → quarantine-launch cycle as an early milestone**, independent of
      feature completeness — do not let "notarize for the first time" collide with a launch
      deadline. (learned: notarization never ran in the prior project; it stacks multiple
      untested failure modes — in-place xattr races, unchecked notarytool exit status, missing
      post-staple Gatekeeper check — that would all surface for the first time at the worst
      possible moment.)
- [ ] Wire **inside-out signing order** from day 1 once you have nested code: dylibs with
      derived identifiers → resource bundles → remaining Mach-Os → app last with entitlements
      applied ONLY to the app, never nested code. Verify signature + timestamp locally before
      any notary submit.
- [ ] Apply the same `--entitlements` flag path to the **local-dev build script**, not just
      the release signing script (learned: an authored `entitlements.plist` with least-privilege
      opt-outs was never actually applied by local dev builds — only by the never-run release
      script — so the "effective" posture was untested and would silently diverge the first
      time a real entitlement was needed).

## 2. Build / sign / install scripts to port nearly verbatim

Port these patterns (not necessarily the literal shell files, but the exact mechanism) from
day 1 rather than rebuilding from scratch — each maps 1:1 to a real production incident that
recurred until it got a permanent script-level guard:

- [ ] **`build-app.sh` equivalent** — orchestrates: native core build → UI build → resource
      bundling → codesign → bundle-size cap → pre-install smoke gate. Include a
      `--verify-resources`-style self-check that runs the real assembled binary and hard-fails
      the build (learned: born from an actual clean-machine crash where a resource bundle
      resolved from a dev build path that doesn't exist outside `.build`).
- [ ] **Native-core (Rust/etc.) staticlib staging with a content-hash staleness guard** —
      `cmp -s` the artifact, force-delete stale link products on any change, touch bridge-source
      headers to force relink. (learned: SwiftPM/linkers silently skip relink when object files
      look identical — a real regression shipped OLD core logic to the installed app despite a
      clean recompile.)
- [ ] **ABI/header staleness guard** — on any cross-language boundary type-layout change, touch
      (or force-recompile) every consumer INCLUDING test targets, not just Sources. (learned:
      stale test objects pattern-matching a re-laid-out enum SIGSEGV in ways indistinguishable
      from an FFI bug.)
- [ ] **`check-bundle-size.sh` equivalent — dual-cap guardrail** (total bundle size cap AND a
      separate executable-only cap). A single total cap masks a silent regression to
      static-linking something that should be a lazy-loaded plugin/dylib; the exec-specific cap
      catches that class specifically. Cheap (~10 extra lines) — add both from day 1.
- [ ] **`verify-app.sh` equivalent** — post-build bundle validation: executable presence,
      Info.plist required keys, code-signature integrity (`--verify --deep --strict`), resource
      bundle resolution, any lazy-loaded-component count vs. manifest (catches silent
      build/copy failures for optional components).
- [ ] **Sentinel-based tier enforcement for the test gate** — a runtime marker file that any
      "heavy"/live/UI test tier writes to if it actually ran its body; the merge gate fails if
      that sentinel is non-empty. Guarantees a headless merge gate can never silently include a
      window-opening test.
- [ ] **Separate scratch/build directories per phase** (e.g. `.build-gate` for the merge gate
      with incremental-index off, vs. `.build` for interactive dev with it on). Small disk cost,
      avoids repeated full-reindex tax on every gate↔interactive switch.
- [ ] **XAttribute-stripping build step if the repo can ever live under an iCloud/file-provider-
      synced directory** (`~/Documents`, `~/Desktop`) — sign in a non-synced temp dir, `ditto
      --noextattr --noacl --noqtn` into the dist output, verify what actually ships from a
      stripped copy, not the synced tree. (learned: file-provider re-stamps xattrs in real time,
      races with codesign, causes flaky signing failures that look intermittent.)
- [ ] **File-descriptor limit raise (ulimit) for any multi-process test suite** (WebView /
      browser-automation / LSP child processes) — raise soft ulimit early in the test-runner
      with a graceful fallback. Default 256 fds is insufficient the moment you parallelize
      anything WebView-shaped.
- [ ] **Toolchain-provenance marker file** if builds ever cross machines/toolchain versions —
      catches "module compiled with toolchain X cannot be imported by toolchain Y" loudly
      instead of a confusing partial failure.
- [ ] **`launchctl asuser` (or equivalent) GUI-session bridge** if you need a VM/CI-adjacent
      machine to run real windowed UI tests — spawns the test/app inside the actual console
      user's session so it gets real WindowServer access. Pair with a root-ownership
      remediation step (chown) since this bridge typically runs the test process as root.
- [ ] **JUnit-XML conversion script** for whatever your native test runner emits, if CI wants
      a standard test-report format.

## 3. Licensing / attribution — wire it end-to-end in ONE PR, not two

This project's single most avoidable P1: the generator existed, the bundle never actually
shipped the notices file, and nobody noticed for the project's entire life.

- [ ] Write the license-aggregation generator (package-manager metadata → a NOTICES file) **and**
      the build-step that copies it into the shipped bundle **and** a test that asserts the
      notices file exists **inside the assembled bundle** (not just that the generator's raw
      output looks well-formed) — all three, same commit, same PR. Never let "generate" and
      "ship" become two separate tickets.
- [ ] From the **first vendored dependency** (any language, any ecosystem — including a
      statically-linked native-core crate/library graph), include it in the notices generator's
      scope. Don't hand-wave "attributed elsewhere" without that "elsewhere" file actually
      existing — audit the generator's actual coverage against your full dependency graph
      (including transitive/native-core deps), not just the top-level package manifest.
- [ ] For any **vendored, non-package-manager-tracked asset** (a downloaded `.min.js`, a
      prebuilt binary, a vendored C file) give it, at the SAME commit that vendors it:
      (a) a `VENDOR.md`/PROVENANCE header (source URL, SHA-256, fetch date, refresh procedure),
      (b) a test that re-hashes the vendored bytes against that manifest, and
      (c) an entry in your advisory-watch tooling's scan list keyed by name+version.
      (learned: a vendored JS bundle sat unaudited for ~11 months and accrued 6 published
      CVEs, including 2 sanitizer-bypass XSS, directly in the untrusted-input rendering path —
      because nothing watched "a blob we downloaded once.")
- [ ] Treat "a lockable manifest (`package.json`/`Cargo.toml`/`Gemfile`) with a gitignored
      lockfile" as a **lint failure**, not a per-workspace judgment call — grep for it in CI /
      pre-commit, applied uniformly across every build sub-workspace (including nested build
      tooling like an asset-bundler workspace), not just the primary manifest.
- [ ] Any scanning/advisory-watch script (SwiftPM/Cargo/OSV/etc.) only counts as "we have
      supply-chain monitoring" if something with a clock actually runs it (CI schedule, cron,
      or a standing step in an autonomous work loop). If the honest answer to "who runs this
      and how often" is "nobody, yet," track that gap as its own ticket explicitly — don't let a
      well-engineered, never-triggered script pass review as equivalent to a live gate.
- [ ] If a CI host / remote won't exist for a while, **build the local-scheduled-gate
      equivalent first** (a script the agent loop or a cron entry actually invokes) and treat
      committed CI YAML as documentation-of-intent until a remote exists. SHA-pin any `uses:`
      actions at authoring time regardless — costs nothing extra now, matters the day a remote
      appears.
- [ ] If you reject a dependency in favor of a DIY replacement (e.g. reject a mutation-testing
      tool on dev-machine-hygiene grounds and plan to hand-roll it), **track the DIY
      replacement as a real ticket with a timeline from the same day**, not an indefinitely
      deferred backlog line — a rejected dependency has two halves (avoid the cost, still get
      the capability); shipping only the first half looks resolved on a board but isn't.

## 4. CI shape

- [ ] Design CI workflows against the **actual planned execution substrate** — if there's no
      git remote yet, the "local gate invoked by the agent loop" is the real gate; GH Actions
      YAML is aspirational until a remote exists. Note this explicitly in a status doc so it
      isn't rediscovered fresh at a pre-launch audit.
- [ ] SHA-pin third-party `uses:` actions at authoring time, not "when it starts mattering."
- [ ] Keep the merge gate **window-free / headless-only**; heavy UI/live tiers are a separate
      nightly/VM lane, never the default `swift test`/`cargo test`/etc. sweep on a dev machine.

## 5. Negative controls — prove your gates have teeth

- [ ] For any pixel/render-level regression guard, build a **codified negative-control switch**
      (a single named helper like `NegativeControl.isBroken("<NAME>")` gated by one env var
      naming convention) that a test can flip to deliberately break the invariant and assert
      the guard goes red — a repeatable, committed proof instead of a one-time hand-revert.
      (learned: `ImageRenderer`/`cacheDisplay`/headless frame-walks give **false greens** for
      compositor-occlusion-class bugs — they rasterize in isolation or are blind to native
      layers entirely. Only real windowed-pixel capture is authoritative for that class; a
      negative control is the only way to prove a test actually catches it.)
- [ ] If your UI framework mixes a declarative-UI layer with an opaque native
      view/representable (WebView, terminal surface, any native-widget bridge) sharing a
      container: add a **grep-based static lint** from the FIRST such pairing that flags a
      representable+sibling combo missing the correct z-order/compositing-group directive.
      Cheaper and stronger than any pixel test (runs on every diff, zero false-greens; the
      pixel test only runs nightly at best).

## 6. Persistence / app-support layout

- [ ] Pick **one** persisted-state root directory convention on day 1 and document it (this
      project accidentally split state across two sibling directories — one keyed by app name,
      one by bundle identifier — a needless "which dir has what" tax every session). Decide up
      front: one dir keyed consistently by bundle ID, subdivided by concern (sessions,
      workspaces, bookmarks, history, caches).
- [ ] Never write to `~/Documents`, `~/Desktop`, `~/Downloads` from automated/test paths — use
      the platform's proper per-user temp/support directory.
- [ ] Build a "reset to clean state" path (clear persisted state to a recoverable backup) from
      day 1 — cheap, and it becomes the standard unstick move for weird local state bugs.

## 7. Budgets (context / handoff caps)

- [ ] Cap the "current state" handoff doc (whatever gets re-injected into agent context after a
      compaction) at a small hard size (e.g. 10-15 KB) with an enforced test/gate, not just a
      convention — treat it as CURRENT STATE, edited in place, never appended tick-by-tick.
- [ ] Cap the root agent-instructions file similarly (e.g. 40 KB) with the same enforced gate.
      A red budget test means prune the file — bumping the cap is a deliberate owner decision,
      not a default response to the file getting long.
- [ ] Keep a separate, unbounded institutional-memory doc (bug patterns, gotchas, architecture
      notes) that is NOT re-injected every session — grepped on demand instead.

## 8. `.claude/` (or equivalent agent-harness config) setup

- [ ] Create `.claude/settings.json` on day 1 with concrete project overrides: toolchain/
      language-version pin, canonical build/test scratch paths, and — critically — **one
      canonical env-var name per secret/config value** (see next item).
- [ ] **Centralize environment-variable/flag reads from day one** — one `EnvConfig`
      struct/enum per language, every read goes through it, with: canonical name, type, default,
      one-line purpose, and a build guard (e.g. compiled out of release builds) for any
      test-only/debug-only flag. (learned: 27+ scattered flags across 50+ call sites
      accumulated with no registry; test-only "break this on purpose" flags were reachable in
      the release binary because nothing enforced a debug-only guard.)
- [ ] **One canonical name per secret** (e.g. a VM sudo password env var) — no fallback/alias
      names. (learned: two different names for the same VM password meant one script read the
      right var and another silently fell through to a stale default — a password rotation
      silently broke half the test suite.)
- [ ] Avoid **any per-machine hardcoded absolute path** (a literal `/Users/<name>/...` in a
      manifest or script) — use `$(git rev-parse --show-toplevel)`, `${HOME}`/`~`, or a
      `.gitignore`d `settings.local.json` for genuinely machine-specific values (VM host/user/
      password, personal build-cache location).
- [ ] Add a `.claude/hooks/pre-commit.sh` (or equivalent) that greps for the anti-patterns
      above before they land: hardcoded `/Users/<name>` paths, a second env-var name for an
      existing secret, a lockable manifest with a gitignored lockfile, a dangerous shell command
      pattern specific to your app (e.g. a `killall <your-app-exec-name>` that could kill the
      developer's own running instance instead of a test spawn).
- [ ] Decide up front: is agent-facing policy going to live as narrative Markdown (works well,
      git-tracked, human-readable, but not machine-enforceable) or structured JSON, or both? If
      Markdown, don't let it substitute for the *enforced* pieces above (env-flag registry,
      pre-commit hook) — Markdown is good for the "why," not the "must never happen."
- [ ] Only add custom `.claude/skills/` once a pattern has repeated 3+ times — don't
      speculatively build skill boilerplate for a one-off workflow; built-in skills + your own
      MCP/tool layer cover most needs early on.
- [ ] If using a task-tracker MCP server (or equivalent system-of-record for work items), stand
      it up on day 1 and drive ALL task state through it — treat it as the system of record, not
      a sidecar spreadsheet. Keep tickets scoped to one PR/commit-worth of work; don't
      over-decompose a coherent change into a step-by-step swarm of micro-tickets.

## 9. Platform-wall lessons to seed into agent instructions immediately (macOS-specific, adapt per platform)

Port this list verbatim into the new project's agent-facing instructions rather than
re-earning each item error-by-error:

- [ ] No GNU `timeout` on macOS — background the command or use an in-tool deadline.
- [ ] `grep` a literal with special chars needs `-F` (regex mode eats `[]{}()`).
- [ ] `ps -p a,b,c` does not combine with `-axo` on macOS — filter with `grep -E` instead.
- [ ] zsh eats bare `==`/globs in echoed args — quote them.
- [ ] Heredocs into a remote shell need single-quoted tags (`ssh host 'bash -s' <<'EOS'`) or
      local `$vars` expand before the remote sees them.
- [ ] `screencapture -l<windowID>` (window-ID-targeted), not full-screen capture, is the only
      reliable way to get real composited pixels of a native-widget-hosting window in a
      VM/headless GUI session — full-screen capture can silently omit certain native content
      layers even when the AppKit/UI-framework-level state reports the window fully visible.
- [ ] TCC/screen-capture attribution through any root-vs-user launch bridge (sudo,
      `launchctl asuser`, a CI runner impersonating a GUI session) is fragile and OS-version-
      sensitive — budget recurring diagnostic time whenever the OS updates, don't assume a
      working recipe stays working.
- [ ] For any secondary-process UI surface (WebView, embedded terminal PTY, subprocess UI),
      build an **in-process/headless test-mount seam** as the default test vehicle from day 1;
      reserve spawned-app / real-window capture strictly for the pixel-exact/true-compositing
      slice. (learned: a spawned WebView's backing process was jetsam-killed mid-test purely
      for being "backgrounded" from the OS's perspective — sidestepped entirely by mounting the
      WebView inside the test process instead.)
- [ ] If a UI-automation driving layer needs to synthesize interactions, name the
      **non-synthesizable tier explicitly and permanently** (e.g. faithful pointer-drag
      gestures, multi-touch, native cross-window drag-and-drop) as a fixed, small, human/
      alternate-tooling-gated set from day 1 — don't let every new drag-shaped feature
      re-litigate "is this really blocked?" from scratch.

---

## Sources

Distilled from a mature-project retrospective covering the scripts/build layer, the deps/
licensing/CI dimension, and the platform-wall struggle dimension of a prior ~8-week
agent-driven macOS build. Specific evidence and ticket numbers, if you need to trace a
claim back further than the one-line "learned" note above, live in that project's own
research corpus (evidence lives in the markdown_viewer analysis dir
docs/research/greenfield-learnings-2026-07-11/ — `aspects/`, `holistic/`, `summaries/`;
pointer does not resolve after copy).
