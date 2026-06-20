# Adversarial Review — FINAL Synthesis (2026-06-18)

Curated, deduplicated roll-up of the 13 dimension reports under
`docs/research/adversarial-review-2026-06-18/`. Every entry below is a
**CONFIRMED** finding (each dimension's reviewer reproduced it; REFUTED items —
the testing-gaps "redaction untested" claim, the concurrency "RepoStats slot
leak", and the memory "scroll-coordinator observer" claim — are excluded).

Findings were cross-checked against the entire `tasked` board (project `tasked`,
prefix `TSK`, 849 tasks; the only project carrying markdown_viewer work). **No
board ticket exists for any finding in this review** — every item is NEW. The
closest prior work is TSK-577/TSK-669 (the WireError emit + host-consume pair),
against which finding **N6** is a *missed call-site* in otherwise-completed work,
and the export-feature tickets TSK-866/871/881, which *introduced* the
deliberately CSP-free export code the security findings target (feature tickets,
not defect tickets — so the security defects are genuinely new).

> Board-search caveat: the `mcp__tasked__task_list` `q=` free-text parameter is
> currently a no-op on this MCP surface (verified — a nonsense query returns the
> full backlog unchanged). Matching was therefore done by paging the entire
> board (created-sort) and scanning titles + spot-reading the candidate tickets.
> Worth filing against the tracker itself (`internal` project) separately.

---

## Executive summary

**Deduplication:** 50 confirmed findings across 13 dimensions collapsed to **44
unique issues**. Two cross-dimension duplicate clusters merged:

- MessagePack unbounded-recursion SIGSEGV — surfaced by *testing-gaps* (critical)
  and *blank-slate-2* (high). One defect → **C1** (critical).
- HTMLSanitizer `javascript:` / event-handler regex bypass — surfaced by
  *security* (twice: the high export-chain + a standalone medium) and
  *testing-gaps* (high). One root defect (the same two regexes) → **H1**, the
  stored-XSS export chain, which subsumes the standalone sanitizer finding and
  the coverage gap.

**Status:** NEW = **44**, Already-tracked = **0**.

**By severity (deduplicated):**

| Severity  | Count | NEW | Tracked |
|-----------|------:|----:|--------:|
| Critical  | 1     | 1   | 0       |
| High      | 9     | 9   | 0       |
| Medium    | 16    | 16  | 0       |
| Low       | 18    | 18  | 0       |
| **Total** | **44**| **44** | **0** |

**The signal:** the codebase is well-hardened on the dimensions that have been
audited before (the in-app CSP, `ProcessRunner`/`GitClient` arg-array hygiene,
the FFI panic walls). The residual risk concentrates in **three seams**:

1. **The newest feature surface — HTML export / "Open in Browser"** (TSK-866 era)
   — which deliberately drops the CSP that everywhere else backstops the
   regex sanitizer, turning known sanitizer bypasses into real stored XSS (H1)
   and adding a path-traversal file-inlining gap (L-sec1).
2. **The remote-core transport** (RemoteTransport / MessagePack, opt-in via
   `MDV_REMOTE_SOCKET`) — an unbounded-recursion crash (C1), use-after-teardown
   in subscription delivery, EINTR-fatal I/O, unbounded orphan-event growth, and
   an Int(UInt64) trap. Bounded to remote-attach deployments today but on the
   project's stated transport-agnostic roadmap.
3. **SwiftUI-body / main-thread work on hot paths** — per-keystroke buffer
   re-encode in the status bar, a git subprocess spawned from context-menu
   validation, and an unindexed cross-file search in the Rust remote twin.

Plus two **data-durability** gaps that can silently lose user edits (hot-exit
clobber of externally-changed files; no fsync on any session/bookmark/history
write).

---

## NEW Critical

### C1 — MessagePack decoder has no recursion-depth limit → remote SIGSEGV (uncatchable DoS) · NEW
- **Severity:** critical · **Dimensions:** testing-gaps, blank-slate-2 (deduped)
- **Location:** `Sources/RustCore/MessagePack.swift:92` (`decode`), `:157`
  (`array`), `:172`/`:184` (`map`); reached on the live remote path at
  `Sources/RustCore/RemoteTransport.swift:232`.
- **Why:** `decode()` recurses through `array`/`map` with no depth guard (the
  `reserveCapacity` clamp bounds *memory*, not *depth*). `readLoop` admits a
  16 MiB frame (`RemoteTransport.swift:222`); a sub-16 MiB envelope of repeated
  `0x91` is ~8M deep and hands straight to `reader.decode()`. Reproduced
  standalone: a 200k-deep `0x91…0xc0` frame exits with **signal 139 (SIGSEGV)** —
  an unrecoverable crash, not a catchable `throw`. The negative/fuzz suite covers
  truncation / OOM-clamp / bad-tags / trailing only — **zero** depth coverage.
  Live via `RemoteCoreAttach.attachIfConfigured` ← `main.swift:70`, gated on
  `MDV_REMOTE_SOCKET`; a buggy/version-skewed server crashes the client with one
  frame, exactly the "looks like an FFI/unwinding bug, is actually a Swift crash"
  class the project has been bitten by.
- **Fix:** thread a depth counter through `decode()`; throw a new
  `MsgPackError.tooDeep` past a sane cap (~64–128, deeper than any real core
  response). Add a teeth test asserting an N-deep frame **throws**, not crashes,
  plus a boundary test at the limit that still decodes.

---

## NEW High

### H1 — Stored XSS in exported / browser-opened HTML — bypassable sanitizer is the *sole* defense (no CSP) · NEW
- **Severity:** high · **Dimensions:** security (×2), testing-gaps (deduped)
- **Location:** `Sources/ViewerCore/HtmlExport.swift:9-32` (CSP-free document) +
  `Sources/ViewerUI/DocumentModel.swift:5082-5113`
  (`htmlExportForActiveMarkdown` / `writeActiveMarkdownPreviewHTML`) +
  `Sources/ViewerCore/HTMLSanitizer.swift:218-274`
  (`stripEventHandlers` / `neutralizeJavaScriptURLs`); menu wiring
  `Sources/MarkdownViewer/main.swift:1599-1609`. Tests pinning only the happy
  path: `Tests/ViewerCoreTests/HTMLSanitizerTests.swift:101-121`.
- **Why:** `htmlExportForActiveMarkdown` renders author markdown via
  `HTMLRenderer().render` (which emits embedded HTML through `HTMLSanitizer`
  *unescaped*) and wraps it with `HtmlExport.standaloneDocument`, which
  **deliberately ships no CSP** so external images render in a browser.
  `writeActiveMarkdownPreviewHTML` writes that to a temp `file://` opened in the
  user's real browser. In-app a strict `default-src 'none'` CSP backstops any
  sanitizer miss; **on the export / "Open in Browser" path that backstop is
  gone**, so the regex sanitizer is the only defense — and it has confirmed
  bypasses, all reproduced against the exact shipped regexes:
  - `<a href="x"onmouseover=…>` — `\s+on[a-z]+` requires whitespace; an
    `on*` attribute abutting a closing quote is **not** stripped.
  - `<svg/onload=…>` — `/` is a valid attribute separator; the `\s+` requirement
    misses it.
  - `jav&#x09;ascript:` (and `&#x6a;avascript:`, `java\tscript:`,
    `jav\nascript:`) — entity-encoded / control-char scheme defeats the literal
    `javascript|vbscript|data:text/html` match; the browser decodes and executes.
  An untrusted markdown file (cloned-repo README, emailed `.md`) carrying one of
  these survives sanitization, lands verbatim in the export, and executes in the
  victim's browser with `file://`-origin privileges (read sibling local files,
  exfiltrate). The class docstring's "CSS-only UI confusion" residual-risk claim
  is false, and the *tests* assert the sanitizer neutralizes `javascript:` —
  manufacturing false confidence that it stops scheme XSS when it stops only the
  literal form.
