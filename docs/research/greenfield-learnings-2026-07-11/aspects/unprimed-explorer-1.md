# Unprimed explorer — fresh-eyes read of `markdown_viewer`

Methodology: no hypotheses given going in. Explored via `git log` statistics, directory
sizes/LOC, `docs/` inventory, `CLAUDE.md`/`LESSONS.md`/`BACKLOG.md`, the owner's own
`FEATURE_INVENTORY.md` / `USABILITY_AUDIT_2026-07-02.md`, and the pre-launch audit summary
already sitting in `BACKLOG.md`. Everything below is evidence-first; the repo's own artifacts
did most of the talking.

## Top-line numbers (8 calendar weeks, 2026-05-14 → 2026-07-11)

| Metric | Value |
|---|---|
| Commits | 3,733 |
| Unique ticket IDs referenced in commits | 1,168 |
| Swift source LOC (`Sources/`) | 170,116 |
| Swift test LOC (`Tests/`) | 177,800 (**more test code than product code**) |
| Rust LOC (`rust-core/`, excl. target) | 53,457 |
| Test functions (`func test`) | 9,988 |
| Markdown docs (repo-wide, excl. tmp/.build) | 471 files |
| `docs/` alone | 381 files |
| `LESSONS.md` | 4,055 lines / 333 KB |
| `CLAUDE.md` (project instructions) | 40 KB (a budget-capped file — it was already hitting a ceiling) |
| `CHANGELOG.md` | 174 KB |
| `AUDIT_BUGS.md` | 146 KB |
| Repo working tree | 6.2 GB (589 MB is stray `tmp/`, 95 MB `rust-core` target-ish, 95 MB `dist/`, but even source-only dirs are 13+10+10 MB) |
| Commit-type breakdown | `docs:` 1,397 (37%!) · `feat:` 988 · `fix:` 374 · `test:` 337 · `perf:` 106 · `refactor:` 50 |

**The single most striking number: `docs:` commits (1,397) outnumber `feat:` commits (988) and
dwarf `fix:` (374).** More individual commits went to writing *about* the work than to fixing
bugs in it. This is not "good documentation hygiene" at this scale — it's a project that spent
more motion on process artifacts (LESSONS entries, audit docs, design docs, tracking docs) than
on hardening the product. The project's own `CLAUDE.md` acknowledges this got out of hand
("Commit hygiene — NO process-noise commits... A day must NOT carry 30+ separate doc commits")
— i.e., the team had to write a rule against its own habit, mid-project, and even then the habit
clearly didn't stop (`docs:` commits keep appearing through July).

## Finding 1 — Unbounded scope creep, much of it owner-seeded but never re-scoped

