# Security & Concurrency Review — TextView / MarkdownViewer

**Date:** 2026-05-25
**Scope:** Full repo, read-only. ~38.8k LoC across `Sources/`, plus `scripts/`, `Resources/`, design docs.
**Reviewer:** opus-4.7 agent (parallel with four others).

---

## Executive summary (top findings ranked by severity × likelihood)

| # | Severity | Likelihood | Title |
|---|---|---|---|
| 1 | **High** | Medium | `markdownviewer://open?path=…` URL scheme accepts any absolute path; trivially weaponizable from a browser / link drag |
| 2 | **High** | Low | Walkthrough drop transport has no authentication; anyone who can write to `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/drop/` drives the live app |
| 3 | **Med** | Med  | `MarkdownRenderedView` flipped `allowsContentJavaScript = true` while `HTMLRenderer` still emits `visitHTMLBlock` / `visitInlineHTML` payloads verbatim — sole defense is the inline CSP `<meta>` (race + bypass surface) |
| 4 | **Med** | Med  | `WalkthroughLoader` only enforces path-escape **when `rootHint` is set**; null-rootHint scripts can `openFile` arbitrary absolute paths (interacts with #2) |
| 5 | **Med** | Low  | MCP server hops to MainActor via `DispatchQueue.main.sync` from a background `Thread`; under load this can deadlock if a MainActor handler ever awaits something that posts back to the same thread |
| 6 | **Med** | Med  | LSP/jq/git/plugin `Process` subprocesses don't enforce wall-clock CPU limits via `setrlimit`; only the plugin host has a timeout. A wedged `sourcekit-lsp` is recoverable, a wedged `jq` ties up a GCD worker indefinitely if the watchdog dispatch is starved |
| 7 | **Med** | Med  | FindEngine + many other regex paths compile user-supplied patterns via `NSRegularExpression` with no timeout / no complexity bound → ReDoS on a maliciously-crafted query |
| 8 | **Med** | Low  | `EditorWriter.save` uses `Data.write(.atomic)` against the user's URL with no symlink check — saving a file whose path is a symlink will silently replace the symlink with the contents (TOCTOU + symlink hijack class) |
| 9 | **Med** | Low  | `LSPDiscovery` adds `~/.npm-global/bin`, `~/.npm/bin`, `~/.local/bin` to the search PATH without ownership verification; an attacker who compromises one of these dirs gets code-exec on the next LSP spawn |
| 10 | **Low** | Med | `Process` use across `GitClient.run` / `GitService.run` / `JQRunner.run` shares a write-pattern: closures store into local `var` from background queues, gated by `DispatchGroup.wait()`. Functional today, but Swift 6 strict-concurrency-compliant only by accident; first refactor that drops the group will introduce races |
| 11 | **Low** | Low | Diagnostic dumps & windowid file written to `FileManager.temporaryDirectory` using deterministic names; another local user with `+x` on that user's tmp can race-rename to clobber |

Detail and lower-priority findings below. Total findings: 27.

---

## 1. External attack surface

### 1.1 Custom URL scheme — `markdownviewer://` (High / Medium)

**Location:** `Sources/MarkdownViewer/main.swift:618-658`

`Info.plist` registers `markdownviewer://` (`scripts/Info.plist:79-89`). The handler accepts:

- `markdownviewer://open?path=/abs/path`
- `markdownviewer://search?root=/path&q=hello`

Both expand `~` and immediately call `model.openPath(...)` / `model.sidebar.setRoot(...)`. **No allow-listing, no path containment, no scheme-source check.** Compare to `MCPToolCatalog.validatedExistingURL` (`Sources/ViewerCore/Automation/MCPToolCatalog.swift:323-341`) which forces paths under `$HOME` or the per-user temp dir — that defense is **not** applied here.

Attack: a malicious webpage triggers `<a href="markdownviewer://open?path=~/.ssh/id_rsa">click here</a>`. macOS shows a "Open this in TextView?" prompt the first time per source app, but users habituated to clicking accept. The user then has their SSH private key on screen and possibly in the in-memory `EditorBuffer` (which would be readable via subsequent MCP `visible_text` if MCP were live).

Stronger attack: arbitrary command palette manipulation via `search` — set the sidebar root to `/private/etc`, run a cross-search for "password", and the panel will surface matches from anywhere the app has TCC access to.

**Fix:** mirror `MCPToolCatalog.validatedExistingURL` (or stricter), and require the scheme target to be a user-selected file (e.g. via security-scoped bookmark) before honoring.

### 1.2 Walkthrough drop transport — unauthenticated automation (High / Low)

**Location:** `Sources/ViewerCore/Walkthrough/WalkthroughDropTransport.swift:38-108`

The transport watches `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/drop/` and auto-executes any well-formed `.json` script that lands there. Directory is created `0o700` (good) but:

- **Co-resident processes** in the user's session (every app, every shell command, every browser extension on macOS) can write to `~/Library/Application Support/...`. There's no kernel-enforced isolation between user processes.
- A script that lands while the app is running fires `scan()` → `delegate.didReceive(script)`. The delegate (`WalkthroughEngine`) then drives `openFile`, `setView`, `splitFile`, `addBookmark`, `revealLine`, etc. against the live `DocumentModel`.

The transport itself doesn't exfiltrate, but combined with #1.1 and #1.4 (path-escape gap), a malicious dropper can make the app open arbitrary files and bookmark them into persistent state.

**Fix options:**
- Require a per-session shared-secret in the script's envelope, rotated on launch.
- Disable the transport entirely unless `TV_WALKTHROUGH_DROP=1` is set in the env at launch.
- Move the drop dir under `~/Library/Containers/.../Data/...` if the app ever sandboxes.

### 1.3 NSServices `openInTextView` — file URL only (Low / Low)

**Location:** `Sources/MarkdownViewer/main.swift:1782-1811`

Correctly filters `urls.filter { $0.isFileURL }` before opening. ✓ No issue, noted for completeness.

### 1.4 Walkthrough loader — path-escape conditional on `rootHint` (Med / Med)

**Location:** `Sources/ViewerCore/Walkthrough/WalkthroughLoader.swift:82-108`

```swift
if let rootHint = script.rootHint {
    // … per-step pathEscape check
}
```

If `rootHint` is nil, **every** path in the script is accepted as-is, including absolute paths to `/etc/`, `/Users/other/...`, etc. The doc-comment says "paths are assumed absolute and the caller has chosen to accept them," but the transport (#1.2) calls `WalkthroughLoader.load(fileAt:)` without injecting a `rootHint`. So the actual default at the file-drop boundary is "no path containment."

**Fix:** at the transport boundary (`WalkthroughDropTransport.scan`), reject scripts that don't carry a `rootHint`, or inject one from the active session's sidebar root before validation.

---

## 2. WKWebView / JS bridge

### 2.1 Markdown rendered view — JS enabled + HTML pass-through (Med / Med)

**Location:**
- `Sources/ViewerUI/MarkdownRenderedView.swift:58-65` — `allowsContentJavaScript = true`
- `Sources/ViewerCore/HTMLRenderer.swift:259-261, 350-352` — `visitHTMLBlock` / `visitInlineHTML` emit `html.rawHTML` **verbatim**
- `Sources/ViewerCore/HTMLRenderer.swift:35` — CSP `default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; …`

The combination is risky:

- The CSP is inlined as an HTTP-equiv `<meta>` tag. That works only if the CSP `<meta>` is processed **before** the first inline `<script>`. CommonMark allows authors to write `<script>alert(1)</script>` inside an HTML block, and `visitHTMLBlock` pastes it verbatim into the document **above** any subsequent content. The CSP `<meta>` is emitted in `<head>` (good), but recent WebKit changes have weakened http-equiv CSP enforcement vs. true HTTP-header CSP. Risk depends on WebKit version.
- More directly: the CSP allows `style-src 'unsafe-inline'`. A markdown author can inject `<style>` blocks that pull off the page (UI confusion) or use CSS `content:` exfiltration tricks (data URI exfil is blocked by `img-src` not allowing `https:`, so this is constrained).
- `style-src 'unsafe-inline'` plus inline `<svg onload="…">` — `script-src` is implicit-default from `default-src 'none'`, which **should** block JS event handlers, but Mermaid's user scripts are added via `addUserScript` which bypasses CSP entirely. Any document containing `mdv-mermaid` triggers `MermaidBundle.shimJS` to install permanently on that WebView (`MarkdownRenderedView.swift:88-107`) — the `mermaidInjected` flag never resets, so a markdown file with one mermaid block followed by a non-mermaid file in the same tab carries the mermaid runtime forward into pages it has no business being in.

**Fix:**
- Switch to a **sanitizing** HTML pass-through (allowlist of tags) for `visitHTMLBlock` / `visitInlineHTML`.
- Don't keep `mermaidInjected = true` permanently — reset on document change or use a separate WebView for mermaid-bearing pages.
- Move CSP to a real HTTP-header equivalent by serving via a `WKURLSchemeHandler` rather than `loadHTMLString`.

### 2.2 CodeMirror editor bridge — `loadFileURL` read access (Low / Med)

**Location:** `Sources/ViewerUI/CodeMirrorEditorView.swift:317-332`

```swift
webView.loadFileURL(htmlURL, allowingReadAccessTo: baseDir)
```

`baseDir` is `Bundle.module.resourceURL` — i.e. the SwiftPM resource directory. Granting `file://` read access to the *parent of the HTML* is the right idiom, but worth checking whether the resource directory shares its parent with anything user-owned (it doesn't — `Bundle.module` lives inside the `.app` bundle, immutable post-sign). ✓ Safe.

### 2.3 `evaluateJavaScript` interpolation of user data (Med / Low)

**Location:** `Sources/ViewerUI/MarkdownRenderedView.swift:209-243`, `Sources/MarkdownViewer/main.swift:1741, 1747`

`runFind` constructs JS via `Coordinator.jsEscape(q)` which round-trips through `JSONSerialization` — correct escaping. ✓

But `cmFoldAll` / `cmUnfoldAll` use `CMBridgeCodec.encodeOutboundJSON(.foldAll)` which is also JSON-encoded — also correct. Spot-checked find/replace and editor dispatch; all user data flows through JSON encoders. ✓ Noted for confirmation.

### 2.4 WKNavigation policy delegate — defense-in-depth (Low / Low)

**Location:** `Sources/ViewerUI/MarkdownRenderedView.swift:407-423`

Allowlists `http`/`https`/`mailto` for `linkActivated`, allows other navigation types unchanged. Note: `WKNavigationType.other` covers programmatic navigation initiated by JS — if a malicious markdown ever executed JS (per #2.1 risk), it could `window.location = 'file:///etc/passwd'` and bypass this check. Tighten by also blocking `file:` / `data:` / `javascript:` regardless of navigation type.

---

## 3. Subprocess / external-binary surface

### 3.1 LSP binary discovery — uncontrolled PATH augmentation (Med / Low)

**Location:** `Sources/ViewerCore/LSP/LSPDiscovery.swift:105-133`

`augmentedSearchPaths()` walks user-owned directories (`~/.npm-global/bin`, `~/.npm/bin`, `~/.local/bin`) plus `/opt/homebrew/bin`, `/usr/local/bin`. There's no check that the matched binary is owned by root / not group-writable / not symlinked off-tree. An attacker who can drop a malicious `pyright` / `typescript-language-server` / etc. into any of these (e.g. via a compromised npm package's postinstall script) gets code-exec inside the user's `TextView` process the next time they open a file in that language.

Mitigation already in place: `runCapture` is invoked only for `xcrun -f` and `/usr/bin/which`, both rooted at `/usr/bin`. The pre-empt-on-found check at line 72 does prefer `Bundle.main.bundleURL/Contents/Resources/lsp/<binary>` first, so if the app ever ships fallbacks they'd win.

**Fix:** at minimum, refuse executables that aren't owned by the current user **and** root, and reject any path whose directory is world-writable.

### 3.2 Git client — defense-in-depth is solid (Pass)

**Location:** `Sources/ViewerCore/GitService.swift:79-86`, `Sources/ViewerCore/Git/GitClient.swift:396-403, 423-433`

Both classes disable `core.hooksPath`, `core.fsmonitor`, `core.editor`, `core.pager` and override `GIT_TERMINAL_PROMPT`/`GIT_EDITOR`/`GIT_PAGER`/`GIT_OPTIONAL_LOCKS`. `GitService` also scrubs env to `PATH=/usr/bin:/bin`. `GitClient.run` inherits the full env (line 428) **except** the four overrides — meaning `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_CONFIG_GLOBAL`, etc. are still inherited. A hostile parent shell could pre-set these to point at a fake config. Low risk in practice (TextView is launched by the user, not by a hostile parent), but `GitService.safeEnvironment` is the stronger pattern; align both. ✓ Mostly good.

### 3.3 Plugin subprocess host — solid v1 (Pass / minor notes)

**Location:** `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift`

- Env scrub to `HOME` only (line 292) — excellent.
- 5s default timeout, 30s cap (line 103-104) — good.
- 1 MB stdout cap (line 105) — good.
- Path-traversal check is string-level only (`if bin.contains("..")` line 138), explicitly called out as not symlink-safe — acknowledged.
- `process.terminate()` then 200ms sleep then `kill SIGKILL` (line 237-242) — correct.
- `O_APPEND` audit log write (line 372-375) relies on PIPE_BUF (4 KB on macOS) for atomicity; lines are <500 bytes per the doc-comment. ✓

**Minor:** the `auditLogURL()` directory creation (`createDirectory(at: ..., withIntermediateDirectories: true)`) doesn't set `0o700` perms — `~/Library/Logs/com.markdownviewer.MarkdownViewer/` ends up world-readable on most umasks. Audit log contains plugin ids and stderr tails; could leak info to a co-resident user.

### 3.4 LSP process — no resource caps (Med / Med)

**Location:** `Sources/ViewerCore/LSP/LSPClient.swift:82-107`

`Process()` is spawned with full inherited environment and no `setrlimit` for CPU / memory / fd count. A wedged or malicious LSP server can consume unbounded resources. Mitigated by per-request timeouts (8-30s) firing `cancelRequest`, but cancellation is best-effort over JSON-RPC, not via process kill.

`shutdown()` (line 589-601) does `SIGTERM` on timeout but only if the client object is explicitly torn down. Crashed-mid-session servers are detected via `LSPPool` (`failAllPending` callback) but with no SIGKILL backstop on the orphaned process.

### 3.5 jq runner — minor TOCTOU on probe (Low / Low)

**Location:** `Sources/ViewerCore/JQRunner.swift:33-36`

`binaryPath` is recomputed on every call (`FileManager.isExecutableFile` x2). Race: between probe and `Process.run`, the binary could be replaced. Practical impact zero (user owns both paths in normal install), noted for the symmetry with #3.1.

### 3.6 MCP server — operates on stdio (Low / Low)

**Location:** `Sources/MarkdownViewer/main.swift:1865-1879`

MCP mode only activates with `--mcp-stdio` flag at launch, sets `NSApplication.ActivationPolicy = .prohibited`. No remote network surface; client must be the parent process. ✓ Low concern, contained.

---

## 4. Concurrency / actor-isolation issues

### 4.1 MCP server `DispatchQueue.main.sync` from background thread (Med / Low)

**Location:** `Sources/ViewerCore/Automation/MCPServer.swift:137-143`

```swift
let response = DispatchQueue.main.sync {
    MainActor.assumeIsolated {
        self.dispatch(...)
    }
}
```

`DispatchQueue.main.sync` from a non-main thread is correct **as long as** the main thread is not currently waiting on the background thread. If a MainActor handler ever does `await someBackgroundTask` that itself waits on the MCP server thread (which is parked in `read(2)`), the system deadlocks. Today none of the v1 tools do this, but it's a foot-gun a future tool (e.g. one that awaits an LSP response) could trip.

Also notable: every request lands on MainActor serialized. A slow tool (`snapshot_window` does PNG encoding) blocks every other UI interaction for its duration.

### 4.2 `nonisolated(unsafe)` lock patterns — audited list

The repo uses `nonisolated(unsafe)` + `NSLock` consistently for shared static caches:

- `GrammarLoader.Locked.cache/failed` — every access bracketed. ✓
- `LSPDiscovery.binaryCache` — every access bracketed. ✓
- `FindEngine.lastRegex{Key,}` — every access bracketed. ✓
- `SessionStore.pending` + `coalesceLock` — every access bracketed. ✓
- `FileTreeRecencyCache.cache` — every access bracketed (note minor: capacity check + clear can race with another reader's lookup, but the worst case is a missed cache hit). ✓
- `BookmarkEntry.iso8601` (ISO8601DateFormatter) — documented thread-safe by Apple. ✓
- `ClaudeLogParser.iso/isoFractional` — same. ✓
- `StatusBar.metricsCache` / `previewSizeCache` — used from MainActor only? Worth confirming; if any preview pipeline is off-main, the cache access lacks bracketing.

All audited patterns look correct. The general approach is sound.

### 4.3 `MCPServer.stopFlag` — lock ordering with input.close (Low / Low)

**Location:** `Sources/ViewerCore/Automation/MCPServer.swift:65-70`

`stop()` sets `stopFlag = true`, then `input.close()`. The reader thread reads `shouldStop` between requests but is parked inside `read(2)` for each byte. The `input.close()` is what actually unblocks it. Sequencing is fine. ✓

### 4.4 GitClient.run — local `var` captured into background closures (Low / Med)

**Location:** `Sources/ViewerCore/Git/GitClient.swift:443-457`

```swift
var outData = Data()
var errData = Data()
group.enter()
outQ.async { outData = ... ; group.leave() }
group.enter()
errQ.async { errData = ... ; group.leave() }
try p.run()
p.waitUntilExit()
group.wait()
```

The local vars are captured by reference into escaping closures. Swift 6 strict concurrency normally rejects this (mutation of a local from a `@Sendable` closure), but `Process.run`/`DispatchQueue.async` aren't `@Sendable`-marked in the same way. **Functionally** the `group.wait()` is a happens-before barrier so the post-wait read is safe — but the pattern is fragile vs. e.g. `GitService.run` which uses `_DataBox` for the same reason. Align on `_DataBox`.

Also: the reader closures call `readDataToEndOfFile()` **before** `try p.run()`. If `p.run()` throws, the pipes' write ends close when `p` deallocates, the readers EOF, group completes, no leak. ✓ But fragile if the ordering is ever shuffled.

### 4.5 JQRunner — same pattern, has `_Box` (Pass)

**Location:** `Sources/ViewerCore/JQRunner.swift:84-97`

Same shape, uses `final class _Box: @unchecked Sendable { var data = Data() }`. Correct.

### 4.6 FileWatcher `_stopped` flag race window (Low / Low)

**Location:** `Sources/ViewerCore/FileWatcher.swift:91-104`

The `setEventHandler` checks `isStopped` before calling `handler()`. The check + handler call isn't atomic — a `stop()` arriving between the check and the handler still fires it once. Doc-comment acknowledges this (line 93-97). Acceptable per design.

### 4.7 LSPClient.cancelRequest from another task (Low / Low)

**Location:** `Sources/ViewerCore/LSP/LSPClient.swift:302-323`

`cancelRequestPublic(id:)` is public-actor → safe re-entry. Inside the actor, `cont.resume(throwing:)` followed by ignoring the eventual server response works because `dispatchInbound` checks `pending.removeValue` returns nil for already-cancelled ids. ✓

### 4.8 LSPPool reaper task — not shown, audit if needed

Not deeply audited in this pass — actor model + idle reaper. Tagged in the design as a known surface; recommend a separate pass focused on `LSPPool.swift` lifecycle.

---

## 5. File I/O / TOCTOU / data integrity

### 5.1 EditorWriter symlink follow on atomic write (Med / Low)

**Location:** `Sources/ViewerCore/EditorBuffer.swift:138-155`

`Data.write(to: url, options: [.atomic])` on macOS: if `url` is a symlink, Foundation writes a temp file alongside the target and renames over the symlink — replacing the symlink with the new file. The user's symlinked dotfile etc. is silently de-symlinked.

This is a **footgun more than a vuln**: an attacker who can plant a symlink at the user's edited path can redirect the write. But it requires write access to the user's editable path, which already implies arbitrary-write capability.

**Fix:** before writing, check `URL.resolveSymlinksInPath()` matches `URL.standardizedFileURL`; warn / refuse otherwise.

### 5.2 JSONFileStore size-check TOCTOU (Low / Low)

**Location:** `Sources/ViewerCore/JSONFileStore.swift:27-34`

```swift
let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
if size > maxSize { return nil }
let data = try? Data(contentsOf: url)
guard data.count <= maxSize else { return nil }
```

Two reads of the file: `attributesOfItem` then `Data(contentsOf:)`. A grow-between-checks would be caught by the second `data.count` check, so functionally safe. ✓

### 5.3 GoToPathHistoryStore — fine (Pass)

64 KB cap, 10-entry cap, JSONFileStore-backed. Sanitization is at the consumer (`GoToPathExpansion.resolveExisting`). No issues.

### 5.4 Sessions write coalescing — sound design (Pass)

`SessionStore.enqueue` + serial `writeQueue` + `coalesceLock` correctly serializes per-URL writes. The `flushSync()` on terminate is the right call. ✓

### 5.5 `WalkthroughDropTransport.scan` ordering vs partial writes (Low / Low)

Documented: extension `.json.tmp`/`.json.partial` deliberately not picked up — caller does atomic rename. Hard to misuse; the lexicographic sort prevents arbitrary ordering attacks. ✓

### 5.6 PluginSubprocessHost audit-log directory perms (Low / Low)

See §3.3 — directory created without `0o700`.

### 5.7 Diagnostic dump files in shared tmpdir (Low / Med)

**Location:** `Sources/MarkdownViewer/main.swift:140-145, 451-453, 516-518, 553-556`

Paths like `${tmp}/com.markdownviewer.MarkdownViewer.windowid`, `${tmp}/mdv-auto.{json,png}`, `${tmp}/mdv-diagnostic-${pid}.json` use the per-user temp dir (`FileManager.temporaryDirectory` resolves to `/var/folders/.../T/`), which is owned 0700 by the user. So another local user can't read or symlink-hijack. ✓ — but if `TMPDIR` is overridden to `/tmp/foo` for testing, that protection lapses.

The `windowid` path is deterministic per-bundle-id (not per-pid) — concurrent app instances would race. Practical impact: tests only.

---

## 6. Regex / parser / input validation

### 6.1 FindEngine — ReDoS via user regex (Med / Med)

**Location:** `Sources/ViewerCore/FindEngine.swift:116-146`

`NSRegularExpression(pattern: query.pattern, options: ...)` is compiled directly from the user's input when `query.kind == .regex`. No timeout on `enumerateMatches`. A pathological pattern like `(a+)+$` against a long line of `a`s hangs the find thread.

Same surface in:
- MCP `find` tool (`Sources/ViewerCore/Automation/MCPToolCatalog.swift:147-176`) — a malicious MCP client can force this hang on the MainActor since the catalog runs `host.automationFind` from the dispatch back to MainActor.
- `CrossFileSearch` — multi-file regex search, same concern at higher amplification.

**Fix:** wrap regex execution in `DispatchQueue.async` with a deadline-and-cancel pattern; reject patterns with nested repetition (`+`, `*`, `{n,}` inside groups) at compile time via a pre-scan.

### 6.2 HTMLRenderer.uniqueSlug — Unicode normalization (Low / Low)

`uniqueSlug` lowercases and filters via `Character.isLetter || isNumber`. Unicode classes can produce surprising slugs for RTL / combining chars, but the worst is heading IDs that collide unexpectedly. Not a vuln.

### 6.3 ClaudeLogParser — input caps in place (Pass)

`maxLineBytes = 4 MB`, `maxEvents = 200_000`. ✓

### 6.4 LSPFraming / MCPFraming — bounded (Pass)

- MCP body cap 16 MB (`MCPFraming.swift:35`)
- Header cap 8 KB (`MCPFraming.swift:71`)
- LSPFraming similar (not shown in this pass but mentioned in design)

Solid. ✓

### 6.5 `application(_:open:)` URL handling — no validation of scheme registration (Low / Low)

**Location:** `Sources/MarkdownViewer/main.swift:618-626`

```swift
if url.scheme == "markdownviewer" {
    handleCustomURLScheme(url)
} else if FileManager.default.fileExists(atPath: url.path) {
    model.openPath(url)
}
```

For non-`markdownviewer` schemes, this falls through to `FileManager.fileExists(atPath: url.path)`. For an `https://example.com/foo` URL the `path` is `/foo`, which usually doesn't exist — harmless. But for a malicious `file:///etc/passwd` from `application(_:open:)`, it opens. macOS already requires the user to grant the app the right to be opened with that URL via Finder/Launch Services, so the practical risk is low. Worth adding `guard url.isFileURL` for the fallthrough branch.

---

## 7. Sandboxing / entitlements / signing

### 7.1 Non-sandboxed by design — documented (Pass)

`scripts/entitlements.plist` correctly disables all dangerous opt-outs (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `disable-executable-page-protection` all `false`). ✓

### 7.2 `--entitlements` not applied in dev build (Low / Low)

**Location:** `scripts/build-app.sh:180-194`

The dev `codesign` invocations use `--options runtime` but do **not** pass `--entitlements`. Only the `sign-and-notarize.sh` path applies them. For local dev builds this is benign (hardened runtime defaults are restrictive enough); just worth noting that a TCC issue specific to entitlements wouldn't surface in dev.

### 7.3 TCC-stable bundle id (Pass)

`CFBundleIdentifier = com.markdownviewer.MarkdownViewer` is stable; `CLAUDE.md` explicitly calls out preserving this for TCC grant continuity. ✓

### 7.4 No `NSAppleEventsUsageDescription` (Low / Low)

Apps that trigger AppleScript on remote apps need this. `scheduleAutoSnapshot` and `runScript` paths use `screencapture` indirectly via `DiagnosticDump.captureWindowToPNG` (not shown but referenced). If that ever pivots to `osascript` / scripting bridges, TCC will block silently without the usage description. Note for future.

### 7.5 `LSHandlerRank = Alternate` for all doc types (Pass)

`Info.plist:97, 110, 123, 149` — all `Alternate`, never `Default`. Won't hijack file associations on install. ✓

### 7.6 URL scheme registration — see §1.1

The single biggest risk surface in `Info.plist` is the registered `markdownviewer://` scheme. Removing it (or requiring an `--enable-url-scheme` flag) would eliminate finding #1.1 entirely.

---

## 8. Misc / minor

### 8.1 `MermaidBundle.runtime` — ~2.5 MB JS pulled in at runtime

The JS bundle is loaded from `Bundle.module` (immutable, signed). The risk is a code-injection at *build time* if the JS was modified — out of scope for a runtime security review, but the supply chain for `Sources/ViewerUI/Resources/mermaid/*` should be audited separately.

### 8.2 `runFind` `walkAndMark` JS — regex escaping (Pass)

Line 292 in MarkdownRenderedView.swift: `query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')` — escapes regex metachars before injecting query as a literal RegExp. ✓

### 8.3 Diagnostic SIGUSR1 handler (Low / Low)

`installDiagnosticSignalHandler` (main.swift:538-577) traps SIGUSR1 and dumps state. Any local process with SIGUSR1 capability against the PID can trigger this. Benign — output is to user-owned tmpdir — but mildly noisy if abused.

### 8.4 `model.openFolderInNewSession` closure captures `[weak self]` over `AppDelegate` (Pass)

main.swift:193-195 — correct use of weak self. ✓

### 8.5 `application(_:open:)` & sessions coordinator coexistence (Pass)

Folder opens via NSServices route through `sessions.openFolder`; file opens go through `model.openPath`. Single-writer per actor. ✓

### 8.6 GitClient `discoverRoot` walks up the tree with no max-depth limit (Low / Low)

Line 35-48: a 32-iteration safety limit is present (`for _ in 0..<32`). ✓

### 8.7 LSP `initialize` always passes parent process id (Info-leak, Low / Low)

`LSPClient.swift:343`: `"processId": pid`. The LSP spec mandates this so the server can exit when the parent dies — by design, not a finding.

### 8.8 Strict-concurrency suppression review

Recent commit `4db521d Cleanup: silence strict-concurrency warnings` indicates active work on the Swift 6 model. The patterns I audited (lock-bracketed `nonisolated(unsafe)` statics, `@unchecked Sendable` boxes with documented invariants) are all defensible. Worth a separate sweep specifically for any `@MainActor` annotation that was *removed* in that cleanup commit — those are the high-risk changes.

---

## Quick-win remediation priorities

1. **Disable or gate the `markdownviewer://` URL scheme** (finding #1.1). One-line `Info.plist` change.
2. **Tighten WalkthroughDropTransport**: require `rootHint` at the transport boundary; consider env-gating the whole transport (findings #1.2, #1.4).
3. **Sanitize raw-HTML pass-through** in `HTMLRenderer.visitHTMLBlock`/`visitInlineHTML` instead of relying solely on the inline CSP `<meta>` (finding #2.1).
4. **Add ReDoS guard** around all `NSRegularExpression` evaluations of user input — wrap with a 250ms timeout & cancel (finding #6.1).
5. **Verify LSP binary ownership** before spawning from `~/.npm-global/bin` etc. (finding #3.1).
6. **Symlink check in `EditorWriter.save`** (finding #5.1).

The rest are defense-in-depth / hygiene items.

---

## What I did not deeply review

- **`LSPPool` lifecycle** — actor reaper task, restart backoff, dead-cooldown. Briefly skimmed; worth its own pass.
- **`SidebarModel` cache contract** — called out in DESIGN.md as a historical bug hotspot but orthogonal to security.
- **CodeMirror v1 bridge `CMEditApplier`** — incremental-edit application; correctness rather than security.
- **`SQLiteReader`** — opens user-selected SQLite files. Library-level vulnerabilities in `libsqlite3` (which Apple ships) are out of scope; we don't write to the DB.
- **`HexSearchEngine` / `CSVFilter` / `Formatter`** — pure parsers, no external IO surface.
- **All test code** in `Tests/`.
- **Tree-sitter grammars themselves** — they're parsing untrusted source; vulnerabilities in the parsers would be upstream issues.

---

*End of report.*
