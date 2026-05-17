# LSP_DESIGN.md — Language Server Protocol integration for TextView

> Status: **DESIGN ONLY.** No code is shipped from this document. All code
> blocks are illustrative — function signatures, type sketches, JSON-RPC
> payloads — to pin down the interface contracts before anyone writes a
> single line of `ViewerCore/LSP/*.swift`.
>
> Audience: someone about to land Phase 1 (sourcekit-lsp hover + go-to-def
> + outline) and the reviewer who has to push back on scope creep.
>
> Length: long. This is the canonical reference. If we shorten it later,
> it's because lessons-learned made parts obsolete, not because we got
> bored.

---

## 0. TL;DR

- TextView is a **viewer**. The LSP integration mirrors that: hover,
  go-to-def, find-references, outline (document symbols), workspace
  symbols, diagnostics, semantic tokens, inlay hints. **No completion,
  no formatting, no code actions, no refactor, no edit-derived
  features ever.**
- Architecture: **one LSP process per (workspace-root, language)
  pair**, spawned lazily on first capability request, reaped on
  workspace close + idle-timeout + app shutdown.
- Transport: **JSON-RPC 2.0 over the child's `stdin`/`stdout`** with
  LSP's `Content-Length` framing. `stderr` is captured separately and
  surfaced via a developer diagnostics panel.
- Dependency posture: **prefer building our own client.** ChimeHQ's
  `LanguageClient` / `LanguageServerProtocol` packages exist and are
  the obvious off-the-shelf choice — but pulling them in puts ~25 kLoC
  of third-party code on the supply-chain surface for what is, at the
  protocol layer, a few hundred lines of Codable structs plus a
  framing reader. We **vendor protocol type definitions selectively**
  (LSP 3.17 is stable; the wire format won't change under us) and
  write the client ourselves. Re-evaluate if scope grows past Phase 3.
- Modules: protocol structs + framing + process supervisor + request
  router live in `ViewerCore/LSP/`. UI (hover popovers, outline panel,
  workspace-symbol palette extension) lives in `ViewerUI/LSP/`.
- Phase 1 ships **sourcekit-lsp only**. Other servers come later under
  config-driven onboarding.

---

## 1. Web research — what the field has learned

Order matters: read this section before the design sections. Several
design decisions cite back here by number, e.g. "see §1.4".

### 1.1 LSP is a JSON-RPC 2.0 protocol with a single framing extension

The wire format is plain JSON-RPC 2.0 with one bolt-on: every message
is prefixed by an HTTP-style `Content-Length: N\r\n\r\n` header
followed by exactly `N` bytes of UTF-8 JSON. This framing is **not in
JSON-RPC itself** — it was added by Microsoft when they wrote LSP to
make stream-based transports tractable. There is also an optional
`Content-Type: application/vscode-jsonrpc; charset=utf-8` header that
in practice nobody emits and clients should default to UTF-8 when it's
absent. (Sources: [LSP 3.17 spec § Base Protocol][lsp-3-17],
[emacs-devel jsonrpc.el thread][emacs-jsonrpc].)

Implication for our framing parser: it must be **strictly byte-oriented
on the header section and length-prefixed on the body**. Naive
line-based JSON parsing breaks on payloads that contain embedded `\r\n`
inside strings, which is extremely common in `hover.contents`
(Markdown blocks).

### 1.2 The client owns the server lifecycle

The server is **dumb about its own lifetime**. The client decides:
- when to spawn (typically lazily, on first request for that language)
- when to `shutdown` (a request) followed by `exit` (a notification)
- when to `SIGTERM` if the server didn't respond to `shutdown` in time
- when to `SIGKILL` if the server didn't respond to `SIGTERM` in time

VS Code's `vscode-languageclient` and Zed's `LspStore` both follow this
pattern. (Sources: [VS Code lifecycle][vscode-lifecycle],
[Zed Language Server Lifecycle][zed-lifecycle], [LSP4IJ
lifecycle][lsp4ij-lifecycle].)

Zombie processes are the #1 operational hazard. The OpenCode bug
([opencode#18632][opencode-zombies]) is instructive: their LSP server
leaks on every parent exit because they don't install SIGCHLD reaping
or `prctl(PR_SET_PDEATHSIG)`-equivalent (which doesn't exist on macOS
anyway; we have to use `posix_spawn` + explicit teardown).

### 1.3 Process-per-language is the only sane partition

Both Zed and VS Code spawn **one process per (language, workspace)**.
You don't multiplex multiple languages through one server (no server
supports it), and you don't multiplex multiple workspaces through one
server reliably either (sourcekit-lsp supports `workspaceFolders` but
the support is uneven across servers — see [Swift Forums multi-folder
thread][swift-multiworkspace]).

Practical implication: **the pool key is `(workspace-root, language)`**,
not just `language`. Two windows open on different SwiftPM packages →
two `sourcekit-lsp` processes.

### 1.4 Some LSPs are pleasant; some are not

| Server | Distribution | Spawn cost | Notes |
|---|---|---|---|
| `sourcekit-lsp` | Ships with the Swift toolchain at `xcrun -f sourcekit-lsp`. | Fast (<1 s for index-aware response on a small SwiftPM target). | Tightly coupled to a SwiftPM `Package.swift` root; degrades gracefully on a loose `.swift` file but loses cross-file features. |
| `rust-analyzer` | Single binary, `rustup component add rust-analyzer`, or pre-built download from GitHub releases. | Slow first-index (10–60 s on medium crate; full re-index after `cargo` changes). Reads from `Cargo.toml`. Spawns proc-macro server subprocesses ([rust-analyzer changelog 313][ra-changelog]). | Big RSS (~500 MB–1.5 GB). |
| `gopls` | `go install golang.org/x/tools/gopls@latest`, lands in `$GOPATH/bin`. | Fast. Requires `go.mod` for full workspace mode; module-aware. | Well-behaved client-wise. |
| `typescript-language-server` | npm: `npm i -g typescript-language-server typescript`. Wraps `tsserver`. | Medium; first init reads `tsconfig.json` and walks `node_modules`. | `tsserver` itself crashes occasionally; the wrapper restarts it but the LSP layer needs to handle the gap. ([typescript-language-server][ts-ls].) |
| `pyright` | `npm i -g pyright` or `pip install pyright`. Microsoft. | Fast. Reads `pyproject.toml` / `pyrightconfig.json`. Pretty strict about virtualenv detection — Zed has dedicated `PythonToolchainProvider` logic ([Zed Lang Registry][zed-langregistry]). | |
| `clangd` | Ships with LLVM (`brew install llvm` → `/opt/homebrew/opt/llvm/bin/clangd`) or Xcode CLT (`xcrun -f clangd`). | Fast on a single TU; needs `compile_commands.json` for multi-file projects. | Will silently fall back to header-search-path guessing on a loose file. Usually correct. |
| `jdtls` | Hard. Eclipse JDT-LS distribution is a tarball, must be unpacked, launched via `java -jar ... -configuration ... -data ...`. Needs a JDK 21+. | Slow start (30–90 s). Workspace state lives in `-data <path>` outside the project. | Reject for Phase 1–3. Heavy operational burden disproportionate to a viewer's needs. |

### 1.5 Semantic tokens vs. tree-sitter — we already have tree-sitter

We already ship tree-sitter highlighting in `ViewerCore/Highlight/`
(see `PHASE_5B_TREESITTER.md`). LSP `textDocument/semanticTokens`
would add semantic-aware coloring (e.g. distinguishing a class
reference from a method call), but:

- The protocol is verbose: it ships token deltas as a flat
  `[lineDelta, charDelta, length, tokenType, tokenModifiers]` array
  that has to be re-resolved to ranges client-side. ([LSP 3.17 §
  Semantic Tokens][lsp-semtok].)
- It's per-document and refresh-on-edit, but **we don't edit**, so
  refresh cost is one-shot per `didOpen`.
- It is **slower than tree-sitter** in the common case ([Lambda
  Land tree-sitter vs LSP][ts-vs-lsp]), and you typically run both
  side-by-side: tree-sitter for the synchronous highlight, semantic
  tokens merged in asynchronously when the server replies.

Verdict for TextView: **Phase 2 at the earliest, behind a feature flag.**
Tree-sitter is good enough; semantic tokens are a polish item.

### 1.6 Editors-as-viewers patterns

- **Nova** (Panic): JS-based extension API; LSP support via the
  `LanguageClient` JS class. Ships built-in adapters for clangd,
  sourcekit-lsp, rust-analyzer. ([Nova LanguageClient docs][nova-lsp].)
  Worth borrowing: the **three transports** (stdio, TCP socket, Unix
  Domain Socket) — we'll do stdio only for Phase 1, but the abstraction
  should leave space for socket transports because Java jdtls and
  some Microsoft-internal servers prefer socket-mode.
- **Zed**: Rust, splits `LocalLspStore` (host-side spawning) from
  `RemoteLspStore` (RPC proxy for remote development). Their
  `LspCommand` trait bridges LSP requests with internal
  Anchor-based coordinates ([Zed LSP integration][zed-lsp]). We don't
  need remote-LSP yet, but the **command-trait abstraction is
  exactly right**: every LSP request becomes a strongly-typed
  command with its own params/result, dispatched through the
  process pool.
- **VS Code** (`vscode-jsonrpc` + `vscode-languageclient`): the
  reference implementation. Spawns via `child_process.spawn`, uses
  `StreamMessageReader` / `StreamMessageWriter` on the child's
  stdio. ([vscode-jsonrpc README][vscode-jsonrpc].)

### 1.7 Swift LSP client libraries on the market

| Package | Maintainer | Status | What it gives you |
|---|---|---|---|
| `ChimeHQ/LanguageClient` | Matt Massicotte (Chime editor) | Active. | Higher-level client abstractions: a `JSONRPCServerConnection`, restart-on-crash policy, a "RestartingServer" wrapper. ([ChimeHQ/LanguageClient][lc-repo], [Chime blog][chime-blog].) |
| `ChimeHQ/LanguageServerProtocol` | Same | Active. | Codable LSP 3.17 type definitions — the boring grunt work of writing every `Position` / `Range` / `Hover` / `DocumentSymbol` struct. ([ChimeHQ/LanguageServerProtocol][lsp-repo].) |
| `ChimeHQ/SwiftLSPClient` | Same | **Deprecated.** Split into the two above. | Don't use. |
| `swiftlang/sourcekit-lsp` repo | Apple | Active. | The server, not a client. It does ship an internal `LSPBindings`-style Codable type set, but it's not a public Swift product. Treat as reference reading, not a dependency. |

**Dep decision.** The minimal-deps rule applies. Pros of pulling
`LanguageServerProtocol` (just the types, not the client):

- ~50 well-tested Codable structs that match the spec exactly
- Saves writing `Position`, `Range`, `Location`, `Hover`,
  `DocumentSymbol`, `WorkspaceSymbol`, `Diagnostic`, … by hand
- Author tracks LSP spec changes for us

Cons:

- ~5 kLoC of types we'd be importing for the subset we'd actually use
- Transitive: pulls `JSONRPC` package as well
- Couples us to ChimeHQ's release cadence

**Recommendation: vendor a hand-picked subset of `LanguageServerProtocol`
type definitions** under `Sources/ViewerCore/LSP/Protocol/`, with file
header comments naming the upstream type. We update on demand. **Do
not pull the package as a SwiftPM dep.** This keeps `Package.swift`'s
dependency list short and keeps us in control of when we adopt new
fields. The vendoring is ~20 files; cost-benefit: fine.

> Don't pull `LanguageClient` itself either. The "RestartingServer"
> wrapper is nice but it's 80% of what we'd want and 100% of what we'd
> have to learn — we can write a simpler version that fits our
> request-nonce / actor patterns (LESSONS §"The request-nonce pattern")
> in fewer lines than reading their code to integrate it would take.

---

## 2. Viewer-relevant LSP capabilities

This is the master table. Anything not on it, we don't do.

| Capability | LSP method | Value for a viewer | Phase | Why |
|---|---|---|---|---|
| Hover (types, doc-comments) | `textDocument/hover` | **HIGH** | 1 | Definitive viewer feature. Mouse-over an identifier → see its type and docstring without opening the def. Pure read. |
| Go to definition | `textDocument/definition` | **HIGH** | 1 | Cmd-click / ⌘-click → open the target file in a new tab. Cross-file navigation is the killer viewer feature; without it you're a text viewer not a code viewer. |
| Document symbols (outline) | `textDocument/documentSymbol` | **HIGH** | 1 | New sidebar section. Hierarchical (classes → methods). Click → scroll source to symbol. |
| Find references | `textDocument/references` | **HIGH** | 2 | Cross-file "who uses this?". Result list in a panel similar to CrossSearchPanel. |
| Workspace symbols | `workspace/symbol` | **HIGH** | 2 | Extends the existing command palette: fuzzy-find symbols across the workspace, not just files. |
| Diagnostics | `textDocument/publishDiagnostics` (push) and pull-model `textDocument/diagnostic` | **MEDIUM** | 2 | Read-only signal. Inline gutter underline + a "Problems" sidebar section. Don't try to surface quick-fixes. |
| Semantic tokens | `textDocument/semanticTokens/full` | **MEDIUM** | 3 | Better-than-tree-sitter coloring. Optional, behind a flag, merged into the existing highlight layer asynchronously. |
| Inlay hints | `textDocument/inlayHint` | **MEDIUM** | 3 | Inline type annotations and parameter names. Decorative; useful for reading. |
| Document highlight | `textDocument/documentHighlight` | **LOW** | — | "Highlight other uses of identifier under cursor in same file." We have tree-sitter-driven token highlighting already; LSP adds little. Punt. |
| Code lens | `textDocument/codeLens` | **LOW** | — | Inline "Run | Debug" actions. Edit-adjacent; viewer doesn't want these. Reject. |
| Folding ranges | `textDocument/foldingRange` | **LOW** | — | Probably useful in the long run but we don't even have folding UI yet. Defer behind folding UI work. |
| Selection ranges | `textDocument/selectionRange` | **LOW** | — | Smart-select-expand. Nice-to-have, not needed. |
| Completion | `textDocument/completion` | **NONE** | — | Edit feature. **Reject.** |
| Signature help | `textDocument/signatureHelp` | **NONE** | — | Triggered by typing. **Reject.** |
| Code action | `textDocument/codeAction` | **NONE** | — | Quick-fixes and refactors. **Reject.** |
| Formatting | `textDocument/formatting` etc. | **NONE** | — | We don't write to disk. **Reject.** |
| Refactor (rename) | `textDocument/rename` | **NONE** | — | **Reject.** |
| Linked editing range | `textDocument/linkedEditingRange` | **NONE** | — | **Reject.** |
| Document links | `textDocument/documentLink` | **LOW** | — | Auto-resolves `import` statements to file paths. Marginal; we can do this with regex+filesystem locally. Punt. |
| Type definition / Implementation / Declaration | `textDocument/typeDefinition` / `/implementation` / `/declaration` | **MEDIUM** | 2 | Variants of go-to-definition. Cheap to add once go-to-def is wired. |
| Call hierarchy | `textDocument/prepareCallHierarchy` + `callHierarchy/incomingCalls` etc. | **LOW** | — | Powerful but heavy UI work. Defer. |
| Type hierarchy | `textDocument/prepareTypeHierarchy` etc. | **LOW** | — | Same as above. |
| Moniker | `textDocument/moniker` | **NONE** | — | Cross-repo navigation infra (LSIF). Not relevant. |

**The product rule:** a feature is in scope iff it answers a question of
the form "what is this?" / "where is this defined?" / "where is this
used?". A feature is out of scope iff it answers "how do I change
this?".

---

## 3. Architecture

### 3.1 Module placement

```
ViewerKit/
  LSPLanguage.swift            — enum of supported server kinds (.sourcekitLSP, .rustAnalyzer, …)
                                  + URL-extension → kind mapping.
                                  Pure values; Foundation only.

ViewerCore/
  LSP/
    Protocol/                  — vendored Codable structs (LSP 3.17 subset)
      LSPPosition.swift
      LSPRange.swift
      LSPLocation.swift
      LSPHover.swift
      LSPDocumentSymbol.swift
      LSPWorkspaceSymbol.swift
      LSPDiagnostic.swift
      LSPInitialize.swift
      LSPCapabilities.swift
      LSPSemanticTokens.swift
      LSPInlayHint.swift
      ServerCapabilities.swift
      ClientCapabilities.swift
    Framing/
      ContentLengthReader.swift — byte-oriented header parser + body reader
      ContentLengthWriter.swift — frames outgoing JSON
    Transport/
      ProcessTransport.swift   — Foundation.Process owner + stdin/stdout/stderr Pipes
      MessageStream.swift      — AsyncSequence of inbound JSON-RPC messages
    Client/
      LSPClient.swift          — public actor; the per-server connection
      RequestRouter.swift      — id allocation, pending-request map, response dispatch
      Capabilities.swift       — initialize negotiation, capability cache
      Discovery.swift          — server-binary discovery (xcrun, PATH, NODE_PATH …)
      WorkspaceRootFinder.swift— Package.swift / Cargo.toml / go.mod / pyproject / compile_commands.json
      ServerSpec.swift         — per-language launch recipe (cmd, args, env)
      ServerSpecs/
        SourceKitLSPSpec.swift
        RustAnalyzerSpec.swift
        GoplsSpec.swift
        TypeScriptLSPSpec.swift
        PyrightSpec.swift
        ClangdSpec.swift
    Pool/
      LSPPool.swift            — actor; (root,language) → LSPClient lookup; lifecycle owner
      IdleReaper.swift         — closes idle clients after a TTL
    Errors/
      LSPError.swift           — typed errors: transportFailure, framingError, decodeError, serverError(code), timeout, …

ViewerUI/
  LSP/
    HoverPopover.swift          — NSPopover wrapping an attributed string built from LSP Hover.contents
    HoverTracker.swift          — bridges NSTextView mouse-move → LSPClient.hover
    GoToDefinitionAction.swift  — invoked from menu / Cmd-click; opens result in a new tab
    OutlineSection.swift        — sidebar section displaying DocumentSymbol tree
    ReferencesPanel.swift       — Phase 2; result list in a sliding pane
    DiagnosticsGutter.swift     — Phase 2; underlines + gutter dots
    DiagnosticsSection.swift    — Phase 2; "Problems" list in sidebar
    WorkspaceSymbolSearch.swift — Phase 2; integrates with CommandPaletteView

MarkdownViewer/                 — no LSP code here; AppDelegate calls into LSPPool.shared on app shutdown for graceful teardown
```

Module-boundary check (LESSONS §"Module boundaries"):

- `ViewerKit` gets one tiny addition: an enum of language-kinds. No
  AppKit. No SwiftUI. Good.
- `ViewerCore` does all the LSP work. Imports `Foundation` (Process,
  Pipe, FileHandle, JSONDecoder, URL) and nothing else. **No
  AppKit.** Crucially — and this is a foot-gun — `Foundation.Process`
  works without AppKit, but some convenience initializers and the
  `terminationHandler` semantics differ. Test on a non-AppKit target.
- `ViewerUI` glues to SwiftUI/AppKit. Hover popover is `NSPopover`,
  outline is SwiftUI.

### 3.2 Process-pool data model

```
                      ┌─────────────────────────────────────────┐
                      │ LSPPool (actor, app-singleton)          │
                      │                                         │
                      │   clients: [Key: LSPClient]             │
                      │   Key = (workspaceRoot: URL,            │
                      │          language: LSPLanguage)         │
                      │                                         │
                      │   idleReaper: TimerTask                 │
                      │                                         │
                      └───┬─────────────────────────────────┬───┘
                          │                                 │
              .client(for:URL) async                 .shutdownAll() async
                          │                                 │
              ┌───────────▼────────┐         ┌──────────────▼──────────┐
              │ LSPClient (actor)  │   …N…   │ LSPClient (actor)        │
              │ root: URL          │         │ root: URL                │
              │ language: …        │         │ language: …              │
              │ transport: Process │         │ transport: Process       │
              │ caps: ServerCaps   │         │ caps: ServerCaps         │
              │ openDocs: Set<URL> │         │ openDocs: Set<URL>       │
              │ pending: [ID:Cont] │         │ pending: [ID:Cont]       │
              └────────────────────┘         └──────────────────────────┘
```

#### LSPPool semantics

- **Pool-key lookup:** given a `URL` for a source file, the pool:
  1. determines `LSPLanguage` from extension (via `LSPLanguage.detect(from:)`),
  2. walks up the directory tree to find the workspace root,
  3. composites `Key(root, language)`,
  4. returns the existing `LSPClient` or spawns a new one.
- **Spawn is lazy.** No LSP starts on app launch. A `sourcekit-lsp`
  starts the first time the user hovers over a `.swift` file in a
  given SwiftPM workspace.
- **Eviction is policy-driven.** Three eviction paths:
  - **explicit:** workspace closed → close all clients keyed on its
    root.
  - **idle:** `IdleReaper` walks pool every 60 s; any client with no
    open documents and last-request older than 5 min is shut down.
  - **shutdown:** app `applicationWillTerminate` calls
    `LSPPool.shared.shutdownAll(timeout: 3s)`.

#### LSPClient semantics

- An `actor` (Swift concurrency, not `@MainActor`). All inbound and
  outbound JSON-RPC serialization runs on the actor's executor.
- One `actor` per server process. Methods are async; callers await.
- Owns the child `Process` and its three pipes (`stdin`, `stdout`,
  `stderr`).
- Holds `pending: [LSPRequestID: CheckedContinuation<JSONValue, Error>]`
  for request/response correlation.
- Maintains `serverCapabilities` from the `initialize` response.

### 3.3 Request/response correlation, cancellation, IDs

LSP uses JSON-RPC 2.0 message IDs: numbers or strings, must be unique
per direction. We allocate **monotonically increasing UInt64** IDs and
serialize as numbers. (Don't reset across reconnects; the server only
sees one direction per session.)

```swift
// Sketch — not for shipping
actor LSPClient {
    private var nextID: UInt64 = 1
    private var pending: [LSPRequestID: PendingRequest] = [:]

    struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
        let cancellationToken: LSPCancellationToken
        let startedAt: ContinuousClock.Instant
    }

    func send<R: Decodable>(
        _ method: String,
        params: some Encodable,
        timeout: Duration = .seconds(8)
    ) async throws -> R {
        let id = LSPRequestID(rawValue: nextID); nextID &+= 1
        let token = LSPCancellationToken()

        let raw: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = PendingRequest(
                    method: method,
                    continuation: cont,
                    cancellationToken: token,
                    startedAt: .now)
                Task { try? await writeRequest(id: id, method: method, params: params) }
                Task { try? await armTimeout(id: id, after: timeout) }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }

        return try JSONDecoder.lsp.decode(R.self, from: raw)
    }
}
```

Cancellation: when the caller cancels its `Task`, we send
`$/cancelRequest` to the server **and** resume the continuation with
`LSPError.cancelled`. The spec says cancelled requests still get a
response from the server (typically with error code `-32800`
RequestCancelled) — we discard the late response by checking whether
the ID still lives in `pending`. (Source: [LSP 3.17 § cancelRequest][lsp-cancel].)

Timeouts: per-request budget. Servers can be **really slow** on first
request after spawn (rust-analyzer initial index takes tens of seconds).
The default timeout is per-method:

| Method | Default timeout |
|---|---|
| `initialize` | 30 s |
| `textDocument/hover` | 3 s |
| `textDocument/definition` | 5 s |
| `textDocument/documentSymbol` | 8 s |
| `textDocument/references` | 15 s |
| `workspace/symbol` | 10 s |
| `textDocument/diagnostic` | 8 s |
| `shutdown` | 3 s |

Timeouts apply *per call*, not lifetime. Hover timeouts after spawn
should retry once after a 500 ms backoff; if the second attempt also
times out, the hover popover shows "(no LSP response)" and we don't
spam more.

### 3.4 Spawn discipline — the zombie hazard

This is where prior art has the most scars. Three layers of defense:

1. **Child setup.** We use `Foundation.Process` (the modern
   `swift-subprocess` package is still in proposal; not stable enough
   to depend on — [SE proposal 0007][subprocess-proposal]). Set:
   - `executableURL` to the resolved binary (no `$SHELL` wrappers,
     no `bash -c`).
   - `arguments` to the per-server arg list.
   - `currentDirectoryURL` to the workspace root (sourcekit-lsp
     and rust-analyzer both read CWD).
   - `environment` to a sanitized environment plus a few required
     vars per server.
   - `standardInput` / `standardOutput` / `standardError` each to a
     fresh `Pipe()`.

2. **Reader tasks.** Two structured `Task`s started immediately after
   `run()`:
   - **stdout reader:** loops on `availableData` reading framed
     messages, decodes them, dispatches to the actor.
   - **stderr reader:** drains into a ring buffer for the dev-diagnostics
     panel. If we don't drain stderr, the child blocks on `write` once
     the kernel pipe buffer fills (~64 KB on macOS).

3. **Termination policy.** When closing a client:
   ```
   step 1: send `shutdown` request, await response with 3 s timeout
   step 2: send `exit` notification (no response)
   step 3: wait for SIGCHLD up to 1 s
   step 4: if still alive, SIGTERM, wait up to 1 s
   step 5: if still alive, SIGKILL, wait up to 500 ms
   step 6: close stdin/stdout/stderr pipes; cancel reader Tasks; release
   ```
   Each transition logs at info level so we can spot a hung server.

4. **Crash watcher.** `Process.terminationHandler` fires when the child
   exits regardless of cause. We use it to:
   - resume every pending continuation with `LSPError.serverCrashed`,
   - decide whether to restart (only if the crash happened more than 10 s
     after spawn; faster crashes are taken as "this server doesn't
     work on this project" and we don't loop),
   - never auto-restart more than 3 times in a 60 s window (matches the
     ChimeHQ `RestartingServer` heuristic).

5. **At-process-exit cleanup.** Register an `atexit` C handler? No —
   `atexit` doesn't fire during SIGKILL of our own process. Instead:
   - `AppDelegate.applicationWillTerminate` calls
     `LSPPool.shared.shutdownAll(timeout: .seconds(3))`.
   - For the SIGKILL case (`kill -9` or crash of TextView itself),
     orphaned LSP children inherit `init` as parent. macOS doesn't
     have `prctl(PDEATHSIG)`. **Mitigation:** on each LSPPool
     startup, scan `ps` for sourcekit-lsp / rust-analyzer / etc. with
     **no living parent matching our bundle identifier**, prompt the
     user before reaping. Or simpler: just leave them; macOS users
     can spot them in Activity Monitor. We'll revisit if this becomes
     a real complaint.

### 3.5 The full request lifecycle, end-to-end

Walking through `User cmd-clicks an identifier`:

```
NSTextView (mouseDown w/ Cmd)
    │
    ▼  computes (line, col) under the click
GoToDefinitionAction.invoke(url, line, col)
    │
    ▼  await
LSPPool.shared.client(for: url)
    │
    │   if no client cached: resolve language, find root, spawn
    │
    ▼
LSPClient.ensureDocumentOpen(url)
    │
    │   if first reference: send textDocument/didOpen with file contents
    │
    ▼
LSPClient.send("textDocument/definition", params: { textDocument: {uri:...}, position: {line, character} })
    │
    │   writes Content-Length-framed JSON to child stdin
    │   adds id → continuation to pending
    │   ChildProcess produces JSON-RPC response on stdout
    │   reader Task decodes, finds id in pending, resumes continuation
    │
    ▼  returns [LSPLocation] (one or more files + ranges)
GoToDefinitionAction
    │
    │   if 0 results: HUD "no definition"
    │   if 1 result : open in new tab, scroll-to-line
    │   if N results: show picker popover
    │
    ▼
DocumentController.openTab(url, scrollTo: line)
```

### 3.6 Document open / close synchronization

**Question: do we send `didOpen`?**

LSP says `textDocument/didOpen` puts a buffer in "managed" state and
the server treats the client as the source of truth for that file's
contents. If we just want to hover on disk content, we *could* try
running without didOpen — but most servers (sourcekit-lsp,
rust-analyzer, typescript-language-server) **return empty / no-result
on any textDocument/* request for a file not opened via didOpen**.

So: yes, we send `didOpen` lazily on first capability request for a
file, with the file's on-disk contents. We do **not** send `didChange`
(the viewer doesn't change the file). When the user closes the tab, we
send `didClose`.

A subtlety: if the file changes on disk while we have it open in the
LSP (file watcher fires), we must:
- re-read the file,
- send `textDocument/didChange` with `text` = whole new contents
  (using `TextDocumentSyncKind.Full`),
- bump `version` monotonically.

This is the *only* place `didChange` shows up in TextView. It's a sync,
not an edit.

### 3.7 Capability negotiation

We send `initialize` with a precisely curated `ClientCapabilities`. We
**deliberately do not advertise**:

- `textDocument.completion`
- `textDocument.signatureHelp`
- `textDocument.codeAction`
- `textDocument.formatting`, `rangeFormatting`, `onTypeFormatting`
- `textDocument.rename`
- `textDocument.linkedEditingRange`
- `textDocument.codeLens`
- `workspace.applyEdit`

The server gets the message: this client can't accept edits. Some
servers (rust-analyzer especially) reduce their workload accordingly.

We advertise:

```jsonc
{
  "processId": <pid>,
  "clientInfo": {"name": "TextView", "version": "0.x"},
  "rootUri": "file:///abs/path/to/workspace",
  "workspaceFolders": [{"uri": "file:///...", "name": "..."}],
  "capabilities": {
    "general": {
      "positionEncodings": ["utf-16", "utf-8"]
    },
    "textDocument": {
      "synchronization": {
        "dynamicRegistration": false,
        "willSave": false,
        "willSaveWaitUntil": false,
        "didSave": false
      },
      "hover": {
        "dynamicRegistration": false,
        "contentFormat": ["markdown", "plaintext"]
      },
      "definition":      { "dynamicRegistration": false, "linkSupport": true },
      "typeDefinition":  { "dynamicRegistration": false, "linkSupport": true },
      "implementation":  { "dynamicRegistration": false, "linkSupport": true },
      "references":      { "dynamicRegistration": false },
      "documentSymbol":  {
        "dynamicRegistration": false,
        "hierarchicalDocumentSymbolSupport": true,
        "symbolKind": { "valueSet": [/* full SymbolKind enum */] }
      },
      "publishDiagnostics": {
        "relatedInformation": true,
        "versionSupport": true,
        "tagSupport": { "valueSet": [1, 2] }
      },
      "semanticTokens": {
        "dynamicRegistration": false,
        "requests": { "range": false, "full": { "delta": false } },
        "tokenTypes": [/* per LSP spec */],
        "tokenModifiers": [/* per LSP spec */],
        "formats": ["relative"]
      },
      "inlayHint": { "dynamicRegistration": false }
    },
    "workspace": {
      "workspaceFolders": true,
      "symbol": {
        "dynamicRegistration": false,
        "symbolKind": { "valueSet": [/* full */] }
      },
      "configuration": true,
      "didChangeConfiguration": { "dynamicRegistration": false }
    }
  },
  "initializationOptions": <server-specific>,
  "trace": "off"
}
```

The `positionEncodings` field is important and **easy to miss**.
LSP positions are by default UTF-16 code units (because the protocol
was designed for VS Code, whose buffer is UTF-16). Swift's `String`
indexing is grapheme-cluster-based by default. We must convert
positions between UTF-16 and our internal representation at the
boundary. (Some newer servers support `utf-8` and `utf-32`; if the
server says it supports `utf-8` we'll prefer that to skip the
conversion.)

### 3.8 Workspace-root detection

Per-language root markers:

| Language | Root marker(s) | Fallback |
|---|---|---|
| Swift | `Package.swift` walking up; else `.xcodeproj` / `.xcworkspace` | Loose-file mode (sourcekit-lsp will still respond, with reduced fidelity) |
| Rust | `Cargo.toml` walking up to the *outermost* one (workspace root) | None — refuse to start |
| Go | `go.mod` walking up | Loose-file mode |
| TypeScript/JavaScript | `tsconfig.json` / `jsconfig.json` / `package.json` walking up | Loose-file mode |
| Python | `pyproject.toml` / `setup.py` / `setup.cfg` / `Pipfile` walking up | Loose-file mode |
| C/C++ | `compile_commands.json` (most reliable) / `CMakeLists.txt` / `Makefile` | Loose-file mode |

The walker stops at the user's home directory or at a `.git` boundary
to avoid pulling in a parent monorepo by accident. The `.git` check is
load-bearing — if you walk past it you can end up with a sourcekit-lsp
spanning a 50-package monorepo.

### 3.9 Concurrency model summary

```
┌────────────────────────────────────────────────────────────────────┐
│ MainActor                                                          │
│   - SwiftUI views                                                  │
│   - NSTextView event delivery                                      │
│   - Hover popover                                                  │
│   - Outline sidebar                                                │
│       └── await LSPPool.shared.client(...).documentSymbols(uri)    │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
                          ▼ Task hop
