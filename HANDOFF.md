<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous cron drain: test-gap + CI-guard arc  (2026-06-22, later ticks)

**Session:** claude-mdv (AUTONOMOUS, ~5min cron).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `d1a2e995` (verify `git log -1`).

## Mission
Autonomous cron drain: pull from the tasked board, drive items to validated, keep `main` headless-gate-green, commit per item (inline — NO workflows).

## Current state — LATEST arc done (2026-06-22 later ticks; all on main, gate-green, validated)
- **Document-tools model-wiring test-gap campaign (7 tickets, ~38 host tests, each filed→validated):** the curated `[reported]` list is heavily STALE — many features are built+validated but had ZERO model-layer host coverage (the engines were tested, the `DocumentModel` wiring was not). Covered: TSK-1113 (case transforms), 1224 (Edit▸Lines), 1225 (cleanup + line-ending), 1226 (CSV-export), 1227 (stats + Markdown link-check), **1228 (HTML-export + 2 SECURITY fences: author-HTML escape + image-inlining containment)**, 1229 (JSON minify + JSON→CSV). All pin the `applyTextTransformToActiveFile`-family + CSV/JSON conversion wiring (write-to-disk, the `can*` gates, no-op/no-file contracts).
- **CI-guard arc:** TSK-788 audit gaps G1–G4 verified done; TSK-1098 residual doc-drift cleanup; the never-shipped WebView-lane CI guard (TSK-1231, in `InfraInvariantTests`).
- **Self-correction:** TSK-1230 was a DUPLICATE of the pre-existing `BundleCapDocConsistencyTests` → removed + dismissed-as-duplicate; lesson recorded.
- (Earlier this run: Rust FormulaEngine port TSK-1213/1216 + on-screen wiring TSK-1215; fold port TSK-1202 — all gated OFF, owner-flip-pending. See `docs/AUTONOMOUS_PROGRESS.md` LOG 2026-06-22.)

## Next action — the clean host-buildable pool is DRAINED again; leverage is OWNER-GATED
1. **TSK-1215** (formula flip) + **TSK-1202** (fold flip) — both `waiting:human`, parity-proven + fuzz-hardened, gated OFF. Flip the gate → VM render-confirm → delete the Swift twin. THE step-change unlock; the agent build is done.
2. Other parked owner decisions: TSK-775 (migration horizon), TSK-1214 (bundle budget target), TSK-788 (audit depth).
3. If continuing autonomously: state-check the board FRESH. The document-tools + audit-gap test veins are drained — do NOT re-mine them. Render/perf/live features are VM-gated (build the host-testable model, leave render at review). Don't manufacture marginal/duplicate tests.

## Key gotchas / lessons (also LESSONS.md)
- **Grep `Tests/` for an existing guard BEFORE building one** (2026-06-22): I built a dup bundle-cap guard; `BundleCapDocConsistencyTests` already covered it. CI-invariants live in `InfraInvariantTests`; bundle-cap doc-sync in `BundleCapDocConsistencyTests`.
- **Curated `[reported]` is STALE** — state-check the item against the code first; many are already built/validated (this drove the whole test-gap campaign).
- **Engine tested ≠ feature shipped:** green tests prove the MODEL, not view consumption. Grep `Sources/` for a non-test consumer.
- **Per-method FFI ABI ripple:** dispatch enum + NEXT_FREE_ID + from_u16 + router + `MDV_METHOD_*` + 3 pinning tests + regen cbindgen via `build-rust-core.sh`. After ANY rust-core change, run `build-rust-core.sh` before the Swift parity tests.
- **Commit messages: NO backticks** (zsh substitutes inside `-m "..."`). Append the cron's `Claude-Session:` trailer.
- **Gate verdict in a SEPARATE step from the commit** (the `… | tail && git commit` exit-0 trap = false-green).
- **Validate cadence:** pure host-testable model/logic → self-validate with a teeth `checks` artifact; render/WebView/pixel → leave at review (VM/owner).

## How to resume
1. `git -C <cwd> log -1`; both gates green: `bash scripts/test-headless-gate.sh` (Swift) + `bash scripts/rust-core-gate.sh` (rust-core) — read each verdict in a SEPARATE step.
2. Fresh board scan (`mcp__tasked__task_next` / `task_list`). The clean host-buildable pool is drained; the leverage is the owner's two flips (above). Don't re-mine the test veins or build duplicate tests.
3. The instant the owner flips `MDV_RUST_FORMULA` or `MDV_RUST_FOLD`: run the post-flip drain (soak / VM render-confirm → delete the Swift twin + reclaim). Don't run T4/T5/WebView/dist on the host.

Commit trailer:
