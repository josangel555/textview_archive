# Pre-launch product review — WebView & JS-bridge security

**Dimension:** CSP integrity across the WebViews, `HTMLSanitizer` bypasses,
script-message-handler trust, `file:`/`data:` scope enforcement, and
XSS/script-injection via rendered markdown or hostile HTML documents.

**Date:** 2026-07-09 · **Reviewer:** automated dimension pass (static analysis)

---

## Executive summary

The WebView security posture is, overall, **strong and unusually well-reasoned**.
The two attacker-facing render paths — arbitrary `.html` files
(`HTMLRenderedView` / `HTMLDocumentPolicy`) and rendered markdown
(`MarkdownRenderedView` / `HTMLRenderer`) — implement genuine, layered
defense-in-depth: an allowlist sanitizer, JavaScript default-deny, a strict
`default-src 'none'` CSP, and a hardened `WKNavigationDelegate` that blocks
`javascript:`/remote/out-of-tree-`file:` navigations (the "WV-4" guard). The
decision kernels are factored into pure, host-testable value functions, and the
threat model is documented candidly (the sanitizer is explicitly labelled "NOT a
security boundary… confirmed bypasses," with the CSP as the load-bearing layer).
The "trust this local HTML" escalation (TSK-1189) and per-page network consent
(TSK-1203) are both fail-closed and keep the anti-exfiltration fence
(`connect-src 'none'`) intact. Mermaid runs `securityLevel: 'strict'` with
`htmlLabels:false`; the vendored bundle is version-pinned and SHA-checked.

The findings below are **hardening gaps, not open holes**. The most notable is
that the **Canvas WebView** (`CanvasWebViewHost` + `canvas.html`) — unlike all
the other WebViews — ships with **no CSP `<meta>` and no navigation-policy
delegate**, while enabling JS and rendering user-authored content via
`innerHTML`. XSS is largely contained by the structured Rust lowering (fixed
attribute names + text/attr escaping), so the concrete residual is a
remote-resource / tracking-beacon exfil vector and an inconsistency with the
app's own "no single layer trusted alone" doctrine. Canvas is currently
owner-parked but compiled into the binary and reachable via the `canvas_*` MCP
tools, so it is in scope for a pre-launch pass.

No P0/P1 issues found in this dimension.

---

## Methodology

**What I examined (static analysis; no window-opening tests run):**

- Sanitizer + policy: `Sources/ViewerCore/HTMLSanitizer.swift`,
  `HTMLSanitizerPolicy.swift`, `HTMLDocumentPolicy.swift`, `HTMLTrustPolicy.swift`,
  `HTMLRenderer.swift`, `HtmlExport.swift`, `JSStringEmbedding.swift`.
- WebView hosts + configs: `Sources/ViewerUI/HTMLRenderedView.swift`,
  `MarkdownRenderedView.swift`, `CodeMirrorEditorView.swift`,
  `CanvasWebViewHost.swift`, `Walkthrough/WalkthroughMermaidWebView.swift`,
  `WalkthroughMermaidPage.swift`, `FeedReaderView.swift`,
  `DocumentModel+HTMLJavaScript.swift`.
- Bundled web assets + CSP `<meta>` tags: `Resources/codemirror/codemirror.html`,
  `Resources/canvas/canvas.html`, `Resources/canvas/canvas.js`,
  `Resources/mermaid/mermaid-shim.js`, `Resources/mermaid/VENDOR.md`.
- Bridge trust: every `WKScriptMessageHandler` registration
  (`mdvEditor`, `mdvCanvas`) and its `didReceive` decoder; every
  `evaluateJavaScript` call site in `Sources/ViewerUI/` (~35 sites) for
  user-string interpolation; `BrowserNavigationPolicy.swift`.
- File/data scope: all `loadFileURL(allowingReadAccessTo:)` and `loadHTMLString`
  base-URL scopes; Rust canvas HTML emitter
  `rust-core/crates/core/src/canvas/lower.rs` (escape functions + sinks).

**How much:** read the full text of the ~12 core Swift policy/host files and the
Rust canvas emitter; grep-audited the whole `Sources/` tree for the bridge,
`evaluateJavaScript`, and file-access surfaces. I did not run the app or any
VM/UI test (per constraints).

---

## Findings

### F1 — Canvas WebView ships with no CSP and no navigation-policy delegate (remote-resource / exfil vector; defense-in-depth inconsistency)

- **Severity:** P2
- **Files:**
  - `Sources/ViewerUI/Resources/canvas/canvas.html:1` (no CSP `<meta>` in `<head>`)
  - `Sources/ViewerUI/CanvasWebViewHost.swift:39` (`init` — JS on by default, no `decidePolicyFor`)
  - `Sources/ViewerUI/Resources/canvas/canvas.js:82,116,613` (`innerHTML`/`outerHTML` sinks)
  - `rust-core/crates/core/src/canvas/lower.rs:320-323` (user-controlled `<img src>` value, attr-escaped only)
- **Evidence:** `canvas.html` has only `<meta charset="utf-8">` — no
  `Content-Security-Policy`, unlike `codemirror.html:9`, `HTMLDocumentPolicy.csp`,
  `HTMLRenderer.renderPage` (line 79), and `HtmlExport.csp`. The host enables JS
  (default `WKWebViewConfiguration`, no `allowsContentJavaScript=false`) and the
  runtime writes engine-produced HTML into the DOM with `root.innerHTML = msg.html`
  (`canvas.js:613`) and `el.outerHTML = p.html` (line 116). `CanvasWebViewHost`
  conforms to `WKNavigationDelegate` but implements only
  `webViewWebContentProcessDidTerminate` — there is **no**
  `decidePolicyFor navigationAction`, so nothing blocks remote sub-resource loads
  or script/redirect navigations (contrast `MarkdownRenderedView` line 997 /
  `HTMLRenderedView` line 339, both of which cancel `http(s)`/out-of-tree `file:`).
  The image node's `src` is user DSL content escaped only for double-quoted
  attribute context (`escape_attr` handles `& < > "`, `lower.rs:30`) — the scheme
  and host are never checked.
- **Impact:** A hostile/received `.canvas` file with an image node
  `src="https://tracker.example/leak.gif"` causes WebKit to fetch a remote URL on
  open — a tracking pixel that leaks "user opened this file" + IP, with no
  `img-src`/`connect-src` fence to stop it. Full script XSS is *contained today*
  because the lowering emits a **fixed set of attribute names** (`data-cv-id`,
  `src`, `style`, `data-cv-kind`, `data-cv-link`) and escapes all values, so an
  attacker cannot inject an `onerror=`/`onload=` handler — but that safety rests
  **entirely** on the emitter never slipping, with no CSP backstop, which
  contradicts the project's explicit "no single layer is trusted alone" doctrine
  (`HTMLDocumentPolicy` header). Any future emitter change that forgets to escape,
  or adds a URL/`href` attribute, becomes live XSS in a `file://`-privileged page.
- **Suggested fix:** (1) Add a strict CSP `<meta>` to `canvas.html` mirroring the
  markdown page (`default-src 'none'; img-src file: data:; style-src 'unsafe-inline';
  font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none';
  base-uri 'none'; form-action 'none';`) — inline scripts still load because
  `canvas.js` is a same-origin `file:` resource under `script-src 'self'` (add
  `'self'`). (2) Implement `decidePolicyFor` on `CanvasWebViewHost` that reuses
  `HTMLDocumentPolicy.decideSubresource`/`decideLink` (or a canvas-specific kernel)
  to cancel remote + out-of-tree loads. (3) Optionally scheme-check the image
  `src` in the Rust lowering (drop non-`file:`/`data:` or non-`https:` per policy).
- **Fix size:** M · **Fix risk:** careful (an over-tight `img-src`/nav policy can
  break legitimate canvas image rendering; validate on the canvas render path
  before landing).

### F2 — Untrusted raw-HTML "Enable JavaScript" toggle turns on the WebView JS engine while relying solely on meta-CSP + a bypassable sanitizer

- **Severity:** P3
- **Files:**
  - `Sources/ViewerUI/HTMLRenderedView.swift:150-152,184-187` (`allowsContentJavaScript` from per-tab opt-in, untrusted docs included)
  - `Sources/ViewerUI/DocumentModel+HTMLJavaScript.swift:127-131` (`showsHTMLJavaScriptToggle` — offered for ANY `.html` in rendered mode, no trust-eligibility check)
  - `Sources/ViewerCore/HTMLSanitizer.swift:35-41` ("NOT a security boundary… a sufficiently clever payload could survive the regex pass")
- **Evidence:** The per-tab JS opt-in (`htmlJavaScriptOptIn`) is exposed whenever
  the current tab is `.html` + rendered (`showsHTMLJavaScriptToggle` checks only
  category and view mode — not `htmlTrustEligible`). Flipping it on sets
  `allowsContentJavaScript = javaScriptEnabled || trusted`, enabling the WKWebView
  JS engine even for an **untrusted / quarantined** document. For untrusted docs
  the sanitizer still strips `<script>`/`on*=` and the CSP is the strict
  `script-src 'none'` envelope, so — per the code's own reasoning
  (`HTMLDocumentPolicy` lines 122-128) — the toggle enables **nothing usefully
  scriptable**. Meanwhile `HTMLSanitizer`'s header warns meta-`http-equiv` CSP
  enforcement "differs subtly… across WebKit versions" and that `<script>`
  payloads "parse *before* the CSP can take effect in some race windows."
- **Impact:** Enabling the JS engine on untrusted content trades a defense layer
  (JS default-deny) for a control that grants no legitimate capability, and
  narrows the safety margin to "meta-CSP alone" precisely on the path where the
  sanitizer is admittedly bypassable. Requires a deliberate user toggle, so
  exploitation is not drive-by; this is a confusing/foot-gun control, not an open
  hole.
- **Suggested fix:** Gate `showsHTMLJavaScriptToggle` on `htmlTrustEligible`
  (only offer JS opt-in for local, non-quarantined files), or remove the untrusted
  JS toggle entirely and fold "run this page" solely into the trust flow (which
  already relaxes `script-src` deliberately). Keep `trusted` as the only path that
  sets `allowsContentJavaScript = true`.
- **Fix size:** S · **Fix risk:** safe.

### F3 — Mermaid and Canvas WebView hosts have no `decidePolicyFor` navigation fence

- **Severity:** P3
- **Files:**
  - `Sources/ViewerUI/Walkthrough/WalkthroughMermaidWebView.swift:24-44` (no navigation delegate at all)
  - `Sources/ViewerUI/CanvasWebViewHost.swift:39-47` (delegate present, `decidePolicyFor` absent — see F1)
- **Evidence:** The two attacker-facing WebViews (`MarkdownRenderedView`,
  `HTMLRenderedView`) both install a hardened `decidePolicyFor` that cancels
  `javascript:`/`vbscript:`, remote schemes, and out-of-tree `file:`
  (`MarkdownRenderedView.swift:997`, `HTMLRenderedView.swift:339`). The mermaid
  walkthrough WebView sets no `navigationDelegate`; the canvas host sets one but
  never decides policy. Both pages carry (mermaid) or should carry (canvas, F1) a
  `default-src 'none'` CSP, and mermaid runs `securityLevel:'strict'`
  (`mermaid-shim.js:38`), so a script-initiated navigation is largely constrained
  by CSP already — but the belt-and-suspenders nav fence the rest of the app
  standardizes on is missing.
- **Impact:** Low today — `WalkthroughMermaidWebView` is explicitly not yet wired
  into the UI (standalone component per its header), and mermaid's own source is
  the user's markdown (contained by strict mode + CSP). This is a consistency /
  belt-and-suspenders gap that becomes relevant the moment either surface is
  wired to broader/less-trusted content.
- **Suggested fix:** Add a small shared `decidePolicyFor` (reusing
  `BrowserNavigationPolicy` or `HTMLDocumentPolicy.decideSubresource`) to both
  hosts; block everything except the bundled bootstrap load.
- **Fix size:** S · **Fix risk:** safe.

### F4 — Script-message handlers (`mdvEditor`, `mdvCanvas`) don't validate frame/source

- **Severity:** P3
- **Files:**
  - `Sources/ViewerUI/CodeMirrorEditorView.swift:904-911` (`didReceive` — no `message.frameInfo.isMainFrame` / source-URL check)
  - `Sources/ViewerUI/CanvasWebViewHost.swift:46` + its `MessageProxy` (same)
- **Evidence:** Both handlers decode `message.body` and act on it without checking
  `message.frameInfo.isMainFrame` or the frame's URL. The CM6 handler drives
  document mutation (`.change`/`.incrementalChange` → `onTextChange`) and LSP
  actions; the canvas handler drives inbound envelopes.
- **Impact:** Theoretical today: both pages load bundled `file:` content with CSPs
  that forbid subframes (`codemirror.html:9` `default-src 'none'` → no `frame-src`;
  canvas would gain the same under F1), so there is no attacker-controlled frame to
  post from, and CM6 renders user text as CodeMirror *text*, not HTML. Still, the
  standard WebKit hardening (assert main-frame + expected URL before trusting a
  message) is omitted.
- **Suggested fix:** In each `didReceive`, early-return unless
  `message.frameInfo.isMainFrame` and (defensively) the frame's `securityOrigin`
  scheme is `file`.
- **Fix size:** S · **Fix risk:** safe.

---

## Positive observations

- **Layered, documented defense-in-depth** for the two real attack surfaces.
  `HTMLDocumentPolicy` (L0 size cap → L1 sanitizer → L2 JS default-deny → L3
  CSP + sub-resource fence → L4 link policy) is exemplary, and the layers are
  independent value functions with host tests.
- **CSP integrity across the primary WebViews.** `default-src 'none'` on both the
  raw-HTML (`HTMLDocumentPolicy.csp`) and markdown (`HTMLRenderer.renderPage`)
  pages; the app injects **its own** `<head>` CSP and never trusts the document's
  self-declared CSP (`HTMLDocumentPolicy.envelope` doc comment). Even
  `x-dns-prefetch-control: off` is set to stop hostname leakage via DNS prefetch
  (`HTMLRenderer.swift:97`) — a subtle, correct touch.
- **Fail-closed trust model.** `HTMLTrustPolicy.isTrustEligible` rejects non-`file:`,
  remote, and quarantined docs; trust and network consent are per-exact-path
  (symlink-resolved), default-off, revocable; the untrusted path *ignores*
  `allowedConnectHosts` as a security invariant (`HTMLDocumentPolicy.cspString`).
- **Anti-exfil fence never relaxed.** Even trusted local HTML keeps
  `connect-src 'none'` unless the user consents to specific HTTPS-only origins,
  which are canonicalized via `URLComponents` (`connectSource(forHost:)`) to reject
  wildcards/paths/userinfo.
- **JS-string embedding hazard handled.** Find queries and bridge payloads are
  JSON-encoded and run through `JSStringEmbedding.sanitize` to escape U+2028/U+2029
  before interpolation into `evaluateJavaScript` (`MarkdownRenderedView.jsEscape`,
  `JSStringEmbedding.swift`). All interpolated numeric values I checked are
  Int/Double-parsed, not raw strings.
- **Sanitizer is quote-aware and entity-decoding.** `HTMLSanitizer` uses a
  quote-aware `tagEnd` tokenizer (not `[^>]*`), decodes HTML entities + strips C0
  controls before scheme comparison, and catches handler-abutting-quote /
  `<svg/onload=>` variants — it closes the classic regex-sanitizer bypasses even
  though it correctly disclaims being the security boundary.
- **Mermaid hardened + supply-chain pinned.** `securityLevel:'strict'`,
  `htmlLabels:false`, runtime injected via `WKUserScript` (not page `<script>`);
  bundle pinned to 11.4.1 with a committed SHA-256 and a `MermaidVendorTests`
  guard against silent swaps (`VENDOR.md`).
- **File-access scopes are tight.** Every `loadFileURL(allowingReadAccessTo:)`
  points at the bundled Resources dir; the raw-HTML `loadHTMLString` base URL is
  the document's own directory, additionally fenced by
  `isWithinDocumentTree` (with a trailing-separator guard against
  `/tmp/site` vs `/tmp/site-secrets`). No `allowUniversalAccessFromFileURLs` /
  `allowFileAccessFromFileURLs` private flags are set anywhere.
- **Export path removes the renderer as an injection vector** entirely
  (`AuthorHTMLDisposition.escape`) since the standalone file runs in a real browser
  with `file:` privileges where the regex sanitizer would be the sole defense
  (`HtmlExport` doc / TSK-966).
- **WebContent-process-death recovery** is wired (`webViewWebContentProcessDidTerminate`),
  avoiding the white-screen footgun without weakening any policy.

---

## Coverage gaps (what I did NOT examine)

- **No dynamic/runtime testing.** All findings are from static reading; I did not
  build a bypass corpus or drive the sanitizer/CSP against a live WKWebView (VM/UI
  tests were out of scope). The sanitizer's self-declared residual ("a clever
  payload could survive the regex pass") was not fuzzed here — worth a dedicated
  fuzz/corpus pass given it is the first line before the CSP.
- **Mermaid 11.4.1 CVE posture** was not deep-checked against an advisory feed;
  I confirmed the config hardening + pinning but did not audit the 2.5 MB bundle
  for a specific known-vuln in that version.
- **CodeMirror bundle internals** (`codemirror.js`, `codemirror.html` full body)
  were only spot-checked for the CSP + message contract, not audited line-by-line
  for a sink that could turn document text into markup.
- **The Rust canvas emitter** (`lower.rs`, `patch.rs`, `chart.rs`) was reviewed for
  the primary escaping sinks and the image `src` path, but not exhaustively for
  every node kind / prop that reaches HTML; the `escape_attr` single-quote omission
  is safe only while every emitted attribute is double-quoted (true today — a
  latent invariant worth a test).
- **The Automation/MCP surface** (`canvas_*`, `run_verb`, `run_task` → the
  `evaluateJavaScript` bridge in `ScriptVerbDispatch`) was checked only for
  user-string interpolation into JS (found safe: Int/Double-parsed args); the
  broader question of what an *agent* can drive through those verbs is a separate
  audit dimension.
- **Print/PDF export** (`createPDF`/`runPrintOperation`) was noted as post-sanitize
  but not audited for data-exfil-through-print scenarios.