┌────────────────────────────────────────────────────────────────────┐
│ LSPPool (actor) — global isolation domain for pool state           │
│   - lookup / insert / remove clients                               │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────────┐
│ LSPClient (actor) — one per server, isolates pending requests +    │
│                     transport writes                               │
│                                                                    │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ stdout reader Task — owns ContentLengthReader; pushes       │  │
│   │   decoded messages into actor via async method calls        │  │
│   └─────────────────────────────────────────────────────────────┘  │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │ stderr reader Task — drains into ring buffer for dev panel  │  │
│   └─────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

Sendable boundaries:
- `LSPLanguage`, `LSPRequestID`, all `LSPProtocol/*` Codable types →
  `Sendable` by construction (value types, all stored properties
  Sendable). Mark them `Sendable` explicitly.
- `LSPClient` and `LSPPool` are actors → automatically Sendable.
- `LSPClientHandle` (a non-actor facade we hand to UI code) wraps a
  weak reference to an actor + a Sendable identifier. Sendable.

---

## 4. Swift types — interface sketch

These are not implementations. They're the **shape** of the public
contract `ViewerCore/LSP/` exposes to `ViewerUI/LSP/`.

### 4.1 Public types

```swift
// ViewerKit/LSPLanguage.swift
public enum LSPLanguage: String, Sendable, CaseIterable {
    case sourcekitLSP        // .swift
    case rustAnalyzer        // .rs
    case gopls               // .go
    case typescriptLanguageServer  // .ts, .tsx, .js, .jsx
    case pyright             // .py
    case clangd              // .c, .cpp, .h, .hpp, .m, .mm
    // jdtls explicitly excluded — see §1.4

    public static func detect(from url: URL) -> LSPLanguage? {
        switch url.pathExtension.lowercased() {
        case "swift":                                return .sourcekitLSP
        case "rs":                                   return .rustAnalyzer
        case "go":                                   return .gopls
        case "ts","tsx","js","jsx","mjs","cjs":      return .typescriptLanguageServer
        case "py","pyi":                             return .pyright
        case "c","cc","cpp","cxx","h","hpp","hh","m","mm": return .clangd
        default: return nil
        }
    }
}
```

