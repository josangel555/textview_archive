<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous drain: render-tail (→review) drained → pivoted to the DocumentModel SRP vein (→validated). (2026-06-28)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `d2111fd2` (verify `git log -1`)

## Mission + OWNER DIRECTIVES (read first)
Autonomous drain loop (cron). Build INLINE, ONE item/firing: spike → implement → test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold LESSONS/AP/CHANGELOG into the item's commit; NEVER idle/stop ("no work" = process failure).
- **"Don't say risky — find the validation path + gain confidence yourself."** (memory `feedback_riskiness_not_a_blocker`). Pick by VALUE; name + DO the validation. Never defer/ask on "risky".
- **"BUILD render-path/VM-tail/perf features TOO — host-test the model, leave render/VM validation at review; do NOT hold for owner on-screen confirmation."**
- **"Pick actionable + proceed with runticks."** BACKLOG.md top has `⚡ Actionable now`.

## THE KEY FINDING this session — two veins, one drained, one flowing
1. **The render-tail user-facing vein is DRAINED for safe-autonomous work.** Every actionable render item's host MODEL was already built (verify-before-build confirmed repeatedly); the remainder is: (a) **occlusion-class render** (1119 mermaid overlay, RSS/browser/PDF/DOCX viewers — AppKit/WKWebView beside SwiftUI → the TSK-488 false-green trap; MUST be VM-pixel-verified, NOT host-green-shipped — do NOT build these blind); (b) **risky working-view rearchitectures** (1139 CSV windowing — sort/filter/select assume the full array); (c) **owner-gated** (the ~417 close-queue, flips 838/1215/1202, decisions 1129/543/589/810/1045/1138). I built the SAFE render-tail (8 items, all →review) — that work is done.
2. **The DocumentModel SRP split (TSK-1110) is the FLOWING vein — USE IT.** Behavior-preserving cluster extractions where **compile + headless gate = COMPLETE confidence** → drives to **validated** (not review; does NOT grow the owner's close-queue). Host-completable, not render/owner-gated, MANY clusters left. **This is the default autonomous work when nothing higher-priority is actionable.** One clean slice per tick.

## Landed THIS session
**Render-tail features (→review; render/VM = owner/VM closes pixels):** TSK-1271 find-scroll (`6e9e4efb`) · 1136/463 editor autocomplete (`868b4c74`,`2716669a`) · 924/1187 CSV multi-cell (verified done) · 1139 CSV viewport pager host core (`2830d9e2`) · 1163/958 Universal Paste (`e3438e72`).
**TSK-1146 editor spell-check — COMPLETE (→review), all 6 layers:** SpellCheckEngine → MarkdownSpellMask code-skip (`925b2481`) → SpellDiagnosticMapping (`a6715db7`) → EditorCoordinator source-tracked spell+LSP merge (`f9649a3f`) → updateEditorText debounced trigger (`eb75cef6`) → CM6 lintGutter render. Prose-gated (md/txt, 200K cap), markdown-aware, churn-guarded; host-tested every layer.
**rust-core:** `whitespace::reveal` proptest hardening (`f38478c3`, run-fresh per-module sweep found the gap).
**DocumentModel SRP slices (→validated-grade, behavior-preserving) — 14 this session:** focus-shortcuts (`aed6171c`) · view-hosting (`8e47f361`) · command-registry (`5061d6bf`) · theming (`52d6e72b`) · highlighting (`140a6a03`) · print/export (`04037cd3`) · rendered-cache (`7866ffe5`) · display-text (`edebd323`) · terminal-launch (`dfa1f1f4`) · active-file-LSP (`41199958`) · editor-buffer (`4c24a122`) · LSP-shared (`2f2494f6`) · CM6-hover (`9fd59346`) · CM6-completion (`d2111fd2`). Now **34 `DocumentModel+*.swift` extensions; DocumentModel.swift 5835 → ~5150 lines**. KEY learning: the core bridges DO decompose sub-cluster by sub-cluster (the "big-bang-only" worry was wrong — extract the request/response pairs, leave the big resolution method).
**Gate reliability:** killed the recurring CrossFileSearchBench false-red (`6455a6ae`) — a wall-clock RATIO assert can't measure inside the parallel gate; now skips under `MDV_HEADLESS_GATE` (see LESSONS).

## Gotchas / lessons (also in LESSONS.md)
- **SRP-extraction mechanics:** a stored prop CAN'T move to a cross-file extension (stays on the class, widen `private`→`internal` or `private(set)`→`internal(set)`); the compiler catches missing access-widening + cross-module imports (e.g. highlighting needed `import ViewerKit` for HighlightLanguage). Delete the method's PRECEDING `///` doc-comment too (else it orphans onto the next decl — gate-blind). Read the cluster fresh before editing (day-boundary resets read-tracking → Edit fails "not read yet").
- **Wall-clock RATIO benches flake the parallel gate** (`--num-workers 18` → contended); gate them behind `MDV_HEADLESS_GATE == nil`. Absolute-budget (5s/3s) + min≤mean asserts are robust.
- **Gate flakes (load-sensitive, NOT your change):** CrossFileSearchBench (now fixed), FoldBench, TabOpPerf (wall-clock), ChromeBodyEvalCount (body-eval), JQRunner (SIGPIPE process-spawn). Policy: confirm the change's OWN tests pass + failures are in that known set, then commit. Confirm gate via PASS MARKERS (`headless gate PASSED` + `tier enforcement: OK`), not just rc.
- **signal code 5** = a Swift Testing runtime trap (overflow/precondition) — diagnose `--filter <Suite> --no-parallel`.

## Next action (post-compaction)
1. `git log -1`; confirm gate-green at HEAD.
2. Engagement check: `mcp__tasked__audit {actor_kind:human, since:1782461740655}` (empty = owner hasn't touched the board).
3. **Continue the TSK-1110 SRP vein** (the flowing lane). DONE this session: print/export, rendered-cache, display-text, terminal-launch, active-file-LSP, editor-buffer, LSP-shared, CM6-hover, CM6-completion. REMAINING clusters in DocumentModel.swift: **`handleCompletionRequest`** (~566 lines — ONE cohesive method = a clean single-method move, but reproducing 566 lines verbatim is botch-prone; weigh it), **Editable-HEX** (#234, ~2611 — IO/`saveHexEdits` + NSAlert UI, interleaved stored props), **Open-As** (interleaved w/ view-mode-lock), and the big **Opening-files** (~1144) + **Tab-management** (~846) hot-path blocks (decompose sub-cluster by sub-cluster, don't big-bang). Per slice: read the cluster → write `DocumentModel+X.swift` → move methods (stored props stay, widen access as the compiler demands) → `swift build` → host gate → commit + record on TSK-1110 (epic stays open).
4. If a NEW signal appears (owner board action / new reported bug), act on it first. Do NOT build occlusion-class render blind; do NOT manufacture marginal sweeps (the coverage/rust per-module veins are drained — re-verify fresh before claiming, but they came up dry).

## How to resume
Read this + BACKLOG.md top. Confirm `main` gate-green. Continue: carve the next DocumentModel SRP cluster (full-confidence, →validated), one clean slice per tick, commit per item, fold docs in. The render-tail (8 items) + spell-check + the SRP slices all sit ready for the owner to close/VM-validate.
