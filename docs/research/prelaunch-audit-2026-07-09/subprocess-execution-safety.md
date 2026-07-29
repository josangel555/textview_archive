# Pre-Launch Review — Subprocess Spawning & Command/Argument Injection

**Dimension:** Trace git/jq/LSP/plugin/terminal/task-runner spawns for user-controlled
paths, args, env, and PATH trust — argument injection, hostile-repo config execution,
and binary-trust prompt bypasses.

**Reviewer lens:** read-only static analysis of every `Process`/`execve` spawn site in
`Sources/`. Date: 2026-07-09.

---

## Executive summary

The subprocess surface is, on the whole, **unusually well-hardened for a pre-launch
codebase** — clearly the product of repeated, tracked security passes (SEC-001/002/005/007,
S3.1, TSK-963/980/998/1129). The two heavy hostile-repo vectors (LSP servers, plugins) have
real trust gates, symlink-containment, ancestor-directory writability checks, credential-env
scrubbing, and code-injection env denylists. `git`, `jq`, and `ffmpeg` route through a shared
`ProcessRunner` with SIGPIPE suppression, SIGTERM→SIGKILL escalation, output caps, and (for
jq/git) kernel resource limits; git additionally runs with a minimal env allowlist, protective
`-c` config overrides, `--` option terminators, and per-revision option-injection guards.

The findings below are **gaps and inconsistencies against that established bar**, not a broken
surface. The most material:

- **The Task Runner (UI panel + MCP `run_task`) is the one spawn path that did NOT get the
  hardening the rest of the app received.** It runs arbitrary repo-authored build scripts
  (`npm run …`, `make …`, `cargo run`) with the app's **entire unscrubbed environment**, and
  behind **no workspace-trust gate** — the exact two protections LSP and the plugin host were
  given. On a machine where the app was launched from a shell with exported credentials, this
  leaks every `*_TOKEN`/`*_SECRET`/`AWS_*` into hostile-repo code. (Findings 1 & 2.)
- **`git diff`/`show`/`blame` run with external-diff and textconv drivers still enabled** — a
  repo whose local `.git/config` is attacker-controlled (e.g. an archive shipped with its
  `.git/` directory) gets arbitrary command execution when the Git panel renders a diff.
  (Finding 3.)

No P0/P1 ship-blockers in this dimension. Findings 1–3 are P2; 4–6 are P3 defense-in-depth
inconsistencies.

---

## Methodology

- Enumerated every spawn site: `rg "Process\(\)"`, `executableURL`/`launchPath`,
  `execve`/`posix_spawn` across `Sources/` (844 files). 16 spawn constructions in 14 files.
- Read in full or in relevant part: `ProcessRunner.swift`, `JQRunner.swift`,
  `Git/GitClient.swift`, `LSP/LSPClient.swift`, `LSP/LSPDiscovery.swift`,
  `LSP/LSPWorkspaceOverrides.swift`, `LSP/LSPLanguage.swift`, `Plugins/PluginSubprocessHost.swift`,
  `Terminal/PTYProcess.swift`, `Terminal/TerminalModel.swift`, `TaskRunner/RunSpec.swift`,
  `TaskRunner/RunnableTaskDiscovery.swift`, `TaskRunnerViewModel.swift`,
  `Automation/MCPToolCatalog.swift` (runTask), `Audio/AudioExporter.swift`,
  `Audio/FFmpegLocator.swift`, `Archive/ArchiveCatalog.swift`, `RemoteCoreAttach.swift`,
  `MarkdownViewer/main.swift` (relaunch), `UISceneApplier.swift` (test scene).
- Cross-checked the argument/env/PATH trust for each: is argv[0] fixed or PATH-resolved; is the
  child env inherited or scrubbed; are user/repo-controlled tokens placed after `--`; are
  revision/path args guarded against leading-`-` option injection; is a shell involved.
- Verified the git-config hardening gap by grepping the whole `Sources/` tree for
  `no-ext-diff`/`no-textconv`/`diff.external`/`GIT_CONFIG_*` — **zero hits**.
- No tests were run (static analysis only, per the read-only constraint).

**Spawn-site inventory (argv[0] / shell / env posture):**