```swift
// ViewerCore/LSP/Client/LSPPool.swift
public actor LSPPool {
    public static let shared = LSPPool()

    public func client(for url: URL) async throws -> LSPClient? {
        // returns nil if no language is associated, throws on spawn failure
    }

    public func shutdownAll(timeout: Duration) async
    public func closeWorkspace(rootedAt: URL) async
}
```

```swift
// ViewerCore/LSP/Client/LSPClient.swift
public actor LSPClient {
    public let language: LSPLanguage
    public let workspaceRoot: URL
    public let serverCapabilities: ServerCapabilities

    // High-level capability methods. Each is a thin wrapper over
    // .send(method:params:) that constructs the params, decodes the
    // response, and converts positions.

    public func hover(at url: URL, line: Int, character: Int)
        async throws -> LSPHover?

    public func definition(at url: URL, line: Int, character: Int)
        async throws -> [LSPLocation]

    public func typeDefinition(at url: URL, line: Int, character: Int)
        async throws -> [LSPLocation]

    public func implementation(at url: URL, line: Int, character: Int)
        async throws -> [LSPLocation]

    public func references(at url: URL, line: Int, character: Int,
                           includeDeclaration: Bool)
        async throws -> [LSPLocation]

    public func documentSymbols(in url: URL)
        async throws -> [LSPDocumentSymbol]

    public func workspaceSymbols(query: String)
        async throws -> [LSPWorkspaceSymbol]

    public func diagnostics(for url: URL)
        async throws -> [LSPDiagnostic]

    public func semanticTokens(for url: URL)
        async throws -> LSPSemanticTokens?

    public func inlayHints(for url: URL, range: LSPRange)
        async throws -> [LSPInlayHint]

    // Internal — document sync. UI code never calls these directly;
    // they're invoked by the higher-level methods above.
    internal func ensureDocumentOpen(_ url: URL) async throws
    internal func notifyDidChange(_ url: URL, newContents: String) async throws
    internal func notifyDidClose(_ url: URL) async throws

    // Lifecycle
    internal func initialize() async throws
    internal func shutdown() async
}
```

```swift
// ViewerCore/LSP/Protocol/* (vendored Codable subset)
public struct LSPPosition: Codable, Hashable, Sendable {
    public let line: Int        // 0-indexed
    public let character: Int   // 0-indexed in the server's positionEncoding
}

public struct LSPRange: Codable, Hashable, Sendable {
    public let start: LSPPosition
    public let end:   LSPPosition
}

public struct LSPLocation: Codable, Hashable, Sendable {
    public let uri: String      // file:// URI
    public let range: LSPRange
}

public struct LSPHover: Codable, Sendable {
    public let contents: HoverContents
    public let range: LSPRange?

    public enum HoverContents: Codable, Sendable {
        case markedString(String)        // legacy {language, value} or string
        case markupContent(kind: String, value: String) // {kind: "markdown"|"plaintext", value}
        case array([MarkedString])
    }
}

public struct LSPDocumentSymbol: Codable, Sendable {
    public let name: String
    public let detail: String?
    public let kind: Int                 // SymbolKind enum (1=File, 5=Class, 6=Method, …)
    public let tags: [Int]?              // 1=Deprecated
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [LSPDocumentSymbol]?
}

public struct LSPWorkspaceSymbol: Codable, Sendable {
    public let name: String
    public let kind: Int
    public let location: WorkspaceSymbolLocation
    public let containerName: String?

    public enum WorkspaceSymbolLocation: Codable, Sendable {
        case full(LSPLocation)
        case uriOnly(uri: String)        // workspaceSymbol/resolve form
    }
}

public struct LSPDiagnostic: Codable, Sendable {
    public let range: LSPRange
    public let severity: Int?            // 1=Error, 2=Warning, 3=Info, 4=Hint
    public let code: DiagnosticCode?
    public let codeDescription: CodeDescription?
    public let source: String?
    public let message: String
    public let tags: [Int]?              // 1=Unnecessary, 2=Deprecated
    public let relatedInformation: [DiagnosticRelatedInformation]?
}
```

### 4.2 Error type

```swift
public enum LSPError: Error, Sendable {
    case noLanguageForURL(URL)
    case noWorkspaceRoot(URL)
    case serverBinaryNotFound(LSPLanguage, searched: [URL])
    case spawnFailed(LSPLanguage, underlying: Error)
    case transportFailure(String)
    case framingError(String)
    case decodeError(method: String, underlying: Error)
    case serverError(code: Int, message: String, data: Data?)   // JSON-RPC error
    case timeout(method: String, after: Duration)
    case cancelled(method: String)
    case serverCrashed(exitCode: Int32, signal: Int32?, stderrTail: String)
    case capabilityNotSupported(method: String)
    case clientShuttingDown
}
```

### 4.3 Request router internals

```swift
internal struct LSPRequestID: Hashable, Sendable {
    public let rawValue: UInt64
}

internal struct OutgoingMessage: Encodable {
    let jsonrpc: String = "2.0"
    let id: LSPRequestID?            // nil for notifications
    let method: String
    let params: AnyEncodable?
}

internal struct IncomingMessage: Decodable {
    let jsonrpc: String
    let id: LSPRequestID?            // present on responses and server→client requests
    let method: String?              // present on notifications and server→client requests
    let result: JSONValue?
    let error: ResponseError?
    let params: JSONValue?
}

internal struct ResponseError: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}
```