- **Fix:** (1) On the CSP-free export path, do **not** emit raw author HTML —
  escape it to text (or DOM-parse-and-reserialize through a real allowlisting
  parser) and ship a restrictive `<meta>` CSP that still permits the external
  images the feature wants (`default-src 'none'; img-src https: data:;
  style-src 'unsafe-inline'`). (2) Independently fix the regexes (anchor the
  handler on `[\s/]`, tokenize attributes quote-aware, and entity-decode /
  control-strip the scheme prefix before matching) so the defense-in-depth layer
  actually holds in-app too. Add the bypass cases above as failing-then-passing
  teeth tests.

### H2 — sqlite3_bind_text holds a dangling pointer (use-after-free) · NEW
- **Severity:** high · **Dimension:** blank-slate-2
- **Location:** `Sources/ViewerCore/SQLite/SQLiteReader.swift:161-168`
- **Why:** The only `sqlite3_bind_*` site passes `nil` = `SQLITE_STATIC`, telling
  SQLite not to copy and to retain `buf.baseAddress`. `sqlite3_step` runs **after**
  the `withUnsafeBufferPointer` closure returns, where the pointer is no longer
  guaranteed valid — a genuine use-after-free. Reached via `schemaFor(_:)` on any
  opened `.db` (exercised by `SQLiteReaderTests.swift:104`).
- **Fix:** pass `SQLITE_TRANSIENT` (SQLite copies), or move the `step` + column
  reads inside the `withUnsafeBufferPointer` closure so the buffer outlives the
  step.

### H3 — Stale/out-of-order async result clobbers the git-chip menu (last-writer-is-wrong) · NEW
- **Severity:** high · **Dimension:** concurrency
- **Location:** `Sources/ViewerUI/GitChipStore.swift:41-46` (`load`), `:31-36`
  (detached enumerate); call site `Sources/ViewerUI/StatusBar.swift:223`
  (`.task(id: root)`).
- **Why:** `load(root:)` publishes branches/worktrees/`loadedRoot` after a
  non-throwing `await` with no freshness/cancellation guard, and the default
  enumerate runs in `Task.detached` which `.task` cancellation cannot stop. On a
  repo switch A→B where A's walk finishes after B's, `load(root:A)` publishes A's
  branches while the user is in repo B — the chip shows the wrong repo and a
  branch-switch acts on the wrong root. Host-reproducible pure logic.
- **Fix:** gate the publish on a monotonic in-flight token compared *after* the
  await; ignore the result if a newer load has started.

### H4 — RepoStatsCache actor blocks its serial executor on synchronous git walks · NEW
- **Severity:** high · **Dimension:** concurrency
- **Location:** `Sources/ViewerCore/Git/RepoStatsCache.swift:62-80` (`stats`);
  blocking calls `GitClient.swift:765` (`headInfo`) / `:905` (`repoStats`);
  caller `Sources/ViewerUI/Git/FolderStatsView.swift:242`.
- **Why:** `stats()` is an actor method with no `await` that calls blocking git
  subprocesses (`for-each-ref`/`rev-parse`; `rev-list --count`, `shortlog -sne`
  — seconds on a monorepo) directly on the actor's serial executor. The walk
  holds the shared cache exclusively, head-of-line-blocking every other
  `stats()`/`invalidate*()`. No in-flight coalescing, so N folder-stats views
  over one repo serialize N multi-second walks. The opposite of
  `TrackedReposStore.refresh`, which off-loads blocking git to `Task.detached`.
- **Fix:** wrap `headInfo()` + `repoStats()` in `await Task.detached{…}.value`
  and add per-key in-flight coalescing.

### H5 — StatusBar re-encodes + rescans the whole editor buffer on every keystroke (cache always misses) · NEW
- **Severity:** high · **Dimension:** performance
- **Location:** `Sources/ViewerUI/StatusBar.swift:506-519` (currentMetrics editor
  branch) → `:568-595` (`metrics(for:)`).
- **Why:** StatusBar observes `tabCoordinator` directly, so its body re-evals per
  editor keystroke. `currentMetrics` does `buf.text.data(using: buf.encoding)?.count`
  — a full encoded copy of the buffer just to count bytes — then builds a
  `bufferFile` and calls `metrics(for:)`, cached on `(url, byteCount)`. The
  byteCount changes every char, so the cache is a perpetual miss; each keystroke
  pays a `lineCount` full scan + `utf16.count` + `LineEndingDetector` +
  `RustIndentAdapter.detect` (FFI) on the main thread. Real per-keystroke
  main-thread tax on large files.
- **Fix:** debounce the metrics recompute, do the byte-count off the encoded copy
  (track length incrementally or compute off-main), and key the cache on a
  content fingerprint that doesn't churn per char.

### H6 — canShowFileHistory spawns a git subprocess on the main thread from menu/context-menu validation · NEW
- **Severity:** high · **Dimension:** performance
- **Location:** `Sources/ViewerUI/DocumentModel.swift:2138-2143`
  (`canShowFileHistory`, `@MainActor`); `GitClient.isTracked`
  `Sources/ViewerCore/Git/GitClient.swift:102-105`; callers
  `SidebarView.swift:1134`, `TabBar.swift:312`, `main.swift:2810`.
- **Why:** `canShowFileHistory` synchronously does `GitClient.discoverRoot`
  (filesystem tree walk) + `isTracked`, which runs
  `git ls-files --error-unmatch -- <path>` — a real child process with
  `waitUntilExit` — wired into `.disabled(!model.canShowFileHistory(for:))` in
  the sidebar-row and tab context menus, evaluated when the menu opens/revalidates.
  Synchronous process spawn + wait on the UI run loop, unbounded on slow/network
  repos. `openFileHistory` already re-checks tracked-ness.
- **Fix:** enable unconditionally + resolve tracked-ness async, or back it with a
  HEAD/index-keyed tracked-set cache like the existing stats cache.

### H7 — Rust `search.files` recompiles the regex per file and never skips `.git`/`node_modules`/build dirs · NEW
- **Severity:** high · **Dimension:** performance
- **Location:** `rust-core/crates/serve/src/search.rs:84-141` (walk loop) calling
  `rust-core/crates/core/src/find_engine.rs:85-88`
  (`RegexBuilder::new().build()` inside `search`).
- **Why:** the walk calls `find_engine::search` per file, and that rebuilds the
  regex via `RegexBuilder::new(&pat).build()` **every call** — with
  `MAX_FILES=10000` the same pattern recompiles up to 10000×. The walk pushes
  every subdirectory unconditionally (`stack.push(path)`) with **no skip-list**,
  descending into `.git` / `node_modules` / `target` / `.build`, reading +
  UTF-8-decoding each then recompiling+running the regex. The Swift twin
  `CrossFileSearch.swift` compiles the matcher once and skips well-known dirs.
- **Fix:** compile the regex once before the walk; add a skip-list before
  `stack.push`. (The Rust remote endpoint is the inferior twin of the Swift path.)

