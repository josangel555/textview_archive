<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous WORK_QUEUE drain → feature vein exhausted  (2026-06-14)

**Session:** claude-mdv (autonomous 10-min loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `9393706`

## Mission
Autonomous loop draining `WORK_QUEUE.md` top-down (build, host-test the model, leave render at `review`; batch + gate once; commit per item). `main` stays headless-gate-green.

## Current state (the important part)
- **The clean, host-testable, NON-render feature vein is drained.** Many firings this session shipped Section-A/B + several Section-C/epic slices. What remains across the WHOLE board is: render/VM (`[VM]` Section-C + the snippets render slices), risky (rust-core **TSK-844** CSV-arena = a *security* heap-cap re-derivation; **TSK-382** DocumentModel central refactor), owner-gated (**343**, **358**), or deferred-by-design (308/309), or foreign (441-445 = tasked-tool dev, skip).
- **Snippets epic (TSK-705): MODEL LAYER 100% DONE, host-tested.** Slices: 1 parser (`SnippetExpansion`/`ParsedSnippet`), 2 `SnippetLibrary` built-ins, 3 `DocumentModel.insertSnippet` + Edit▸Insert-Snippet menu, 4 `SnippetStore` (user JSON, merged over built-ins), 5 `SnippetSession` (tab-stop nav model). All in `Sources/ViewerCore/Snippets/`. **Remaining = pure render/VM:** CM6 Tab-key wiring (apply `SnippetSession`: intercept Tab → select the returned range → advance) + a management UI.
- **≈13-item `review` backlog** (my recent `[VM]` work: 355/753/755/756/762/718/726/759/360/352/705…) awaits a VM/owner glance to reach `done` — I can't self-validate render-coupled behavior on the host.
- Working tree clean (except pre-existing untracked `archive/Untitled.txt`, `untitled*.md` — NOT mine).

## Next action (pick one — needs an owner steer for max value)
The autopilot default is another `[VM]` model fragment, but the **high-leverage moves are owner-gated**:
1. **Answer 343** (local-history: snapshot-on-save default-on vs opt-in + retention) → unblocks a clean wiring+revert build (the `LocalHistoryStore` engine is already built+tested).
2. **Answer 358** (absolute font-size × zoom interaction; wait for TSK-470?).
3. **Lane steer:** (a) **rust-core 844** — needs a FRESH focused session (security heap-cap; don't rush deep in a long session); (b) keep **snippets render slices** on the VM; (c) **382** memory with a profiling spike.
4. **Clear the `review` backlog** on the VM (`bash scripts/test-in-vm.sh` / the GUI pixel lane) → many items → `done`.

## Key facts / gotchas (also in LESSONS.md)
- **`Formatter.SupportedFormat.detect` is a VIEW-MODE change** (gates the `.formatted` lens + Format toggle via a dual gate with `ViewMode.formatterExtensions`) — markdown is deliberately in neither. (TSK-350 lesson.)
- **A change to `Formatter.detect` / a wire / a staged header** can false-fail the gate via stale `mdv-serve` (`cargo build -p mdvcore-serve`). NEVER bundle `git commit` with the gate-verdict grep.
- Gate = `bash scripts/test-headless-gate.sh` (uses `.build-gate` scratch). Heavy tiers self-skip on host. `^EXIT=` via `$?` (zsh has no bash `PIPESTATUS`).
- CM6 DOM styling (e.g. TSK-360 gutter tint, snippet Tab-nav) is INSIDE the WebView — not the SwiftUI-over-WebView compositor trap; but its VISUAL still needs VM pixels.

## Tracker
- `tasked` board (`:8787`, project `tasked`, agent `claude-mdv`). TSK-705 at `review` (model done). TSK-343 parked (waiting:human). Consolidated DECISIONS NEEDED live in `docs/AUTONOMOUS_PROGRESS.md` (top log).

## How to resume
1. Read THIS, then `docs/AUTONOMOUS_PROGRESS.md` (top logs — current strategic state + DECISIONS NEEDED), then `WORK_QUEUE.md`.
2. `git -C <repo> log --oneline -5` (HEAD ≥ `9393706`); confirm tree clean.
3. If the owner answered 343/358 or steered a lane → do that. Else: the cleanest *autonomous* build left is a `[VM]` Section-C model fragment or the snippets CM6 Tab-wiring (VM-validated). Honestly, surfacing the steer (above) is higher-value than more thin slices.