### 4.4 Framing — `ContentLengthReader`

```swift
internal actor ContentLengthReader {
    private let fileHandle: FileHandle
    private var buffer: Data = Data()
    private static let maxHeaderBytes = 4096
    private static let maxBodyBytes   = 16 * 1024 * 1024   // 16 MB hard cap

    init(fileHandle: FileHandle) { self.fileHandle = fileHandle }

    /// Returns the next frame's body bytes, or nil at EOF.
    func nextMessage() async throws -> Data? {
        // 1. Read until we have "\r\n\r\n" in the buffer.
        // 2. Parse header lines: each "Key: Value\r\n".
        //    - Require Content-Length (Int >= 0). Reject if missing.
        //    - Tolerate Content-Type (we ignore it; reject if charset
        //      != utf-8 or unspecified).
        //    - Reject any unknown header at strict mode? No — log and
        //      proceed. Robust client wins.
        // 3. Read exactly Content-Length bytes of body.
        // 4. Return body Data (caller decodes as JSON).
        // Throws LSPError.framingError on any spec violation.
    }
}
```

Invariants the parser must hold:

- Header section is **strict 7-bit ASCII**. Any byte > 0x7F → reject.
  (Servers do not put non-ASCII in headers; if you see one, the stream
  is desynced.)
- `Content-Length` is **mandatory**. Without it, drop the connection
  ([LSP4j #210][lsp4j-malformed-bug]).
- Body is decoded as UTF-8. Invalid UTF-8 → `LSPError.framingError`.
- Body length capped at 16 MB. A 50 MB hover response is a bug, not a
  feature — fail hard.

### 4.5 Open-question type: position encoding

```swift
internal enum PositionEncoding: String, Sendable {
    case utf8  = "utf-8"
    case utf16 = "utf-16"
    case utf32 = "utf-32"
}

internal struct PositionConverter {
    /// Convert a (line, utf16-character) LSP position into a Swift
    /// String.Index. Reads the line from `text` and walks `utf16` units.
    func swiftIndex(forLSPPosition pos: LSPPosition,
                    in text: String,
                    serverEncoding: PositionEncoding) -> String.Index?

    /// Inverse: given a Swift String.Index, produce the LSP position.
    func lspPosition(forSwiftIndex idx: String.Index,
                     in text: String,
                     serverEncoding: PositionEncoding) -> LSPPosition
}
```

This is the **single most subtle correctness bug class** in LSP clients.
Get it wrong → hover popovers point at the wrong identifier for any
line containing an emoji or non-BMP character. The tests in §9 must
include emoji-containing lines.

---

## 5. UI integration points (`ViewerUI/LSP/`)

### 5.1 Hover popover

**Trigger:** mouse hover over an identifier in `SourceTextController`'s
NSTextView, paused for ≥400 ms (configurable). Same idea as Xcode's
hover-delay.

**Implementation outline:**

- `HoverTracker` is an `NSResponder` mouse-tracking helper attached
  to the NSTextView. It debounces mouse-move with a 400 ms timer.
- On debounce fire, it computes `(URL, line, character)` from the
  current mouse position via `NSTextView.characterIndexForInsertion(at:)`
  → string index → line/character.
- Calls `await LSPPool.shared.client(for: url)?.hover(...)`.
- On result: builds an `NSAttributedString` from `LSPHover.contents`
  (re-using our existing Markdown renderer in `HTMLRenderer` or
  via `swift-markdown`'s renderer if simpler) and shows in an
  `NSPopover` anchored to the identifier's rect.

**Risks:**

- Don't trigger a hover request for every mouse move. Debounce hard.
- Cancel the in-flight request when the mouse moves to a new identifier.
- If the popover is currently shown, dismiss-and-reshow with a 100 ms
  guard to avoid jitter when crossing whitespace.

**Compositor caveat (LESSONS §"compositor bug"):** NSPopover lives in
its own window, not in the SwiftUI view tree. It does not affect the
NSScrollView tile chain. **Safe.**

### 5.2 Go-to-definition

**Trigger:**

- Cmd-click on identifier (mouse).
- Menu command "Go → Jump to Definition" (⌃⌘J in Xcode, we'll match).
- Right-click context menu "Jump to Definition".

**Result handling:**

- 0 locations → status-bar message: "no definition found".
- 1 location → open in **new tab** (per existing tab semantics) at
  the target line and column. Scroll-to-line uses the existing
  request-nonce pattern (LESSONS §"request-nonce").
- N locations → popover with a picker; clicking an entry opens it.

The "open in new tab" path goes through the existing
`DocumentController.openTab(_:scrollTo:)` API. If the file is
**already open**, switch to that tab and scroll. If it's outside
the workspace root, open it anyway (sourcekit-lsp will return SDK
files for stdlib references — `Swift.swiftinterface` and friends).

### 5.3 Outline panel (document symbols)

**Where:** a new sidebar section in `SidebarView.swift`. Sits below
the existing tree, above MetadataPanel. Collapsible.

**Data flow:**

- When the active document changes or its content reloads (file
  watcher), call `client.documentSymbols(in: url)`.
- Result is a tree of `LSPDocumentSymbol`. Render with `OutlineGroup`
  (SwiftUI native; renders trees, supports lazy expansion).
- Click a symbol → scroll source view to its `selectionRange`.

**SwiftUI specifics:**

```swift
struct OutlineSection: View {
    @ObservedObject var model: DocumentModel
    @State private var symbols: [LSPDocumentSymbol] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Section("Outline") {
            if symbols.isEmpty {
                Text("No symbols").foregroundStyle(.secondary)
            } else {
                OutlineGroup(symbols, children: \.children) { symbol in
                    OutlineRow(symbol: symbol) {
                        model.scrollSourceTo(line: symbol.selectionRange.start.line)
                    }
                }
            }
        }
        .task(id: model.currentURL) { await loadSymbols() }
    }
}
```

**Caveats:**

- `OutlineGroup` uses `LazyVStack` internally — no allocation of huge
  arrays per body re-eval (LESSONS §"ForEach(stride.map)" warning).
- Identity: `LSPDocumentSymbol` doesn't have a stable ID across reloads.
  We'll hash on `(name, kind, range.start)` for `Identifiable`.
- `OutlineGroup` does **not** trigger NSScrollView reentrancy
  (LESSONS §"compositor bug") because it's pure SwiftUI inside a
  SwiftUI sidebar. **Safe.**

### 5.4 Workspace symbols → command palette

The existing `CommandPaletteView` is fuzzy-find by filename. We
extend it: typing a prefix like `#` or `@` (steal Slack semantics)
switches to symbol-search mode.

```
⌘P "User"             → file-name search
⌘P "@User"            → workspace symbol search via LSP
⌘P "#initialize"      → also workspace symbol, alt prefix
```

**Implementation:**

- `CommandPaletteView` keeps existing file-name index in memory.
- On `@` / `#` prefix detection, switches data source to
  `WorkspaceSymbolSearch` which does:
  ```swift
  func search(_ q: String) async -> [LSPWorkspaceSymbol] {
      // For every active workspace root + language, query each LSP.
      // Merge, dedupe by (uri, range.start, name), fuzzy-rank.
  }
  ```
- The fuzzy-rank uses our existing `FuzzyMatcher` for client-side
  scoring on top of whatever the server returns.
- Server-side cancellation: typing fires a new query on each
  keystroke (debounced 80 ms); previous queries are cancelled via
  `$/cancelRequest`.

### 5.5 Diagnostics (Phase 2)

Two surfaces:

1. **Inline:** wavy underlines in the source view via NSTextStorage
   temporary attributes. Severity → color (red error, yellow warn,
   blue info, gray hint).
2. **Sidebar:** "Problems" section, list of `LSPDiagnostic` across
   all open files. Click → jump to range.

**Wire model:** servers either push diagnostics via
`textDocument/publishDiagnostics` notifications **or** require pull
via `textDocument/diagnostic`. Capability negotiation tells us which.
We support both:

- **Push:** install a notification handler on the client; on receipt,
  store in `DocumentModel.diagnostics[uri]` and signal the source view
  + sidebar.
- **Pull:** request-and-cache on didOpen + on every external file
  change (file watcher) + on demand (user presses "refresh").

### 5.6 Semantic tokens (Phase 3, optional)

Merged into the existing tree-sitter highlight pipeline. Tree-sitter
runs synchronously on every change; semantic tokens are requested
async and overlay on top once they arrive. If the server is slow or
unresponsive, tree-sitter's output stands. (See [Zed Semantic
Tokens][zed-semtok] for the pattern.)

---

## 6. Per-language config

Live data — keep up to date. Table is the spec; `ServerSpec` files
implement it.

| Server | Language(s) | Install command (macOS) | Default spawn command | Root marker | Init options worth setting |
|---|---|---|---|---|---|
| `sourcekit-lsp` | Swift | Ships with Swift toolchain. Find via `xcrun -f sourcekit-lsp`. | `sourcekit-lsp` (no args; reads `SOURCEKIT_LOGGING` env) | `Package.swift` (walk up) | `{"swiftPM": {}}` — optional toolchain override |
| `rust-analyzer` | Rust | `rustup component add rust-analyzer` *or* `brew install rust-analyzer`. Resolve via `rustup which rust-analyzer` first, fall back to `$PATH`. | `rust-analyzer` (no args) | `Cargo.toml` (walk to outermost) | `{"checkOnSave": {"enable": false}, "procMacro": {"enable": true}}` — viewer doesn't need cargo check |
| `gopls` | Go | `go install golang.org/x/tools/gopls@latest`. Resolve via `$(go env GOPATH)/bin/gopls`. | `gopls` (no args; or `-mode=stdio` redundantly) | `go.mod` (walk up) | `{"usePlaceholders": false, "completionDocumentation": false}` (we don't use them anyway) |
| `typescript-language-server` | TS/JS | `npm i -g typescript-language-server typescript`. Resolve via `$(npm bin -g)/typescript-language-server` — but `npm bin` is deprecated, use `npm root -g` parent. | `typescript-language-server --stdio` | `tsconfig.json` / `jsconfig.json` / `package.json` (walk up) | `{"hostInfo": "TextView"}` |
| `pyright` | Python | `npm i -g pyright` (preferred — bundled binary) or `pip install pyright`. | `pyright-langserver --stdio` | `pyproject.toml` / `setup.py` / `pyrightconfig.json` (walk up) | `{"python": {"venvPath": "<detected>"}}` — needs venv discovery |
| `clangd` | C/C++/ObjC | `brew install llvm` → `/opt/homebrew/opt/llvm/bin/clangd`, or `xcrun -f clangd`. | `clangd --background-index --clang-tidy=false --completion-style=detailed` (we don't use completions but the flag is harmless) | `compile_commands.json` / `.clangd` / `CMakeLists.txt` | none |
| `jdtls` | Java | **Reject for Phase 1–3.** | n/a | n/a | n/a |

**Binary discovery strategy** (in `Discovery.swift`):

1. **Per-user override:** check `~/Library/Application Support/TextView/lsp.json`
   for an explicit path. (Plugin/hackability hook — see HACKABILITY.md.)
2. **xcrun:** for sourcekit-lsp, clangd, try `xcrun -f <tool>`. This
   resolves against the active Xcode/CLT.
3. **$PATH:** fall back to `which`-style lookup. Augment `$PATH` with
   common install locations the user's GUI shell won't see:
   `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`,
   `~/go/bin`, `~/.local/bin`.
4. **rustup:** for rust-analyzer, prefer `rustup which rust-analyzer`
   so the resolved binary matches the active toolchain.
5. **npm global root:** for typescript-language-server, pyright,
   query `npm root -g` once at startup, cache.

If discovery fails: throw `LSPError.serverBinaryNotFound` with the
searched paths, and **surface a one-line status-bar warning** with a
"How to install" link to a docs page. Don't pop a modal.

---

## 7. Phased rollout

### Phase 1 (target: 1–2 weeks of work)

**Scope:** sourcekit-lsp only. Three capabilities: hover, go-to-def,
document-symbol outline.

**Acceptance criteria:**

- Hovering an identifier in any `.swift` file inside a SwiftPM
  package opens a popover with type info, within 600 ms.
- Cmd-click jumps to the definition, opens in a new tab.
- Sidebar shows a hierarchical outline that scrolls the source on click.
- Closing a workspace cleanly shuts the LSP (no zombie in
  `ps aux | grep sourcekit-lsp`).
- App force-quit (`kill -9`) leaves at most one orphaned sourcekit-lsp
  (no crash loop, no rapid respawn).

**Out of scope for Phase 1:**

- Diagnostics
- Semantic tokens
- Workspace symbols
- Find references
- Any non-Swift language

**Files touched (estimate):**

```
NEW:  Sources/ViewerKit/LSPLanguage.swift
NEW:  Sources/ViewerCore/LSP/Protocol/{15 files, ~600 LoC}
NEW:  Sources/ViewerCore/LSP/Framing/{2 files, ~150 LoC}
NEW:  Sources/ViewerCore/LSP/Transport/{2 files, ~120 LoC}
NEW:  Sources/ViewerCore/LSP/Client/{6 files, ~600 LoC}
NEW:  Sources/ViewerCore/LSP/Pool/{2 files, ~200 LoC}
NEW:  Sources/ViewerCore/LSP/ServerSpecs/SourceKitLSPSpec.swift (~80 LoC)
NEW:  Sources/ViewerUI/LSP/HoverPopover.swift (~150 LoC)
NEW:  Sources/ViewerUI/LSP/HoverTracker.swift (~100 LoC)
NEW:  Sources/ViewerUI/LSP/GoToDefinitionAction.swift (~80 LoC)
NEW:  Sources/ViewerUI/LSP/OutlineSection.swift (~120 LoC)
MOD:  Sources/ViewerUI/SidebarView.swift  (add OutlineSection)
MOD:  Sources/ViewerUI/DocumentModel.swift (LSP-derived state)
MOD:  Sources/ViewerUI/TextDisplayView.swift (HoverTracker + Cmd-click)
MOD:  Sources/MarkdownViewer/AppDelegate.swift (shutdownAll on terminate)
NEW:  Tests/ViewerCoreTests/LSPFramingTests.swift
NEW:  Tests/ViewerCoreTests/LSPMockServerTests.swift
```

### Phase 2 (target: another 1–2 weeks after Phase 1 lands)

**Scope:** workspace symbols, find-references, diagnostics, add
rust-analyzer and gopls.

**Acceptance criteria:**

- `⌘P @<name>` returns workspace-symbol matches from sourcekit-lsp
  within 800 ms.
- Cmd-Option-F on an identifier opens a references panel.
- Diagnostics underline appears within 2 s of opening a file with
  errors.
- rust-analyzer spawns successfully on a `Cargo.toml`-rooted project.
- gopls spawns on `go.mod`-rooted project.

### Phase 3 (target: future)

**Scope:** typescript-language-server, pyright, clangd, semantic
tokens, inlay hints.

Treat as separate engineering reviews; the architecture should
accommodate them without churn.

### Phase 4 (NEVER)

`jdtls`, completion, formatting, refactor, edit-derived features.
This row exists to point at when scope creep tries to climb back in.

---

## 8. Risk + reject list

Read this before changing any rule below.

### 8.1 Hard rejects — out of scope by product mandate

- ❌ **No completion.** The viewer doesn't accept keystrokes into source.
- ❌ **No signature help.** Same.
- ❌ **No formatting.** We don't write to the file.
- ❌ **No code actions / quick-fixes.** No edit surface.
- ❌ **No rename / refactor.** Same.
- ❌ **No on-type formatting.** Same.
- ❌ **No `applyEdit` workspace edits ever.** If a server sends one,
   we politely reject with a JSON-RPC error.

### 8.2 Soft rejects — feasible but punted

- ⚠ **Code lens.** Could show "5 references" inline. Belongs to
  "show me uses" which we already cover via find-references; not
  worth the gutter complexity.
- ⚠ **Document highlight.** Tree-sitter already handles
  same-identifier highlighting locally.
- ⚠ **Folding ranges.** Folding UI doesn't exist; can't preview a
  hidden feature.
- ⚠ **Call hierarchy + Type hierarchy.** Powerful, but disproportionate
  UI work for a viewer.

### 8.3 Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Zombie LSP processes after crash | High | Medium (resource leak) | §3.4: terminate ladder + crash watcher + at-startup orphan detection |
| LSP binary not found / mis-resolved | High | Low (degraded UX) | §6: layered discovery; per-user override; status-bar warning, no modal |
| Slow first-request after spawn (rust-analyzer) | High | Medium | §3.3: per-method timeouts; UI shows "indexing…" hint; retries gated |
| Server returns malformed JSON / non-spec output | Medium | Medium | §4.4: strict framing; §4.2 decode-error path with telemetry; never crash the client |
| Position encoding mismatch (UTF-16 vs Swift indices) | Medium | High (silent wrong-data bugs) | §4.5: PositionConverter; emoji-containing tests are mandatory |
| Long hover responses lock the popover | Low | Low | §3.3: hover timeout 3 s; show partial popover after 100 ms if response in flight |
| Reentrancy with NSScrollView compositor (LESSONS) | Low (LSP doesn't touch ruler) | High | UI integration uses NSPopover (separate window) + SwiftUI OutlineGroup (no NSRulerView). Visual regression test extended to cover outline-on. |
| Workspace root mis-detected (monorepo) | Medium | Medium | §3.8: `.git`-boundary stop; user override |
| pyright virtualenv detection wrong | Medium | Low | Phase 3; reuse Zed-style toolchain provider; default to "no venv" with a one-click override |
| LSP child writes to stderr indefinitely | Low | Medium (pipe blocks → child hangs) | §3.4 layer 2: dedicated stderr drain Task, ring-buffer cap |
| 16 MB+ JSON response from server | Low | High (OOM) | §4.4: framing hard cap; server response > cap → fail request, log, disconnect-and-restart |
| stdin write blocks under back-pressure | Low | Medium | stdin pipe write happens on a `Task.detached` so the actor doesn't block; bounded outgoing queue with drop-on-overflow for notifications, never for requests |
| Stale completions if user reopens fast | Low | Low | We don't ship completion 😉 |
| Server sends server→client request we don't handle | Medium | Low | Always respond with JSON-RPC method-not-found; never silently drop (the server may be waiting) |

### 8.4 The "this is the viewer mandate" check

Before merging any LSP-touching PR, ask:

1. Does this change allow the user to **modify** a source file from
   within TextView? If yes → reject.
2. Does this change cause TextView to send any `textDocument/didChange`
   notification that wasn't triggered by an on-disk file change? If
   yes → reject.
3. Does this change implement or wire up `textDocument/completion`,
   `signatureHelp`, `codeAction`, `formatting`, or `rename`? If yes →
   reject.
4. Does this change advertise a `ClientCapability` for any of the
   above? If yes → reject.

If all four are "no", the PR is **viewer-shaped**. Proceed.

---

## 9. Test strategy

Three tiers, matching the existing `TESTS_AUDIT.md` taxonomy.

### 9.1 Tier 1 — pure unit tests (fast, no processes)

Run on every PR. Target: <2 s total.

| Test file | What it covers |
|---|---|
| `LSPFramingTests` | Round-trip of `Content-Length` framing; edge cases: empty body, body with `\r\n`, multi-byte UTF-8, exactly-at-cap bodies, headers spanning a read boundary, missing Content-Length → error, junk before first header. |
| `LSPCodableTests` | Encode/decode each protocol struct against fixtures captured from real servers. Pin the exact JSON shape; mark any field optional only where the spec says so. |
| `PositionConverterTests` | UTF-16 ↔ Swift-index conversion on lines containing: ASCII only, BMP non-ASCII (é, 漢), non-BMP (👨‍👩‍👧, 𝕏), grapheme clusters (🇨🇦), CRLF, trailing whitespace, empty lines. Each line is asserted at every column boundary. |
| `RequestRouterTests` | ID allocation monotonic; response routing matches ID; cancellation removes from pending; duplicate-ID response is dropped with telemetry; late response after cancel is dropped silently. |
| `WorkspaceRootFinderTests` | Synthetic directory trees: `Package.swift` in root, in subdir, none; `Cargo.toml` with workspace inheritance; `.git` boundary stop. |
| `ServerSpecTests` | For each `ServerSpec`, assert the command-line shape matches the spec table; assert the init-options JSON shape is what we expect. |
| `LSPLanguageDetectionTests` | URL → LSPLanguage mapping for every extension, including edge cases (`.tsx` → typescript, `.h` → clangd). |

These tests use **no Process**, **no Pipe**, **no LSP server**. They
operate on in-memory bytes and synthetic file trees.

### 9.2 Tier 2 — mock-LSP integration tests

A `MockLanguageServer` actor inside the test target speaks JSON-RPC
back over an in-memory `Pipe` pair (we use `Pipe` not `Process` —
two Pipes wired together — to avoid spawning real processes). It
implements only the methods under test, with canned responses.

| Test file | What it covers |
|---|---|
| `LSPClientInitializeTests` | Mock server replies to `initialize`; client correctly parses ServerCapabilities; client sends `initialized` notification afterward. |
| `LSPClientHoverTests` | didOpen → hover → response. Assert position converted correctly; assert popover content. |
| `LSPClientDefinitionTests` | didOpen → definition → response with 0, 1, N locations; assert each branch. |
| `LSPClientDocumentSymbolTests` | Nested document symbols round-trip correctly; identity stable; children populated. |
| `LSPClientCancellationTests` | Send hover, cancel before response, assert `$/cancelRequest` sent, assert continuation resumes with `.cancelled`, assert late response is silently dropped. |
| `LSPClientCrashTests` | Mock server closes its outbound pipe mid-request; assert `.serverCrashed` error fans out to all pending; assert pool entry is removed. |
| `LSPClientTimeoutTests` | Mock server never replies; assert per-method timeout fires; assert `$/cancelRequest` is sent on timeout too. |
| `LSPPoolEvictionTests` | Idle timer evicts after TTL; explicit workspace close evicts; double-close is idempotent. |

### 9.3 Tier 3 — live-server smoke (NOT on CI)

A handful of scripts under `scripts/lsp-smoke/`. Each spawns a real
`sourcekit-lsp` against a fixture SwiftPM package and asserts hover /
definition / outline come back in expected shape. **Run manually
before each phase release.** Reasons not on CI:

- CI may not have a Swift toolchain version that matches what the
  fixture expects.
- The first sourcekit-lsp request after spawn takes 1–10 s of indexing;
  flaky in CI.
- We can't (and shouldn't) install rust-analyzer / gopls / etc. on CI
  for the cost-vs-flake tradeoff.

The mock tests (Tier 2) carry the protocol contract. The live tests
(Tier 3) carry the integration smoke. Don't blur the two — every
flaky-on-CI live test is a maintenance tax.

### 9.4 Property-based corner

The framing parser is a perfect fit for a property test: feed it
arbitrary byte sequences, assert it never crashes, only ever returns
`.framingError` or a valid frame. Even without `swift-testing`'s
property-test integration, a hand-rolled "100 randomized inputs"
loop catches a lot. Worth ~50 lines of code.

---

## 10. Worked JSON-RPC examples

For people who haven't read the spec end-to-end, here are concrete
wire-level examples. All shown without the `Content-Length` header for
readability — assume each blob is preceded by `Content-Length: <len>\r\n\r\n`.

### 10.1 initialize

Client → server:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "processId": 88421,
    "clientInfo": {"name": "TextView", "version": "0.5.0"},
    "rootUri": "file:///Users/me/code/myswift",
    "workspaceFolders": [
      {"uri": "file:///Users/me/code/myswift", "name": "myswift"}
    ],
    "capabilities": {
      "general": {"positionEncodings": ["utf-16", "utf-8"]},
      "textDocument": {
        "hover": {"contentFormat": ["markdown", "plaintext"]},
        "definition": {"linkSupport": true},
        "documentSymbol": {"hierarchicalDocumentSymbolSupport": true}
      },
      "workspace": {"workspaceFolders": true}
    },
    "trace": "off"
  }
}
```

Server → client:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "capabilities": {
      "textDocumentSync": {"openClose": true, "change": 1},
      "hoverProvider": true,
      "definitionProvider": true,
      "referencesProvider": true,
      "documentSymbolProvider": true,
      "workspaceSymbolProvider": true,
      "positionEncoding": "utf-16"
    },
    "serverInfo": {"name": "SourceKit-LSP", "version": "5.10"}
  }
}
```

Client → server (notification, no `id`):

```json
{"jsonrpc": "2.0", "method": "initialized", "params": {}}
```

### 10.2 didOpen

```json
{
  "jsonrpc": "2.0",
  "method": "textDocument/didOpen",
  "params": {
    "textDocument": {
      "uri": "file:///Users/me/code/myswift/Sources/Lib/Foo.swift",
      "languageId": "swift",
      "version": 1,
      "text": "import Foundation\n\nstruct Foo {\n    let bar: Int\n}\n"
    }
  }
}
```

### 10.3 hover

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "textDocument/hover",
  "params": {
    "textDocument": {"uri": "file:///Users/me/code/myswift/Sources/Lib/Foo.swift"},
    "position": {"line": 2, "character": 7}
  }
}
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "contents": {
      "kind": "markdown",
      "value": "```swift\nstruct Foo\n```\n\nA simple struct."
    },
    "range": {
      "start": {"line": 2, "character": 7},
      "end":   {"line": 2, "character": 10}
    }
  }
}
```

### 10.4 definition

Request shape mirrors hover. Response:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": [
    {
      "uri": "file:///Users/me/code/myswift/Sources/Lib/Foo.swift",
      "range": {
        "start": {"line": 2, "character": 7},
        "end":   {"line": 2, "character": 10}
      }
    }
  ]
}
```