### H8 — Swift grammar deps use caret ranges, violating the manifest's own exact-pin policy · NEW
- **Severity:** high · **Dimension:** api-design-and-deps
- **Location:** `Package.swift:66-94`; contradicted comment `Package.swift:57-60`.
- **Why:** every tree-sitter grammar + SwiftTreeSitter uses `from:` while the
  manifest's own swift-markdown line uses `.upToNextMinor` and its comment warns
  that `from:` lets SwiftPM walk to arbitrary future 0.x API. SwiftPM `from:`
  resolves to the next **major** (`>=x, <1.0.0` for 0.x), so the drift window is
  *wider* than a minor bump — any future 0.x of an attacker-file-parsing grammar
  can land on a `swift package update`. These 14 grammars parse untrusted input.
- **Fix:** replace `from:` with `exact:` (or `.upToNextMinor:`) for every grammar
  + SwiftTreeSitter, matching the documented policy.

### H9 — Supply-chain audit (cargo-audit / cargo-deny) never gates a PR · NEW
- **Severity:** high · **Dimension:** api-design-and-deps
- **Location:** `.github/workflows/nightly-supply-chain.yml:11-14` (schedule /
  workflow_dispatch only); `.github/workflows/pr.yml:97` (no audit/deny in the
  PR gate).
- **Why:** the PR gate runs `rust-core-gate.sh` (clippy + cargo test) but never
  `rust-supply-chain-audit.sh`, so license/bans/sources/advisory/yanked checks
  are absent from the merge path. `--locked` catches *unintended* lock drift, but
  a *deliberate* lock edit adding a disallowed-license / banned-dup / yanked /
  advisory crate passes the PR; the backstop only runs the next nightly.
- **Fix:** add `cargo audit` + `cargo deny` to `pr.yml` (or invoke
  `rust-supply-chain-audit.sh` from the PR gate). (Related to validated TSK-554,
  which wired the script into a gate — but the *PR* path is still uncovered.)

---

## NEW Medium

### M1 — RemoteTransport subscription handler can fire after `unsubscribe` returns (use-after-teardown) · NEW
- **Severity:** medium · **Dimension:** concurrency
- **Location:** `Sources/RustCore/RemoteTransport.swift:282-288` (route event arm)
  vs `:181-188` (`unsubscribe`).
- **Why:** `route` copies `subs[event.sub]` out under the lock, releases it, then
  invokes the handler outside the lock; `unsubscribe` nils `subs[sub]` under the
  lock and returns. The reader's local copy survives the nil-out, so
  `handler(event)` can run after `unsubscribe` (and any teardown of its captured
  state) completed — the "no events after unsubscribe" guarantee callers assume
  doesn't hold.
- **Fix:** deliver events on a per-transport serial queue that `unsubscribe`
  sync-barriers on, or explicitly document the trailing-call contract.

### M2 — MCPServer.runOnMainActor parks the reader thread on a no-deadline semaphore · NEW
- **Severity:** medium · **Dimension:** concurrency
- **Location:** `Sources/ViewerCore/Automation/MCPServer.swift:222-240`
  (`runOnMainActor`), `:80-85` (`stop`).
- **Why:** `runOnMainActor` blocks the reader on `semaphore.wait()` with no
  deadline. If the main actor wedges, the reader parks indefinitely and `stop()`
  (which only closes stdin) can't release a thread already past the read and
  parked mid-request — a real liveness gap. (The `return box!` force-unwrap is
  presently sound — `work()` is non-throwing and `box` is always assigned before
  `signal()` — but is a future-refactor hazard.)
- **Fix:** bounded wait returning a JSON-RPC internal error on timeout; carry a
  `Result` so the unwrap disappears.

### M3 — NSRange from unchecked remote highlight offset: Int(UInt64) traps · NEW
- **Severity:** medium · **Dimension:** blank-slate-2
- **Location:** `Sources/RustCore/CoreClient.swift:1052-1056` →
  `Sources/ViewerCore/RustHighlightAdapter.swift:53-55`.
- **Why:** `Int(try a[0].u64Value())` traps at runtime for values > `Int.max`, so
  a remote server returning `start = 2^63` crashes the app at decode time
  (pre-clamp). Highlight is a capability bit, so a remote producer can route here.
  (The reviewer's second claim — `NSRangeException` from over-long ranges — is
  REFUTED: all three apply paths clamp to text length first. Only the
  `Int(UInt64)` trap is real.)
- **Fix:** `Int(exactly:)` with a clamp/throw instead of the trapping conversion.

### M4 — PTY child does non-async-signal-safe work between forkpty() and execve() · NEW
- **Severity:** medium · **Dimension:** blank-slate-2
- **Location:** `Sources/ViewerUI/Terminal/PTYProcess.swift:89-99,118-151`.
- **Why:** the child branch + `execLoginShell` run between `forkpty` and `execve`:
  `ProcessInfo.processInfo.environment`, `Dictionary.map`, `strdup`→`malloc`,
  `withCString` String bridging — none async-signal-safe. The process is heavily
  multi-threaded (RemoteTransport reader, FSEvents, GCD, WebKit), so the
  malloc-lock-held-at-fork deadlock window is real; the code comment itself
  concedes "async-signal-safe-ish". Intermittent terminal-spawn hang/corruption.
- **Fix:** precompute env/argv/strdup'd arrays in the parent; the child does only
  `chdir` + `execve`. Or use `posix_spawn`/`posix_openpt`.

### M5 — LSP `lsp.json` override: untrusted repo `args`/`env` reach the trusted discovered server · NEW
- **Severity:** medium · **Dimension:** security
- **Location:** `Sources/ViewerCore/LSP/LSPLanguage.swift:378-393` +
  `Sources/ViewerCore/LSP/LSPWorkspaceOverrides.swift:113-195,230-243`.
- **Why:** when `isOverrideCommandTrusted` *refuses* a repo-supplied command, the
  fallback still spawns the trusted binary with `arguments: defaultArguments +
  entry.arguments` and `environment: mergedEnvironment` (repo env layered over
  the scrubbed base). The trust gate only gates the *binary path*, not args/env.
  Node servers honor `NODE_OPTIONS` (not name-scrubbed) and many servers take
  `--require`/`--plugin`/config-path flags — so a refused-command `lsp.json`
  still injects code-load args+env into a trusted server.
- **Fix:** on the untrusted-command fallback, use only `defaultArguments` + the
  scrubbed base env; honor repo `args`/`env` only when the command itself passed
  the gate. Add a test pinning `arguments == defaultArguments` /
  `environment == scrubbedLaunchEnvironment()` on the untrusted path.

### M6 — snapshotWindow discards the rich WireError out-buffer (no logWireErrorIfPresent) · NEW (gap in TSK-669)
- **Severity:** medium · **Dimension:** ffi-rust-boundary
- **Location:** `Sources/RustCore/CoreClient.swift:293-307` (`snapshotWindow`).
- **Why:** `snapshotWindow` calls `try check(status)` with **no**
  `Self.logWireErrorIfPresent(buf)`, while every other buf-returning path logs it
  (`callBuf:397`, `CoreEnvelope.call:98`, `mdvEnvelopeCall:584`,
  `mdvEnvelopeCallAux:617`). The Rust export *does* write a rich WireError into
  `out_buf` on error (`crates/ffi/src/lib.rs:852`), so the diagnostic exists and
  is silently dropped — on the path most likely to hit large-snapshot faults.
  This is a missed call-site in the work **TSK-669** completed (whose own
  validation noted "free-function error sites = noted remainder"); TSK-669 is
  validated/closed, so this residual is NEW.
- **Fix:** add `Self.logWireErrorIfPresent(buf)` before `check(status)` in
  `snapshotWindow` (and audit any other export sites for the same omission).

