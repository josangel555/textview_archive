> Provenance: research subagent a56fc31d (web + repo-grounded, read-only) on 2026-05-31. The simple, safe way to manage and clean the git-worktree buildup.

# Git Worktrees: Lifecycle, Safe Cleanup, and Preventing the 124 GB Buildup

## Situation in one paragraph

~60 agent worktrees under `.claude/worktrees/`, created by Claude Code's subagent system, each **locked** with the owning agent PID. Both locking PIDs are **dead** — orphaned from interrupted/crashed parallel runs. The 124 GB is **almost entirely `.build/`** (Swift build output, ~2–3 GB each); the shared `.git` is only **36 MB**. `.build/` is gitignored, the worktrees have **zero uncommitted non-ignored changes**, and **73 of 79** agent branches are already merged into `main`. **Net: deleting all agent worktrees loses essentially nothing** — almost all 124 GB is reclaimable build cache.

## 1. Lifecycle

```
add → use → remove → prune
git worktree add <path> [<branch>]     # linked tree, shares the ONE object DB
(commit in it; objects + ref land in shared .git)
git worktree remove <path>             # deletes dir + admin metadata (the clean teardown)
git worktree prune                     # only mops up metadata for dirs already gone
```

## 2. Directory vs shared object DB — what's lost vs preserved

| Artifact | Lives where | Survives deleting the worktree dir? |
|---|---|---|
| Committed work (reachable from a branch) | shared object DB + `refs/heads/<b>` | **Yes** |
| Branch ref | shared `refs/heads/` | **Yes** — `remove`/`prune` never delete the branch |
| Reflogs / stashes | shared `.git` | **Yes** |
| **Uncommitted / untracked changes** | only the working dir | **No — gone** |
| Build artifacts (`.build/`) | working dir (gitignored) | **No — but disposable** |

The only irreplaceable thing in a worktree is uncommitted/untracked work — here, **none**.

## 3. Locking — why, and how to remove locked ones

Claude Code locks each agent worktree with its PID so a concurrent `prune`/`gc` won't yank a *running* agent's tree. The gap: on crash/interrupt nothing unlocks them → immune to auto-prune forever (locked = immortal at any age).

```bash
git worktree unlock <path> && git worktree remove <path>   # preferred (remove still guards unclean)
git worktree remove --force --force <path>                 # double-force: removes locked + unclean
```

## 4. Build-artifact bloat — the actual root cause

Each worktree got its own full `.build/` → 60 × ~2 GB. Fix: keep build output **outside** the worktree.
- **SwiftPM (us):** `swift build --build-path <shared>` or `SWIFTPM_BUILD_DIR` (newer toolchains). Point at a per-agent subdir under a shared parent **outside** `.claude/worktrees/` (SwiftPM tolerates a shared parent + per-agent subdir better than one literal shared dir for concurrent builds).
- **Cargo (the Rust core, later):** `CARGO_TARGET_DIR`.

This decouples "reap the worktree" (instant) from "reap the 2 GB cache" (independent schedule).

## 5. Why `git gc` never reaped these

- `gc` auto-runs `worktree prune --expire 3.months` — **but only removes entries whose directory is missing.** Ours all exist.
- **`locked` exempts the entry from pruning at any age.** Locked + present = permanently immortal.
- Commits reachable from a branch ref are never gc'd — the 79 branch refs pin them (harmless for disk; clutters `git branch`).

Net: nothing was ever going to self-clean. Lock defeats prune; live refs defeat object gc.

## 6. The simple, safe cleanup

Pre-flight (read-only):
```bash
repo=/Users/me/Documents/workspaces/claude/markdown_viewer
for d in "$repo"/.claude/worktrees/*/; do s=$(git -C "$d" status --porcelain 2>/dev/null); [ -n "$s" ] && echo "DIRTY: $d"; done
git -C "$repo" worktree list --porcelain | grep -o 'pid [0-9]*' | sort -u   # confirm PIDs dead
```
Reap (reclaims ~124 GB):
```bash
git -C "$repo" worktree list --porcelain | awk '/^worktree .*\/\.claude\/worktrees\//{print $2}' \
  | while read -r wt; do git -C "$repo" worktree unlock "$wt" 2>/dev/null; git -C "$repo" worktree remove --force "$wt"; done
git -C "$repo" worktree prune --verbose
```
Then drop **merged** scratch branch refs (cosmetic):
```bash
git -C "$repo" branch --merged main --list 'worktree-*' | xargs -r git -C "$repo" branch -d
```
Do **not** blanket `-D` unmerged branches. Optional compaction: `git gc --prune=now`.

## 7. Preventing recurrence

1. Move build output out of the worktree (`--build-path`/`SWIFTPM_BUILD_DIR`) — biggest single win.
2. Reap on a schedule keyed on **dead lock PID** (not age — a long run is legitimately old).
3. Upgrade Claude Code ≥ v2.1.76 (built-in stale-worktree cleanup; fires only on new-session start, so still pair with #2).
4. `git config gc.worktreePruneExpire 1.week.ago` (won't help locked entries — only #2 does).
5. Periodically delete merged agent branches.

## Pitfalls
- `rm -rf` a worktree without `prune` → stale metadata ("prunable"). Always `remove`, or `prune` after.
- **Lock = immortal** — a tool that locks-with-PID but never unlocks on crash accumulates unboundedly (exactly this bug).
- `remove` ≠ branch deletion (branch ref survives; delete separately). Deleting the dir never costs committed work.
- `git status --porcelain` per worktree before any force-remove of a fleet.
- Shared build dir + concurrent builds can corrupt/serialize — prefer per-agent subdirs under a shared parent.

### Sources
git-worktree / git-gc / git-prune docs; gitworktree.org; claude-code#34282 (stale-worktree cleanup gap, fixed v2.1.76); Rust Project Goals (cargo build-dir layout); various engineering blogs (cited in the research transcript).