Servers may return `Location | Location[] | LocationLink[]`. Always
decode as the most-general form and normalize internally.

### 10.5 documentSymbol

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "textDocument/documentSymbol",
  "params": {
    "textDocument": {"uri": "file:///..."}
  }
}
```

Response (hierarchical form, since we advertised support):

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": [
    {
      "name": "Foo",
      "kind": 23,                      // SymbolKind.Struct
      "range":          {"start":{"line":2,"character":0},"end":{"line":4,"character":1}},
      "selectionRange": {"start":{"line":2,"character":7},"end":{"line":2,"character":10}},
      "children": [
        {
          "name": "bar",
          "kind": 7,                   // SymbolKind.Property
          "range":          {"start":{"line":3,"character":4},"end":{"line":3,"character":16}},
          "selectionRange": {"start":{"line":3,"character":8},"end":{"line":3,"character":11}},
          "children": []
        }
      ]
    }
  ]
}
```

### 10.6 cancelRequest

A notification, no `id` on the message itself (but `params.id` references the request being cancelled):

```json
{
  "jsonrpc": "2.0",
  "method": "$/cancelRequest",
  "params": {"id": 4}
}
```

### 10.7 shutdown + exit

```json
{"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": null}
```

Response (an empty result is the success signal):

```json
{"jsonrpc": "2.0", "id": 99, "result": null}
```