### M7 — Skewed envelope method-id reports Internal, indistinguishable from a real fault · NEW
- **Severity:** medium · **Dimension:** ffi-rust-boundary
- **Location:** `rust-core/crates/ffi/src/lib.rs:298-302` (unknown method →
  `MdvStatus::Internal`); `Sources/RustCore/CoreClient.swift:54-66` (Internal →
  `.internalError`).
- **Why:** `mdvcore_call` with an unknown method returns `Internal` (the `=99`
  catch-all; no `UnknownMethod` variant), mapped to `.internalError` —
  identical to a genuine core fault. The envelope dispatchers don't consult
  `CoreABI.capabilities` first, so the "host gates on capabilities first"
  contract is unenforced at this layer. In-process the `assertCompatible()` wire
  crash-fast masks it; it bites the remote-skew / forward-compat path.
- **Fix:** add an `UnknownMethod` status variant (or gate on capabilities before
  dispatch) so a method-space skew is distinguishable from a fault.

### M8 — Hand-rolled JSON number parser accepts malformed numbers JSONSerialization rejects (A/B parity gap) · NEW
- **Severity:** medium · **Dimension:** correctness
- **Location:** `rust-core/crates/core/src/json.rs:264-300` (`Parser::number`).
- **Why:** Rust's `number()` accepts `0123`→`123`, `1.`→`1.0`, `-.5`→`-0.5`,
  `01.5`→`1.5` (both digit loops permit zero digits; no leading-zero rule).
  `JSONSerialization` (the Swift twin `ClaudeLogParser` decoder, via `try?`)
  returns nil for each and **drops the whole JSONL record**. A transcript record
  with such a number is parsed by the Rust core but silently dropped by the Swift
  twin — a real A/B parity divergence (record present in one front-end, absent in
  the other), violating the documented Foundation-parity contract. (`1e` is
  already rejected by Rust's f64 parse — a poor teeth example — but the gap holds
  for `0123`/`1.`/`-.5`/`01.5`.)
- **Fix:** enforce the JSON number grammar (reject leading `0`+digit, require ≥1
  digit after `.` and after `e`/`E`); add `is_err()` teeth tests.

### M9 — O(N²) heading-slug dedup in the Rust markdown engine · NEW
- **Severity:** medium · **Dimension:** performance
- **Location:** `rust-core/crates/core/src/markdown.rs:447-473` (`unique_slug`);
  backing `used_slugs: Vec<(String,u32)>` at `:129`.
- **Why:** `used_slugs` is a `Vec` and `unique_slug` does
  `iter_mut().find(|(s,_)| *s == slug)` per heading — a linear scan with full
  String equality, O(N²) over N headings. The Swift original uses
  `[String:Int]` (O(1)). Latent correctness gap too: the suffixed
  `{slug}-{n}` is never inserted into `used_slugs`, so cross-base-slug collisions
  can produce duplicate ids.
- **Fix:** `HashMap<String,u32>`; insert the suffixed slug back.

### M10 — Claude monitor filteredSessions re-filters + re-sorts with per-session `lowercased()` allocs every keystroke · NEW
- **Severity:** medium · **Dimension:** performance
- **Location:** `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:110-126`
  (`filteredSessions`); consumed at `:418` (ForEach) + nav helpers.
- **Why:** a plain computed property that, on a non-empty needle, allocates
  `title?.lowercased()` + `cwd?.lowercased()` + `projectDirName.lowercased()` per
  session (3 fresh Strings each) then `.sorted` the whole list unconditionally
  (sort even on the empty-needle path). Read from ForEach + nav helpers → recomputes
  on every body eval and keystroke: O(N log N) + 3N allocs per char on the main
  thread. `sessions` is assigned once and could be pre-sorted/pre-folded.
- **Fix:** pre-sort + pre-fold (cache lowercased fields) at index time; skip the
  sort on the empty-needle path.

### M11 — Hex search runs a full-buffer scan synchronously on the main thread per keystroke (no debounce) · NEW
- **Severity:** medium · **Dimension:** performance
- **Location:** `Sources/ViewerUI/HexView.swift:110-111`
  (`.onChange(of: searchQuery/searchMode)`) → `:208-238` (`recomputeMatches`);
  `RustHexSearchAdapter.search(... in: file.data)` at `:233`.
- **Why:** `.onChange` invokes `recomputeMatches` synchronously; it scans the
  entire `file.data` with no debounce. The match *list* is capped, but the *scan*
  blocks the run loop per keystroke — a full multi-MB scan per char on large
  binaries, unlike the text find bar's ~150ms throttle.
- **Fix:** debounce + off-main scan over the immutable `Data` snapshot.

### M12 — Remote-core: unbounded orphan-event dictionary keyed by attacker-chosen sub id (OOM) · NEW
- **Severity:** medium · **Dimension:** blank-slate-1
- **Location:** `Sources/RustCore/RemoteTransport.swift:40, :282-296` (route event
  arm), cap at `:52`.
- **Why:** `orphanEvents` caps each per-sub list at `orphanBufferCap=256` but
  creates a new dict entry for *any* unseen `event.sub` with no cap on the number
  of distinct keys and no eviction of never-subscribed keys. A buggy/compromised
  `mdv-serve` streaming events with monotonically increasing sub ids grows the
  dict unboundedly (each retained body up to 16 MiB) until the client OOMs. The
  single-frame cap does not bound aggregate orphan footprint.
- **Fix:** bound the orphan store globally (cap distinct sub keys and/or total
  retained bytes), or only buffer events for sub ids pending subscription and
  discard genuinely-unknown subs immediately.

### M13 — RemoteTransport read/write treat EINTR as a fatal connection error · NEW
- **Severity:** medium · **Dimension:** error-handling
- **Location:** `Sources/RustCore/RemoteTransport.swift:442-454` (`readExact`),
  `:423-440` (`writeEnvelope`).
- **Why:** both throw `.io` on any `-1` with no `errno == EINTR` retry and no
  `EAGAIN`/`EWOULDBLOCK` guard. The reader routes that throw into
  `readerDidExit`, which sets `closedError` (terminal — every later `callInner`
  throws), drops all subs, and there's no reconnect in v1 — so a single stray
  signal permanently drops the tunnel and reverts the app to in-process engines
  mid-operation.
- **Fix:** retry on `EINTR`; handle `EAGAIN`/`EWOULDBLOCK` per the socket mode.

### M14 — StatusBarMemorySampler repeating Timer has no deinit backstop · NEW
- **Severity:** medium · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerUI/StatusBarMemory.swift:50-87` (class); lifecycle
  only `:118-119` onAppear/onDisappear.
- **Why:** the class has no `deinit`; the run-loop-retained 1.5s repeating Timer is
  invalidated only by `stop()`, wired solely to `StatusBarMemoryChip.onDisappear`.
  The `[weak self]` tick lets the sampler dealloc while the orphaned timer keeps
  firing on any missed `onDisappear`. LIVE code (always-visible chip).
- **Fix:** `deinit { timer?.invalidate() }`.

### M15 — GitPanelModel 60s Timer + in-flight Tasks rely solely on stop(); no deinit backstop · NEW
- **Severity:** medium · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerUI/Git/GitPanelModel.swift:151-167` (start/stop, no
  deinit); mounted via `GitPanelView.swift:36-37`.
- **Why:** no `deinit`; the 60s Timer is added to `RunLoop.main(.common)` and
  invalidated only in `stop()`, wired solely to `GitPanelView.onDisappear`. The
  `[weak self]` tick lets the model dealloc while the timer survives. Additionally
  `refreshTask`/`loadMoreTask`/`logSearchTask` are cancelled only in `stop()`, so
  a missed `onDisappear` can leave an in-flight detached git shell-out outliving
  the model. LIVE code.
