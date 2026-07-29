# Aspect: Bug Types — root-cause taxonomy across markdown_viewer's history

Scope: every distinct *mechanism* of bug found in the corpus (not symptom), how it was
found, how long it evaded detection, what fix actually stuck, and what the rebuild should
bake in structurally. Evidence-first; every claim cites a report/commit/file.

---

## Taxonomy — the distinct types, frequency/severity, evidence

### 1. Async/timing races — "imperative state around a declarative render"
**Frequency: very high (the single most recurring class). Severity: high (user-visible, repeat offenders).**
The shape: state is written by an imperative step (a callback, a `Task`, a `didFinish`
delegate) that is assumed — but never proven — to run before the declarative layer
(SwiftUI body re-eval) reads it. Same class recurs at multiple layers:
- **Scroll-restore (TSK-1046):** WebView `didFinish` → SwiftUI re-eval → `Task` hop → render,
  no single stage owned the state; 13 commits over the arc, 3 distinct "fixes" that didn't
  stick before collapsing to a pull-based single source of truth
  (`docs/research/.../commits/c-15of19.md`, commit `a28a5a35`/`1e339e9c`).
- **Session-switch scroll reset / footer-stats blank-on-switch (TSK-1120) / "loading…" flashes**
  — CLAUDE.md names these explicitly as the SAME class: "imperative state populated AROUND a
  switch, raced by the declarative render that reads it" (`CLAUDE.md` §Root-cause discipline).
- **CM6→Swift text-sync debounce never flushed at save/close/blur/quit** — a 200ms debounce
  timer is itself a race against `⌘S`; `codemirror.html:121` / `EditorCoordinator.swift:863`
  (`BACKLOG.md` THEME 1).
- **Session-switch tab drain deletes the hot-exit spill it just wrote** — a `remove()` runs
  before a `!isBulkDraining` guard is checked, i.e. two async-adjacent steps assumed ordered
  that weren't (`DocumentModel.swift:3221`, `BACKLOG.md` THEME 1).