The product started as "TextView / MarkdownViewer" — per `README.md`, "A native macOS file
viewer + minimal editor — plaintext and markdown." What actually got built, per
`docs/FEATURE_INVENTORY.md` (the owner's own July 2 audit), spans **12 major feature families**:
Editor, File nav & workspace, Viewing/rendering, Markdown power tools, Data formats (CSV/hex/
SQLite/diff), Media, Dev tools (LSP, git inspector, code review), Automation & extensibility
(plugin host, MCP server, 160 script verbs), Import/paste/convert, Feeds & web, Canvas (a
freeform drawing/diagramming surface), and general app chrome. That's a full-blown IDE +
multimedia viewer + automation platform, not a markdown viewer.

The origin is visible in `OwnerWishlist.md`: an early, informally-captured brainstorm literally
lists "TextEdit feature parity," "NotePad++ wishlist," "Mini VS Code type," "Sublime type,"
"Extensive Git repository visualizer," a Claude-Code-activity-timeline feature, etc. — i.e. the
owner *did* originate a lot of this breadth. But nothing in the repo shows a re-scoping
conversation that turned that brainstorm into a prioritized, cut-able scope. Instead the agent(s)
chased essentially the entire wishlist in parallel, all the way to "built," and only checked
usability 7 weeks in (`USABILITY_AUDIT_2026-07-02.md`), at which point the owner's own verdict
was: **"We have been building many features, but almost all of them are unusable. Editor works,
vim mode works, File nav mostly works. The rest are unfinished, unpolished or unusable."**

That audit also found the tracker itself was actively *lying in both directions* — some tickets
marked "model-only, UI missing" turned out to have working UI when the code was actually read
(image editor: ticket said "~4 capabilities," code had 10 wired; CSV multi-select ticket said
model-only, code had it; LSP completion ticket said "not wired," code had it wired). The
takeaway isn't "trust tickets less" — it's that **breadth without a hard WIP limit produces a
board that nobody, including the agents doing the work, can trust**, and 7 weeks passed before
anyone checked ground truth against the map.

**For the rebuild:** decide the product's edges *before* week 1, in writing, and treat "add a new
top-level feature family" as an event that requires deliberately shrinking or deferring
something else — not a free action. A breadth-first strategy across 12 feature families with a
single always-green test gate created the illusion of steady progress (tests passing, tickets
closing) while the thing the owner actually cared about — a good editor experience — sat
un-prioritized relative to Canvas, VST-hosting explorations (later marked a "non-goal" after
being built out — see `docs/VST_HOSTING_NON_GOAL_2026-06-25.md`), spreadsheet multi-sheet
support, and a Claude-Code activity timeline.

## Finding 2 — Test volume became a proxy for quality, and the proxy broke

9,988 test functions, 177,800 lines of test code — more test LOC than product LOC — is an
enormous investment. Yet the pre-launch audit (run 2026-07-09, findings sitting unresolved in
`BACKLOG.md` as of today) turned up P1-severity, default-ON-path bugs that a green test suite
had been masking for weeks:

- CM6→Swift text sync debounces 200ms and is **never flushed on save/close/blur/quit** — `⌘S`
  can persist a stale mirror, silently dropping the last keystrokes typed.
- Editable-hex has no conflict/no-clobber handling at all — dirty bytes are in-memory only and
  vanish on quit/crash with no prompt.
- A session-switch code path deletes the hot-exit spill file it *just wrote*, losing 1–32 MiB of
  unsaved edits.
- Every caller of `JSONFileStore.write` discards its `Bool` return — disk-full silently loses
  sessions and hot-exit data.
- A malformed bookmark entry causes a strict-decode failure that **wipes the entire bookmarks
  file**.
- The "Merge…" conflict-resolution button silently behaves as "Keep Mine," clobbering external
  edits on next save.
- An unbounded-recursion formula parser can stack-overflow-abort the whole app (uncatchable by
  `catch_unwind`) from a crafted CSV cell.
- No crash-loop breaker: a crash-on-open document reopens unconditionally on every relaunch — a
  permanent boot loop.
- `THIRD_PARTY_NOTICES.md` is generated but **never copied into the shipped bundle** — the app
  would redistribute ~30 statically-linked Rust crates and 15 tree-sitter grammars with zero
  attribution.
- Notarization has **never been run once** in 8 weeks (0 Developer ID identities configured).
- The always-on MCP automation socket is unauthenticated — same-user access can execute
  `run_task` (arbitrary shell), and `run_verb`'s open/save-copy path bypasses the app's own
  home-directory jail fence.

None of this is a knock on test *volume* — it's evidence that a huge, host-green, headless test
suite optimizing for "does the model layer behave" left an entire class of *integration/
lifecycle/security* bugs (save-path flush timing, crash recovery, bundle assembly, attack
surface) essentially unguarded, because the CI gate never exercised them. `CLAUDE.md` itself
documents this exact failure mode repeatedly under different names — "the ImageRenderer false-
green trap," "compositor occlusion," "stale-dist trap," "model-fixed, on-screen UNVERIFIED" — a
whole taxonomy of "the tests were green and the feature still didn't work" had to be built up
reactively, ticket by ticket, rather than designed in from the start.

**For the rebuild:** decide the test *pyramid shape* deliberately up front (what fraction unit vs
integration vs true end-to-end-on-real-artifact), and make "would this test have caught a
save-path data-loss bug / a crash-loop / a missing notarization step" an explicit design
question for the top of the pyramid — not something backfilled by a pre-launch audit in week 8
after ~10,000 tests already exist.

## Finding 3 — The documentation/process layer grew faster than anyone's ability to read it

`CLAUDE.md` (project instructions, re-injected into every session) is 40 KB and is explicitly
**budget-capped by a host test** (`ContextBudgetTests`) because it kept growing — the file
itself documents this arms race: "Budgets have TEETH... A red budget test means PRUNE THE FILE."
`LESSONS.md` is 4,055 lines / 333 KB. `docs/` alone holds 381 markdown files, many of them
dated point-in-time design docs (`*_2026-06-XX.md`) that were apparently never folded back into
a living doc or archived — `archive/` exists and holds some historical material, but the current
`docs/` tree still has things like `CANVAS_DESIGN.md` *and* `CANVAS_DESIGN_CANVAS-0001.md`,
`PROJECT_MANAGEMENT_DESIGN.md` *and* `PROJECT_MANAGEMENT_DESIGN_v2.md`, `CODE_REVIEW_DESIGN.md`
*and* `CODE_REVIEW_V2_DESIGN_2026-06-01.md` — i.e. superseded docs left in place alongside their
replacements, with no visible pruning discipline until very late (the `CLAUDE.md` "context
budget" section is dated 2026-07-03, five and a half weeks in).

This matters operationally, not just aesthetically: every fresh agent session re-reads
`CLAUDE.md` + `HANDOFF.md` and is expected to internalize the state of `LESSONS.md`/`BACKLOG.md`
before doing anything. A 40 KB instructions file plus a 333 KB lessons file is a real tax paid
on *every single session start*, and the growth was clearly organic/reactive (each entry is a
real, hard-won lesson — the problem isn't that the entries are wrong, it's that the format never
had a compaction/summarization pass keeping it dense).

**For the rebuild:** build the "prune as you grow" discipline (max size + summarize-and-archive)
into the process from day one, not as a week-5 budget test reacting to an already-bloated file.
Consider a structured lessons *database* (queryable, taggable, one line per lesson with a link
to detail) rather than one linearly-growing prose file that every session must re-read start to
finish.

## Finding 4 — The tracker (task board) essentially became a second product to maintain

1,168 unique ticket IDs were created and referenced in commit messages over 8 weeks — roughly
21 tickets/day, every day, for two months. Combined with Finding 1's tracker-vs-code drift
finding, and the explicit late-project memory entry "⛔ Avoid over-decomposition of tickets
(2026-07-10)" (a corrective rule filed *after* the pattern had already produced a bloated board),
this reads as another case of a good instinct ("track everything," "file generously") running
without a counterbalancing discipline until very late. The board's own feedback doc
(`docs/TRACKER_FEEDBACK.md` referenced throughout) and repeated "audit the board vs reality"
passes (`FEATURE_INVENTORY.md`'s "3-for-3 refuted" stale-ticket spot-check) suggest a meaningful
fraction of agent time went to *maintaining the map* rather than *the territory*.

**For the rebuild:** a ticket-per-thread discipline (the "avoid over-decomposition" rule the
project eventually adopted) should be a **day-1** rule, not a week-8 correction, and the
tracker's accuracy should itself be spot-checked against code periodically and cheaply (a
lightweight "does this ticket's description match a grep of the code" check) rather than
requiring a dedicated full-repo audit to discover the drift.

## Finding 5 — What actually worked and is worth keeping

Not everything here is a cautionary tale — several structural choices look genuinely sound and
are worth carrying into the rebuild:

- **Tiered testing with an explicit host/VM split** (`TierBaseCases`: headless T1/T1m/T2′ on the
  host, live-app T4 and pixel T5 only on a VM, gated by `MDV_VM_GUI_SESSION`) is a well-reasoned
  answer to "how do you keep an agent from popping windows on the owner's live screen while still
  getting real UI coverage." The self-skip-unless-explicitly-enabled default (closing TSK-817,
  "a bare `swift test` used to spawn a window mid-work") is a good pattern generally: **heavy/
  intrusive test tiers should default OFF and require an explicit env flag**, not rely on agents
  remembering not to run them.
- **Rust core for the reusable/performance-sensitive engine logic, Swift/SwiftUI for the shell**
  is a sound split reflected in the LOC (53K Rust vs 170K Swift) and in the explicit "Swift
  engines with an approved Rust port take bugfixes only" migration policy — that's a real
  mechanism for stopping investment in code known to be superseded, which is more disciplined
  than most projects manage.
- **Negative-control tests** (`MDVNegativeControl.isBroken("<NAME>")`, gating a deliberate
  regression behind an env var to prove a guard actually goes red) is a genuinely good idea for
  proving test teeth — worth keeping as a named pattern from day one rather than discovering it
  reactively after a "false green" incident.
- **Bundle-size and context-size budgets enforced by failing tests** (80 MB/65 MB bundle cap,
  12 KB/40 KB doc caps) — the mechanism (a red test forces a conversation, not silent drift) is
  right; only the *timing* (introduced after the thing had already grown) was wrong. Set these
  budgets before the file/bundle exists, not after it's already 3x the eventual cap.

## Summary — the pattern underneath all four findings

Every finding above is the same shape: **a good instinct (build broadly, test heavily, document
lessons, track work) that ran without a corresponding limiting/pruning mechanism until the
project was already deep enough in that a corrective rule had to be written and retrofitted.**
The rebuild's biggest lever isn't "do less testing" or "write fewer docs" — it's **pair every
generative habit with its limiting habit from the start**: a scope boundary alongside the
feature wishlist, a pyramid-shape decision alongside the test-writing habit, a prune/archive
pass alongside the lessons-logging habit, a ticket-granularity rule alongside the "file
generously" habit. In this project, every one of those limiting habits arrived, in writing, only
after the unlimited version had already cost real time and produced a real mess to clean up.
