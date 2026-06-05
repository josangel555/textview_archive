# Codebase Audit Report — TextView / MarkdownViewer

**Depth:** deep · **Coverage:** 74 subsystem × dimension cells, depth = deep · **Scope:** read-only (no code was changed)

> This was a **read-only audit**: every finding below was verified by reading and, where noted, by running the actual code or a faithful standalone reproduction — but **no source was modified**. The machine-readable, deduped list of all 80 verified findings (with `file:line`, evidence, and suggested fixes) lives in `AUDIT_BUGS.md` alongside this report. This document is the human-facing narrative: severity rollup, the most serious findings explained, theme groupings, a coverage map, and recommended next actions.

---

## 1. Executive summary

**80 verified findings** across security, performance, resource lifecycle, correctness, A/B parity, observability, and test honesty. Every finding in this report was adversarially verified — false positives were filtered out before inclusion.

### Counts by severity

| Severity | Count | What it means here |
|---|---:|---|
| **S1** | 1 | Remotely-triggerable, catastrophic — arbitrary file exfiltration from a browser the user already has open |
| **S2** | 16 | Crash on adversarial/ordinary input, main-thread freeze, security defense that is structurally dead, or a CI gate with a hole over the highest-risk code |
| **S3** | 45 | Real boundary/containment defects, resource leaks, races, parity drift, silent-failure surfaces, and load-bearing test gaps |
| **S4** | 18 | Lower-blast-radius bugs, doc/config drift, dev-tool footguns, and defense-in-depth degradations |
| **Total** | **80** | |

### Severity distribution

```
S1  █                                                          1
S2  ████████████████                                          16
S3  █████████████████████████████████████████████            45
S4  ██████████████████                                        18
```

### Top themes (where the risk concentrates)

1. **Filesystem containment is the dominant security theme (7 findings, incl. the only S1).** Three independent containment fences — the `mdv-web` loopback server, `URLSchemePolicy` (`markdownviewer://`), and `MCPToolCatalog` (MCP `open_path`) — each have a real bypass. The web server has *no* path containment at all and *no* Host/Origin check, so DNS-rebinding turns it into remote arbitrary-file read (S1). The Swift fences share two repeated defects: an **unanchored temp-dir prefix** (sibling-directory escape) and **no symlink resolution** (in-home symlink reaches outside the fence). The same flaw appearing in three places points at a missing shared `isContained(_:in:)` helper.

2. **ReDoS defenses that don't actually bound match time (5 findings, 2× S2).** The headline two-layer defense — a static shape guard plus a 250 ms wall-clock cap — fails on both layers: the cap is **structurally dead code** (the stop-check only runs *per emitted match*, but catastrophic backtracking burns CPU *while failing to match*, so the closure never fires), and the shape guard misses the common non-capturing / named-group / multiplicative-quantifier forms. The highest-risk channel (the MCP `find` tool, which accepts `regex:true` from automation) is the *one* path that skips the bounded matcher entirely.

3. **Process / subprocess lifecycle leaks (5 findings, incl. a dead-feature S2).** `PTYProcess` never resets `childPID`, so **terminal restart silently no-ops** (the "Restart shell" button and the `[process exited]` recovery view are dead) and `terminate()` reaps with `WNOHANG` *immediately* after `SIGHUP`, leaking a zombie per teardown/restart/quit. The LSP teardown story has parallel issues: a fixed 2 s app-quit budget that ≥2 servers can't meet, and 21 test sites that reap child processes on a detached, never-awaited `Task`.

4. **Redundant full-dataset clones on the Rust core hot path (4 findings, 2× S2).** The CSV FFI `session_table` clones the entire parsed table purely to hand `encode_frame` a `&` it never consumes (a no-op clone of a multi-MB dataset on the open path), and `CsvSession.snapshot()` keeps a resident second copy of the filtered rowset and clones a third on every pull. The default (unfiltered) view permanently retains a verbatim duplicate of `table.rows`.

5. **O(n²) hot-path work freezing the MainActor (several findings, multiple S2).** `CSVParser.appendToField` rescans `field.unicodeScalars.count` per appended scalar (~2400× slower than the Rust port that fixed it; measured 2.35 s for a 60 K cell), and `HexView` repaints **all** matches (up to 50 K) on every arrow-step through search results. Both run synchronously on the MainActor.

6. **A/B parity drift between the Swift and Rust implementations (several findings).** The Rust ports are pinned by differential tests advertised as "byte-for-byte," but `diff::parse_coord`, `diff::parse_diff_git_paths`, and the CSV/View truncation flag diverge from Swift on adversarial input — and the parity test corpora (notably IndentDetect) have **zero CRLF / empty-coordinate cases**, so the gate is dishonest about the divergent class.

7. **Untrusted-input crash safety on the wire/JSON boundaries (several findings).** `MCP.Value.int` traps on out-of-`Int64` JSON numbers (a single malformed `tools/call` aborts the whole host), and the Swift MessagePack reader `reserveCapacity`s straight from an untrusted count field (a 9-byte body drives a ~34 GB allocation → OOM-abort) with no `MAX_FRAME_LEN` counterpart to the Rust side.

8. **Test honesty / coverage gaps that manufacture false confidence (10+ findings).** The catastrophic-regex test only exercises the *one* shape the guard catches (so green ≠ safe); the Swift wire decoder (the stated protocol-skew attack surface) has zero negative-path coverage; the `.handleDead` panic-recovery contract is untested; the editable-HEX save/dirty/close data-loss path has zero tests; and several VM/CI lanes report green over skipped, crashed, or never-run suites.

