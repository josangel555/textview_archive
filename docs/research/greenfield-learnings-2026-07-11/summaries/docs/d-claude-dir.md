# `.claude/` Configuration Layer — Summary & Learnings

**Batch:** Agent-harness layer configuration (`.claude/` project settings, skills, hooks, agents)  
**Date:** 2026-07-11  
**Status:** Empty directory; no project-specific agent configuration found  
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Overview

The `.claude/` directory exists but **is completely empty**. The markdown_viewer project contains no project-specific agent configuration, no custom skills, no lifecycle hooks, and no settings overrides — it relies entirely on Claude Code harness defaults and the global `~/.claude/CLAUDE.md` user instructions.

---

## File Inventory

```
/Users/me/Documents/workspaces/claude/markdown_viewer/.claude/
└── (empty)
```

**Analysis:** The directory was created but never populated. The configuration guidance lives in:
- **Project-specific instructions:** `/Users/me/Documents/workspaces/claude/markdown_viewer/CLAUDE.md` (39 KB, committed to repo) — ENTIRELY replaces what would go in `.claude/settings.json`
- **Global user instructions:** `/Users/me/.claude/CLAUDE.md` (comprehensive system-wide policies)
- **Project board tracking:** via MCP tools at `localhost:8787` (tasked server, shared across projects)
- **Test/build configuration:** in `scripts/` (shell scripts), `Package.swift` (Swift), `rust-core/Cargo.toml` (Rust), CI workflows

---

## Key Findings

### 1. **Configuration-as-Markdown, Not Configuration-as-JSON**

The project chose to **encode all agent-facing policy directly in `CLAUDE.md`** rather than in structured `.claude/settings.json`. This is unusual but has merits:

**Pros:**
- Git-tracked, versioned alongside code changes (a policy-change appears in commit history)
- Human-readable, narrative-friendly — explains *why* policies exist (e.g., root-cause discipline, testing mandates, VM-only UI tiers)
- Linked from code comments (`CLAUDE.md §Task tracking`) so developers know where to find the source
- Single source of truth per project (no sync risk between CLAUDE.md and settings.json)
- Owner reviews policy changes in PR context, not auto-inherited from global defaults

**Cons:**
- Agents cannot parse this structure into actionable constraints (no machine-readable manifest)
- No integration with the Claude Code `update-config` skill for runtime policy changes
- Policies are advisory prose, not enforced gates (agents can misread or ignore guidance)
- Searching across projects requires grep + file reading, not a unified `settings.json` schema

### 2. **No Custom Skills or Hooks**

The `.claude/` directory references a non-existent skill:
- `CLAUDE.md:29` mentions `.claude/skills/run-uat` for agent-driven UAT validation
- This skill was never created; the actual UAT harness lives in `docs/research/agent-uat-framework-2026-06-20/` and `scripts/vm-*` shell scripts

**Implication:** Custom skills are entirely absent from this project. All agent tooling is either:
- Built-in Claude Code skills (`run`, `verify`, `code-review`, etc.)
- MCP tools (`mcp__tasked__*` for board operations, `mcp__textview__*` for UI automation once available)
- Bash scripts in `scripts/` (invoked by agents via Bash tool, not registered as skills)

---

## Architectural Decisions Found

### A. **Distributed Configuration, Not Centralized**

The project spreads configuration across multiple sources rather than centralizing in `.claude/settings.json`:

| Configuration Layer | Location | Purpose |
|---|---|---|
| **Agent policy** | `CLAUDE.md` (repo root) | Testing mandates, git discipline, task lifecycle, autonomous-loop SOP |
| **Build/test config** | `scripts/`, `Package.swift`, `Cargo.toml` | Swift/Rust/JS deps, compile flags, test gates, VM credentials |
| **CI config** | `.github/workflows/` | PR gate, nightly suite, perf baseline |
| **Env flags** | `Sources/` + `scripts/` | 27+ distinct `MDV_*` flags (no central registry — **audit finding F8**) |
| **Secrets** | `scripts/test-in-vm.sh`, hardcoded `<vm-sudo-password>` | VM sudo password (split-brain F3) |
| **Board tracking** | `localhost:8787` (tasked MCP) | Task state, lifecycle, comments |
| **Hand-off state** | `HANDOFF.md` (repo root) | Pre-compaction session snapshot (12 KB budget) |
| **Institutional memory** | `LESSONS.md` (repo root, 333 KB) | Bug patterns, architecture notes, gotchas |