Then:

```json
{"jsonrpc": "2.0", "method": "exit"}
```

The server should exit on its own within ~1 s. If it doesn't, we
escalate to SIGTERM → SIGKILL per §3.4.

### 10.8 server-error response

If a request encounters a server-side error (e.g. position outside
file), the response carries an `error` field instead of `result`:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "error": {
    "code": -32602,
    "message": "Invalid params: line 999 is out of range"
  }
}
```

We decode this as `LSPError.serverError(code: -32602, ...)` and either
surface it (developer panel) or eat it (hover popover just doesn't
appear). Per-method policy.

---

## 11. Configuration surface (user-facing)

Hackability hook (HACKABILITY §"Add a new file type"): a single
JSON file at `~/Library/Application Support/TextView/lsp.json` lets
the user override or add servers without rebuilding.

Schema sketch:

```jsonc
{
  "servers": {
    "sourcekitLSP": {
      "command": "/Users/me/swift-toolchain/usr/bin/sourcekit-lsp",
      "args": [],
      "env": { "SOURCEKIT_LOGGING": "1" },
      "initializationOptions": {}
    },
    "rustAnalyzer": {
      "command": "/Users/me/.cargo/bin/rust-analyzer",
      "args": [],
      "env": {},
      "initializationOptions": {
        "checkOnSave": { "enable": false },
        "procMacro":   { "enable": true }
      }
    },
    "customLuaLS": {
      "extensions": ["lua"],
      "command": "/opt/homebrew/bin/lua-language-server",
      "args": [],
      "env": {},
      "rootMarkers": [".luarc.json", ".luarc.jsonc", ".git"]
    }
  },
  "enabled": ["sourcekitLSP"],
  "globalTimeouts": { "hoverMs": 3000, "definitionMs": 5000 }
}
```

This file is **read once on app startup** and reloaded on a menu-
triggered "Reload LSP config" action. We don't watch it — it changes
rarely, and a stale reader is a worse bug than the user pressing
reload.

Validation: malformed JSON → log + fall back to defaults + status-bar
warning. Unknown server name → ignore that entry. Missing required
fields → reject that entry. Never crash on bad config.

---

## 12. Observability + dev diagnostics

A dev-only panel (gated behind `MDV_LSP_DEBUG=1` or a `View → Debug`
menu) showing:

- One row per LSPClient: `(language, root, state, pid, uptime, RSS,
  pending request count, last-method, last-error)`.
- A scrolling log of JSON-RPC messages (in / out), truncated to last
  500. Pretty-printed.
- A scrolling tail of each child's stderr (last 200 lines from the
  ring buffer).

Cost: ~150 LoC of SwiftUI; pays for itself the first time a server
silently misbehaves. We've eaten that cost in the past — see the
`DiagnosticDump.swift` precedent.

Telemetry counters (in-memory, no network):

- `lsp.spawn.success` / `lsp.spawn.failure` by language
- `lsp.request.success` / `lsp.request.timeout` / `lsp.request.error`
  by method
- `lsp.crash.count` by language
- `lsp.framing.error.count`

Read via the `Help → Show Counters` menu. Pure debug aid; we never
exfiltrate.

---

## 13. Things specifically NOT to do

(LESSONS-style anti-pattern list — each entry would re-create a
specific bug class.)

- **Don't share one LSPClient across workspaces** even for the same
  language. SourceKit-LSP technically supports `workspaceFolders` but
  rust-analyzer / gopls / pyright support is uneven and forcing all
  servers through the lowest common denominator is brittle. One
  client per `(root, language)` is non-negotiable.
- **Don't parse JSON-RPC line-by-line.** Bodies legitimately contain
  embedded `\r\n` inside string values (any multi-line `hover.contents`
  field). Use the `Content-Length` byte count, period.
- **Don't drop the stderr drain.** macOS pipes have ~64 KB buffers;
  a chatty server (rust-analyzer with `SOURCEKIT_LOGGING=1`) will
  fill it within seconds and block on `write`. The child then stops
  responding to anything. Drain stderr unconditionally.
- **Don't `pkill -f sourcekit-lsp`.** The user may have other Swift
  tooling open. Target by PID via our pool.
- **Don't `await` an LSP request from `MainActor` without a deadline.**
  If the server is slow, the entire UI thread blocks. Always wrap in
  `Task { ... }` and bound the request lifetime with a per-method
  timeout. Never call `client.hover(...)` directly in a view's `body`.
- **Don't trust the server's `serverCapabilities`.** A server can
  advertise `hoverProvider: true` and still return `null` for hover at
  many positions. Treat any capability claim as "may work", not "will
  work". Code paths must handle both.
- **Don't reuse JSON decoders across threads** unless they're
  thread-safe. `JSONDecoder` is — but custom userInfo state isn't.
  Keep decoders local to the reader task.
- **Don't auto-restart in a tight loop.** Cap at 3 restarts per 60 s,
  same as ChimeHQ's `RestartingServer`. Faster crashes mean the
  workspace is broken, not the server.
- **Don't advertise `workspace.applyEdit`** in client capabilities.
  Some servers proactively send applyEdit requests even unsolicited
  (rust-analyzer used to do this around proc-macro errors). If we
  don't advertise, they won't send. If we did and we ignored, the
  server might wedge waiting for our reply.
- **Don't expose LSP errors as modal alerts.** They happen often
  (file outside workspace, position out of range, server still
  indexing). Status-bar text is the right surface.
- **Don't ship semantic tokens in Phase 1.** Tree-sitter already
  works. Adding a second highlight source before everything else
  is stable invites flicker bugs and racing-attribute confusion in
  the NSTextStorage.

---

## 14. Open questions (resolve before / during Phase 1)

1. **Position encoding default.** SourceKit-LSP supports `utf-8` since
   Swift 5.9. Do we always negotiate `utf-8` to skip conversion, or
   keep `utf-16` for spec conformance? Tentative answer: prefer
   `utf-8`, fall back to `utf-16`. Cost: more test cases.
2. **didOpen text fidelity.** Should we send the on-disk bytes as-is,
   or our in-memory String (which may have already gone through
   line-ending normalization)? Answer: on-disk bytes, decoded as
   UTF-8 with replacement. Anything else risks position drift.
3. **File watcher integration.** When `FileWatcher` fires on an LSP-
   opened file, do we synchronously send `didChange` or debounce? A
   git checkout can rewrite 100 files in one burst — debouncing per-
   file by 200 ms avoids floods.
4. **Workspace-symbols rate-limit.** Each keystroke in the command
   palette → a new `workspace/symbol`. Should we debounce 80 ms (per
   §5.4) or 150 ms? Worth A/B testing manually.
5. **Outline auto-scroll-to-current-symbol.** Should the outline
   highlight follow the source cursor? Probably yes (it's the
   industry default), but adds a "what symbol contains this line?"
   computation we'd need to derive locally.
6. **Per-language enable/disable in UI.** Should the user be able to
   toggle "use LSP for Swift" without editing the JSON config? Probably
   yes in SettingsView, Phase 2.

---

## 15. Glossary

- **LSP** — Language Server Protocol. JSON-RPC-over-stdio (usually)
  protocol from Microsoft.
- **JSON-RPC** — JSON-encoded RPC spec. Requests have `id`, responses
  echo it, notifications have no `id`.
- **server / client** — In LSP, the language tool is the *server*; the
  editor is the *client*. We are the client.
- **document URI** — `file:///abs/path`. LSP doesn't use plain paths.
- **position** — `(line, character)`, both 0-indexed. `character` is
  in the negotiated encoding (default UTF-16).
