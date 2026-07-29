## Closure status (2026-07-11, same-day gap-closure pass)

- **§1 root-docs fix — CLOSED.** `summaries/docs/d-root-md.md` now has per-file entries for
  `OVERNIGHT_REPORT.md`, `TESTS_AUDIT.md`, `VM-SETUP.md` and states the scope as 23 files.
- **§2 board ground truth — CLOSED.** `aspects/board-ground-truth.md` records a board-queried,
  authoritative total (1,474 tickets) with per-lane counts and the wx-contamination caveat;
  `MASTER_SYNTHESIS.md`/`holistic/PM_HOLISTIC.md`/`PORTABLE/PM_APP_LEARNINGS.md` now cite
  1,474 (board-verified 2026-07-11) instead of the old ~1,168/~1,500 figures.
- **§3 verification+tags — CLOSED.** `MASTER_SYNTHESIS.md` and `PORTABLE/RISK_REGISTER.md`
  carry inline verified/refuted/unverified tags at every pre-launch-audit citation; two broken
  cross-file pointers (`PORTABLE/PM_APP_LEARNINGS.md`, `PORTABLE/DAY_ONE_CHECKLIST.md`) and one
  false claim (`PORTABLE/SCRIPTS_SEED.md`) were fixed for standalone-copy self-containment.
- **§4 coverage audit — CLOSED.** `summaries/COVERAGE_AUDIT.md` exists with full method, counts
  table, and per-file writeups for the 20 zero-mention + 9 shallow-only files;
  `summaries/INDEX.md`'s Coverage note cites the true 98.3%/99.1% figures.
- **§5 scripts seed + cross-refs — CLOSED.** `PORTABLE/SCRIPTS_SEED.md` exists, self-contained,
  covering all 7 requested load-bearing patterns verbatim with incident/adaptation notes.
- **§6 supply-chain + reverts — CLOSED.** `aspects/supply-chain.md` (live-verified dependency/
  pin/vendoring/CI audit) and `summaries/commits/REVERTS.md` (6 revert commits classified,
  resolving the 2-vs-12 discrepancy) both exist and match their described content.

---

# Completeness critique — greenfield-learnings-2026-07-11

Adversarial pass against the ask in `README.md` (every file, every commit, every aspect,
Fable holistic, portable artifacts). Verdict: the corpus is genuinely large and mostly does
what it claims, but three claims of "complete coverage" do not survive a spot-check, one
whole evidence source (the live `tasked` board) was never actually queried despite being the
system of record, and a chunk of `PORTABLE/` leans on numbers whose provenance is unverified
or internally inconsistent. None of this invalidates the top-20 learnings — they're
independently triangulated — but the gaps below should be closed or explicitly disclaimed
before the owner treats this as ground truth.

---

## 1. Corpus coverage claims are FALSE, not just incomplete

`summaries/docs/d-root-md.md` states: *"Scope: all repo-root `*.md` except `LESSONS.md`...
Enumerated via `find <repo> -maxdepth 1 -name '*.md' ! -name 'LESSONS.md'` — 22 files."*

A live re-run of that exact `find` command returns **23 files**, and three are entirely
absent from the batch's per-file write-up:

- `OVERNIGHT_REPORT.md` — 0 mentions anywhere in the file.
- `TESTS_AUDIT.md` — 0 mentions anywhere in the file.
- `VM-SETUP.md` — 0 mentions anywhere in the file.

This isn't a stale-file timing issue (these three are tracked, committed files, not the
untracked `OwnerWishlist.md.bak`/`Untitled.txt` scratch noise from `git status`). The batch's
own stated count (22) is already one short of what `find` returns today, meaning either the
enumeration under-counted at run time too, or files were dropped silently between "found"
and "written up." Given `TESTS_AUDIT.md` and `VM-SETUP.md` are exactly the kind of doc a
rebuild needs (test-debt inventory; VM bring-up recipe — the latter is cited as a `PORT`
candidate pattern *by name* in `PORTABLE/` without the source doc itself ever having been
read), this is a real, not cosmetic, gap.