**This is the default for the owner's setup**: Agent-facing policy is MARKDOWN in the repo; infrastructure config is split by domain (build, CI, secrets, env). The `.claude/` layer is not used because:
1. No per-project overrides to the harness are needed (global `~/.claude/CLAUDE.md` suffices)
2. The project does not define custom skills or hooks
3. Policies are easier to version in git than in JSON sidecar files

---

### B. **Strong Test/Build Configuration, Weak Agent-Integration**

The config-hygiene audit (`docs/research/prelaunch-audit-2026-07-09/config-hygiene.md`) found:
- ✅ **Excellent dependency pinning** (Swift exact, Rust deny-list, cargo-deny.toml tightened)
- ✅ **Centralized LSP config** (externalizable JSON, not hardcoded)
- ✅ **Release gates** (`check-no-secrets.sh`, signed plist, entitlements minimal)
- ❌ **Scattered env flags** (27 keys, 54 read sites, no central registry — F8)
- ❌ **Per-machine hardcoded paths** (`/Users/me` in `.cargo/config.toml`, `.js` scripts — F2)
- ❌ **Build-cache migration half-applied** (two `target-dir` locations, cold rebuilds after reboot — F1)
- ⚠️ **Test-mode code in release binary** (MDV_ENABLE_BROKEN_*, MDV_FAKE_LSP_* not wrapped in `#if DEBUG` — F5)

**Implication:** Infrastructure configuration is robust where it matters (deps, secrets, gates) but has friction points (env-flag sprawl, path hardcoding) that a `.claude/settings.json` or centralized config module would catch.

---

### C. **Agent Autonomy Without Structured Guidance**

The project uses **autonomous chunk-loops** (agents work through a backlog without human intervention) and **workflow fan-outs** (Workflow tool spawning 40+ agents in parallel), yet has **no machine-readable constraints** on what agents can do:

- No `.claude/hooks` to enforce "revert breaking changes before committing"
- No `.claude/settings.json` to gate "only run these Swift versions"
- No skill registry for "use only these exact tools, not Bash for everything"
- Policy is prose: "Do NOT use the Workflow tool… Work INLINE" (CLAUDE.md), "Spike + design auto-approved" (TASK_WORKFLOW.md)

**This works** because the owner is also the architect (understands the constraints deeply) and agents are instructed to read the docs. **This would NOT scale** to a larger fleet or multi-owner setup.

---

## Portable Artifacts & Patterns

### 📌 **For the Next Project: `.claude/` Checklist**

If the owner wants to **formalize agent configuration** in the next project, the minimal `.claude/` structure would be:

```
.claude/
├── settings.json           # Project overrides (Swift version, build paths, env flags)
├── settings.local.json     # Machine-specific (user home, VM credentials) — .gitignored
├── hooks/
│   ├── pre-commit.sh       # Gate: no killall, no secrets, Swift version check
│   ├── post-commit.sh      # Log AUTONOMOUS_PROGRESS.md, validate board state
│   └── compaction.sh       # Prune HANDOFF.md, archive LESSONS.md sections
└── skills/
    ├── run-uat.md          # UAT skill (if custom scripting is needed)
    └── verify-render.md    # Pixel-test skill (if codified as a skill, not just docs)
```

**Status:** PORT the idea. This project **does not have these files**, so nothing to copy verbatim.

### 📌 **Lessons to Carry Forward**

1. **Configuration-as-Markdown is version-friendly** — Commit policy changes in git log, not in JSON migrations. Works well for agent-readable-but-not-machine-executable constraints (like testing mandates).