9. **Adversarial-input crashes that bypass the guards meant to stop them (several S2).** `~6000` nested blockquotes (~12 KB) **SIGSEGV** the app because PARSE-03's depth cap sits *downstream* of cmark's own native-C recursive parse; `IndentDetector` mis-parses **every** CRLF file (Swift's `Character` view collapses `\r\n`); `EditorWriter` silently downgrades a `0600` secret to world-readable when the original file is write-but-not-readable (EACCES).

The standout structural pattern across themes 1–3 and 6: **the right pattern already exists in the codebase**, just not applied uniformly. `HTMLDocumentPolicy` resolves symlinks correctly; the highlight path has a per-language compile lock; `LSPClient.shutdown()` reaps with a bounded escalation; `LSPClientFakeServerTests` awaits teardown synchronously. The defects are the *siblings* that diverged from the established correct pattern — which makes most of them low-risk, high-confidence fixes.

---

## 2. The most serious findings (S1 / S2), explained

Each entry: **what / where**, **why it matters**, **suggested fix**.

### S1 — `mdv-web` DNS-rebinding → remote arbitrary-file exfiltration
- **Where:** `rust-core/crates/web/src/main.rs:66` (and the companion S2 at `:96`).
- **What:** `handle_conn` drains and **discards every request header** — the `Host` header is never inspected — and `route()` parses the HTTP method into `_method` and discards it (GET/POST/PUT treated identically). There is no Host allowlist, no `Origin`/`Sec-Fetch` check, no CSRF token. Binding `127.0.0.1` stops *other hosts* but not a browser the user already has open.
- **Why it matters:** A malicious web page can DNS-rebind an attacker-controlled hostname to `127.0.0.1` and issue cross-origin requests to `http://127.0.0.1:8765/view?path=/Users/<user>/.ssh/id_rsa`. The rebind makes the response *same-origin to the attacker*, so the file bytes become fully readable to attacker JS. Combined with the companion finding (`/view` and `/browse` serve **any** absolute path — `root` confinement is purely cosmetic), this is full exfiltration of any file the running user can read for as long as the dev server is up. The module doc's "localhost-only, single user, no auth" framing defends the wrong threat model.
- **Fix:** Read (don't discard) headers and reject any request whose `Host` is not exactly `127.0.0.1:<port>` / `localhost:<port>` (421/403); reject non-GET methods (405); add an unguessable per-session token printed at startup and required on `/browse` and `/view`. And land the companion fix below so a rebind has nothing to steal.

### S2 — `mdv-web` `/view` and `/browse` serve ANY absolute path (`root` confinement is cosmetic)
- **Where:** `rust-core/crates/web/src/main.rs:96`.
- **What:** `root` is canonicalized once at startup and shown in the banner, but it's used *only* as the default landing dir. The moment a request supplies `?path=`, that value goes straight to `read_entries`/`read_capped` (`fs::read_dir` / `fs::File::open`) with **no canonicalize and no `starts_with(root)` check**. `/view?path=/etc/passwd` returns the bytes; `/browse?path=/` lists the whole disk; `../` traversal works (`pct_decode` decodes `%2e%2e%2f`).
- **Why it matters:** This is the load-bearing precondition that makes the S1 rebinding catastrophic rather than annoying. It's the web-tier analog of the `markdownviewer://` CRIT-1 boundary.
- **Fix:** After decoding `?path`, canonicalize it (resolving symlinks to close the symlink-escape variant) and 404 anything whose canonical form is not `starts_with` the canonicalized root. Apply to **both** routes via a single `validated_under_root(root, candidate)` chokepoint.

### S2 — `URLSchemePolicy` temp-dir containment uses an unanchored prefix (sibling-directory bypass)
- **Where:** `Sources/ViewerCore/Security/URLSchemePolicy.swift:55`.
- **What:** `containedPath()` is the fence every `markdownviewer://` path funnels through (reachable from any local process or any web page via `<a href>`). The HOME arm is correctly anchored with `home + "/"`, but the temp arm degrades to a bare `p.hasPrefix(temp)`. The inline comment claims `temp` already ends in `/` — that premise is **false**: `temporaryDirectory.standardizedFileURL.path` returns `/var/folders/<rand>/T` with **no trailing slash**. So `hasPrefix(temp)` matches any *sibling* whose name begins with `T`, e.g. `/var/folders/<rand>/T-attacker/loot.txt`. That parent dir is user-writable.
- **Why it matters:** Re-opens the exact CRIT-1 filesystem boundary the policy exists to close. A local process can `mkdir` a `T`-prefixed sibling and have the URL scheme open files outside the intended `HOME ∪ TMPDIR` boundary. No test covers the temp-sibling case, and the misleading comment will lead the next maintainer to believe it's safe.
- **Fix:** Drop the bare `|| p.hasPrefix(temp)` arm — `p == temp || p.hasPrefix(temp + "/")` is already exhaustive. Fix/delete the false comment. Factor a single `isContained(_:in:)` shared with `MCPToolCatalog` so the boundaries can't drift. Add `test_tempSiblingDirectoryPrefix_rejected`.

### S2 — `CSVParser.appendToField` is O(n²) per cell (~2400× slower than the Rust fix)
- **Where:** `Sources/ViewerCore/CSVParser.swift:182`.
- **What:** `appendToField` checks `field.unicodeScalars.count >= limits.maxCellChars` on **every** appended scalar. `UnicodeScalarView` is not random-access and caches no length, so `.count` walks the whole buffer each call — building a field of N scalars is O(N²). The PARSE-04 per-cell cap (64 K) makes it exploitable: the cap check *is* the O(N) op, run on the way up to the cap, so a 64 K field pays ~64 K²/2 ≈ 2.1e9 scalar walks.
- **Why it matters:** This is the **default live path** (`RustCSVGate` defaults OFF; `CSVParser.parse` is the fallback even when Rust is enabled), reached by ordinary input (one long unquoted cell, embedded base64/JSON) and by the PARSE-04 degenerate "one giant field" shape. It runs synchronously on the MainActor via `CSVTableView.reparse`, freezing the UI. **Measured 2.35 s for a 60 K-char field** vs 0.001 s tracked. The Rust port (`csv.rs`) already fixed this with a separately-tracked `field_chars` counter.
- **Fix:** Track field length in a local `var fieldScalarCount`, incremented on append and reset in `commitField()`; compare against `maxCellChars` instead of calling `.count`. Add a perf-regression test asserting a 64 K cell parses well under 100 ms.

### S2 — `HexView` repaints ALL search matches (up to 50 K) on every arrow-step
- **Where:** `Sources/ViewerUI/HexView.swift:718`.
- **What:** `HighlightKey` includes `currentMatch`, so each `stepMatch` (⌘G / arrow) changes the key, forcing `applyHighlights` to `removeAttribute(.backgroundColor)` over the entire `textStorage` and re-paint **every** match (up to `matchCap = 50,000`) — even though the only visual delta is which single match is orange vs yellow. All on the MainActor inside `updateNSViewController`.
- **Why it matters:** Stepping through a file with tens of thousands of matches (a 2-byte pattern in a multi-MB blob) does O(matches × patternLen) attribute writes per keypress, pinning the main thread. Correct cost is O(2): un-tint the previously-active match, tint the new one.
- **Fix:** Split the key. When only `currentMatch` changed, take a fast path that repaints only the old-active and new-active ranges (yellow→base on the previous index, base→active on the new), skipping the full removeAttribute + full repaint. Track `lastActiveMatchIndex` separately.

### S2 — `mdvcore_session_table` clones the whole parsed `Table` purely to serialize it
- **Where:** `rust-core/crates/ffi/src/lib.rs:481`.
- **What:** `mdvcore_session_table` deep-clones the session's entire parsed `Table` (`session.table().clone()` — every cell `String`, the `Vec<Vec<String>>`, the header) and immediately passes a *reference* to `encode_frame`. `encode_frame<T: Serialize>(value: &T)` borrows and never consumes, so the clone is dead weight: `wire::encode_frame(session.table())` is identical output.
- **Why it matters:** For a multi-MB CSV this is a full redundant allocation + per-cell `String` copy of the whole dataset on the critical open path (`RustCSVAdapter.rustParse → session.table()`), on top of the unavoidable serialization copy. It's the Rust-side twin of the `snapshot()` clone family.
- **Fix:** Drop the clone — `match wire::encode_frame(session.table()) { ... }`.

### S2 — SEC-006 ReDoS wall-clock cap in `HighlightedText.ranges` is structurally dead code
- **Where:** `Sources/ViewerKit/HighlightedText.swift:75`.
- **What:** The 250 ms budget check lives *inside* the `enumerateMatches` block, which fires **only on a match**. Catastrophic backtracking burns CPU inside ICU *while failing to match*, so the closure never runs and `stop.pointee = true` is never reached. **Reproduced:** `(.*a){26}b` vs 40 `a`s ran 30+ s with zero block invocations. Layer one (the shape guard) also misses obvious exponential shapes: `isLikelyCatastrophicRegex` returns false for `(.*X){N}`, `a{1000}{1000}`, `(?:a+)+`, `((a+))+`.
- **Why it matters:** A pattern that hangs also slips the shape guard. Reachability is public-API today (the live `SearchAnywhere` caller passes `.literal`), but this is a bottom-layer ViewerKit API explicitly designed for reuse and self-described as a live ReDoS defense — any future caller wiring a regex find field inherits a defense that does not work.
- **Fix:** Don't rely on the in-block stop. Run match enumeration on a worker with a hard wall-clock deadline (background queue + `DispatchSemaphore.wait(timeout:)`) and return `[]` on overrun. Broaden `isLikelyCatastrophicRegex` to reject quantified groups whose body contains an unbounded quantifier and stacked/multiplicative bounded quantifiers, and handle named-group introducers.

### S2 — `FindEngine.search` enumerates user/automation regex with no wall-clock deadline (MCP `find` bypasses SEC-006)
- **Where:** `Sources/ViewerCore/FindEngine.swift:70`.
- **What:** `RegexComplexityGuard`'s own docstring names `FindEngine` as the first intended caller of `boundedMatches` (SEC-006) and states match-time enumeration "must therefore ALSO be wall-clock-bounded." `FindEngine.makeRegex()` calls `reject()` at compile time, but `search()` calls `regex.enumerateMatches(...)` **directly with no deadline** — `boundedMatches` has exactly one caller (`TextDisplayView.swift:1295`). A polynomial-backtracking pattern that passes `reject()` (the guard explicitly does not model polynomial backtracking) can peg a core.
- **Why it matters:** Reachable from the **MCP `find` tool** (`regex:true` is directly settable by automation) against a multi-MB document, blocking the MainActor where the MCP bridge runs. The defense exists; the highest-risk input channel is the one path that skips it.
- **Fix:** Route `FindEngine.search`'s enumeration through `RegexComplexityGuard.boundedMatches` (it already returns `(matches, timedOut)`); surface `timedOut` to the MCP `find` result.

### S2 — PARSE-03 guards the visitor but not cmark-gfm's parse stage → ~6000 nested blockquotes SIGSEGV
- **Where:** `Sources/ViewerCore/HTMLRenderer.swift:16`.
- **What:** PARSE-03's depth cap (`maxDepth=512`) bounds `HTMLVisitor` recursion, but it sits *downstream* of `Document(parsing: markdown)`. cmark-gfm parses adversarial input into a tree via its own native-C recursive descent with no effective bound, blowing the C stack **before** the visitor (and the guard) runs. The crash is a hard **SIGSEGV**, not graceful truncation. Bisected: threshold between ~5000 and 6000 leading `>` chars — **~8–12 KB**, three orders of magnitude below the 4 MB `markdownRenderMaxBytes` cap.
- **Why it matters:** The render runs synchronously inside the SwiftUI body (`HTMLRenderer().renderPage` at `SplitPaneView.swift:144`), so opening a crafted/corrupt markdown file instantly kills the app with no recovery. The G5 hardening test deliberately stays under cmark's limit, so existing coverage never exercises the real attack.
- **Fix:** Bound nesting **before** handing input to cmark: pre-scan for the run-length of leading block-nesting markers and reject/truncate documents whose maximal nesting exceeds a safe ceiling (a few hundred), surfacing `LargeMarkdownPlaceholderView`. The input-side cap is the only reliable fix — cmark's recursion is uncatchable native C.

### S2 — `IndentDetector` mis-parses every CRLF (Windows) file; A/B parity is silently broken
- **Where:** `Sources/ViewerCore/IndentDetector.swift:20`.
- **What:** `detect()` splits lines with `text[pos...].firstIndex(of: "\n")` over the **Character (grapheme) view**. In Swift `"\r\n"` is a *single* grapheme cluster, so `firstIndex(of: "\n")` never matches the LF inside a CRLF pair — the loop returns nil on the first iteration and treats the entire file as one line. A 4-space CRLF source reports `—` (no indent); a CRLF file starting with spaces reports a bogus width.
- **Why it matters:** The value is shown to the user in `StatusBar`, so every Windows-authored file shows wrong indent metadata. Worse, the Rust port (`indent.rs`) splits with `text.split('\n')` which does *not* collapse CRLF, so the two implementations **disagree** on CRLF input (Rust = `Spaces(4)`, Swift = `—`) — and the `IndentDetectABTests` corpus has **zero CRLF cases**, so the `XCTAssertEqual(rust, swift)` parity gate is dishonest.
- **Fix:** Iterate `text.unicodeScalars` (as `CSVParser` does) or split on the LF scalar and strip a trailing CR per line. Add CRLF cases to both `IndentDetectorTests` and the AB corpus. The Rust side also needs a trailing-`\r` strip.

### S2 — `EditorWriter` silently drops mode/owner/xattrs on EACCES → 0600 secret becomes world-readable
- **Where:** `Sources/ViewerCore/EditorBuffer.swift:248` (same bug verbatim in `HexBinaryWriter`, `HexEditBuffer.swift:231-249`).
- **What:** The temp+rename path exists to replay the original file's mode bits, owner/group, and xattrs onto the replacement. But the metadata snapshot comes from `open(targetPath, O_RDONLY | O_NOFOLLOW)`, which fails with **EACCES** for any existing file the process can *write but not read* (a `0200`/ACL-denied secret, a root-owned group-writable file). On EACCES the code only special-cases ELOOP, so it leaves `existingMeta == nil` and writes a fresh temp + rename — the saved file inherits the **umask mode (0644)**, the writer's uid/gid, and an **empty xattr set**.
- **Why it matters:** A `0600` secret silently becomes world-readable; quarantine/ACLs are dropped — the precise harm the doc comment says the function prevents.
- **Fix:** Distinguish EACCES from ENOENT. On EACCES, recover at least mode+owner via `lstat`/`stat` for replay, or refuse the save with a recoverable error rather than silently downgrading. Mirror in `HexBinaryWriter`.

### S2 — `PTYProcess` never resets `childPID` → terminal restart can never re-spawn a shell (dead feature)
- **Where:** `Sources/ViewerUI/Terminal/PTYProcess.swift:62`.
- **What:** `childPID` is set in `start()` and **never reset** to its negative sentinel in either teardown path. `start()` guards with `guard childPID <= 0 else { return true } // already running`. `TerminalModel.restart()` calls `pty.terminate()` then `pty.start()` on the same instance — but because `terminate()` left `childPID > 0`, `start()` short-circuits and never calls `forkpty`.
- **Why it matters:** The `[process exited]` recovery view and the explicit "Restart shell" menu button **silently no-op**, leaving the user staring at a permanently dead pane the UI claims to have revived. The model also believes a child exists for a pid that is gone — a dead feature plus a state-retention bug. Reachable from both the live Restart UI and `applicationWillTerminate` teardown.
- **Fix:** Reset `childPID = -1` under the lock in **both** `terminate()` and `handleEOF()`. Add a lifecycle test asserting `restart()` respawns.

### S2 — MCP `visible_text` truncation: dead placeholder + char-vs-byte confusion + O(N) trim loop, untested
- **Where:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:205`.
- **What:** Three stacked defects with zero coverage. (1) **Dead code:** `let prefix = text.prefix { _ in true }` walks the entire multi-MB string to produce a copy discarded via `_ = prefix`. (2) **Units bug:** the cap is a UTF-8 *byte* count (`visibleTextMaxBytes` = 10 MiB) but `String(text.prefix(cap))` takes that many *Characters*, over-taking up to 4× the byte budget. (3) **Perf footgun:** `while truncated.utf8.count > cap { truncated.removeLast() }` is quadratic-ish (~1M `removeLast`+`utf8.count` passes for an 11 MB doc). Every test only checks `truncated:false`.
- **Why it matters:** All three fire on the exact large-document case the cap exists to make cheap, on the MCP automation surface, unverified.
- **Fix:** Delete the dead `prefix`. Replace char-prefix + `removeLast` with UTF-8-boundary-correct byte truncation (`text.utf8.prefix(cap)` then decode the largest valid leading subsequence). Add a test feeding a >cap string (ASCII + emoji straddling the boundary).

### S2 — `SessionStore` reads index + every snapshot on the launch main thread with no size cap → startup OOM/hang
- **Where:** `Sources/ViewerCore/Sessions/SessionStore.swift:113` (also `:127`, `:158`).
- **What:** All three `SessionStore` reads omit `maxSize`, so `JSONFileStore.read` falls back to `maxSize: .max`, which **disables both** the stat-based and post-load size guards. `SessionStore` is the *only* `JSONFileStore` consumer with no ceiling — `BookmarksStore` (1 MiB), `ReviewStore` (10 MiB), `PluginGrantStore`, etc. all pass one. These reads run on the **launch critical path on the main thread** (`SessionsAppCoordinator.bootstrap()` → `core.restore()` → synchronous `loadIndexResult()` + a loop of `load(id:)` over every index entry) before the SwiftUI view mounts. The store lives in a user-writable dir whose contents grow with tabs/recents.
- **Why it matters:** A single oversized or runaway `index.json`/`<uuid>.json` forces an unbounded `Data(contentsOf:)` + `JSONDecoder.decode` on the main thread = startup OOM or multi-second hang with no recovery (re-read every launch). `JSONFileStore`'s own docstring ("a tampered file can't inflate into memory") is **false** for this caller. The corrupt path even reads the file twice.
- **Fix:** Add `SessionStore` size ceilings (e.g. 4 MiB index, 16 MiB snapshot) and pass them on all three reads; an oversized file then degrades to the existing `.corrupt`/nil start-empty path. Optionally move the reads off the main thread.

### S2 — Plugin timeout/SIGKILL path leaks reader threads + pipe fds when a grandchild holds the write-end
- **Where:** `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift:262-281`.
- **What:** `call()` never kills the child's *process group* and never force-closes the read handles on the timeout path. After `terminate()`/`kill(SIGKILL)` only the single pid dies. If the plugin forked a grandchild that inherited the stdout/stderr pipe write-ends (the documented v1 wrapper-script usage), the parent's read fds never reach EOF, so both reader closures stay blocked forever in `availableData`. The join is a best-effort 500 ms semaphore wait whose result is *discarded*, so `call()` returns leaving two global-queue workers permanently parked. Up to **4 pipe fds + 2–3 blocked workers leak per invocation**.
- **Why it matters:** `PluginRegistry`'s sidebar provider re-invokes `host.call` on every sidebar refresh, so this compounds toward `RLIMIT_NOFILE` exhaustion and libdispatch thread starvation that eventually starves *all* global-queue work app-wide. Same class as the `PTYProcess` zombie finding, on a path that previously had zero concurrency findings. The existing test only covers a single-process runaway, so the leak path is untested.
- **Fix:** Run the plugin in its own process group and on timeout signal the whole group (`kill(-pgid, SIGTERM)` → `kill(-pgid, SIGKILL)`). When the 500 ms wait times out, force-close the handles so the blocked `read(2)`s return and workers unwind. Consider `DispatchSource`/`DispatchIO` on a single owned serial queue instead of two parked blocking loops.

### S2 — Monitor detail load re-opens the transcript file once per line (O(N) open/seek/close)
- **Where:** `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:150`.
- **What:** `loadRedactedEvents` calls `index.line(at: i, ...)` for every physical line, and `ClaudeSessionIndex.line(at:)` does `openReadOnly` → seek → read one line → `close()` on **every** call. For a real ~29 K-line / 100 MB transcript that's ~29,000 open()+lseek()+read()+close() round-trips, on top of the full streaming scan already done by `lineOffsets(for:)` and the subsequent full `parser.parse`. The detail view does **three passes** over the file plus N file-opens.
- **Why it matters:** The schema doc itself cites 29 K-line transcripts as realistic, so this is hot-path, not pathological.
- **Fix:** Add a streaming `redactedEvents(from:)`-style scan that decodes+redacts+parses each line during the single existing chunked pass, or read lines sequentially from one held `FileHandle`. Collapses 3 passes + N opens to 1 pass.

### S2 — rust-core CI gate does NOT enforce the no-panic policy on `mdvcore-ffi` (the only `unsafe` crate)
- **Where:** `rust-core/crates/ffi/Cargo.toml:25`.
- **What:** `rust-core-gate.sh`'s no-panic claim rests on four clippy **restriction** lints (`unwrap_used`/`expect_used`/`indexing_slicing`/`panic`) — which fire only where opted in. `mdvcore-core` opts in via the workspace lints table; the FFI crate deliberately does *not* inherit workspace lints and its local `[lints.clippy]` declares only `all=deny` + two unsafe-block lints, never the four no-panic lints. `lib.rs`'s crate attributes don't add them either.
- **Why it matters:** The gate's no-panic enforcement has a hole on **the single crate that opts out of `forbid(unsafe_code)`** — hosting every `extern "C"` shim, `catch_unwind`, MsgPack decode, and raw bounds validation. A stray `.unwrap()`/indexing panic in FFI marshaling compiles clean; if it lands outside `ffi_guard!`/`catch_unwind` (a `Drop`, anything outside the macro) it unwinds across the C ABI = **UB**. Empirically reproduced: a planted `.unwrap()` passes the gate's own clippy command clean.
- **Fix:** Add the four restriction denies to `ffi/Cargo.toml [lints.clippy]` (or as `#![deny(...)]` in `ffi/src/lib.rs`, keeping test-only allows via `clippy.toml`). Add a regression test that drops a bare `.unwrap()` into a non-test ffi fn and asserts the gate goes red.

### S2 — Catastrophic-regex test only exercises the form the guard catches (false confidence)
- **Where:** `Tests/ViewerKitTests/HighlightedTextTests.swift:135`.
- **What:** `testCatastrophicRegexDoesNotHang` asserts elapsed < 1.0 s for `(a+)+$` — but that pattern is caught by `isLikelyCatastrophicRegex` and short-circuits to literal, so the test passes for a reason **orthogonal** to what it claims to prove. There is zero coverage of the non-capturing `(?:a+)+`, doubly-nested `((a+))+`, or alternation-wrapped forms — the exact gap that lets the S2 hang ship. **Reproduced:** `(?:a+)+$` hangs >20 s and is classified non-catastrophic.
- **Why it matters:** The suite's green status actively masks the live hang.
- **Fix:** Add tests feeding `(?:a+)+$`, `((a+))+$`, `(a|aa)+$` against a long non-matching haystack asserting either `isLikelyCatastrophicRegex == true` OR `ranges()` returns within a hard off-thread deadline. These fail against the current implementation — exposing the S2.

---

## 3. Findings grouped by theme

Counts are confirmed findings per theme. Severities in brackets.

### Filesystem containment boundary — 7 findings
The single largest security cluster, and where the only S1 lives.
- **[S1]** `mdv-web` no Host/Origin validation, ignores HTTP method → DNS-rebinding remote exfiltration — `web/src/main.rs:66`
- **[S2]** `mdv-web` `/view` & `/browse` serve any absolute path; `root` is cosmetic — `web/src/main.rs:96`
- **[S2]** `URLSchemePolicy` temp-dir unanchored-prefix sibling bypass — `URLSchemePolicy.swift:55`
- **[S3]** `MCPToolCatalog.validatedExistingURL` identical temp-dir sibling bypass + existence oracle — `MCPToolCatalog.swift:334`
- **[S3]** Both validators standardize `..` but never resolve symlinks (in-home symlink escapes) — `URLSchemePolicy.swift:47`
- **[S3]** `WalkthroughLoader.requireRootHint` trusts attacker-authored `rootHint` (`rootHint:"/"` ⇒ everything passes) — `WalkthroughLoader.swift:57`

> **Cross-cutting fix:** extract a single `isContained(_:in:)` helper that anchors with `temp + "/"` *and* resolves symlinks on both operands (mirroring `HTMLDocumentPolicy.isWithinDocumentTree`), and share it across `URLSchemePolicy` and `MCPToolCatalog`. Three of these findings collapse into one fix.

### ReDoS / regex match-time bounding — 5 findings
- **[S2]** SEC-006 250 ms cap is structurally dead (stop-check only runs per match) — `HighlightedText.swift:75`
- **[S2]** `FindEngine.search` skips `boundedMatches` — MCP `find` regex path is unbounded — `FindEngine.swift:70`
- **[S3]** Shape guard mis-tokenizes named-group `(?<name>...)`, letting a catastrophic pattern slip — `HighlightedText.swift:146`
- **[S4]** `unboundedBrace` compiles a fresh `NSRegularExpression` + copies a tail-substring per call inside two O(n) loops — `HighlightedText.swift:132`
- **[S2 test-gap]** Catastrophic-regex test only covers the caught shape — `HighlightedTextTests.swift:135`

### Process / subprocess lifecycle & reaping — 5 findings
- **[S2]** `PTYProcess` never resets `childPID` → restart can never respawn (dead feature) — `PTYProcess.swift:62`
- **[S3]** `PTYProcess.terminate()` reaps with `WNOHANG` immediately after SIGHUP → zombie per teardown — `PTYProcess.swift:266`
- **[S3]** LSP test cleanup is fire-and-forget `defer { Task { await pool.closeAll() } }` (21 sites) — `LSPPoolFakeServerTests.swift:110`
- **[S3]** `applicationWillTerminate` LSP `closeAll()` 2 s budget exceeded by ≥2 sequential servers → leak to launchd — `main.swift:472`
- **[S2]** Plugin timeout/SIGKILL leaks reader threads + fds when a grandchild holds the write-end — `PluginSubprocessHost.swift:262`

### Redundant full-dataset clones — 4 findings
- **[S2]** `mdvcore_session_table` clones the whole `Table` to serialize it (`encode_frame` borrows) — `ffi/src/lib.rs:481`
- **[S3]** `CsvSession.snapshot()` deep-clones the filtered rowset per pull + keeps a second resident copy — `core/src/session.rs:124`
- **[S3]** `CsvSession` cache permanently retains a verbatim duplicate of `table.rows` on the unfiltered view — `core/src/filter.rs:57`
- **[S3 perf]** `MsgPackReader` allocates a transient `[UInt8]` per string/int token (O(cells) churn) — `MessagePack.swift:59`

### O(n²) / quadratic hot-path work — 6 findings
- **[S2]** `CSVParser.appendToField` rescans `.unicodeScalars.count` per scalar (~2400×) — `CSVParser.swift:182`
- **[S2]** `HexView` repaints all matches (≤50 K) per arrow-step — `HexView.swift:718`
- **[S3]** `HexView` `HighlightKey` equality is O(matches) array compare per update — `HexView.swift:701`
- **[S4]** MCP stdio header scan is O(header_len × buffered_bytes) (`removeFirst` + full copy per byte) — `MCPFraming.swift:217`
- **[S3]** `DiagnosticDump.describeTextView` reads `tv.string.count` (full grapheme walk per dump) — `DiagnosticDump.swift:196`
- (plus `unboundedBrace`, counted under ReDoS)

### Untrusted-input crash safety (MCP / wire) — 2 findings
- **[S3]** `MCP.Value.int`/`optionalInt` trap on out-of-`Int64` JSON numbers (one bad `tools/call` aborts the host) — `MCPProtocol.swift:92`
- **[S3]** Swift MessagePack reader `reserveCapacity`s from an untrusted count, no `MAX_FRAME_LEN` (~34 GB OOM) — `MessagePack.swift:119`

### Parsing & adversarial input — 2 findings
- **[S2]** PARSE-03 guards the visitor, not cmark's parse stage → ~6000 nested blockquotes SIGSEGV — `HTMLRenderer.swift:16`
- **[S2]** `IndentDetector` mis-parses every CRLF file; A/B parity silently broken — `IndentDetector.swift:20`

### File I/O & metadata preservation — 4 findings
- **[S2]** `EditorWriter` drops mode/owner/xattrs on EACCES → 0600 → world-readable (same in `HexBinaryWriter`) — `EditorBuffer.swift:248`
- **[S4]** `FileWatcher` construction failure silently disables external-edit detection (no fallback/signal) — `DocumentModel.swift:3269`
- **[S3]** `FileWatcher.attach()` never re-checks `_stopped` — reattach racing `stop()` leaks a live source + fd — `FileWatcher.swift:206`

### Unbounded cache / state growth — 1 finding
- **[S3]** `LSPPool` retains per-file `openedFiles`/`fileVersions`/`fileHashes` forever (no `didClose`); server doc memory grows monotonically — `LSPPool.swift:68`

### State coordination / cache invalidation — 4 findings
- **[S3]** `SidebarModel.clearCache()` leaves `flatVisibleRows` memo stale → git branch switch renders the old tree — `SidebarModel.swift:548`
- **[S3]** `GitPanelModel.loadMoreLog` races `refreshCurrent`/`setRepoRoot` → cross-repo/stale commits appended — `GitPanelModel.swift:221`
- **[S3]** Fold-query path skips the per-language compile lock the highlight path uses → double-compile race — `TreeSitterEngine+Folds.swift:280`

### Observability / silent failure — 4 findings
- **[S3]** `RustCoreFallback` swallows the Rust bridge fault (including a caught FFI `.panic`) with zero observability — `RustCoreFallback.swift:53`
- **[S3]** MCP `find` silently maps an invalid regex to zero matches (no `isError`) — `DocumentModel+AutomationHost.swift:73`
- **[S4]** MCP stdout write failure is logged + swallowed; read loop spins on (half-close hang) — `MCPServer.swift:346`

### Rust ↔ Swift A/B parity drift — 3 findings
- **[S3]** `diff::parse_coord` keeps empty subsequences; Swift drops them → divergent hunk numbers — `diff.rs:263`
- **[S4]** `diff::parse_diff_git_paths` strategy-4 splits empties differently — `diff.rs:224`
- **[S3 contract]** Shared `View` model drops CSV PARSE-04 truncation → every non-Swift front-end mis-renders a clamped table as complete — `view.rs:115`

### Untrusted-HTML sanitization — 1 finding
- **[S3]** `HTMLSanitizer.stripElement` attribute scan is not quote-aware (`[^>]*?`) → element tail leaks as live markup — `HTMLSanitizer.swift:76`

### MCP `visible_text` / state correctness — 3 findings
- **[S2]** `visible_text` truncation: dead placeholder + char-vs-byte + O(N) trim, untested — `MCPToolCatalog.swift:205`
- **[S4]** `current_state` returns 0-based `selectedTabIndex`, `select_tab` consumes 1-based — round-trip off by one — `DocumentModel+AutomationHost.swift:96`

### App lifecycle teardown — 1 finding
- **[S4]** `--auto-snapshot`/`--diagnose` call raw `exit()`, bypassing `applicationWillTerminate` (skips session/JSON flush + LSP teardown) — `Diagnostics.swift:148`

### Wire decode allocation / efficiency — 2 findings
- **[S4]** Wire frame decode accepts trailing garbage after a valid value (no end-of-stream check) — `MessagePack.swift:81`
- (plus `MsgPackReader` per-token allocation, counted under clones)

### Resource exhaustion / DoS hardening — 4 findings
- **[S3]** `mdv-web` unbounded request-line/header read + unbounded per-conn thread spawn, no socket timeout (slow-loris, fd exhaustion) — `web/src/main.rs:64`
- **[S4]** TUI rebuilds the full `Vec<ListItem>` per frame, unbounded by viewport — `tui/src/main.rs:292`
- **[S4]** TUI `--snapshot` uses `.expect()` → panic; release `panic="abort"` makes it a bare abort — `tui/src/main.rs:274`

### CI gate / build-invariant enforcement — 5 findings
- **[S2]** rust-core gate doesn't enforce no-panic on `mdvcore-ffi` (the only `unsafe` crate) — `ffi/Cargo.toml:25`
- **[S3]** No gate verifies the shipped bundle links the Rust `dist` (panic=unwind) profile — `build-rust-core.sh:30`
- **[S3]** `test-in-vm.sh` JUnit converter drops skipped AND crashed cases (under-reports / false-green) — `test-in-vm.sh:84`
- **[S3]** VM `quick` mode selects WebView suites but never sets `MDV_RUN_WEBVIEW_TESTS` → 100% self-skip (false-green render coverage) — `test-in-vm.sh:146`

### Test honesty / coverage gaps — 11 findings
- **[S3]** Swift wire decoder (the stated protocol-skew attack surface) has zero negative-path coverage — `MessagePack.swift:81`
- **[S3]** `.handleDead` panic-recovery contract (headline FFI mitigation) completely untested — `CoreClient.swift:159`
- **[S2]** Catastrophic-regex test covers only the caught shape — `HighlightedTextTests.swift:135`
- **[S3]** Editable-HEX dirty/save/close path (#234) has zero coverage on a data-loss-adjacent feature — `DocumentModel.swift:2047`
- **[S3]** `csv.rs` quote-state-machine edge cases (PARSE-04 motivators) have zero asserted coverage — `csv.rs:293`
- **[S3]** Web router error paths (400/404, missing path, hostile `mode=`) untested — `web/src/main.rs:85`
- **[S3]** `EditorRepublishInvariantTests` cursor-mirror assertion (`<= 1`) permits the storm it forbids — `EditorRepublishInvariantTests.swift:148`
- **[S3 test-gap]** Editor nav-policy has zero coverage (root cause the `.other` asymmetry went unaudited) — `CodeMirrorEditorView.swift:613`

### Type-model / config consistency — 3 findings
- **[S3]** Dead/contradictory `.svg` type model — classified `.image` yet listed as a formatter ext (unreachable formatted mode); three primitives disagree — `ViewMode.swift:167`
- **[S4]** `.tsx` highlighted with the plain TS grammar; `tree_sitter_tsx` ships in the dylib but is unreachable — `wrapper.c:12`

### VM smoke / harness scripting — 4 findings
- **[S3]** `vm-smoke.sh` launches a nonexistent path for any file outside the project root (double-slash) — `vm-smoke.sh:74`
- **[S3]** `vm-smoke.sh` command injection via the file-path arg into a remote `sudo`'d `sh -c` — `vm-smoke.sh:110`
- **[S4]** `vm-smoke.sh` resets a stale `MarkdownViewer/Workspaces` dir no store uses — `vm-smoke.sh:93`
- **[S4]** `TierGateObserver` sentinel create-path uses a destructive atomic write — concurrent first-violations clobber — `TierGateObserver.swift:128`

### Code signing / bundle packaging — 2 findings
- **[S3]** All 11 grammar dylibs signed with the main bundle id (`--deep --identifier` footgun) — malformed for notarization — `build-app.sh:197`
- **[S4]** Exec sub-cap documented as 16 MB everywhere but actually 26 MB (doc/comment drift) — `check-bundle-size.sh:63`

### CI build efficiency — 2 findings
- **[S3]** CI compiles the entire SwiftPM + Rust tree from scratch every PR run (no `actions/cache`) — `pr.yml:32`
- **[S3]** VM `all` lane runs live-app `ViewModeMatrixSmokeTests` twice (build-app gate + full sweep) — `test-in-vm.sh:64`

### Image / SQLite editing — 1 finding
- **[S3]** `aspectFit` traps (SIGTRAP) on NaN/Inf box dimension — `Int(NaN)` is a hard crash, not a throw — `ImageDocument.swift:96`

### Claude transcript subsystem (parser / index / monitor) — 5 findings
- **[S3]** Sidebar Claude timeline bypasses the mandatory redaction barrier (`events(from:)` not `redactedEvents`) → un-redacted transcript content surfaced — `ClaudeTimelineSection.swift:176`
- **[S2]** Monitor detail load re-opens the transcript once per line (O(N) open/seek/close) — `ClaudeMonitorView.swift:150`
- **[S3]** Session title (first user prompt) stored unbounded (≤4 MB per session retained) — `ClaudeSessionIndex.swift:357`
- **[S4]** Index scan redacts every record solely to count surfaced events (doubles per-line work) — `ClaudeSessionIndex.swift:367`

### ViewerUI editor WKWebView navigation — 1 finding
- **[S3]** Editor nav delegate allows ALL `.other` navigations unconditionally — no scheme/baseURL guard (the WV-4 render-side defense is absent on the editor; `file:`/`data:`/`javascript:` `window.location` escape) — `CodeMirrorEditorView.swift:618`

---

## 4. Coverage map (subsystems × dimensions, depth = deep)

The audit covered **74 cells** at deep depth. Rows are subsystems; columns are review dimensions. Each cell marks whether that dimension was reviewed deeply for that subsystem and, where applicable, the count of confirmed findings landing in it.

Legend: `●n` = reviewed deep, n confirmed findings · `●` = reviewed deep, no findings · `·` = not in scope for this cell.

| Subsystem \ Dimension | Security | Perf | Concurrency / lifecycle | Correctness / logic | Resource leak | A/B parity | Test honesty |
|---|---|---|---|---|---|---|---|
| `rust-core/crates/web` | ●2 | ● | ●1 | ● | ●1 | · | ●1 |
| `rust-core/crates/ffi` | ●1 | ●1 | ● | ● | ● | ● | · |
| `rust-core/crates/core` (csv/filter/session/diff/view) | ● | ●2 | ● | ●2 | ●3 | ●2 | ●1 |
| `rust-core/crates/tui` | · | ●1 | ● | ●1 | ●1 | · | ● |
| `Sources/RustCore` (MessagePack/CoreClient) | ●1 | ●2 | ● | ● | ● | ● | ●2 |
| `Sources/ViewerCore/Security` (URLScheme/MCP/Walkthrough) | ●4 | ● | ● | ● | ● | · | ●1 |
| `Sources/ViewerCore/Automation` (MCP) | ●2 | ●1 | ● | ●2 | ● | · | ● |
| `Sources/ViewerCore` (CSV/Indent/HTML/Sanitizer/Editor) | ●2 | ●1 | ● | ●3 | ● | ●1 | ●1 |
| `Sources/ViewerCore/LSP` | ● | ●1 | ●2 | ● | ●1 | · | ● |
| `Sources/ViewerCore/Sessions + Review` | ●2 | ● | ●1 | ● | ● | · | ● |
| `Sources/ViewerCore/Plugins` | ● | ● | ●1 | ● | ●1 | · | ● |
| `Sources/ViewerCore/Highlight + ImageEditing` | ● | ● | ●1 | ●1 | ● | · | ● |
| `Sources/ViewerCore/Claude*` (parser/index/monitor) | ●1 | ●3 | ● | ● | ●1 | · | ● |
| `Sources/ViewerKit` (HighlightedText/ViewMode) | ●2 | ●1 | ● | ●1 | · | · | ●1 |
| `Sources/ViewerUI` (Hex/Sidebar/Git/Terminal/FileWatcher) | ● | ●3 | ●3 | ●2 | ●2 | · | ●1 |
| `Sources/ViewerUI` editor WKWebView | ●1 | ● | ● | ● | · | · | ●1 |
| `Sources/MarkdownViewer` (main / Diagnostics) | ● | ● | ●1 | ●1 | ●1 | · | · |
| `Sources/TreeSitterLazyWrappers` | · | · | · | ●1 | · | · | · |
| `scripts/` (build-app/build-rust/vm-smoke/check-size/test-in-vm) | ●1 | ●2 | ● | ●3 | · | · | ●3 |
| `.github/workflows` | · | ●1 | · | · | · | · | ● |
| `Tests/` (harness / LSP / republish / editor) | ● | ● | ●2 | ●1 | ●1 | · | ●2 |

**Reading the map.** The densest security cells are `ViewerCore/Security` (the containment fences) and `rust-core/crates/web` (the loopback server) — exactly where the S1/S2 cluster lives. Concurrency/lifecycle findings concentrate in `ViewerUI` (Hex/Sidebar/Git/Terminal/FileWatcher) and the process-spawning subsystems (LSP, Plugins, PTY). Perf findings split between the Rust hot path (clones), the MainActor render paths (CSV/Hex), and the Claude transcript subsystem. Test-honesty findings span almost every subsystem — the recurring shape is a green suite that exercises only the path the implementation already handles. A handful of cells (e.g. TreeSitter wrappers × security, web × parity) are intentionally narrow because those dimensions don't apply to those subsystems.

---

## 5. Recommended next actions

Ordered by risk-reduction per unit of effort. None of these were applied — this audit changed no code.

### Immediate (this week) — close the remote/crash surface
1. **Land the `mdv-web` containment + Host check together** (`web/src/main.rs:66`, `:96`). One `validated_under_root` chokepoint on `/view` and `/browse` plus a `Host`/method allowlist neutralizes the only S1 and its enabling S2 in a single change. Until then, document that the binary must never run while browsing untrusted sites.
2. **Cap the cmark nesting before parse** (`HTMLRenderer.swift:16`). A pre-scan run-length guard on leading block-nesting markers is the only reliable fix for the ~12 KB SIGSEGV, and it's the difference between "opening a corrupt file kills the app" and "graceful placeholder."
3. **Cap `SessionStore` reads** (`SessionStore.swift:113/127/158`). Pass explicit `maxSize` ceilings; an oversized launch file then degrades to start-empty instead of a main-thread OOM/hang on every launch.
4. **Harden `MCP.Value.int` + MessagePack `reserveCapacity`** (`MCPProtocol.swift:92`, `MessagePack.swift:119`). `Int(exactly:)` + a `MAX_FRAME_LEN` mirror of the Rust side stop a single malformed wire frame / `tools/call` from aborting the host.

### Near-term (this sprint) — fix the dead defenses and dead features
5. **Make the ReDoS cap real and route `FindEngine` through it** (`HighlightedText.swift:75`, `FindEngine.swift:70`). Off-thread enumeration with a hard deadline, plus a broadened shape guard, fixes both S2s and the named-group S3. Then add the failing tests (`(?:a+)+$`, `((a+))+$`) so the suite stops lying.
6. **Fix `PTYProcess` `childPID` reset + bounded reap** (`PTYProcess.swift:62`, `:266`). Restores the "Restart shell" feature and stops the zombie-per-teardown leak. Mirror the bounded SIGHUP→poll→SIGKILL escalation already used by `LSPClient.shutdown()`.
7. **Fix `EditorWriter`/`HexBinaryWriter` EACCES handling** (`EditorBuffer.swift:248`). A silent 0600→world-readable permission downgrade on save is a data-confidentiality regression; distinguish EACCES from ENOENT.
8. **Extract one `isContained(_:in:)` helper** (anchor with `temp + "/"`, resolve symlinks on both operands) and apply it to `URLSchemePolicy` and `MCPToolCatalog`. Collapses three containment findings into one fix and prevents future drift.
9. **Fix `IndentDetector` CRLF handling + add CRLF parity cases** (`IndentDetector.swift:20`). Restores correctness for every Windows file and makes the A/B gate honest.

### Quality / efficiency (opportunistic)
10. **Kill the redundant Rust clones** (`ffi/src/lib.rs:481`, `session.rs:124`, `filter.rs:57`) — a one-line drop on the FFI path plus a cache-shape change removes 2–3× resident copies of every open CSV.
11. **De-quadratic the MainActor hot paths** — `CSVParser.appendToField` field-length counter (`:182`) and `HexView` fast-path repaint (`:718`). Both are isolated, measured, with a known-correct reference (the Rust port; O(2) repaint).
12. **Plug the lifecycle leaks** — plugin process-group kill + handle force-close (`PluginSubprocessHost.swift:262`), LSP `closeAll()` parallelization/budget (`main.swift:472`), `FileWatcher` reattach `_stopped` re-check (`FileWatcher.swift:206`), `LSPPool` `closeFile` (`LSPPool.swift:68`).

### Process / CI hygiene
13. **Close the `mdvcore-ffi` no-panic gate hole** (`ffi/Cargo.toml:25`) with a red-on-bare-`.unwrap()` regression test — the gate currently doesn't cover the one crate where a panic across the C ABI is UB.
14. **Make the VM/CI lanes honest** — JUnit `skipped`/crash reporting (`test-in-vm.sh:84`), set `MDV_RUN_WEBVIEW_TESTS` for the suites `quick` selects (`:146`), and add `actions/cache` for the SwiftPM + Rust trees (`pr.yml:32`).
15. **Backfill the load-bearing test gaps** — wire-decoder negative paths, the `.handleDead` panic-recovery contract, and the editable-HEX save/dirty/close path. These guard data-loss and crash-recovery behavior with currently-zero coverage.
16. **Fix the `vm-smoke.sh` command-injection + bogus-path bugs** (`:110`, `:74`) — a dev tool that pipes a known sudo password into a remote shell with an unsanitized path argument is worth tightening even though it's local-only.
17. **Reconcile the doc drift** — exec sub-cap (16 → 26 MB) and the `--deep --identifier` dylib signing before the Developer ID / notarization transition, where the duplicate-identifier signing will start failing.

---

*End of report. Full machine-readable findings with evidence and per-finding suggested fixes: `AUDIT_BUGS.md`.*