- **Fix:** `deinit` mirroring `stop()` (invalidate timer + cancel tasks).

### M16 — SidebarModel.pruneChildrenCacheIfNeeded cannot enforce the cap when expanded dirs exceed it · NEW
- **Severity:** medium · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerUI/SidebarModel.swift:693-712`.
- **Why:** the prune loop `continue`s past (never evicts) `rootURL` or any
  `expanded.contains(key)` entry, with `target = 256*2/3 = 170`. `expanded` is a
  `Set<URL>` restored from session snapshots, so it can hold an unbounded number
  of dirs. When the cached expanded-dir count exceeds 170, `idx` runs to the end
  while `childrenCache.count` stays over cap — the cap is unenforceable for that
  working set (e.g. a deep restored monorepo session). LIVE code.
- **Fix:** make the target achievable or allow eviction of expanded-but-offscreen
  dirs; at minimum gauge/log the over-cap exit.

---

## NEW Low

### L-conc1 — PTYProcess.start() double-fork window; onOutput/onExit read unsynchronized · NEW
- **Severity:** low · **Dimension:** concurrency
- **Location:** `Sources/ViewerUI/Terminal/PTYProcess.swift:68-111` (start
  unlock-fork-relock), `:29-32`/`:170`/`:225` (callbacks).
- **Why:** `start()` checks the `childPID<=0` guard under lock, unlocks, runs the
  slow `forkpty`, then re-locks to assign `childPID`. Two concurrent `start()`
  calls passing the guard would fork two shells and leak a master fd/pid; the type
  is `public @unchecked Sendable` and only documents idempotency. `onOutput`/`onExit`
  are plain vars read on `readQueue` without lock. Low: the only in-tree caller is
  `@MainActor TerminalModel`, which serializes + guards with `!pty.isRunning`.
- **Fix:** hold the lock across guard+assign (or a `starting` flag); guard the
  callback reads or make them constructor `let`s.

### L-conc2 — AudioEditorViewModel.load() has no re-entrancy guard (duplicate decodes) · NEW
- **Severity:** low · **Dimension:** concurrency
- **Location:** `Sources/ViewerUI/AudioEditorViewModel.swift:94-114`; call site
  `AudioEditorView.swift:50` (`.task`).
- **Why:** `@MainActor` (no data race) but no guard against re-invocation while a
  prior `Task.detached` decode is in flight (view reappears → `.task` re-fires;
  detached decode ignores cancellation). Two full multi-MB decodes run
  concurrently; the later clobbers the earlier's published state. Wasteful, not
  incorrect.
- **Fix:** track the decode in a `Task?` and cancel/ignore a prior in-flight load.

### L-rt1 — Remote-transport call-id off-by-one (&+= before read; ids start at 2) · NEW
- **Severity:** low (cosmetic) · **Dimension:** blank-slate-2
- **Location:** `Sources/RustCore/RemoteTransport.swift:34,109`.
- **Why:** `nextId=1`; `callInner` does `nextId &+= 1` before reading, so the
  first call uses id 2 and id 1 is never used; `hello` uses id 0. No
  correctness/concurrency impact today.
- **Fix:** post-increment; document id 0 as reserved for `hello`.

### L-ffi1 — decodeWireError silently returns nil on a malformed rich-error frame · NEW
- **Severity:** low · **Dimension:** ffi-rust-boundary
- **Location:** `Sources/RustCore/CoreClient.swift:459-477` (`decodeWireError`),
  `:406-413` (`logWireErrorIfPresent`).
- **Why:** `decodeWireError` returns nil on any unframe/decode failure and
  `logWireErrorIfPresent` logs nothing on nil, so a non-empty-but-malformed
  WireError frame (the version-skew case) yields zero breadcrumb exactly when
  diagnosis matters most. Observability gap, not a correctness bug.
- **Fix:** emit a debug breadcrumb on decode failure of a non-empty error buf,
  keeping the no-throw contract.

### L-perf1 — Rust fuzzy matcher reallocates Vec<char> for query and target per candidate · NEW
- **Severity:** low · **Dimension:** performance
- **Location:** `rust-core/crates/core/src/fuzzy.rs:55-56`.
- **Why:** `match_query` collects both query and target into fresh `Vec<char>`
  per call; the batch rank calls it once per candidate, rebuilding the constant
  query Vec N times per keystroke. Low: the filename/command corpus is bounded.
- **Fix:** a batch entry point that collects the query `Vec<char>` once and
  iterates `target.char_indices()` directly.

### L-sec1 — Exported HTML inlines arbitrary local files via unfenced image src (path traversal) · NEW
- **Severity:** low · **Dimension:** security
- **Location:** `Sources/ViewerUI/DocumentModel.swift:5088-5093` +
  `Sources/ViewerCore/HtmlExport.swift:56-93`.
- **Why:** the export resolves each `<img src>` via
  `baseDir.appendingPathComponent(decoded).standardizedFileURL` (which collapses
  `..`) and reads it with `Data(contentsOf:)` with **no containment check**, then
  base64-embeds it. `![](../../../../etc/passwd)` (or any readable file with an
  image extension) inlines into the export. The in-app `.html` path fences with
  `HTMLDocumentPolicy.isWithinDocumentTree`; the export inlining path does not.
  Low (user exports own doc to chosen dest) but the asymmetry is genuine.
- **Fix:** require each image URL to be contained in the document subtree
  (reuse `isWithinDocumentTree`); skip/leave-relative any that escape.

### L-sec2 — LSP binary resolution applies the writable-dir safety check inconsistently and only one level deep · NEW
- **Severity:** low · **Dimension:** security
- **Location:** `Sources/ViewerCore/LSP/LSPDiscovery.swift:65-101`
  (`resolveBinary`), `:122-136` (`isBinarySafeToSpawn`), `:19-38`
  (`locateSourceKitLSP`).
- **Why:** `isBinarySafeToSpawn` is applied to augmented-prefix candidates + the
  `which` result, but **not** to either `locateSourceKitLSP` path (`xcrun -f` /
  `/usr/bin/sourcekit-lsp`). It also inspects only the immediate parent dir, not
  ancestors, so the 0777-ancestor/0755-leaf rename-swap isn't caught. Exposure
  small (xcrun resolves into SIP/root-owned Xcode; minimal GUI PATH).
- **Fix:** apply the check to every resolved path (incl. xcrun) and widen it to
  walk ancestors up to a trusted root.

### L-sec3 — ffmpeg locator honors $PATH without the writable-dir check; output path not -- separated · NEW
- **Severity:** low · **Dimension:** security
- **Location:** `Sources/ViewerCore/Audio/FFmpegLocator.swift:35-46` +
  `Sources/ViewerCore/Audio/AudioExporter.swift:156-185`.
- **Why:** `FFmpegLocator.resolve` walks `$PATH` and returns the first executable
  `ffmpeg` with no ownership check. `runFFmpeg` correctly uses an args array +
  4-var env allowlist, but `url.path` is positional with no `--` sentinel, so a
  path beginning with `-` parses as a flag. Exposure small (infrequent explicit
  MP3 export, output from `NSSavePanel`).
- **Fix:** run discovered candidates through the LSP ownership check; insert `--`
  before `url.path`.

### L-bs1 — Markdown safe_url bypassable by intra-scheme whitespace WebKit strips (javascript: smuggling) · NEW
- **Severity:** low (defense-in-depth only) · **Dimension:** blank-slate-1
- **Location:** `rust-core/crates/core/src/markdown.rs:505` (`safe_url`), reached
  from `:332`/`:344`; WebView `allowsContentJavaScript=true` at
  `Sources/ViewerUI/MarkdownRenderedView.swift:120`.
- **Why:** `safe_url` uses `trim()` (edge-whitespace only, not internal
  tab/LF/CR), so `java\tscript:` fails `is_scheme` and the URL returns verbatim
  as a relative path; `escape()` doesn't strip the control char. WebKit strips
  tab/LF/CR before scheme resolution, reviving it as `javascript:` in the DOM.
  Defense-in-depth only: the nav delegate cancels `javascript:`/`vbscript:` for
  both `.linkActivated` and `.other` after WebKit re-normalises, plus a
  no-script-src CSP — so no confirmed XSS.
- **Fix:** strip ASCII tab/LF/CR (and ideally C0 controls) from raw before scheme
  extraction, per WHATWG URL parsing.

### L-bs2 — Archive entry names passed as positional unzip/tar args without a `--` terminator · NEW
- **Severity:** low · **Dimension:** blank-slate-1
- **Location:** `Sources/ViewerCore/Archive/ArchiveCatalog.swift:109`
  (`unzip -p <archive> <name>`), `:111` (`tar -x.. -O -f <archive> <name>`).
- **Why:** `extractEntry` passes `name` (parsed from the archive's own listing,
  attacker-controlled) as a trailing positional arg with no `--` separator;
  `run` uses an args array (no shell) and there's no leading-dash rejection. A
  member name beginning with `-`/`--` can be re-interpreted as an option. Blast
  radius limited (no write path, output to app temp).
- **Fix:** insert `--` before the entry name in both invocations (verify bsdtar
  accepts `--` in the member position; else reject names beginning with `-`).

### L-bs3 — Terminal eraseLineFromCursor traps on inverted Range in a 1-column screen after a wide glyph · NEW
- **Severity:** low · **Dimension:** blank-slate-1
- **Location:** `Sources/ViewerCore/Terminal/TerminalScreen.swift:289`
  (`for c in cursor.col..<cols`), wide-char advance at `:246-258`.
- **Why:** `cols==1` is constructible. After writing a width-2 glyph at col 0 →
  wrap sets col=0 + lineFeed (no col reset) → `cursor.col += 2 = 2`; then
  `eraseLineFromCursor` runs `for c in 2..<1`, a `lowerBound>upperBound` Range
  that fatally traps. Only the row is guarded, not the column (unlike
  `eraseLineToCursor`/`eraseChars`/`deleteChars`); `eraseScreenFromCursor`
  inherits it. Low: needs a 1-column terminal the UI doesn't normally produce.
- **Fix:** clamp the column (`for c in min(cursor.col, cols)..<cols`) and
  normalise `cursor.col` into `0...cols` after a degenerate-width write.

### L-bs4 — git cumulativeDiff/commitDiff bypass the isSafeRevision option-injection guard · NEW
- **Severity:** low · **Dimension:** blank-slate-1
- **Location:** `Sources/ViewerCore/Git/GitClient.swift:221-223`
  (`cumulativeDiff`), `:1030-1037` (`commitDiff`); guard helper `:1151`.
- **Why:** both feed refs into `git diff`/`git show` with no `isSafeRevision` and
  no `--`, unlike `diff(from:to:path:)` which gates both refs. `--output=<file>`
  is a real `git show`/`diff` write primitive the protective `-c` flags don't
  cover. No live exploit (refs are 40-hex SHAs / ranges from parsed `git log`),
  so latent.
- **Fix:** gate both methods through `isSafeRevision` (return `""` on failure);
  add a `--` terminator after the revisions where the subcommand accepts one.
  (`fileDiff:1020` is similarly unguarded — worth folding in.)

### L-mem1 — HexEditBuffer.undoStack is unbounded · NEW
- **Severity:** low · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerCore/HexEditBuffer.swift:53`, `:123-133`.
- **Why:** appended on every value-changing `apply`, cleared only by
  `markSaved`/`revert`; each `Edit` is `Int+UInt8+UInt8` so growth is slow but
  genuinely unbounded across a long edit session. `BookmarksStore.removalUndoStack`
  IS capped (`maxUndoDepth=20`, drop-oldest), so the pattern exists. LIVE code.