2. **Avoid per-user hardcoded paths** — F2 found `/Users/me` in `.cargo/config.toml`. Use `$(git rev-parse --show-toplevel)` in scripts, `${HOME}` or `~` in configs with careful shell expansion, or a `.gitignore`d override file for per-machine literals.

3. **Centralize env-flag reads** — F8 found 27 keys scattered across 54 call sites. Next project: one `EnvConfig` struct/enum per language, all reads go through it.

4. **Split-brain secrets are a footgun** — F3: two names for the VM password (`MDV_VM_SUDO_PASS` vs `MDV_VM_SUDO_PASSWORD`) mean one script reads the right var, another reads the fallback, password changes silently break half the suite. Use one canonical name + back-compat shim.

5. **Board (tasked MCP) is the system of record, not a sidecar** — This project uses `localhost:8787/mcp` as the authoritative task tracking, driven via MCP tools. Works well for agent autonomy (agents can read/advance task state as code) but creates a runtime dependency (MCP down = can't track). For the next project, **same pattern is recommended**.

6. **Thin the verify fleet; account session limits are real** — The audit workflow hit the session limit running 39 agents in parallel with a 3-agent verify fan-out. For autonomous runs, **run verifiers serially or in small batches**, not a full cartesian product.

7. **Do NOT over-decompose tickets** — 2026-07-10 directive (recorded in CLAUDE.md §Task tracking, BACKLOG.md, memory): a ticket = one PR/commit, not each step. Fold checklist items into the parent. Legit splits = different tier/lane (host model vs VM render), not "write code" + "write test" + "update docs".

---

## Decision Records

### D1: **Configuration-as-Markdown, Not Configuration-as-JSON**

**Decision:** Store agent-facing policy in `CLAUDE.md` (repo-root, committed, markdown), not `.claude/settings.json` (JSON, separate from code).

**Rationale:**
- Policy changes are visible in git history
- Narrative explanation of *why* is preserved (e.g., why UAT must run on VM, why over-decomposition is bad)
- No sync risk between prose and structured config
- Agents read the same docs humans read

**Trade-offs:**
- Not machine-enforceable (agents can ignore prose guidance)
- Searches must grep the file, not query a schema
- Updates require prose rewrites, not JSON merges

**Outcome:** Worked well for a ~8-week intensive build; **would need formalization (settings.json) at scale** (10+ agents, multi-owner).

### D2: **No Custom Skills; Use Existing Claude Code Skills + MCP Tools**

**Decision:** Do not create `.claude/skills/` — rely on built-in skills (`run`, `verify`, `code-review`) and MCP tools (`mcp__tasked__*`).

**Rationale:**
- Built-in skills are well-tested and familiar
- MCP tools (tasked, textview) provide domain-specific RPC without custom skill boilerplate
- Custom skills require testing/versioning overhead

**Trade-offs:**
- Can't enforce "use only these tools" as a machine-readable constraint
- Custom logic (e.g., a domain-specific UAT runner) is prose guidance + bash scripts, not a branded skill

**Outcome:** Effective for this project. **Next project should consider custom skills if**:
- A repeated pattern emerges (e.g., "render-validate 10 times per ticket") that would benefit from a skill boundary
- Multi-agent coordination requires a shared harness (e.g., a verification skill that runs on behalf of all agents)

### D3: **Centralize Env Flags (Deferred)**

**Decision:** Do NOT create a central `EnvConfig` module or `.claude/settings.json` for env flags. Leave them scattered across 54 sites (F8).

**Rationale:**
- Project was under time pressure; refactoring 27 env-flag reads would be churn
- Env flags are operational overrides, not load-bearing architecture

**Trade-offs:**
- Typos in flag names fail silently (a mistyped `MDV_` read just means "off")
- Audit surface is large (anyone can enable test hooks like `MDV_ENABLE_BROKEN_RULER` in the release build)

**Outcome:** Acceptable for a pre-launch push. **Next project should centralize from day one** (one `EnvConfig` type per language, all reads go through it; guards in `#if DEBUG` for test-only flags).

---

## Recommendations for Greenfield (Next Project)

### 🎯 **Immediately (Day 1)**

1. **Create `.claude/settings.json`** with:
   - Swift version constraint (e.g., `"swift": "6.3"`)
   - Project paths (root, build, test output, VM mount points)
   - One canonical VM password variable name (e.g., `"vm_sudo_pass_env": "MDV_VM_SUDO_PASS"`)

2. **Create `.claude/hooks/pre-commit.sh`** to:
   - Reject hardcoded `/Users/<name>` paths
   - Reject `killall MarkdownViewer` (or by app name) except in explicitly-whitelisted scripts
   - Reject duplicate env-var names (e.g., `MDV_VM_SUDO_PASSWORD` alongside `MDV_VM_SUDO_PASS`)

3. **Document env flags early** — one `enum EnvFlag` or `struct EnvConfig` in each language (`Swift`, `Rust`, `Shell`) with:
   - Canonical name
   - Type (boolean, string, path)
   - Default value
   - One-line purpose
   - Build guard (`#if DEBUG` for test-only)

### 📋 **Phase 2 (After Day 5)**

4. **Thin the verify fleet.** If using Workflow for autonomous runs, don't cartesian-product verifiers. Run them serially or in fixed-size batches.

5. **Centralize agent-facing policy** — still in `.claude/CLAUDE.md`, but structured with clear sections:
   - Testing mandates (tier definitions, gate rules, UAT lanes)
   - Git workflow (rebase + ff, commit hygiene, board discipline)
   - Autonomy scope (what agents can auto-approve, what needs owner park)
   - Env-flag reference (with defaults, build guards, deprecations)

6. **Add `.claude/settings.local.json` (`.gitignore`d)** for:
   - User home path (for build-cache, test artifacts)
   - VM host/user/password (if different from team defaults)
   - Any machine-specific paths that would break on VM/other-developer clones

---

## Summary: What to Keep, What to Skip

| Artifact | Status | Carry-Forward |
|---|---|---|
| **Empty `.claude/` directory** | SKIP | Start from scratch; don't replicate the absence |
| **Configuration-as-Markdown** (CLAUDE.md) | PORT | Works well for narrative policy; add structured sections (enum, reference) |
| **Distributed config** (script + manifest + CI) | DISTILL | OK for build/test, but centralize env flags early to avoid F8 |
| **No custom skills** (use built-ins) | DISTILL | Good baseline; add skills only if a pattern repeats 3+ times |
| **Env-flag sprawl** (27 keys, 54 sites) | SKIP | Fix F8 before the next project ships; centralize from day one |
| **Per-machine hardcoding** (F2) | SKIP | Use `$(git rev-parse --show-toplevel)`, `${HOME}`, or `.gitignore`d overrides |
| **Split-brain secrets** (F3) | SKIP | One canonical var name per secret + back-compat shim if needed |
| **Board + MCP tracking** | PORT | Tasked MCP at localhost:8787 is excellent; extend for next project |
| **Chunk-loop autonomy** (work w/o asking) | PORT | Powerful pattern; guard with clear scope in settings + hooks |

---

## Metrics & Gaps

- **Files in `.claude/`:** 0
- **Custom skills:** 0
- **Lifecycle hooks:** 0
- **Env flags centralized:** 0/27 (all scattered)
- **Per-machine paths hardcoded:** 4+ (`/Users/me` in `.cargo/config.toml`, `.js` scripts, `render-icon.swift`)

---

## Appendix: Referenced Audits & Docs

- `docs/research/prelaunch-audit-2026-07-09/config-hygiene.md` — Findings F1–F8 (config weaknesses)
- `CLAUDE.md` — §Task tracking (over-decomposition directive), §Autonomy (chunk-loop SOP)
- `TASK_WORKFLOW.md` — Lifecycle lanes, autonomy scope, validation policy
- `BACKLOG.md` — Pre-launch audit findings (themes 1–6, unverified)
- `LESSONS.md` — Gotchas, patterns, architectural notes (333 KB, dense)