| Site | Executable | Shell? | Child env | Notes |
|---|---|---|---|---|
| `GitClient` | fixed probed `git` | no | minimal allowlist | protective `-c`, `--`, rev guards |
| `JQRunner` | fixed probed `jq` | no (unless rlimits→`/bin/sh` wrapper) | `PATH`+`LANG` only | cpu/fsize/nofile caps, output cap |
| `LSPClient` | discovered/trusted binary | no | scrubbed+denylist | trust prompt, symlink/dir checks |
| `PluginSubprocessHost` | plugin-folder binary | no | scrubbed | symlink containment, pgroup kill |
| `PTYProcess` (terminal) | `$SHELL`→`/bin/zsh` | it IS a shell | full inherit | expected — user's own login shell |
| `TaskRunnerViewModel` | `/usr/bin/env`+argv | no | **full inherit** | **no scrub, no trust gate** |
| `MCPToolCatalog.runTask` | `/usr/bin/env`+argv | no | **full inherit** | allowlisted task id; **no scrub** |
| `AudioExporter` (ffmpeg) | resolved `ffmpeg` | no | allowlist | dir-writability check (parent only) |
| `ArchiveCatalog` | fixed `/usr/bin/{unzip,tar}` | no | full inherit | args after `--`; hand-rolled timeout |
| `main.swift` relaunch | `/usr/bin/open -n <ownBundle>` | no | inherit | own bundle path only — safe |
| `UISceneApplier` git | `/usr/bin/git` | no | inherit | test-instance scene fixture only |
| `RemoteCoreAttach` | (none) | — | — | connects to existing socket, no spawn |

---

## Findings

### 1. Task Runner and MCP `run_task` run untrusted-repo build scripts with the full unscrubbed app environment — P2

**File:** `Sources/ViewerUI/TaskRunnerViewModel.swift:49-60`;
`Sources/ViewerCore/Automation/MCPToolCatalog.swift:468-481`

**Evidence:** `TaskRunnerViewModel.run` builds the child with
`process.executableURL = /usr/bin/env`, `process.arguments = argv`, and **never sets
`process.environment`** — so Foundation gives the child the parent's entire environment.
The tasks come from `RunnableTaskDiscovery` (`npm run <name>`, `make <target>`,
`cargo run`, `pytest`, `go test`) parsed out of a freshly-opened project's manifests.
`npm run <name>` / `make <target>` execute arbitrary shell authored inside that repo.
`MCPToolCatalog.runTask` is the same pattern; it only sets `process.environment` when
`spec.environment` is non-empty (line 475), and `RunSpec.build` leaves it empty by default —
so the common path also inherits the full parent env.

Contrast the deliberate scrubbing everywhere else:
`GitClient` (`GitClient.swift:1330-1344`) builds a four-var allowlist explicitly to avoid
leaking `*_TOKEN`/`*_SECRET`/cloud creds; `LSPLanguage.scrubbedLaunchEnvironment`
(`LSPLanguage.swift:522+`) does the same for LSP children; `AudioExporter.runFFmpeg`
(`AudioExporter.swift:255-258`) passes only `PATH/HOME/TMPDIR/LANG`; `PluginSubprocessHost`
uses `scrubbedEnvironment()`. The task runner — which runs *more* attacker-influenced code
than any of them — is the only path that inherits everything.

**Impact:** When the app is launched from a terminal (`mdv .`), it inherits the shell's
exported secrets. Opening a hostile repo and running any discovered task (or an MCP-connected
agent calling `run_task`) hands those secrets to repo-authored `package.json`/`Makefile`
scripts. A launchd-launched GUI instance has a minimal env, but the terminal-launch case is
exactly why the other paths scrub — this path regresses that guarantee.

**Suggested fix:** Route both spawns through a scrubbed env allowlist (reuse
`LSPLanguage.scrubbedLaunchEnvironment` or the ffmpeg allowlist pattern), merging
`spec.environment` on top. Consider also applying `ProcessRunner.ResourceLimits` (cpu cap)
as jq/git do.

**Fix size:** S · **Fix risk:** careful (a too-tight allowlist can break tasks that need a
toolchain var like `JAVA_HOME`/`NODE_PATH`; mirror the LSP allowlist which already enumerates
these).

---

### 2. No workspace-trust gate before executing discovered repo tasks (UI + MCP) — P2