- **Fix:** cap with `maxUndoDepth` + drop-oldest.

### L-mem2 — RingBufferSink metric registry (counters/gauges) is unbounded by tag cardinality · NEW
- **Severity:** low (latent) · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerCore/Observability/RingBufferSink.swift:69-70,
  :118-130`; cleared only by `reset()` `:200-208`.
- **Why:** `counters`/`gauges` are unbounded dicts keyed by `MetricKey(name,tags)`
  with arbitrary `[String:String]` tags accepted at the emit boundary; only
  `reset()` (a test/UI affordance) purges. The only two call sites are static
  no-tag names (`TrackedReposChannel.swift:212,217`), so the explosion isn't
  currently reachable — an API-contract / false-"bounded by construction" hazard.
- **Fix:** cap distinct series (drop/aggregate + a dropped counter) or reject
  high-cardinality tags at emit; document + assert the contract.

### L-mem3 — ChainedMonitor.deinit may call NSEvent.removeMonitor off the main thread · NEW
- **Severity:** low (narrow) · **Dimension:** memory-and-resources
- **Location:** `Sources/ViewerUI/LSP/LSPHoverAttachment.swift:421-430`.
- **Why:** `ChainedMonitor` is a plain `private final class` (not `@MainActor`),
  so its `deinit` is nonisolated and calls `NSEvent.removeMonitor` (main-thread
  AppKit) directly. The `LSPHoverToken.deinit` keepalive narrows the common path
  to main, but fails in the dropped/never-run-Task case (shutdown / saturated
  main actor), dragging `removeMonitor` off-main. Same dead/PoC caveat as the
  hover leak below (no live caller of `bind`).
- **Fix:** make monitor teardown `@MainActor`-isolated.

> **Note on the LSP-hover NSPopover leak (memory dimension, self-rated *high*):**
> CONFIRMED in the code as written (both observer blocks strong-capture `state`;
> cleanup deferred to an unstructured `Task` in `deinit`) **but
> `LSPHoverAttachment.bind` has no live callers in `Sources/` or `Tests/`** — it
> is opt-in PoC code, so the leak is not reachable in the shipping app. Filed
> here at **low** (latent / dead-code) rather than the reviewer's high: fix
> before wiring the feature up — weak-capture `state` in both blocks + an explicit
> `@MainActor invalidate()` called from teardown — but it carries no current
> user-facing exposure. (`L-mem3` above is the same file's sibling hazard.)

### L-eh1 — Image-editor "Save a Copy…" swallows every write error (silent data loss) · NEW
- **Severity:** low (high user impact, narrow trigger) · **Dimension:** error-handling
- **Location:** `Sources/ViewerUI/ImageEditorView.swift:149`.
- **Why:** `try? vm.export(format:to:)` — every export failure (disk full, dir
  not writable, encoder/HEIC failure) is discarded with zero feedback after the
  user clicks Save. The sibling `AudioEditorView.saveCopy()` (`:282-290`) uses
  do/catch + NSAlert, so this is a deviation from convention.
- **Fix:** do/catch + NSAlert mirroring the audio sibling.

### L-eh2 — Several silent-failure error sinks across git-log open, Open-in-Browser, save-copy, SQLite, decode · NEW (cluster)
- **Severity:** low (cluster of 7 confirmed sinks) · **Dimension:** error-handling
- **Locations / why (each independently CONFIRMED):**
  - `DocumentModel.swift:2241-2242` — git-log markdown tab opens even when the
    `try?` file write failed; content-hash filename re-opens a STALE prior
    git-log for the path with no signal (silent staleness). `createDirectory`
    also `try?`.
  - `main.swift:2540` (producer `DocumentModel.swift:5107-5114`) — "Open in
    Browser" collapses "no markdown active" and "temp HTML write failed" into the
    same silent no-op; the sibling `exportAsHTML` correctly alerts.
  - `GitClient.swift:1287` (stderr twin `:1296`) — git output decode failure
    collapses to `""`, so a single non-UTF-8 byte nukes file-history/status/stash
    to empty, indistinguishable from genuinely empty. Fix: lossy
    `String(decoding:as:UTF8.self)`.
  - `SQLiteBrowserView.swift:225-228` — post-open schema-listing failures are
    `(try? …) ?? []`; a DB that opens but can't enumerate its schema shows as
    successfully-opened-but-empty.
  - `DocumentModel.swift:3284-3288` — "Save a Copy" silently re-encodes to UTF-8
    when the buffer encoding can't represent the text (the `SaveCopyError`
    throw is dead); diverges from the editor-save path which throws.
- **Fix:** surface each via the established do/catch + NSAlert pattern, and use
  lossy decode where a single bad byte shouldn't nuke the payload.

### L-eh3 — Remote-core attach can install a connection that died during the init→register window · NEW
- **Severity:** low · **Dimension:** error-handling
- **Location:** `Sources/ViewerCore/RemoteCoreAttach.swift:40-52` with
  `RemoteTransport.swift:76-81,302-323`.
- **Why:** `RemoteTransport.init` starts the reader before returning;
  `RemoteCoreAttach` assigns `onClose` afterwards then installs into the registry.
  `readerDidExit` captures `onClose` once and is one-shot, so a server death in
  that window fires nothing (auto-revert skipped) and line 52 installs an
  already-dead transport (every adapter call throws), with `onClose` never
  re-firing. Narrow race, sticky failure.
- **Fix:** check `closedError` before install (and after assigning `onClose`);
  bail to in-process if already closed.

### L-data1 — Data-integrity cluster: hot-exit clobber, no-fsync writes, >1MiB edit drop, and 4 lower-impact persistence gaps · NEW (cluster)
- **Severity:** mixed (two high-rated by the dimension, folded here as one
  persistence cluster) · **Dimension:** data-integrity-persistence
- **The two most serious (dimension-rated high):**
  - **Hot-exit restore re-seeds the dirty baseline from the current disk file
    with no external-change guard — silent clobber of edits made while the app
    was closed.** `DocumentModel.swift:2002-2013` overlays persisted `unsavedText`
    onto a baseline re-read fresh from disk; `TabSnapshot`
    (`SessionSnapshot.swift:47-56`) stores no `(mtime,size)`/hash. The conflict
    prompt fires only on a live file-watcher tick (`:5258`), never inside
    `saveEditor` (`EditorCoordinator.swift:498-499`), so a change made while the
    app was dead produces no tick; a post-relaunch save overwrites the
    externally-changed file with no prompt. **Fix:** persist `(mtime,size)`+hash
    in `TabSnapshot`; stat on restore and run the conflict prompt on mismatch.
  - **JSONFileStore / EditorWriter atomic writes carry no fsync barrier** —
    power-loss/crash can truncate session, bookmark, history files.
    `JSONFileStore.swift:84-91` (`Data.write(.atomic)`),
    `EditorBuffer.swift:338,358` (temp write + rename),
    `LocalHistoryStore.swift:95,101`. No `fsync`/`F_FULLFSYNC` anywhere in
    ViewerCore (the one `JSONFileStore.swift:96` hit is a comment wrongly
    claiming fsync happens); docstrings claim crash-safety that isn't there.
    Atomic rename ≠ durable; for `Sessions/index.json` this is a route to an
    empty session strip after a hard power-off. **Fix:** temp-write → `fsync(temp
    fd)` → rename → `fsync(dir fd)`. (APFS COW makes a zero-length outcome less
    likely than the classic ext4 case, but durability still isn't guaranteed.)
- **The five lower-impact members (all CONFIRMED):**
  - Hot-exit silently discards in-flight edits >1 MiB
    (`DocumentModel.swift:1962-1966,1984-1987`; editor cap is 32 MiB so a 1–32 MiB
    dirty buffer is reachable) — a large paste + quit loses every unsaved byte.
  - `LocalHistoryStore` keys revision dirs on a 64-bit FNV-1a hash with no
    collision check and never reads back `_path` (`:172-179,99-102,133-137`) —
    two paths colliding interleave/overwrite each other's history (practical
    reachability low; missing integrity check real).
  - `SessionIndex` requires a non-optional `version`; a legacy/hand-edited index
    missing it is classified corrupt, discarding `lastActiveID` + ordering
    (`SessionSnapshot.swift:232`, `SessionStore.swift:140-168`,
    `SessionsCoordinator.swift:105-112,187-205`). **Fix:** decode-optional
    defaulting to 1, keep the downgrade guard.
  - SessionStore + JSONFileStore flush two independent write queues with no
    cross-queue ordering; `persist()` enqueues `index.json` before the per-session
    snapshots, so a crash in the no-fsync window can leave the index a generation
    ahead of an interrupted snapshot.
  - `BookmarkEntry` decode substitutes `Date()` for an unparseable `addedAt`
    (`BookmarksStore.swift:263`), corrupting `addedAt`-sorted ordering in the
    bookmarks sidebar (`BookmarksSection.swift:157,164,247`). **Fix:** fall back
    to `Date.distantPast`, or carry a `dateUncertain` flag the UI won't trust.

### L-test1 — Windowed CSV snapshot (snapshot_window_frame) has no Rust unit test for its clamping edges · NEW
- **Severity:** low · **Dimension:** testing-gaps
- **Location:** `rust-core/crates/core/src/session.rs:227`
  (`snapshot_window_frame`); `session.rs mod tests` (`:342`) has none touching
  it.
- **Why:** the clamp math (`offset.min(len)`,
  `start.saturating_add(limit).min(len)`, `.get(start..end).unwrap_or(&[])`) is
  exercised only through the FFI (offset 0/50/95/200, limit 10/100_000/3). The
  three canonical edges — `limit==0`, `offset==len` exactly, and `offset+limit`
  saturating overflow — are untested at any layer.
- **Fix:** add Rust `#[test]`s for those edges asserting empty/tail (not panic),
  host-runnable in `rust-core-gate`.