**Action:** run a Haiku pass on the 3 missing files, append entries to `d-root-md.md` in the
same format, and correct the "22 files" scope line. Then re-grep every batch INDEX's stated
file count against a fresh `find`/`git ls-files` before trusting any other "N/N complete"
claim in this corpus — the same failure mode (a coverage line asserting completeness that
a two-command spot-check falsifies) may recur in the code batches, which were not
spot-checked with the same rigor here (see §4).

---

## 2. The live `tasked` board was never queried — ticket-level analysis rests entirely on git-log grep

The owner's ask says "~1,500 board tickets." The corpus never reconciles this:

- `MASTER_SYNTHESIS.md` and `holistic/PM_HOLISTIC.md` both say **"~1,168 unique tickets."**
- `PORTABLE/PM_APP_LEARNINGS.md`'s own header says **"~1,500-ticket."**
- Neither number is sourced to an actual board query. A grep across the whole `docs/research/
  greenfield-learnings-2026-07-11/` tree for evidence of `mcp__tasked__task_list` / `mcp__tasked__task_get`
  / `localhost:8787` calls returns **zero hits in any aspect or holistic report** — every
  ticket-shaped claim (lane distribution, the "735 validated-awaiting-done + 284 review, 304h
  median stall, 39.8% stalled" figures in learning #8, the P4/P5 evidence-drift claims) is
  derived from **commit-message `TSK-####` grep and the prior meta-analysis document**, not
  from the board's actual current state — which is directly queryable via the
  `mcp__tasked__*` MCP tools this session has available and CLAUDE.md calls "the system of
  record."
- This matters because CLAUDE.md itself documents that the board both over- and
  under-states ground truth relative to code (learning #13/P5 in `PM_APP_LEARNINGS.md`) — so
  a ticket-count/lane-distribution claim sourced only from commit trailers inherits exactly
  the drift the corpus itself flags as untrustworthy, with no independent check against the
  board API that would have been trivial to run.

**Action:** one `mcp__tasked__task_list` sweep (paginated, filtered to this project's agent/
session tags per `reference_tasked_board_is_shared_across_projects`) to get authoritative
lane counts, true ticket total, and stall-time distribution; reconcile against the
1,168/1,500 discrepancy and correct whichever holistic doc is wrong. This is maybe 30 minutes
of tool calls the corpus-building fleet had every opportunity to spend and didn't.

---

## 3. Pre-launch-audit findings are flagged once, globally, then treated as load-bearing everywhere downstream

`MASTER_SYNTHESIS.md` carries one caveat paragraph up top ("pre-launch-audit findings are
gap-class evidence... individual bugs are plausible, unconfirmed"). That's the right instinct,
but it is not actually threaded through the document:

- Learning #4 ("Consumption ≠ completion") cites three specific unverified findings
  (FormulaEngine, 3-pane merge UI, notices file) as concrete proof points **without
  restating "unconfirmed"** at the point of use — a reader skimming the top-20 list (which is
  explicitly designed to be skimmed — "each is one line + an evidence pointer") will read
  these as settled fact.
- Learning #16 (agent trust model / unauthenticated socket) and the `AUDIT_BUGS.md` /
  `docs/research/prelaunch-audit-2026-07-09/` security claims carried into
  `PORTABLE/RISK_REGISTER.md` have the same issue — worth checking directly.
- The audit's own directory (`docs/research/prelaunch-audit-2026-07-09/`) is described in
  MEMORY.md as "~30 UNVERIFIED audit dimension reports (plausible, unconfirmed)" with the
  adversarial verify phase **never run**. Nothing in this corpus re-ran that verify phase or
  spot-checked even a sample of the ~30 findings against the actual current codebase before
  promoting them into "top 20 learnings" and a portable risk register.

**Action:** either (a) spend a bounded pass (5-10 findings, the ones cited in the top-20 and
`RISK_REGISTER.md`) confirming them against current `main` with file:line + repro, or (b) add
an inline "[unverified]" tag at every individual citation point (not just the doc preamble)
so the top-20 list and `RISK_REGISTER.md` don't read as harder evidence than they are. Given
`RISK_REGISTER.md` is meant to be copied into the new repo and acted on, shipping it with
silently-downgraded-to-implicit confidence is the highest-value fix in this whole gap list.

---

## 4. Per-file KEEP/REDO/AVOID verdicts were spot-checked far less than the commit archaeology

The commit-history side (`summaries/commits/`) shows real rigor: exact commit counts,
explicit revert-count discrepancy called out and left unresolved rather than papered over
(§"Revert count discrepancy" in `MASTER_SYNTHESIS.md` — 2 vs 12, honestly flagged). The
code-corpus side does not show equivalent self-checking:

- `summaries/INDEX.md` asserts "53/53 batches — complete" with one asterisk
  (`t-ui-root-5of6` missing from tallies but present on disk) — this was caught, which is
  good, but it means the fleet's own self-reported coverage numbers have already been shown
  unreliable once in this exact corpus, and no second file-count reconciliation was run
  against the other 52 batches to see if the same slip happened elsewhere (my one spot-check
  above, on the docs side, found a second, unrelated instance of exactly this failure mode —
  see §1). Two independent instances of the same class in two different sub-corpora is a
  signal, not a coincidence.
- `MASTER_SYNTHESIS.md` itself flags (§"Where the analyses disagree") that Haiku per-file
  KEEP verdicts grade "what code looks like," not cross-file wiring correctness — a sharp,
  correct caveat — but this caveat is about *quality*, not *coverage*. Nobody checked whether
  the Haiku batches' file *enumeration* (as opposed to judgment) is complete, the way I did
  for the docs batch. Given 2,005 Swift+Rust files across ~30 code batches, a systematic
  `find`-vs-batch-manifest diff was never run.

**Action:** for each of the 30 `summaries/code/*.md` batches, diff the batch's stated file
list against `find <scope-dir> -type f` for that scope; this is a cheap, mechanical check
that would either confirm the "53/53 complete" claim or surface more silent drops like the
one found in §1.

---

## 5. Portable artifacts: mostly stand alone, with named exceptions

Spot-checked `PORTABLE/DAY_ONE_CHECKLIST.md`, `ARCHITECTURE_SEED.md`, and
`PM_APP_LEARNINGS.md`. The good news: these are written generically ("your CI-equivalent,"
"Rust-staticlib-vs-dylib (or equivalent)") and don't hard-code this repo's paths as
instructions to follow — they cite this-repo specifics only as evidence in parentheticals,
which is the right pattern. Two real exceptions found:

- `DAY_ONE_CHECKLIST.md` §1 tells the reader to "Run `scripts/setup-signing.sh`-equivalent" —
  correctly hedged with "equivalent," so this is fine, but a few lines later it prescribes
  copying named scripts *nearly verbatim* (`MASTER_SYNTHESIS.md` §"Port these nearly
  verbatim": `build-app.sh`, `build-rust-core.sh`, `check-bundle-size.sh`, `test-in-vm.sh`,
  `sign-and-notarize.sh`, `restage-header.sh`) — but none of those six scripts' actual
  content was extracted into `PORTABLE/`. The new repo doesn't have this repo; "port nearly
  verbatim" is not actionable without either (a) the script bodies copied into `PORTABLE/` or
  a `PORTABLE/scripts/` staging dir, or (b) a durable pointer that survives this repo being
  archived/deleted. Right now the pointer is "go read `aspects/deps-tooling.md` §Portable
  rules 6," which only tells you *which* scripts, not their content.
- None of the `PORTABLE/*.md` files were tested by actually dropping them into an empty
  directory and reading them cold — several internal cross-references
  (`PORTABLE/PM_APP_LEARNINGS.md` → "Section 2 is that redesign's mechanisms" referring to a
  section inside the same doc, fine; but other portables reference `aspects/*` and
  `holistic/*` paths that will not exist in the new repo once this directory isn't carried
  over). If the intent is "copy only `PORTABLE/` into day 1," those cross-doc pointers break
  immediately.

**Action:** either copy the six named scripts' bodies (or a tight excerpt of the load-bearing
parts — xattr-safe staging, the ABI-skew/content-hash check, the dual-cap check, the GUI-
session bridge trick, inside-out signing order, header restaging) into a new
`PORTABLE/SCRIPTS_SEED.md` or literal script stubs, and audit every `PORTABLE/*.md` for
references to `aspects/`/`holistic/`/`summaries/` paths, replacing them with either inlined
content or an explicit "this pointer only resolves inside the analysis repo, not after copy."

---

## 6. Aspects not explicitly covered despite being named in the owner's ask

The requirement statement asks for "task-management types" and "automation struggles" —
both exist (`struggle-taskmgmt.md`, `struggle-automation.md`) — but two aspects implied by
the ask are thin-to-absent as *named* deliverables:

- **Dependency/supply-chain posture as its own aspect.** `aspects/deps-tooling.md` exists and
  is reasonably good, but the ask's "inefficiency" and "security" framing plus this project's
  own `.github/workflows/nightly-supply-chain.yml` and the "6 Mermaid CVEs over ~11 months
  with no executor" finding (learning #15) suggest a supply-chain-specific aspect distinct
  from general deps/tooling would have been warranted — currently that finding is buried
  inside a broader doc rather than given a dedicated pass that inventories every dependency
  the project actually shipped with (SwiftPM + Cargo + vendored JS) and its patch-lag.
- **No dedicated "what got deleted / reverted / abandoned" pass.** The revert-count
  discrepancy (2 vs 12) is flagged as unresolved, but nobody actually enumerated the 12 (or
  2) revert commits by content to classify *why* they were reverted — that's exactly the kind
  of "what NOT to build" signal a greenfield rebuild wants, and it's one `git log --grep=
  revert -i` + read away, not done here.

**Action:** these are lower priority than §1–§3 (nice-to-have depth, not a correctness gap in
what's already written), but worth a follow-up ticket if the owner wants the corpus to be
exhaustive rather than "very good."

---

## Summary — priority order to close

1. **[Cheap, high-value]** Fix the false "22/22 complete" claim in `d-root-md.md`; add the 3
   missing root-doc entries. (~20 min)
2. **[Cheap, high-value]** Run a `find`-vs-manifest diff across all 30 code batches to check
   for silent drops of the same class found in §1. (~30 min)
3. **[Cheap, high-value]** One `mcp__tasked__task_list` sweep to get authoritative ticket
   counts/lane distribution and resolve the 1,168-vs-1,500 discrepancy across
   `MASTER_SYNTHESIS.md` / `PM_HOLISTIC.md` / `PM_APP_LEARNINGS.md`. (~30 min)
4. **[Medium effort, highest downstream risk]** Thread the "unverified" tag through every
   individual pre-launch-audit citation in the top-20 list and `RISK_REGISTER.md`, or spend a
   bounded pass confirming the ~10 most load-bearing findings against current `main`. (~2-4h)
5. **[Medium effort]** Inline the six "port nearly verbatim" scripts' load-bearing logic into
   `PORTABLE/` so it survives independent of this repo; audit `PORTABLE/*.md` for dangling
   `aspects/`/`holistic/` cross-references. (~1-2h)
6. **[Optional depth]** Dedicated supply-chain aspect; enumerate-and-classify the revert
   commits. (~1h)
