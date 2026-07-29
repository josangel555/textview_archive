# The global `~/.claude/` harness layer — what actually runs the agent

The project's own `.claude/` dir (`/Users/me/Documents/workspaces/claude/markdown_viewer/.claude/`)
is confirmed **empty** (just the bare directory, zero files — verified via `find`). Every piece of
agent-harness behavior this project relies on — the handoff/compaction system, safe-write
enforcement, session save/load, the statusline, keybindings — lives entirely in the user's
**global** `~/.claude/`. That means none of it is versioned with the repo, none of it survives a
`git clone` onto a new machine, and (as documented below) at least one piece of it has already
silently drifted out of sync with what the project's CLAUDE.md claims exists.

---

## 1. Skills — `/Users/me/.claude/skills/` (15 top-level dirs)

| Skill | What it does | Problem it solved (project-relevant?) | Port verdict |
|---|---|---|---|
| **handoff** | 4-phase `/handoff` procedure: (1) distill session learnings into `LESSONS.md`/`BACKLOG.md`/`CLAUDE.md`/memory files, (2) reconcile the `tasked` MCP tracker, (3) write `HANDOFF.md` with a mandatory `<!-- CLAUDE-HANDOFF v1 -->` marker line, (4) tell the user to `/compact`. | **THE compaction-amnesia countermeasure.** Directly paired with the SessionStart re-inject hook (below) — this is the single most load-bearing piece of the harness for a long-running, frequently-compacted project. | **vendor-in-repo.** This is project workflow, not personal style — the marker-line contract, the file targets (`HANDOFF.md`, `LESSONS.md`, `BACKLOG.md`), and the tracker-reconciliation step are all project-specific enough that a fresh project should own its own copy from day 1, tuned to its own tracker/docs layout. |
| **save** | `/save [suffix]` — bundles the *running* session (transcript `.jsonl` + `meta.json` + file-history + tasks + session-env) into a `.tar.gz` under `~/Documents/backup/claude/session_backup/`. Walks up `$PPID` to find `~/.claude/sessions/<PID>.json` for session identity. | Session-continuity insurance independent of compaction — a portable snapshot you can `/load` into a fresh session or hand to another machine. | **keep-global.** Operates on Claude Code's own session storage (`~/.claude/sessions`, `~/.claude/projects`), which is inherently per-machine/per-install, not repo state. Vendoring it in-repo buys nothing since its inputs aren't in the repo. |
| **load** | `/load` (list bundles) / `/load <substring>` (filter) / `/load <filename>` (restore: new UUID, rewrite sessionId refs in the transcript, re-place file-history/tasks/session-env, print `claude --resume <uuid>`). | Companion restore half of `save`. | **keep-global** — same reasoning as `save`. |
| **home-deps-audit** | Sweeps every JS/Python/Rust/Java/Go project under `$HOME` for known-CVE deps (osv-scanner + native auditors), remediates, then reclaims disk by deleting `node_modules`/`.venv`/`target`/`.build`. Also audits Homebrew drift. Companion `GOTCHAS.md` documents every failure mode hit (osv-scanner v1→v2 CLI break, JS batch-panic workaround, noise filters, `osv-scanner fix` before deleting `node_modules` ordering trap). | Machine-wide hygiene, not project-scoped — this is explicitly the *cross-project* sibling of `osv-scanner`. | **keep-global.** By design it operates across `$HOME`, so it can't be meaningfully scoped into one repo. |
| **osv-scanner** | Per-project vulnerability scan via Google's OSV.dev scanner — lockfiles, SBOMs, container/Go images. Covers install, common scan invocations, finding interpretation, remediation patterns (upgrade/override/ignore-with-reason), CI SARIF wiring, and honest limits (OSV coverage gaps, reachability). | Would directly serve markdown_viewer's Rust-core dependency hygiene rider (`default-features=false`, pinned versions, dep-approval gate in CLAUDE.md) if invoked regularly — currently no evidence it's wired into the rust-core gate. | **keep-global**, but **the invocation pattern is worth vendoring**: a rebuild's `scripts/rust-core-gate.sh`-equivalent could shell out to `osv-scanner scan source -L Cargo.lock` as a CI step — that's a one-line addition to an in-repo script, not a reason to duplicate the whole skill. |
| **local-fleet** | Orchestration pattern + two scripts (`fanout.sh`, `llm.sh`) for offloading bulk, parallelizable, *pure-text-transform* LLM work to a local self-hosted model (Ollama/llama-server) via OpenAI-compatible HTTP, while the cloud session stays the verifying orchestrator. Hard rules: local = no tool use, weak-model-proposes/strong-model-disposes, ground+cite, scratch-only until verified. | Token-conservation pattern; not currently referenced anywhere in markdown_viewer's docs/scripts — no evidence it's in active use on this project. | **keep-global.** Generic to any project; scripts read env vars (`LLM_BASE_URL`, `LLM_MODEL`), nothing repo-specific to vendor. |
| **apple-container-test-env** | Mount-and-run pattern (`container run -v $PWD:/app ...`) for zero-host-dep JS/TS test sandboxing via Apple's `container` CLI — explicitly *not* `Dockerfile.test` + `container build`. Covers base-image selection, VPN/NAT triage for the sandbox's networking, vendoring runtime deps when network is unreliable. | markdown_viewer is Swift/Rust, not JS/TS — this skill's container-mount pattern doesn't apply directly, but its **mount-and-run over build-and-run** principle is the same shape as the VM workflow markdown_viewer already uses (rsync the tree + run tests over ssh, never rebuild an image per change). | **project-specific-skip** for this exact skill (wrong ecosystem), but the underlying *principle* (mutable mount beats rebuilt image/bundle for iteration speed) is already independently vendored in markdown_viewer as `scripts/test-in-vm.sh` / the rsync-then-ssh VM workflow — no action needed, just noting the pattern rhymes. |
| **mac-headless-render-ops** | tmux+caffeinate launch pattern, per-frame progress logs, cron health checks, `powermetrics` GPU/thermal monitoring, cross-machine parallel-render split math — for multi-day Blender/ML/transcode jobs. | Not applicable — markdown_viewer has no long-running render/compute jobs. | **project-specific-skip.** Unrelated domain (video/render pipelines), pure noise if vendored into an editor-app repo. |
| **blender-\*** (6 skills: `5x-api-gotchas`, `cycles-glass`, `cycles-render`, `cycles-volumetric-beams`, `laser-show`, `mcp-driving`) | Blender/Cycles domain knowledge and MCP-driving mechanics. | Not applicable. | **project-specific-skip** — entirely unrelated domain. |
| **chrome-extensions** | Manifest V3 build/publish guidance + 17 reference docs (content scripts, service workers, CSP/sandbox, Web Store review checklist, etc). | Not applicable — markdown_viewer is a native macOS app, not a browser extension. | **project-specific-skip.** |
| **modern-web-guidance** | ~95 reference guides across CSS layout, forms, passkeys, performance (CWV/INP), accessibility, scroll-driven animation, WebMCP. Triggers on HTML/CSS/client-JS work. | markdown_viewer's rendered-Markdown surface uses a WKWebView (per CLAUDE.md's "compositor occlusion" section and WebView test suites), so *some* of this (CSP, `content-visibility`, scroll-driven UX) is tangentially relevant to that WebView content — but the skill is written for building web *apps*, not embedding one WebView pane inside a native app. | **project-specific-skip** as a whole skill; if the rebuild leans more heavily on WebView-rendered content, cherry-pick individual reference docs (e.g. `performance/defer-rendering-heavy-content.md`) rather than vendoring the ~95-doc corpus. |