### L-test2 — ClaudeLogParser.parseTimestamp does not guard non-finite Doubles and is untested for it · NEW
- **Severity:** medium per dimension; folded low here (silent, hostile-input only)
  · **Dimension:** testing-gaps
- **Location:** `Sources/ViewerCore/ClaudeLogParser.swift:271-280`.
- **Why:** `JSONSerialization` parses `{"ts":-1e400}` → `Double(-inf)`;
  `parseTimestamp` (no `isFinite` guard) returns `Date(timeIntervalSince1970:
  -inf)` (empty description, `-inf` interval) which flows into `>=`/`<`
  comparisons (duration pairing `ClaudeMonitorLog.swift:239`, event ordering) — a
  silent correctness bug for hostile/corrupt transcripts (an explicitly untrusted
  format). No test feeds the private `parseTimestamp` a non-finite/absurd value.
- **Fix:** guard with `n.isFinite` (optionally clamp to a sane epoch range); add
  infinity/nan/out-of-range tests asserting nil.

### L-api1 — tree-sitter-swift pinned to a bare git revision with no upstream tag/version · NEW
- **Severity:** low · **Dimension:** api-design-and-deps
- **Location:** `Package.swift:77` (`revision: 7b7909f…`); `Package.resolved`
  tree-sitter-swift entry has no `version` field.