**File:** `Sources/ViewerUI/TaskRunnerViewModel.swift:42-74`;
`Sources/ViewerCore/Automation/MCPToolCatalog.swift:453-491`

**Evidence:** `run(_:)` and `runTask` spawn the resolved task with no trust check on the
originating workspace. The tasks are `npm run`/`make`/`cargo run` — arbitrary code execution
by construction. The MCP path resolves the id against a fresh `RunnableTaskDiscovery` pass
(good — it's an allowlist, so an agent can't inject an arbitrary command string), but any task
the repo *declares* still runs, on **any filesystem path the agent passes** (`args.string("path")`
→ `validatedExistingURL`), with no human in the loop.

The app already ships the pattern this is missing: LSP added `LSPTrustStore` +
`LSPTrustPrompt` (`LSPClient.swift:149-176`) precisely because "open a repo, get a
workspace-local binary spawned" is RCE-on-browse; a repo-local server binary now blocks
until the user confirms, and **fails closed** in headless contexts. The task runner has no
equivalent. (VS Code's Workspace Trust is the table-stakes precedent for exactly this
open-arbitrary-folder-then-run-its-scripts flow.)

**Impact:** Running a task from a just-opened untrusted folder executes its build scripts.
Via MCP, an automation agent can drive `run_task` against any readable repo without user
confirmation. This is narrower than finding 1's passive leak because it requires an explicit
"run" action — but the MCP surface removes the human, making it the more material half.

**Suggested fix:** Gate task execution behind a per-workspace trust decision (reuse the
`LSPTrustStore` model, or a shared `WorkspaceTrust`), and make the MCP `run_task` tool
fail-closed for an untrusted workspace unless trust was granted interactively.

**Fix size:** M · **Fix risk:** careful (UX-affecting; a one-time-per-workspace prompt is the
right shape, matching the LSP precedent).

---

### 3. `git diff`/`show`/`blame` run with hostile-repo external-diff & textconv drivers enabled — P2

**File:** `Sources/ViewerCore/Git/GitClient.swift:1257-1264` (`protectiveFlags`);
diff/show sites `1097-1117`, `1134-1141`, `254` (`blame`), `550` (`stash show -p`)

**Evidence:** `protectiveFlags` disables the classic config-RCE vectors —
`core.hooksPath=/dev/null`, `core.fsmonitor=false`, `core.editor=true`, `core.pager=cat`,
`protocol.file.allow=user` — but does **not** neutralize `diff.external` / textconv drivers,
and none of the diff-producing calls pass `--no-ext-diff` or `--no-textconv`. A tree-wide grep
for `no-ext-diff|no-textconv|diff.external|GIT_CONFIG_*` returns zero hits. Git honors
`[diff] external = <cmd>` and per-driver `[diff "x"] command/textconv = <cmd>` (selected via
in-tree `.gitattributes`) from the repo's **local** `.git/config`, running that command
whenever a diff/blame/show is generated.

**Impact:** `.git/config` is not transmitted by `git clone`, but it *is* present in an archive
that ships a full `.git/` directory (a realistic delivery — people zip repos). The app opens
folders and renders diffs in the Git panel automatically once a repo is focused
(`UISceneApplier` even auto-focuses the Status tab). Opening such a folder and viewing a diff
→ arbitrary command execution. This is squarely "hostile-repo config execution."

**Suggested fix:** Add `-c diff.external=` (empty) to `protectiveFlags`, and pass
`--no-ext-diff --no-textconv` on the `diff`/`show`/`blame` invocations (or set
`GIT_EXTERNAL_DIFF`/`GIT_CONFIG_NOSYSTEM` in the env). Blanket-disabling ext-diff/textconv has
no downside for a read-only viewer that renders diffs itself.

**Fix size:** S · **Fix risk:** safe.

---

### 4. `fileDiff(path:atCommit:)` omits the `isSafeRevision` option-injection guard its siblings all apply — P3

**File:** `Sources/ViewerCore/Git/GitClient.swift:1097-1104`