**How found:** never by static inference — CLAUDE.md's root-cause SOP explicitly bans
"restoreScroll runs after select(), so it's too late" reasoning without runtime proof, because
SwiftUI body re-eval is async/coalesced. Found only by *instrumenting at runtime* / building a
live in-process WebView test that reproduced the exact render VM timing (`c6327698` — "the
final 'right vehicle' was CM6 in-process WebView, not headless").
**How long it evaded:** TSK-1046 took 13 commits / multiple sessions; each "fix" patched one
stage of the async chain and the bug reappeared at the next stage.
**Fix pattern that stuck:** collapse the chain to a single, pull-based source of truth
(`tab.renderedScrollY` read declaratively) instead of adding another imperative seed/patch.
CLAUDE.md codifies this explicitly ("prefer collapsing the fragile chain over adding a
stage-patch... a single source of truth removes the race by construction").

### 2. Staleness — build/link/mirror artifacts silently served as fresh
**Frequency: high (~8 distinct instances named in LESSONS.md). Severity: high — produces
false regressions and false passes both directions.**
- **SwiftPM does not track a linked `.a` as a build input.** `swift test --filter` won't
  relink after a native rebuild; even a full `swift test --parallel` can silently ship stale
  Rust code if the resulting object is byte-identical after a Swift-file touch (no real
  content change). Fixed by `build-rust-core.sh` deleting SwiftPM link products whenever the
  staged `.a` content changes; long-term fix recommended is an xcframework `binaryTarget`
  (`LESSONS.md` batch 2, "Theme: SwiftPM / build staleness traps"; `d-lessons-2of2.md`).
- **Cross-module enum-layout skew** — adding a case to a cross-module enum leaves stale
  `Tests/` `.o` files compiled against the old tag order; a pure-Swift `throw` with zero FFI
  involvement then SIGSEGVs on the stale pattern-match, looking *exactly* like an FFI/unwinding
  bug (`CLAUDE.md` §SwiftPM staleness traps; live case 2026-06-12).
- **VM `dist/` staleness (UAT trap).** The VM rsync excludes `dist/`; `test` mode never
  rebuilds it, so live-app/pixel tests spawn a build that can be *weeks* stale, producing a
  fabricated "editor save doesn't persist" data-loss alarm. Fix: `all` mode rebuilds `dist/`
  first; standing check = compare binary mtime vs. `git log -1` before trusting any UAT
  failure (`CLAUDE.md` §Testing rules; `LESSONS.md` "VM UAT stale-dist trap", 2026-06-15).
- **`RustCoreHeaderRestageTests.swift`** exists specifically as a hermetic regression guard for
  this exact trap (TSK-626), verifying `restage-header.sh`'s mtime-touch behavior
  (`summaries/code/t-core-root-6of7.md`).

**How found:** by noticing a bug that "shouldn't be possible" given the diff just landed, then
checking artifact timestamps rather than trusting the test result.
**Fix pattern that stuck:** an explicit compare-and-touch/force-relink step wired into the
build script (not a manual habit); a hermetic test that re-enacts the staging script's exact
behavior.

### 3. False-green verification bugs (the "model fixed, on-screen unverified" trap)
**Frequency: very high, arguably the project's most expensive class in aggregate agent-hours.
Severity: critical — repeatedly caused "fixed" to be reported when nothing had changed on
screen.**
- **Compositor occlusion is the flagship instance.** An opaque, layer-backed
  `NSViewRepresentable` (WebView/terminal) composites OVER an earlier-painted SwiftUI sibling
  even when geometrically non-overlapping; `ImageRenderer` and `cacheDisplay` give a FALSE
  GREEN because they either rasterize SwiftUI's tree in isolation (placeholder for the
  representable — no occlusion to see) or are blind to CA layers entirely (renders black).
  Only real WindowServer pixel capture (`screencapture -l<windowID>`, T5) is authoritative
  (`CLAUDE.md` §Compositor occlusion; `d-lessons-1of2.md` — "single most expensive, most-
  referenced lesson"). Recurred 3+ re-attempts in one day (c-01) before a 9-commit TSK-488
  rework (c-05) made it stick, and only stuck once a *negative-control switch*
  (`MDVNegativeControl.isBroken`) was mandated to prove the guard could actually go red.
- **`NSTextView.layoutManager.numberOfGlyphs` stays ~0 for a TextKit-2 view even when fully
  populated** — a "blank/did not mount" false-negative; use `textStorage.length` instead
  (`LESSONS.md` batch 1, 2026-06-2x cluster).
- **Headless-WKWebView cannot reliably synthesize real mouse/pointer gestures** (verified over
  4 VM rounds) — a webview-lane test asserting "click worked" is a false green for gesture
  bugs; the durable answer is state-driven assertions + a grep-guard at code level + AX/spawned-
  app UAT for the actual gesture (`LESSONS.md` batch 1).
- **`screencapture -x` (full-screen) does not framebuffer-composite app-window content** even
  though the window is AppKit-healthy — a structural false-negative unless window-ID-targeted
  capture is used (`LESSONS.md` batch 1).

**How found:** by deliberately reverting a fix and confirming the test/guard actually goes red
— "demonstrate teeth" — which is now a standing CLAUDE.md mandate.
**Fix pattern that stuck:** tier the test architecture as an explicit type hierarchy
(`HeadlessUITestCase`/`LiveAppTestCase`/`PixelTestCase`) enforced at runtime by a
`TierGateObserver`, and treat pixel capture as the *only* authority for compositing claims.

### 4. FFI/boundary bugs — enum layout, unwinding-that-isn't-FFI, UAF, uncatchable native aborts
**Frequency: high in the Rust-core era (c-03 onward). Severity: high — several are true
crash-class bugs, not just test noise.**
- **SIGSEGV that looks like an FFI bug but is pure-Swift stale-object skew** (see #2 above) —
  the diagnostic trap is assuming FFI is the culprit when it's actually a stale `.o` compiled
  against a shifted enum tag order.
- **UAF on concurrent handle free (TSK-541).** Raw `Box::into_raw` handle pattern let a
  concurrent `free` race an in-flight call. Fixed with a global
  `Mutex<HashMap<usize, Arc<SessionHandle>>>` registry — lookups clone the `Arc` under the lock
  so in-flight calls keep the session alive even if a concurrent free runs; `try_lock` (not
  blocking) returns `Busy` on contention, a poisoned lock returns permanent `HandleDead`
  (`summaries/code/src-rust-other-crates.md`, `rust-core/crates/ffi/src/handle.rs`).
- **Stack-overflow abort that `catch_unwind` cannot catch.** The Rust formula parser's
  unbounded recursion overflows the stack under `=((((…` and hard-aborts the process — `ffi_guard!`'s
  `catch_unwind` wrapper is powerless against a stack-overflow abort (distinct from a catchable
  `panic!`). Same class as a cmark deep-nesting SIGABRT found in audit. Fix: an explicit
  recursion-depth cap (~128, matching `serde_json`'s default) with a degrade-to-raw-text
  fallback, not a `catch_unwind` retrofit (`BACKLOG.md` THEME 2; `LESSONS.md` batch 2 "parser
  hardening").
- **`NSFileHandle` close-race raises an uncatchable ObjC `NSFileHandleOperationException`.**
  Calling `.fileDescriptor` / `.availableData` on a handle that gets closed concurrently
  crashes the whole process — Swift `catch`/`try` cannot intercept an ObjC exception. This is
  the SAME shape as the FFI stack-overflow-abort bug: a native runtime abort below the
  language's own exception machinery. TSK-1559's fix replaced `availableData` reads with raw
  POSIX `read(2)`/`write(2)` on a cached fd, converting the crash into an inspectable
  `EPIPE`/`EBADF` (`c-19of19.md` §TSK-1559; three-commit fix, `84cb6560`/`75fb2ac6`).
  `PluginSubprocessHost.close()`s pipe handles under `availableData` readers` was flagged in
  the audit as the SAME unfixed class recurring elsewhere (`BACKLOG.md` THEME 2).
- **Grapheme (Swift `Character`) vs Unicode-scalar (Rust `char`) index domains diverge** on
  combining marks/ZWJ emoji — any fuzzy-match/highlight code claiming "byte-exact Swift/Rust
  parity" is dishonest for non-ASCII input unless it uses a grapheme-segmentation crate
  (`LESSONS.md` batch 2, "cross-language porting").
- **A configured `[workspace.lints] deny` is a dead letter if CI never runs `cargo clippy`/
  `cargo test` on it** — real panic sites shipped despite the deny because CI only ran
  `cargo build` (`LESSONS.md` batch 2).

**How found:** SIGSEGV-vs-staleness was found by `touch`ing dependent files and re-running; the
UAF was found by code review of the free-vs-call pattern (TSK-541 in the port's own hardening
pass); the stack-overflow-abort and NSFileHandle bugs were found in a dedicated audit/drain
sweep specifically hunting "uncatchable aborts on default-ON paths" (`BACKLOG.md` THEME 2).
**Fix pattern that stuck:** for the handle UAF, an `Arc`-backed registry (structural, not a
patch). For uncatchable native aborts, the fix is *never* "wrap it in a language-level catch" —
it's eliminating the abort precondition entirely (recursion cap; raw syscalls that return
error codes instead of throwing ObjC exceptions).

### 5. Data-loss classes (the single biggest audit cluster — THEME 1, ~8 P1s)
**Frequency: high, and specifically corroborated across multiple independent audit passes.
Severity: critical (user data).** All root causes are variations on **"a debounce/cache/mirror
is never flushed at the moment that matters, or a write's failure is silently swallowed":**
- Debounce-never-flushed: CM6→Swift 200ms mirror not flushed at save/close/blur/quit → `⌘S`
  can persist a stale mirror (see #1).
- In-memory-only dirty state with no crash/quit guard: hex-editor dirty bytes live only in
  memory, lost on quit/crash with no prompt (`DocumentModel+EditableHex.swift`).
- Ordering bug in a drain path: hot-exit spill deleted before the guard that should have
  protected it is checked (see #1).
- **Silent write-failure propagation:** `JSONFileStore.write`'s `Bool` return is discarded by
  every caller — a disk-full quit loses sessions + hot-exit edits with zero signal
  (`SessionStore.swift:414`).
- **Strict-decode wipes:** `BookmarksStore` strict-decodes an array; one malformed entry wipes
  ALL bookmarks and the next toggle clobbers the file on disk — the fix pattern that exists
  elsewhere in the codebase (`readLenientArray`) was simply not applied here
  (`BookmarksStore.swift:242`).
- **UI affordance lying about its own semantics:** the disk-conflict "Merge…" button silently
  behaves as "Keep Mine," clobbering the external edit on next save
  (`DiskConflictBanner.swift:40`).

**How found:** the ~30-dimension pre-launch audit fanout (`docs/research/prelaunch-audit-2026-07-09/`),
triaged/deduped into themes 2026-07-10 — **all UNVERIFIED**, the adversarial-verify phase never
ran. Signal quality rated HIGH (27/30 reports carry real file:line evidence) but every item is
"plausible, unconfirmed" pending confirmation (`BACKLOG.md` header).
**Fix pattern (not yet applied — audit paused):** none of these are landed fixes; they're
findings. The class-level fix implied by the corpus (matches lessons elsewhere) is: (a) flush
debounced state on every teardown path (save/close/blur/quit), not just the timer tick; (b) make
write-failure a typed error that propagates, not a discarded `Bool`; (c) use lenient/partial
decoding for any store that must survive one corrupt record; (d) UI copy must match the actual
code path it triggers.

### 6. Compositor/occlusion — folded into #3 above (it's the paradigm false-green case)
See #3. Worth flagging separately in a taxonomy sense: it is not merely a *verification* bug,
it is also a genuine **rendering-architecture bug class** — any opaque `NSViewRepresentable`
sibling of a SwiftUI view needs `.compositingGroup().zIndex()` ordering in *every* layout branch,
or the sibling silently disappears depending on paint order (`CLAUDE.md` §Compositor occlusion).

### 7. CRLF / grapheme-cluster bugs
**Frequency: low-count but recurring in exactly the same shape twice. Severity: medium
(silent corruption, not a crash).**
- **`LSPPositionConverter` matches `"\n"` as a `Character`** — a CRLF (`\r\n`) is a *single*
  grapheme cluster to Swift's `Character` iterator, so line-ending scans that iterate by
  `Character` never match, corrupting diagnostics/folds/formatter edits on CRLF files
  (`LSPPositionConverter.swift:55`, `BACKLOG.md` THEME 2).
- **The identical shape was already a named LESSONS.md rule before this instance was found**:
  "don't iterate a string by user-perceived Character when scanning for line-ending bytes... a
  CRLF sequence is a single grapheme cluster" (`LESSONS.md` batch 1, "curated don't re-break
  this list") — meaning the lesson was captured once, then the SAME bug class recurred in a
  different subsystem (LSP) that wasn't cross-checked against the existing lesson.
**Takeaway:** a documented lesson does not automatically propagate to sibling code paths; it
needs either a lint/grep-guard or a shared utility function, not just a LESSONS.md entry.

### 8. Memory blowups
**Frequency: low-count, but at least one was severe enough to swap-thrash the whole host.
Severity: critical when it hits (host-level, not just app-level).**
- **Naive O(n×m) LCS diff algorithm caused a 77GB memory spike**, swap-thrashing the entire
  development host. Fix chain: common-prefix/suffix trim → line interning to ints → Myers
  O(N·D) linear-space diff (the diffutils/git-standard algorithm) → a hard size-guard that
  refuses to invoke the differ above a threshold and falls back to a snapshot
  (`LESSONS.md` batch 1, 2026-06-2x cluster).
- **Memory-metric mismeasurement is itself a recurring failure mode**: VSZ is meaningless
  (address space), RSS undercounts (misses compressed/swapped pages); `phys_footprint` is the
  metric that actually reflects memory pressure on macOS (`LESSONS.md` batch 1; also
  `reference_macos_memory_metrics.md` in MEMORY.md).
- **Multi-process rendering engines (WebKit) show up as several persistent helper processes**
  once any instance has ever been created — naive RSS-summing misattributes that baseline to
  the app's own code (`LESSONS.md` batch 1).
- **Tests have no memory ceiling by default** — a runaway algorithm under test can take down
  the whole host, not just fail the test (`LESSONS.md` batch 1).

**How found:** the host itself became unresponsive (swap-thrashing) — the failure mode found
itself; no dedicated instrumentation caught it in advance.
**Fix pattern that stuck:** the textbook algorithmic fix (Myers diff) PLUS a hard resource
guard that refuses to run above a size threshold — i.e., algorithmic correctness alone was not
trusted to prevent recurrence; a circuit breaker was added on top.

### 9. Startup / process-identity crash class (bonus — not in the prompt's list but load-bearing)
**Frequency: single instance, but P0 and structurally interesting.**
`main.swift` initialized `NSApplication.shared` *before* branching on `--mcp-connect`, so every
MCP bridge subprocess (same bundle executable, different invocation mode) registered itself as
a running GUI app instance. Finder then tried to *activate* a zombie bridge instead of launching
the real app — "app un-openable," LS -600 (`TSK-1566`, `c-19of19.md`). Root cause: a
process-mode branch happened *after* a global, order-sensitive side effect. Fix: hoist the
bridge branch above `NSApplication.shared` (bridge is pure POSIX, never touches AppKit) + a
PPID-poll watchdog so zombie bridges self-reap; guarded going forward by a test that parses the
*live* `main.swift` and fails red if the ordering regresses (`MCPBridgeLaunchOrderTests`).

---

## What worked — practices that earned their keep

- **Negative-control switches force a guard to prove it can go red** (`MDVNegativeControl.isBroken`,
  gated by `MDV_ENABLE_BROKEN_<NAME>=1`). Converts "revert the fix by hand and confirm red" from
  an ad-hoc manual step into a committed, repeatable CI proof — codified after compositor-
  occlusion burned the project multiple times on ungated false greens (`CLAUDE.md`).
- **Tier-as-type-hierarchy test architecture** (`HeadlessUITestCase`/`LiveAppTestCase`/
  `PixelTestCase`, `TierGateObserver` sentinel enforcement) made "which class of bug does this
  test actually catch" machine-checkable instead of a convention people forget
  (`summaries/code/t-ui-harness.md`).
- **Collapsing the async chain to a single pull-based source of truth**, applied twice
  independently (scroll-restore, and generically named in CLAUDE.md's root-cause SOP #4) — both
  times a multi-commit rework arc that "kept coming back" was closed permanently only once the
  fix stopped adding another stage-patch.
- **Arc-backed handle registry for FFI concurrency** — a textbook, structural UAF fix (not a
  lock-harder patch) that generalizes to any C-boundary "opaque token → live object" pattern.
- **Explicit recursion/nesting depth caps on any recursive-descent parser over untrusted input**
  — cheap, and the *only* fix that actually works against a native stack-overflow abort (no
  language-level catch can substitute for it).
- **Root-cause SOP as a gating checklist** (CLAUDE.md §Root-cause discipline: is this a CLASS?
  what's the MECHANISM — sync/async/data? VERIFY end-to-end, don't infer from code order;
  collapse don't patch) — written specifically because a re-diagnosis from scratch landed a fix
  for the wrong cause once (TSK-1046 live miss cited in the doc itself).
- **Demonstrated teeth on every real-UI test** (revert → confirm red → restore) as a standing
  practice, not a one-off audit step.

## What hurt — costly failures and their mechanism

- **False-green verification tooling (`ImageRenderer`, `cacheDisplay`, headless frame-walks)
  was trusted for compositor claims for a long stretch before pixel capture became mandatory.**
  Mechanism: these tools rasterize SwiftUI's *own* tree in isolation or are blind to CA layers —
  they structurally cannot see the occlusion because the representable's opaque layer doesn't
  exist in their capture path. Cost: 3 re-attempts in one day plus a later 9-commit rework
  before it stuck (`d-lessons-1of2.md`).
- **Re-diagnosing from a ticket's existing (already-correct) understanding wasted a full
  session** — TSK-1046 was re-diagnosed as a read-race and a partial fix landed for a different
  cause than the one the ticket already documented (warm-cache re-attach skipping `didFinish`;
  CM6 `initialSelection` ignoring the scroll channel). Mechanism: skipping "read the ticket's
  `understanding` + comments FIRST" before acting (`CLAUDE.md` §Root-cause discipline, item 0).
- **Uncatchable native aborts (stack-overflow abort, ObjC `NSFileHandleOperationException`)
  were initially approached as catchable errors** (wrap in `catch_unwind` / Swift `try`) before
  the mechanism was understood — both required eliminating the *precondition* for the abort,
  not adding a catch layer that structurally cannot intercept it.
- **A documented lesson (CRLF-as-single-grapheme) did not stop the same bug from recurring in a
  different subsystem** (LSPPositionConverter) — a LESSONS.md entry is not self-enforcing;
  without a shared utility or a lint, each new string-scanning site can independently re-commit
  the same mistake.
- **VM `dist/` staleness produced a fabricated P0 ("editor save doesn't persist")** that cost a
  round of investigation before the root cause (weeks-stale binary, not a regression) was found —
  a cheap mtime-vs-commit check upfront would have prevented the entire detour.
- **Silent write-failure propagation (`Bool` return discarded)** is architecturally the cheapest
  data-loss bug to prevent (a typed `Result`/throwing signature forces callers to handle it) and
  the audit found it unaddressed project-wide at persistence boundaries — evidence that a
  language-level affordance (discardable `Bool`) was systematically misused rather than a one-off
  mistake.

## Design implications for the rebuild

**Do differently from day 1 (structural, not process):**
1. **No flag-return persistence APIs.** Every write/save API returns a typed `Result`/throwing
   signature that the compiler forces callers to acknowledge — kills the `JSONFileStore.write`
   discarded-`Bool` class outright, not just in the one place it was found.
2. **Every debounced/coalesced write gets an explicit, tested flush hook wired into every
   teardown path** (save, close, blur, quit, crash-handler) from the moment the debounce is
   introduced — not retrofitted after an audit finds it missing. Treat "debounce with no flush
   contract" as a code-review-blocking pattern, the same way a memory leak would be.
3. **Recursion/nesting depth caps are mandatory on any recursive-descent parser over untrusted
   input, added at the same time the parser is written** — not discovered later via a
   `catch_unwind`-can't-catch-this incident. Bake it into the Rust-core parser template
   (matches the corpus's own `serde_json`-default-128 recommendation).
4. **Native syscalls, not high-level handle APIs, for anything that can race a close.** The
   `NSFileHandle` `.availableData`/`.fileDescriptor` uncatchable-exception class should be a
   standing "never do this" rule for any process-pipe or socket code from day one, in whichever
   language stack is used (POSIX `read`/`write` on a cached fd, error-code return, never an
   exception-throwing high-level wrapper on a resource another thread can close).
5. **Build pixel-level (real compositor) UI regression tests from day one for any hybrid
   SwiftUI/AppKit-representable surface**, not after the false-green tooling burns the project
   repeatedly. If the rebuild's UI stack similarly mixes a reactive framework with opaque native
   surfaces (WebView, terminal, canvas), assume compositor occlusion is a *when*, not an *if*.
6. **Treat the linked native-core artifact (Rust `.a`/dylib) as an explicitly tracked build
   input from day one** — prefer an xcframework `binaryTarget` (native SwiftPM tracking) over a
   raw `-L` flag, closing the SwiftPM-staleness class structurally instead of via a
   compare-and-touch script bolted on later.
7. **Any async handoff with more than one stage (delegate callback → framework re-eval → task
   hop → render) should be designed with a single, pull-based read as the DEFAULT shape**, not
   discovered as the fix after 2+ patch attempts. If a value can be read declaratively from one
   owning source, don't seed it imperatively from multiple call sites.

**What to accept as inherent cost (budget for it, don't try to eliminate):**
- VM/render test-harness investment is permanent infrastructure tax (matches the commits-index
  "harness bring-up" finding) — every new validation surface needs its own multi-commit unblock.
- Some fraction of "audit found a plausible bug" will turn out to be a duplicate of an existing,
  documented lesson that simply wasn't propagated to a new call site (CRLF class) — a periodic
  cross-check ("does this finding match an existing LESSONS.md entry in a different subsystem?")
  is cheaper than expecting zero recurrence.
- A first pre-launch-scale audit fanout (~30 dimensions) will surface a genuine data-safety
  cluster (THEME 1 here) no matter how careful the incremental development was — schedule it as
  a recurring checkpoint (matches the commits-index top learning #5: "run systematic,
  severity-triaged audits repeatedly, not once"), not a one-time gate.

---

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **Every persistence write returns a typed, checked result — no discardable `Bool`/silent-fail
   write APIs, anywhere, from the first commit.**
2. **Every debounced/coalesced state mirror ships its flush-on-teardown hook (save/close/blur/
   quit) in the SAME commit that introduces the debounce — a debounce without a flush contract
   fails review.**
3. **Any recursive-descent parser over untrusted input gets an explicit depth/nesting cap in the
   SAME commit it's introduced, with a test that (a) accepts valid deep-but-under-cap input and
   (b) confirms the cap actually rejects over-cap input.**
4. **Never call a high-level exception-throwing/ObjC-bridged API (`NSFileHandle.availableData`,
   etc.) on a resource another thread/process can concurrently close — use the raw syscall with
   an inspectable error return.**
5. **When a timing/race bug survives a second "fix" attempt, stop patching stages of the async
   chain — collapse to a single, pull-based source of truth instead.**
6. **Any opaque native view sibling of a reactive-framework view gets explicit compositing/
   z-order treatment in every layout branch from the moment it's added; the ONLY acceptable
   proof that it renders correctly is a real compositor pixel capture — in-process snapshot
   tools are a false green for this class by construction.**
7. **Every regression-guard test must be demonstrated to fail: revert the fix (or flip a
   negative-control switch), confirm the test goes red, then restore. A test that has never
   been shown to fail is not a guard.**
8. **Treat a linked native-core binary as a tracked build input from day 1 (xcframework/
   equivalent), not a raw linker flag — closes the stale-relink class structurally instead of
   needing a compare-and-touch script discovered after the fact.**