- **capability** — A feature a client or server claims to support.
  Both directions negotiate at `initialize`.
- **workspace root** — Directory the LSP treats as the project base.
  Determined per-language from marker files.
- **didOpen / didChange / didClose** — Notifications that bring a
  document into the LSP's managed-buffer view.
- **request-nonce pattern** — TextView-internal pattern (LESSONS) for
  triggering one-shot actions across SwiftUI / AppKit boundaries.
  Used for "scroll to line" when navigating from outline / def.

---

## 16. Sources

Citations for the research in §1.

- LSP 3.17 specification: <https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/>
- LSP 3.18 specification (draft, for forward-looking decisions): <https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/>
- VS Code LSP overview: <https://learn.microsoft.com/en-us/visualstudio/extensibility/language-server-protocol>
- VS Code `vscode-languageserver-node` / `vscode-jsonrpc`: <https://github.com/microsoft/vscode-languageserver-node>
- Zed LSP integration deepwiki: <https://deepwiki.com/zed-industries/zed/5.2-language-server-integration>
- Zed Language Server Lifecycle: <https://deepwiki.com/zed-industries/zed/5.3-language-server-lifecycle>
- Zed Language Registry and Adapters: <https://deepwiki.com/zed-industries/zed/5.1-edit-prediction-system>
- Zed semantic tokens docs: <https://zed.dev/docs/semantic-tokens>
- Apple sourcekit-lsp repo: <https://github.com/swiftlang/sourcekit-lsp>
- sourcekit-lsp Configuration File doc: <https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Configuration%20File.md>
- "Developing a sourcekit-lsp Client: Why Won't it Talk to Me?": <https://forums.swift.org/t/developing-a-sourcekit-lsp-client-why-wont-it-talk-to-me/41350>
- "Multiple workspace folders" (Swift Forums): <https://forums.swift.org/t/multiple-workspace-folders/55042>
- ChimeHQ LanguageClient: <https://github.com/ChimeHQ/LanguageClient>
- ChimeHQ LanguageServerProtocol: <https://github.com/ChimeHQ/LanguageServerProtocol>
- ChimeHQ SwiftLSPClient (deprecated): <https://github.com/ChimeHQ/SwiftLSPClient>
- Matt Massicotte / Chime "Language Server Protocol Client in Swift": <https://www.chimehq.com/blog/swift-lsp-client>
- Nova LanguageClient API: <https://docs.nova.app/api-reference/language-client/>
- rust-analyzer configuration: <https://rust-analyzer.github.io/book/configuration.html>
- rust-analyzer manual: <https://rust-analyzer.github.io/manual.html>
- rust-analyzer changelog 313: <https://rust-analyzer.github.io/thisweek/2026/02/02/changelog-313.html>
- typescript-language-server: <https://github.com/typescript-language-server/typescript-language-server>
- "Tree-sitter vs. LSP" (Lambda Land): <https://lambdaland.org/posts/2026-01-21_tree-sitter_vs_lsp/>
- "LSP processes remain as orphaned zombie processes after opencode exits": <https://github.com/anomalyco/opencode/issues/18632>
- LSP4IJ language server lifecycle management: <https://deepwiki.com/redhat-developer/lsp4ij/3.2-language-server-lifecycle-management>
- "Server doesn't respond to invalid request" (lsp4j): <https://github.com/eclipse-lsp4j/lsp4j/issues/210>
- jsonrpc Content-Length framing discussion: <https://lists.gnu.org/archive/html/emacs-devel/2023-10/msg00388.html>
- Swift Subprocess proposal (SE-0007 / swift-foundation): <https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md>
- "Running a Child Process with Standard I/O" (Apple Developer Forums): <https://developer.apple.com/forums/thread/690310>
- Swift.org "Configuring Neovim for Swift Development": <https://www.swift.org/documentation/articles/zero-to-swift-nvim.html>

[lsp-3-17]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
[lsp-semtok]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_semanticTokens
[lsp-cancel]: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#cancelRequest
[vscode-lifecycle]: https://learn.microsoft.com/en-us/visualstudio/extensibility/language-server-protocol
[vscode-jsonrpc]: https://github.com/microsoft/vscode-languageserver-node/blob/main/jsonrpc/README.md
[zed-lifecycle]: https://deepwiki.com/zed-industries/zed/5.3-language-server-lifecycle
[zed-lsp]: https://deepwiki.com/zed-industries/zed/5.2-language-server-integration
[zed-langregistry]: https://deepwiki.com/zed-industries/zed/5.1-edit-prediction-system
[zed-semtok]: https://zed.dev/docs/semantic-tokens
[lsp4ij-lifecycle]: https://deepwiki.com/redhat-developer/lsp4ij/3.2-language-server-lifecycle-management
[opencode-zombies]: https://github.com/anomalyco/opencode/issues/18632
[swift-multiworkspace]: https://forums.swift.org/t/multiple-workspace-folders/55042
[ra-changelog]: https://rust-analyzer.github.io/thisweek/2026/02/02/changelog-313.html
[ts-ls]: https://github.com/typescript-language-server/typescript-language-server
[ts-vs-lsp]: https://lambdaland.org/posts/2026-01-21_tree-sitter_vs_lsp/
[nova-lsp]: https://docs.nova.app/api-reference/language-client/
[lc-repo]: https://github.com/ChimeHQ/LanguageClient
[lsp-repo]: https://github.com/ChimeHQ/LanguageServerProtocol
[chime-blog]: https://www.chimehq.com/blog/swift-lsp-client
[emacs-jsonrpc]: https://lists.gnu.org/archive/html/emacs-devel/2023-10/msg00388.html
[lsp4j-malformed-bug]: https://github.com/eclipse-lsp4j/lsp4j/issues/210
[subprocess-proposal]: https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md