**Evidence:** Every other revision-taking method (`commitDiff` 1110, `diff(from:to:)`
1135-1136, `mergeBase` 1181, `revParse` 1190, `blobSha` 1205, `commitDiff` via `isSafeRevision`)
validates that the revision does not begin with `-`. `fileDiff` builds `"\(sha)~"` and
`"\(sha)"` with **no guard**, and these tokens sit **before** the `--` terminator. A `sha`
of `-o…`/`--output=…` shape would be parsed by `git diff` as an option.

**Impact:** Low exploitability today — the two callers (`GitVersionSource`, `FileHistoryModel`)
pass SHAs parsed out of `git log`, so the value is a real 40-hex object id, not user-typed.
This is a defense-in-depth inconsistency: the guard is uniform everywhere else and one method
skipped it.

**Suggested fix:** Add `guard Self.isSafeRevision(sha) else { return "" }` at the top of
`fileDiff`, matching the siblings.

**Fix size:** S · **Fix risk:** safe.

---

### 5. `FFmpegLocator` binary-trust check is weaker than the LSP/plugin standard it cites — P3

**File:** `Sources/ViewerCore/Audio/FFmpegLocator.swift:64-86`

**Evidence:** `isUsable` checks only that the **immediate parent directory** is not
group/world-writable. It does not walk the full ancestor chain, and does not check the binary
**file's own** permission bits. `LSPDiscovery.isBinarySafeToSpawn`
(`LSPDiscovery.swift:142-179`) was hardened (TSK-963/998) to do exactly both: walk every
ancestor to `/` (defeating a rename-swap through a writable grandparent) and refuse a
group/world-writable binary file (defeating in-place overwrite). The FFmpeg check's own comment
says it "mirrors `LSPDiscovery.isBinarySafeToSpawn`" but predates those two hardenings.

**Impact:** A `ffmpeg` early on `$PATH` whose grandparent dir is `0o777`, or a writable ffmpeg
file inside a safe dir, would be trusted and spawned. Exposure is lower than LSP (user-initiated
MP3 export, and `$PATH` is the app-inherited PATH, not repo-controlled), but it's a needless
inconsistency in a shared trust primitive.

**Suggested fix:** Replace the local `isContainingDirSafe` with a call to
`LSPDiscovery.isBinarySafeToSpawn` (or lift that into a shared `BinaryTrust` helper both use).

**Fix size:** S · **Fix risk:** safe.

---

### 6. `ArchiveCatalog` spawns bypass `ProcessRunner` — no env scrub, no resource caps, hand-rolled timeout — P3