- **Why:** a bare SHA can't be matched against semver-keyed advisory ranges
  (the lone grammar without semver — json 0.24.8, rust 0.24.2 for contrast), so
  there's no released version to cross-reference, no semver advisory match, and a
  manual unguarded `parser.c` re-diff on update. Not currently exploitable.
- **Fix:** pin to a released tag/version once upstream publishes one, or document
  the manual-review requirement on bump.

### L-api2 — Dead-but-exported FFI surface: per-method symbols + the entire CSV-session filter/snapshot/window family · NEW (cluster)
- **Severity:** low · **Dimension:** api-design-and-deps
- **Locations:** per-method symbols `rust-core/crates/ffi/src/lib.rs:376,397,422,
  451,505,570` (replacement table `Sources/RustCore/CoreTransport.swift:60` is
  `[:]`); CSV-session family `lib.rs:720,771,821,868` +
  `CoreClient.swift:270-318` (sole consumer `RustCSVAdapter.swift:55-57` calls
  only `CsvSession(bytes:)` + `.table()`).
- **Why:** all six per-method symbols carry `#[unsafe(no_mangle)]` but every
  stateless method routes via the envelope (`mdvcore_call`); their only callers
  are Rust unit tests. The CSV filter/snapshot/window subset (`setFilter`,
  `snapshot`, `snapshotWindow`, `filteredCount`) is referenced only by its own
  definitions + tests — `CSVTableView` filters in-memory via Swift `CSVFilter`.
  Dead-but-exported on the committed C ABI (a maintenance/ABI-surface liability;
  also note M6 above — `snapshotWindow` *is* reachable enough to have a real
  observability bug, so confirm reachability before deleting that one).
- **Fix:** drop the per-method `no_mangle` exports post-envelope-soak (tracked
  separately as TSK-820 for the symbol cleanup); gate/remove the unreachable CSV
  family or wire `CSVTableView` to it (TSK-668 is the wiring follow-up).

---

## Appendix — dedup & status ledger

| # | Title (short) | Sev | Dimensions merged | Status |
|---|---------------|-----|-------------------|--------|
| C1 | MessagePack unbounded recursion → SIGSEGV | crit | testing-gaps + blank-slate-2 | NEW |
| H1 | Stored XSS in CSP-free HTML export (sanitizer bypass) | high | security ×2 + testing-gaps | NEW |
| H2 | sqlite3_bind_text use-after-free | high | blank-slate-2 | NEW |
| H3 | Git-chip stale async clobber | high | concurrency | NEW |
| H4 | RepoStatsCache actor blocks on git walk | high | concurrency | NEW |
| H5 | StatusBar per-keystroke buffer re-encode | high | performance | NEW |
| H6 | canShowFileHistory spawns git on main thread | high | performance | NEW |
| H7 | Rust search.files recompiles regex + no skip-list | high | performance | NEW |
| H8 | Grammar deps caret-ranged (pin-policy violation) | high | api-design-and-deps | NEW |
| H9 | cargo-audit/deny never gate a PR | high | api-design-and-deps | NEW |
| M1 | RemoteTransport handler fires after unsubscribe | med | concurrency | NEW |
| M2 | MCPServer no-deadline semaphore park | med | concurrency | NEW |
| M3 | Int(UInt64) trap on remote highlight offset | med | blank-slate-2 | NEW |
| M4 | PTY non-async-signal-safe fork→exec | med | blank-slate-2 | NEW |
| M5 | LSP override args/env reach trusted server | med | security | NEW |
| M6 | snapshotWindow drops WireError out-buf | med | ffi-rust-boundary | NEW (gap in TSK-669) |
| M7 | Skewed method-id → Internal indistinguishable | med | ffi-rust-boundary | NEW |
| M8 | JSON number parser A/B parity gap | med | correctness | NEW |
| M9 | O(N²) heading-slug dedup (Rust md) | med | performance | NEW |
| M10 | Claude monitor filteredSessions per-keystroke allocs | med | performance | NEW |
| M11 | Hex search synchronous full scan per keystroke | med | performance | NEW |
| M12 | Unbounded orphan-event dict (remote) | med | blank-slate-1 | NEW |
| M13 | RemoteTransport EINTR fatal | med | error-handling | NEW |
| M14 | StatusBarMemorySampler no deinit | med | memory-and-resources | NEW |
| M15 | GitPanelModel no deinit (timer + tasks) | med | memory-and-resources | NEW |
| M16 | SidebarModel prune can't enforce cap | med | memory-and-resources | NEW |
| L-conc1 | PTYProcess.start double-fork window | low | concurrency | NEW |
| L-conc2 | AudioEditorViewModel.load re-entrancy | low | concurrency | NEW |
| L-rt1 | Remote call-id off-by-one (cosmetic) | low | blank-slate-2 | NEW |
| L-ffi1 | decodeWireError silent nil on malformed | low | ffi-rust-boundary | NEW |
| L-perf1 | Rust fuzzy Vec<char> realloc per candidate | low | performance | NEW |
| L-sec1 | Export inlines local files (path traversal) | low | security | NEW |
| L-sec2 | LSP binary check inconsistent + 1-level | low | security | NEW |
| L-sec3 | ffmpeg locator no ownership check + no `--` | low | security | NEW |
| L-bs1 | Markdown safe_url intra-scheme whitespace | low | blank-slate-1 | NEW |
| L-bs2 | Archive entry name no `--` terminator | low | blank-slate-1 | NEW |
| L-bs3 | Terminal eraseLineFromCursor 1-col trap | low | blank-slate-1 | NEW |
| L-bs4 | git cumulativeDiff/commitDiff option-injection | low | blank-slate-1 | NEW |
| L-mem1 | HexEditBuffer.undoStack unbounded | low | memory-and-resources | NEW |
| L-mem2 | RingBufferSink unbounded tag cardinality | low | memory-and-resources | NEW |
| L-mem3 | ChainedMonitor.deinit off-main removeMonitor | low | memory-and-resources | NEW |
| (note) | LSP-hover NSPopover leak (dead/PoC bind) | low* | memory-and-resources | NEW (dead code) |
| L-eh1 | Image-editor Save-a-Copy swallows write error | low | error-handling | NEW |
| L-eh2 | 5 silent error sinks (git-log/browser/decode/sqlite/save) | low | error-handling | NEW (cluster) |
| L-eh3 | Remote attach installs dead connection (race) | low | error-handling | NEW |
| L-data1 | Persistence cluster (hot-exit clobber, no-fsync, +5) | high→low | data-integrity-persistence | NEW (cluster) |
| L-test1 | snapshot_window_frame untested edges | low | testing-gaps | NEW |
| L-test2 | parseTimestamp non-finite unguarded/untested | low | testing-gaps | NEW |
| L-api1 | tree-sitter-swift bare-SHA pin | low | api-design-and-deps | NEW |
| L-api2 | Dead-but-exported FFI surface (cluster) | low | api-design-and-deps | NEW (cluster) |

\* The LSP-hover leak self-rated *high* by the memory dimension; reclassified low
here because `LSPHoverAttachment.bind` has **no live caller** (dead/PoC code) — fix
before the feature ships, but no current exposure.
