# Regression Types — markdown_viewer greenfield run

**Dimension:** what regressed and why — silent unshipped features, flag-gated code
that never flipped, perf regressions, "fix didn't stick" re-fix loops, and which
guard classes would have caught each earliest and cheapest.

**Sources:** `docs/research/prelaunch-audit-2026-07-09/regressions.md`,
`.../scaling-limits.md`; `docs/research/greenfield-learnings-2026-07-11/summaries/commits/{INDEX,c-15of19}.md`;
`LESSONS.md` (compositor bug §890-1030, terminal-tab-strip §3061-3090, CSV 1MB→1GB §1535-1560,
markdown 4MB cap §1902); `CLAUDE.md` root-cause-discipline + compositor-occlusion sections;
`git log` (`847b7921`, `47489558`).

---

## Taxonomy — the distinct types in this dimension

### 1. Dead render tail — model shipped, UI mount never wired
**Frequency:** systemic pattern, 4 confirmed live instances in the last ~10 commits alone
(`regressions.md` P1/P2 findings) + 1 historical (`TSK-956` audio hosting, LESSONS.md §448).
**Severity:** P1 (when the missing tail is a data-safety fallback) down to P2/P3 (dead menu).

- `ConflictResolutionView.swift` + `DocumentModel.beginConflictResolution` — **0 callers**,
  built and host-tested (`f9127559`), but the live auto-merge path (`5ed63734`) that needed
  it as its escape hatch ships without it. A real overlapping edit still forces a lossy
  keep-mine/reload-theirs binary choice — the exact scenario the feature exists to protect.
  (`regressions.md` P1 #2.)
- `activeContentMenu` (`DocumentModel.swift:2153`) — computed, host-tested, **0 UI consumers**;
  the commit itself says "the live dynamic NSMenu is the AppKit tail" (`9addfda8`).
  (`regressions.md` P2 #4.)
- `allowHTMLNetwork`/`revokeHTMLNetwork` — CSP-escalation core built and security-tested,
  **0 callers** outside the definition; no grant UI exists so a user cannot use the feature
  at all (`8253d8cb`). Fail-closed, so not a security hole — but reads as shipped on the
  board while inert on screen. (`regressions.md` P2 #3.)
- `TSK-956` Audio-plugin hosting: the discovery layer (`AudioUnitInventory` etc.) shipped and
  the epic was marked `fixed`; the headline capability (live `AVAudioEngine` hosting) was
  never built, and the gap was recorded as a comment, not a ticket — so it silently dropped
  off the backlog (LESSONS.md §448).

**Mechanism:** the project's own review methodology (host test the model, host test the
FFI/data layer) is fully satisfiable *without* touching the UI mount point. Ticket hygiene
allowed "fixed" to close on the model slice, with the render tail deferred as a *comment*
("the live X is the render/AppKit/VM/AX tail") rather than its own tracked, blocking child
ticket. The board and CHANGELOG describe the feature from the user's seat even though the
user cannot reach it (`regressions.md` P2 #5, "systemic pattern").

### 2. Default-flip with an undelivered safety contract
**Frequency:** 1 confirmed instance, but structurally repeatable (any feature-flagged perf
path that flips default-on before its documented fallback is proven).
**Severity:** P1 — flips into the hot/default render path.

- `847b7921` flips `domPatchEnabled` to default-ON (opt-out `MDV_DOM_PATCH=0`) to kill a
  2-9s reload storm. `BlockPatchJS.swift` documents *"the Swift caller treats `false` as
  fall back to loadHTMLString … non-regressing by construction."* The actual caller
  (`MarkdownRenderedView.tryApplyDOMPatch`) fires `evaluateJavaScript(..., completionHandler:
  nil)` and **unconditionally returns `true`** — the completion handler that would trigger
  the documented fallback is discarded. A JS-side `false` or thrown error now leaves stale
  DOM on screen with no full-reload recovery. Additionally the patch path skips re-running
  mermaid/math post-load JS passes, so a patched-in block that becomes a mermaid/math host
  renders as inert markup. (`regressions.md` P1 #1.)
- The commit message itself flags "re-run as the agentic UAT" — i.e. the confirming UAT was
  not done at flip time, and the flip shipped ahead of its own validation gate.

**Mechanism:** a flag went from default-OFF, tested (`47489558`, TSK-1183 slice B) to
default-ON (`847b7921`) on a *perf* justification without an equivalent audit of the
*documented* safety contract — the contract was written in a comment, never asserted by a
test, and the implementation silently diverged from the comment.

### 3. Perf regression from a wrong-complexity primitive
**Frequency:** at least 3 concrete cases across the run; likely under-counted since perf
audits were episodic, not continuous.
**Severity:** P0-class in the moment (whole-Mac thrash / multi-hundred-MB spikes), each
caught and fixed once found.

- **CSV: 1 MB file → ~1 GB resident.** `ScrollView { VStack { ForEach(rows) } }` is not
  lazy — SwiftUI instantiates every child view up front. 50K rows × ~10 cells × ~2 KB
  SwiftUI-internal overhead per node ≈ 1 GB. Fixed with `LazyVStack` (LESSONS.md §1535-1560);
  triggered a full memory/perf audit sweep the same day (2026-05-18).
- **Markdown: uncapped file → hundreds-of-MB spike.** `swift-markdown` → `HTMLRenderer` →
  `WKWebView.loadHTMLString` allocates several multiples of input size transiently (AST +
  N inline strings + emitted HTML + WebContent DOM); a 58 MB markdown file spiked memory by
  hundreds of MB before `markdownRenderMaxBytes = 4 MB` capped the render path
  (LESSONS.md §1902-1910).
- **O(n×m) line-diff → 77 GB phys_footprint → whole-Mac swap-thrash.** A naive `LineDiff.lcs`
  allocated an `(n+1)×(m+1)` Int matrix with no size guard; a storage test diffing large
  content took the whole VM/host down, not just the test process (LESSONS.md §434). Fixed
  with prefix/suffix trim + line-interning + Myers O(N·D) linear-space + a hard size-guard
  (≥1 MiB either side ⇒ snapshot, never invoke the differ).

**Mechanism common to all three:** a *correctness-only* mental model of a hot path (a UI
list, a renderer, a diff algorithm) with no attention to its big-O or per-item constant
until a real input revealed it. All three were caught by a **user-triggered symptom**
(the app visibly ballooned/hung), not by a proactive perf gate — the audits that followed
were reactive, not preventive.

### 4. "Fix didn't stick" — re-fix loops from patching a stage instead of the mechanism
**Frequency:** 2 large documented arcs (TSK-1046 ×13 commits, TSK-1243 ×11 commits over
10+ VM round-trips) + the smaller compositor-occlusion arc (3 attempts before root cause,
c-01) + the terminal-tab-strip arc (4 wrong fixes before root cause, TSK-488).
**Severity:** high cost in velocity (24 commits / 12% of a 197-commit slice for two tickets
alone, c-15), not correctness risk once actually fixed.

- **TSK-1046 (scroll-restore, 13 commits):** a multi-stage async handoff (WebView
  `didFinish` → SwiftUI re-eval → `Task` hop → render) where no single stage owned the
  state. Fix strategy evolved sequence-patch → fallback-read → finally collapsed to a
  single pull-based source of truth (`tab.renderedScrollY`), landing in ~5 lines
  (`a28a5a35`) once found. Test-harness debugging (async-await continuation bridge, probe
  timeout scaling) consumed most of the 13 commits — proving the *test vehicle itself* was
  the wrong tool before the real render-layer fix (`1e339e9c`) landed.
- **TSK-1243 (UAT env-delivery, 11 commits, 10+ VM round-trips):** `LaunchServices open
  --env` silently drops env vars under `sudo -u` (the VM GUI lane). Three sequential wrong
  theories (ProcessInfo snapshot, `getenv`, `didFinishLaunching` timing) before the actual
  fix — a config-file side-channel (`~/.mdv-launch-config.env`, read *before* any lifecycle
  hook). The board notes the agent **re-diagnosed from scratch** despite an existing ticket
  understanding — this incident is the direct origin of CLAUDE.md's root-cause-discipline
  step 0 ("READ the ticket's existing understanding FIRST").
- **Compositor occlusion (3 re-attempts, c-01; formalized after TSK-488, c-05):** an opaque
  `NSViewRepresentable`'s `CALayer` occludes SwiftUI siblings painted before it; the fix
  isn't a layout tweak but explicit z-ordering (`compositingGroup().zIndex`). All 3-4 wrong
  attempts (per bug instance) were driven by tools structurally blind to WindowServer
  composition (`ImageRenderer`, `cacheDisplay`, frame-walks) reporting false green.
- **Terminal tab strip (4 wrong fixes, TSK-488):** same compositor-occlusion class,
  independently rediscovered because the false-green tool matrix (`ImageRenderer` draws a
  *placeholder* for the representable, so it never sees the occlusion) wasn't yet codified
  as a standing rule. Root cause found only via `screencapture -l<windowID>` — real
  WindowServer pixels.

**Mechanism common to all four:** the fix target was a *symptom stage* in a longer chain
(one hop of an async sequence, one theory of an env-var loss, one visible layer in a
composite) rather than the actual mechanism, and — critically — **the diagnostic tool used
to validate each attempted fix was blind to the real failure mode** (headless test can't see
async race timing under real WebKit; `ImageRenderer`/`cacheDisplay` can't see WindowServer
composition; `ProcessInfo`/`getenv` theories weren't checked against the actual LaunchServices
behavior before implementing). Every one of these arcs stopped re-occurring only when a
**pixel/runtime-truth-level observation replaced code-order inference**.

### 5. Unbounded growth / missing caps (latent, not-yet-triggered regressions)
**Frequency:** 5 P2 + 2 P3 findings in the scaling-limits audit; **0 P0/P1** — the codebase
is unusually disciplined here, so this class is mostly "found before it regressed."
**Severity:** low urgency now, but exactly the shape that becomes a P0 field bug months
into real usage (a tool "left running for weeks with hundreds of files").

- Interactive tab-open (`TabsState.openOrReveal`) has **no cap** — only *restore* is capped
  at 200; each `Tab.state` retains the file's full `String` contents uncapped (500-tab
  scenario ≈ 1 GiB raw content resident, independent of the LRU-bounded glyph stores).
- Local History has a strict 20 MiB **per-file** cap but **no global** cap/GC — one
  directory per file ever edited, no age sweep, no dead-file reap → unbounded disk over
  months.
- Sidebar file tree materializes **every** child of an expanded directory (no cap, no
  paging) — a 100k-entry `node_modules` does 100k synchronous symlink resolutions.
- `git status` buffers up to 512 MiB of subprocess output (bounded, but the ceiling is far
  above any useful payload — effectively "capped" in name only for pathological repos).

**Mechanism:** these are not "regressions" in the sense of a working thing breaking — they
are **caps that were applied to the acute/first-open path but never re-applied to the
long-horizon/cumulative path** (restore vs. interactive-open; per-file cap vs. global cap;
search-walk cap vs. tree-display walk). The team's own pattern — cap the hot path — was
applied inconsistently to the *adjacent* accumulation path.

---

## What worked — practices/designs that earned their keep

- **Explicit ceilings with rationale comments, applied almost everywhere.**
  `TextFileLoader.readableMaxBytes` (512 MiB hard, stat-refuses *before* allocating),
  `markdownRenderMaxBytes` (4 MiB), `highlightMaxBytes` (512 KiB), CSV's 4 MiB windowed-
  assembly threshold, `CrossFileSearch.maxResults`, `HistoryStore.maxEntries` (100) with a
  `pruneMissing` dead-file sweep, `git log --maxEntries 50`. This "cap the hot path with a
  documented number and a test" habit prevented essentially all *acute* OOM/hang scenarios
  (`scaling-limits.md` positive-observations section) — the audit found **zero** P0/P1s in
  the entire scaling dimension.
- **Bounded caches with survivor-preserving eviction, not wipe-on-overflow** —
  `InsertionOrderedCache` (batch-evict to 2/3), `HighlightCacheActor` (LRU-8/tab),
  `SourceControllerCache` (LRU-4 / 64 MiB with real `NSTextStorage` teardown). Explicit,
  testable eviction beats `NSCache` (repo-wide zero `NSCache` usage, deliberately).
- **The structural prohibition beats the test, for the compositor-occlusion class.**
  CLAUDE.md/LESSONS.md codified "never attach `NSRulerView` to the source view" as a
  code-review-time, statically-greppable rule — cheaper and stronger than any pixel test,
  because the pixel test only runs nightly/pre-release, not on every commit. The pixel test
  (`SourceViewVisualRegressionTests`, with a negative-control `MDV_ENABLE_BROKEN_RULER=1`
  meta-test proving it can actually fail) is belt-and-suspenders, not the primary defense.
- **Collapsing the async chain to a single source of truth, once found.** Both TSK-1046
  (scroll: `tab.renderedScrollY` pull-based read) and TSK-1243 (env: config-file side
  channel read before any lifecycle hook) resolved permanently only when the fix eliminated
  the multi-stage handoff rather than sequencing it more carefully. Both then became
  standing CLAUDE.md directives ("collapse the fragile chain… don't add a stage-patch").
- **Negative-control switches as committed, repeatable teeth-proofs** — `MDVNegativeControl.isBroken("RULER")`
  gates a deliberate regression behind an env var so a pixel test's ability to fail is
  demonstrated on every CI run, not just once by hand (CLAUDE.md, TSK-1134).
- **Root-cause SOP codified from a specific incident, then applied going forward.**
  TSK-1243's "agent re-diagnosed from scratch despite an existing ticket understanding"
  directly produced CLAUDE.md's step-0 rule; TSK-1046 directly produced the
  "collapse-don't-patch" rule. Post-incident codification, not just a one-off fix, is what
  kept the *class* of bug from recurring identically (though the terminal-tab-strip
  occlusion bug still recurred once more before the false-green tool matrix was written
  down explicitly — codification lagged discovery by one incident).

## What hurt — the costly failures, with root-cause mechanism

- **"Model-tested" was treated (by the board, not by CLAUDE.md's own rules) as equivalent
  to "shipped."** The dead-render-tail pattern recurred at least 4 times in the final ~10
  commits of the run because the team's disciplined host-testing habit is *satisfiable*
  without touching the UI mount point — a ticket can go `fixed`/`review` on model+FFI
  coverage alone, and the render tail becomes a comment ("the live X is the AppKit/VM tail")
  instead of a tracked, blocking child ticket. Comments don't show up in a board sweep;
  tickets do. Mechanism: **process gap between "test coverage exists" and "user-reachable,"**
  not a testing-discipline failure — the tests that exist are good tests, they just test the
  wrong 80%.
- **A documented safety contract in a comment, not asserted by a test, silently diverged
  from the implementation** (`domPatchEnabled` default-flip). The comment said "non-
  regressing by construction, the caller falls back"; the actual caller discarded the
  completion handler. Nobody ran a test that would fail if the fallback stopped firing,
  because "the contract is documented" was treated as sufficient. This is the single most
  dangerous instance in this dimension because it flipped default-ON into the hot render
  path for every markdown file re-render.
  Mechanism: **a prose contract, not a codified invariant**, guarding a perf-motivated
  default flip.
- **Wrong-complexity primitives (VStack-not-lazy, unbounded diff matrix, uncapped markdown
  render) were caught reactively, by a user hitting the wall, not proactively by any perf
  gate.** All three post-mortems are excellent (root cause found the same day/afternoon in
  each case), but all three are *symptom-triggered* audits, not scheduled ones. Mechanism:
  **no continuous/automated perf-regression gate on memory footprint for these hot paths**
  — CLAUDE.md's "measure, don't guess" perf discipline came *after* these incidents, as a
  lesson learned from them.
- **The test/harness vehicle itself became the bottleneck for two large arcs** (TSK-1046,
  TSK-1243) — 24 commits (12% of a 197-commit slice) went to debugging the UAT harness, not
  the product bug. The app's async boundaries (WebView lifecycle, LaunchServices env
  delivery under sudo) were not designed to be synchronously observable, so validating a
  fix required building new introspection machinery under time pressure, which itself had
  bugs. Mechanism: **production code and its validation harness co-evolved reactively**
  instead of the harness being built, stabilized, and proven first.
- **A tool structurally blind to the actual bug reported false green, repeatedly, across
  two independent incidents of the same underlying bug class** (compositor occlusion:
  ruler-in-tile-call, then terminal-tab-strip). `ImageRenderer` and `cacheDisplay` were
  each re-trusted as "the test passed" in separate incidents before the false-green
  mechanism was documented as a standing rule. Mechanism: **the team didn't yet have a
  taxonomy of "which observation layer can see which bug class"** — that taxonomy (stage
  ①-④ compositing pipeline, which tool sees which stage) only exists in LESSONS.md *after*
  paying for it twice.

## Design implications for the rebuild

**Do differently from day 1:**

1. **Treat "render tail" as a first-class ticket-typing rule, not a comment convention.**
   A ticket that ships a model/data layer with a UI mount point deferred MUST spawn a
   separate, linked, blocking child ticket for the mount — never a prose note. Add a board
   query/gate: "any ticket marked done/fixed whose diff adds a public
   type/view/accessor with zero callers in `Sources/` outside its own defining file" is an
   automatic red flag (this is exactly the `regressions.md` grep methodology — codify it as
   a CI/gate script, not a one-off audit pass, from day one).
2. **Any prose "contract" backing a default-flip (X falls back to Y on failure) must be an
   assertion, not a comment.** Before flipping a perf optimization to default-ON, write the
   test that fails if the documented fallback stops firing (inject a JS-side `false`/thrown
   error and assert `loadHTMLString` was invoked) — do this as part of the SAME commit that
   flips the default, not as a follow-up.
3. **Stand up the pixel/WindowServer-truth test lane (T5-equivalent) and the false-green
   taxonomy on day one**, not after paying for the compositor bug twice. If any UI layer
   mixes framework-native views with third-party/native representables (WebView, terminal
   surface, PDF view, etc.), assume compositor-occlusion is possible and write the
   structural prohibition (explicit z-order / compositing group) into the architecture
   BEFORE the first instance ships, not as a post-hoc fix.
4. **Apply every cap twice: once to the acute/first-touch path, once to the cumulative/
   long-horizon path.** The scaling-limits audit's recurring miss shape is "the hot path is
   capped, the thing that accumulates around it isn't" (restore-cap vs. interactive-open,
   per-file-cap vs. global-cap, search-cap vs. tree-display-cap). Write this as a checklist
   item for every new cache/store/list: "what caps the *rate of accumulation*, not just the
   *size of one entry*?"
5. **Build and stabilize the async-observability seam before building on top of it.**
   Where a value must round-trip through an async chain (WebView lifecycle, LaunchServices
   env, any multi-hop restore), design a **pull-based single source of truth** from the
   start (a value the render layer *reads* declaratively) rather than a push-based sequence
   of side effects timed against each other. This is cheaper before the first bug than after
   the 13th commit of patching.
6. **A perf-regression gate on memory footprint for known-hot paths (large-file open, large
   list render, diff) should exist from day one**, even if crude (a benchmark asserting
   phys_footprint stays under N MB for a fixed input size). All three perf blowups here were
   caught by a human noticing a spike, not by CI.

**Accept as inherent cost (don't over-invest trying to eliminate):**

- Some fraction of harness-building work for VM/pixel/AX validation will always be "test
  infrastructure debugging," not product work — CLAUDE.md's own estimate is 15-20% of
  velocity on a comparable UI-heavy rebuild. Budget it, don't be surprised by it.
- Root-cause misdiagnosis on a genuinely novel async/timing bug will cost 2-3 wrong
  attempts even with good discipline — the win is capping it there (via the "2+ patch
  attempts → stop, collapse the chain" rule) rather than eliminating the first miss
  entirely.

---

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **A feature is not "done" until its board ticket names a real caller.** Any new
   view/model/accessor with zero callers outside its own file is an automatic gate failure,
   checked by a grep-based CI step, not just an audit pass — run it on every merge to `main`,
   not just pre-launch.
2. **A documented fallback/safety contract for a default-flip must ship as a test in the
   same commit as the flip**, asserting the failure path actually triggers the fallback —
   never trust a code comment as the enforcement mechanism.
3. **When a bug fix survives 2 patch attempts and the bug returns, stop patching stages —
   find and eliminate the single source of truth / collapse the async chain.** Don't attempt
   a third sequencing fix.
4. **Before re-diagnosing any recurring bug, read the ticket's existing `understanding` and
   prior fix commits first** (`git log --all -S <symbol>`, `git branch -a --contains`) — a
   session was burned reinventing a fix that already existed on an unmerged worktree.
5. **Maintain an explicit "which tool can see which bug class" taxonomy** (compositor
   composition needs real WindowServer pixels; async races need runtime instrumentation, not
   code-order inference; env-var propagation needs the actual OS mechanism verified, not
   theorized) and consult it before trusting any green result on a rendering/timing bug.
6. **Every cache/store/list gets two caps at design time: one on the size of a single
   accumulation event, one on the total accumulated state** (count and/or bytes, with an
   LRU/age-based eviction policy) — write both into the ticket's acceptance criteria before
   the first line of code.
7. **A structural/architectural prohibition (a code-review-checkable rule) beats a runtime
   test for any bug class the test suite structurally cannot observe** (WindowServer
   composition, true concurrency races) — write the rule down and grep for violations,
   don't rely solely on a nightly pixel test to catch it.
8. **Perf-sensitive hot paths (large-file open, unbounded list render, diff/merge
   algorithms) get a footprint-bound benchmark in the same PR that introduces them** — don't
   wait for a user-triggered "the app ballooned to 1 GB" incident to discover an O(n×m) or
   non-lazy-render mistake.