**File:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:196-225`

**Evidence:** The archive lister/extractor spawns fixed `/usr/bin/unzip` and `/usr/bin/tar`
(good — argv[0] fixed, user paths after `--`), but rolls its own poll-loop wall-clock timeout
(`while p.isRunning, Date() < deadline { Thread.sleep(0.02) }`) instead of using the shared
`ProcessRunner`. Consequences: no CPU/fsize/nofile `ResourceLimits`, no combined output cap
(`readDataToEndOfFile()` on `unzip -p` of a crafted entry buffers unbounded — a decompression
bomb has only the 20s wall timeout as a bound), full inherited env, and no SIGTERM→SIGKILL
escalation (`terminate()` only, so a wedged child that traps SIGTERM leaves the reader thread
blocked on EOF).

**Impact:** `unzip`/`tar` are not code-execution surfaces, so this is not RCE — but a hostile
archive (zip bomb / a member that decompresses to gigabytes) can drive memory/CPU with only a
coarse wall-clock bound, and the parser thread can wedge on a SIGTERM-trapping child. Low
severity given the extractors aren't code vectors.

**Suggested fix:** Route through `ProcessRunner.run(p, timeout:, limits:, maxOutputBytes:)`
like git/jq/ffmpeg; add a scrubbed env allowlist for consistency.

**Fix size:** S · **Fix risk:** safe.

---

## Positive observations

The following are genuinely strong and worth preserving through any refactor:

- **`GitClient` (`GitClient.swift:1301-1366`):** minimal env allowlist (never copies `GIT_*`
  or credential-shaped vars), `protectiveFlags` disabling hooks/fsmonitor/editor/pager,
  `protocol.file.allow=user`, `standardInput = nullDevice`, uniform `--` terminators, per-revision
  `isSafeRevision` guards, `safeRelativePath` (rejects leading-`-`, absolute, `..`), CPU/fsize
  caps + 512 MB output cap, lossy UTF-8 decode, and an `AuditLog.processSpawn` record per call.
- **LSP trust stack:** `LSPTrustStore`/`LSPTrustPrompt` fail-closed workspace-local-binary gate
  (`LSPClient.swift:149-176`); `isBinarySafeToSpawn` full-ancestor + file-bit writability walk
  (`LSPDiscovery.swift:142-179`); xcrun-resolved path re-gated through the same check;
  `dangerousEnvNames` denylist stripping `NODE_OPTIONS`/`DYLD_*`/`PYTHONSTARTUP`/… from
  repo-supplied `lsp.json` env (`LSPWorkspaceOverrides.swift:219-301`); untrusted override
  drops args *and* env, not just the command (`LSPLanguage.swift:365-444`); scrubbed base env
  on both paths.
- **`PluginSubprocessHost` (`PluginSubprocessHost.swift:120-237`):** string `..` reject +
  post-symlink-resolution containment check (SEC-007), scrubbed env, own-process-group kill so
  a timeout takes down the whole tree, path-free audit logging (no filesystem-layout leak).
- **`ProcessRunner`:** `F_SETNOSIGPIPE` on the stdin fd (prevents a fast-failing child from
  killing the parent), SIGTERM→SIGKILL escalation with recycled-pid guard, combined-byte output
  cap, orphan-holds-the-pipe post-kill drain grace, and the `/bin/sh -c 'ulimit …; exec "$0" "$@"'`
  rlimit wrapper documented against macOS's real (partial) `setrlimit` enforcement.
- **`JQRunner`:** fixed binary probe, `PATH=/usr/bin:/bin`+`LANG=C` only, cpu+fsize+nofile
  caps, 256 MB output cap with explicit "partial blob → throw, don't hand back truncated JSON".
- **`PTYProcess`:** the only intentionally-full-env, is-a-shell spawn — and it correctly is the
  user's *own* login shell (`$SHELL`→`/bin/zsh`, `-zsh` login argv), which is the expected trust
  boundary for a terminal, not a leak.
- **`main.swift` relaunch** spawns `/usr/bin/open -n` against its **own** `Bundle.main.bundleURL`
  only — no external input.

---

## Coverage gaps (not examined, or examined shallowly)

- **`AuditLog` completeness:** confirmed git and the plugin host emit `processSpawn` records;
  did **not** verify whether jq / LSP / task-runner / ffmpeg / archive spawns are audit-logged.
  If audit coverage is a launch requirement, the un-logged spawns are a follow-up.
- **Rust-core spawns:** this review covered the Swift/`Sources` tier only. The Rust workspace
  (`rust-core/crates/serve`, `tui`, `web`, `pm`) and whether any crate shells out (e.g. a
  `std::process::Command` in the daemon or PM/SQLite tooling) was **not** examined — a separate
  pass should grep `rust-core/` for `Command::new`/`std::process`.
- **`scripts/` lane:** build/sign/VM-test shell scripts (`build-app.sh`, `install-app.sh`,
  `test-in-vm.sh`, `vm-smoke.sh`) were out of scope (dev tooling, not shipped runtime) and not
  reviewed for injection.
- **PATH-resolution of `/usr/bin/env <driver>`:** I reasoned that the task-runner drivers
  (`npm`/`make`/`cargo`/`go`/`pytest`) are fixed argv[0]s resolved against the *app-inherited*
  PATH (not repo-controlled), so a repo can't plant a PATH entry. I did **not** trace whether
  any flow re-exports a repo-relative `node_modules/.bin` or venv `bin` into the app's PATH
  before a task spawn (e.g. via the terminal's OSC-7 cwd or a shell-activation import) — if such
  a path exists it would upgrade findings 1/2.
- **Dynamic runtime behavior:** everything here is static analysis; no spawn was exercised, and
  no test was run (per the read-only / no-window constraint). The git `diff.external` finding in
  particular is asserted from code + the zero-hit grep, not demonstrated against a live hostile
  `.git/config`.
- **`LSPVSCodeExtensions.locateServer`:** the VS Code-extension server-discovery fallback
  (`LSPLanguage.swift:506`) was noted but its own path-trust posture was not read in depth.