---

## 2. Hooks — `/Users/me/.claude/hooks/` + `settings.json` wiring

Two hook scripts exist as files, but **only one is actually wired**. `settings.json`'s `hooks` block
contains a single entry:

```json
"hooks": {
  "SessionStart": [
    { "matcher": "compact",
      "hooks": [{ "type": "command", "command": "bash /Users/me/.claude/scripts/handoff-reinject.sh" }] }
  ]
}
```

No `PreToolUse` entry exists anywhere in `settings.json` (confirmed — grepped for `PreToolUse`,
`backup-on-write`, `block-edit-fullfile` across `settings.json`; no `settings.local.json` exists).

| Hook script | Location | Trigger (per script's own header comment) | Actually wired? | What it does | Problem solved | Port verdict |
|---|---|---|---|---|---|---|
| `handoff-reinject.sh` | `~/.claude/scripts/` (referenced from `settings.json`, not `~/.claude/hooks/`) | `SessionStart`, `matcher: "compact"` | **Yes** — live in `settings.json`. | Reads the SessionStart JSON on stdin; only acts if `.source == "compact"`. Reads `$cwd/HANDOFF.md`, verifies the `<!-- CLAUDE-HANDOFF v1 -->` marker (so it never injects an unrelated file), enforces a **12000-byte budget** (truncates + appends a loud self-correction instruction if over budget — this is the enforcement half of the `HANDOFF.md` ≤12KB rule stated in markdown_viewer's own `CLAUDE.md`), then appends a **"HOT FILES" list** (`git diff HEAD~10..HEAD` + `git status --porcelain`, deduped, capped at 25) with an explicit "re-Read before Edit/Write" instruction. Emits via `hookSpecificOutput.additionalContext` (the only SessionStart output shape that reaches the model — plain stdout only reaches the user). Fails open on any missing dep/file/parse error. | **This is the direct mechanism behind markdown_viewer CLAUDE.md's "Context budgets" section** — the hook is what actually enforces the 12KB `HANDOFF.md` cap at runtime (the `ContextBudgetTests` Swift test is the *repo-side* teeth; this hook is the *harness-side* teeth). Also directly targets the #1 post-compaction error class noted in the hook's own comment: "260 hits in the 1.3GB-session meta-analysis" of Edit/Write firing on files whose read-state compaction wiped. | **vendor-in-repo, adapted.** This is the single highest-value hook to bring day-1: pair it with an in-repo `HANDOFF.md` budget test from the start (not bolted on later, as happened here per the CLAUDE.md dated note). The git hot-files logic is entirely generic (any git repo) and needs zero adaptation. |
| `backup-on-write.sh` | `~/.claude/hooks/` | `PreToolUse` on `Write`, per header comment | **No** — not present in `settings.json`'s `hooks` block. | If `Write` targets a path that already exists, copies it to `~/Documents/backup/claude/file_overwrites/<path-with-/-as-->.{timestamp}` before the write proceeds, logs an audit line. Never blocks. | Implements the *belt* of the global CLAUDE.md "Safe file writes — never destroy data" policy (never assume a filename is unused). | **Gap worth flagging, not just a port verdict**: the script exists and is well-written, but with no `PreToolUse` registration it is currently **inert** — Write overwrites are not actually being backed up by this mechanism today, despite the policy being documented as if enforced. Either it was deliberately disabled, or it regressed out of `settings.json` at some point. **Recommendation for the rebuild:** vendor-in-repo (or keep-global, doesn't matter for this one since backups land in `~/Documents/`, not the repo) **but add a startup self-check** — a hook/script that asserts its own hooks are actually registered in `settings.json`, so policy-vs-enforcement drift like this is caught immediately instead of silently. |
| `block-edit-fullfile-rewrite.sh` | `~/.claude/hooks/` | `PreToolUse` on `Edit`, per header comment | **No** — same gap as above. | If `Edit`'s `old_string` equals the entire current file contents (mod one trailing newline), denies the edit via `hookSpecificOutput.permissionDecision: "deny"` with a reason instructing a new versioned file instead. | Implements the *suspenders* of the same safe-writes policy — catches the "Edit used as Write-in-disguise" loophole the backup hook alone wouldn't catch (a full-content Edit silently replaces the file with no backup trigger, since `backup-on-write.sh` only fires on the `Write` tool). | Same as above: **vendor-in-repo + self-check.** This one is arguably more valuable to port since it's a hard `deny`, not just a soft backup — actively prevents the failure mode rather than just insuring against it. |

---

## 3. Scripts — `/Users/me/.claude/scripts/`

| Script | Called by | Purpose |
|---|---|---|
| `handoff-reinject.sh` | `settings.json` SessionStart hook | Covered above. |
| `save-session.sh` | `save` skill | Walks `$PPID` → `~/.claude/sessions/<PID>.json` for session identity, tars `transcript.jsonl` + `meta.json` + optional `file-history/`/`tasks/`/`session-env/` into `~/Documents/backup/claude/session_backup/<name>_<timestamp>[_<suffix>].tar.gz`, writes a `.meta.json` sidecar for fast listing. Safe-write: appends `$$` on same-second filename collision rather than clobbering. |
| `load-session.sh` | `load` skill | List mode (newest-first, sourced from sidecar `.meta.json` when present) or restore mode (extract bundle to temp, generate fresh UUID, `sed`-rewrite every old-sessionId reference in the transcript to the new UUID, re-place extras dirs, print `claude --resume <uuid>`). Handles both new `.tar.gz` and legacy bare-`.jsonl` bundle formats. |

Both `save-session.sh`/`load-session.sh` are **keep-global** for the same reason as their skills —
they operate purely on Claude Code's own per-machine session storage, which has no repo-side
counterpart to vendor.

---

## 4. Global `~/.claude/CLAUDE.md` — existence + section map only

Confirmed to exist, 205 lines. Per instructions, content is **not** reproduced here — only the
section-heading map (this is the user's personal cross-project engineering-style contract, not
project state):

```
# About me
# Dependencies and project setup
# Project tracking
# Bash command style
# Git workflow
# Tool-use narration
# Tool initiative — be eager, not hesitant
# Research — don't bias the inputs
# Containerized tests on macOS
# Safe file writes — never destroy data
# File locations — never write to /tmp
# Printing paths, URLs, and ports
# Response shape
  ## When I push back, correct, or call out an issue
  ## Inline label vocabulary (use what applies, skip the rest)
  ## Multi-item / batched prompts
  ## Use formatting tools generously
    ### Lean into Claude Code's terminal rendering
  ## Confidence and uncertainty
  ## Guidance on Automated Development Life Cycle
    ### Automated Guidance
```

This is the layer that supplies senior-engineer calibration, dependency-approval gates, git
trunk/rebase discipline, bash-narration style, the safe-writes policy (whose enforcement hooks are
examined in §2), the `/tmp`-is-forbidden rule, and the principles-flavored "Automated Guidance" block
that governs autonomous/cron behavior. None of it is markdown_viewer-specific; it applies unchanged
to every project this user runs Claude Code against.

**Port verdict: keep-global, unambiguously.** This is identity/style, not project state — vendoring
it in-repo would fork it per-project and rot immediately.

---

## 5. Project memory — `~/.claude/projects/-Users-me-Documents-workspaces-claude-markdown-viewer/memory/`

- **`MEMORY.md`** (the index file itself): 56 entries, one line each, format
  `- [Title (date)](filename.md) — one-line takeaway`, each linking to a standalone `.md` file in
  the same directory. Prefixed `⭐` on ~9 entries marking especially load-bearing lessons.
- Directory holds **60 files total**: the `MEMORY.md` index + 59 individual memory notes, split by
  the naming-prefix taxonomy visible in the index — `feedback_*` (28 files, user corrections/style
  preferences), `project_*` (12 files, standing decisions/state for specific initiatives like the
  Rust-core migration or the canvas epic), `reference_*` (19 files, reusable technical facts like
  VM SSH-key recovery or macOS memory-metric gotchas).
- This directory is **keyed by the encoded absolute cwd path**
  (`-Users-me-Documents-workspaces-claude-markdown-viewer`) — it is Claude Code's own per-project
  memory feature, addressed by path hash, not by anything inside the repo.

**Finding worth surfacing:** this project's own memory (`project_repo_relocated.md`, per the
index) already documents a near-miss where exactly this addressing scheme was put at risk — an
iCloud sync incident on `~/Documents` threatened to move/empty the repo, which would have
orphaned this entire memory directory (a *different* encoded-cwd path = a *different*, empty
memory store from Claude Code's perspective). The `handoff` skill's own Phase 1 instructions
already hedge against this correctly ("save genuinely durable facts that aren't derivable from the
repo... skip anything the repo or git history already records") — i.e., the design intent is that
`MEMORY.md` is a *supplement* for facts that don't belong in repo docs, while `LESSONS.md`/
`BACKLOG.md`/`HANDOFF.md` (all in-repo, git-tracked) are the durable, portable primary record.
That intent is sound; the risk is only in facts that *only* ever get written to memory and never
promoted to a repo doc.

**Port verdict:** memory itself is **not portable** (mechanically pinned to cwd path) — nothing to
vendor. The actionable takeaway for a rebuild is procedural, not a file to copy: *treat memory as
disposable/regenerable, and audit periodically (e.g. at each `/handoff`) that anything genuinely
load-bearing has also landed in an in-repo doc.*

---

## Notable gaps found during this audit

1. **Dangling skill references in the project's own `CLAUDE.md`.** markdown_viewer's `CLAUDE.md`
   repeatedly references a `run-uat` skill and a `vm-ui-testing` skill/lane (e.g. "run via the
   `run-uat` skill, NOT `swift test`", "`.claude/skills/run-uat` / `vm-ui-testing`"). Searched
   exhaustively — `find` across both the entire repo and the entirety of `~/.claude/` for
   `*run-uat*` / `*vm-ui-testing*` — **zero matches**. These skills do not exist anywhere on this
   machine today. Either they were removed, never actually committed after being planned, or they
   lived in a worktree that was since reaped. This is the exact failure mode this whole research
   task exists to prevent: **a skill load-bearing enough to be named as mandatory testing
   procedure in the project's own instructions, that was never durably vendored anywhere.**
2. **Policy/enforcement drift on the safe-writes hooks** (§2): `backup-on-write.sh` and
   `block-edit-fullfile-rewrite.sh` are fully written, well-commented, and describe themselves as
   `PreToolUse` hooks — but neither appears in `settings.json`'s `hooks` block, so (best guess,
   not independently runtime-verified) they are not currently firing, despite the global
   `CLAUDE.md` describing the safe-writes policy they implement as if it were active.

---

## Rebuild recommendation

**Split principle:** vendor in-repo anything that encodes *how this specific project must be
operated* (so a fresh clone on a new machine gets the harness for free, and so "the skill doesn't
exist anymore" can never happen again); keep global anything that encodes *how this user works
across all projects* (style, git discipline, cross-project utilities) — duplicating that per-repo
would fork it and let copies drift.

**Commit into the new project's own `.claude/` on day 1:**

- **`.claude/settings.json` (project-scoped, not global)** wiring:
  - `SessionStart` → a repo-local copy of `handoff-reinject.sh` (adapt only the budget constant
    and the git hot-files window; the marker-line + fail-open logic is already generic).
  - `PreToolUse` → repo-local copies of `backup-on-write.sh` and `block-edit-fullfile-rewrite.sh`,
    **actually registered this time** — and add a trivial startup/CI check that greps
    `.claude/settings.json` for the hook command paths the repo ships, so a future silent
    deregistration (as apparently happened here) fails loudly instead of quietly.
- **`.claude/skills/handoff/SKILL.md`** — a repo-owned copy of the 4-phase handoff procedure,
  tuned to this project's actual doc set (`HANDOFF.md`/`LESSONS.md`/`BACKLOG.md` + whatever
  tracker it uses) from the start, rather than bolted on mid-project.
- **Any skill a project's own `CLAUDE.md` names as mandatory procedure** (the `run-uat` /
  `vm-ui-testing` lesson): if a testing/validation lane is load-bearing enough to be referenced by
  name in project instructions, its `SKILL.md` belongs in `.claude/skills/` **inside that repo**,
  full stop — never only in `~/.claude/skills/`, where it can be edited/removed by unrelated work
  in a different project and silently orphan every reference to it.
  - Also worth generalizing beyond skills: **any script a project's `CLAUDE.md` treats as
    mandatory tooling belongs in the repo's own `scripts/`, not `~/.claude/scripts/`** — same
    orphaning risk, same fix. (This project already gets this right in practice — its VM test
    scripts live under `scripts/`, e.g. `scripts/test-in-vm.sh` — the gap is specifically the two
    named-but-missing skills, not the scripts layer.)
- **A context-budget test/gate** (this project's `ContextBudgetTests`) alongside the
  `HANDOFF.md`-reinject hook from day 1 — ship the soft (hook truncation) and hard (CI-gated test)
  enforcement together, not staggered.
- **Empty-but-headed scaffolds** for `HANDOFF.md` (with the `<!-- CLAUDE-HANDOFF v1 -->` marker
  already in place), `LESSONS.md`, `BACKLOG.md` — so the very first `/handoff` invocation has a
  target instead of having to invent the convention mid-project.

**Leave global** (no action needed, already correctly scoped): the user's `~/.claude/CLAUDE.md`
identity/style contract; `save`/`load` session-bundle skills and their scripts (pinned to Claude
Code's own per-machine session storage, nothing to vendor); cross-project utility skills
(`osv-scanner`, `home-deps-audit`, `local-fleet`, `apple-container-test-env`,
`mac-headless-render-ops`) — invoke them from the new project when relevant rather than forking
copies into it; domain-specific skills with zero overlap (`blender-*`, `chrome-extensions`,
`modern-web-guidance`) — irrelevant noise if vendored into an unrelated repo.

**Treat as inherently non-portable, budget for it explicitly:** the `~/.claude/projects/<encoded-
cwd>/memory/` auto-memory store. It cannot be vendored (it's keyed by absolute path, not repo
identity) and is one `git mv`/relocation away from silently starting over, as this project's own
memory (`project_repo_relocated.md`) already records happening once. The mitigation isn't
technical, it's disciplinary: keep leaning on the `handoff` skill's existing "promote durable
facts to repo docs, use memory only as a supplement" rule, and don't let a fact live *only* in
memory if it's genuinely load-bearing.
