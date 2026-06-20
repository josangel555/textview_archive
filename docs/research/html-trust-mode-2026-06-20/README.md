# Trust-local-HTML render mode — security design (TSK-1189, 2026-06-20)

Owner-approved (build it) with three riders: **(1) tightly gated · (2) surface
any failure to the user with details · (3) all layers, no vulns.** This is the
highest-risk change in the app — it relaxes HTML sanitization — so it's designed
threat-model-first and shipped in slices, gate foundation before any relaxation.

## Threat model (what we're defending)

Opening a raw `.html` is two attack surfaces (per `HTMLDocumentPolicy`):
1. **Script injection** — the doc runs arbitrary JS.
2. **Local-file read / exfiltration** — a `file://` doc pulls sibling/parent
   files as sub-resources and beacons them to a remote origin.

Trust-mode deliberately relaxes **#1** (a trusted local page runs its own
scripts — that's the feature). It must keep **#2 fully bounded**: a trusted page
is "a local web page," NOT a filesystem reader or a phone-home exfiltrator.

## The gate (L-trust) — unspoofable, fail-closed, per-document

A document is *trusted* iff ALL hold (any failure ⇒ untrusted ⇒ today's full
hardening — fail closed):
- **`file://` and local** — never `http(s)`/remote. Remote can NEVER be trusted.
- **Explicit per-document opt-in**, keyed to the exact standardized path. Default
  OFF. Trusting A never trusts B (no wildcard, no directory-wide trust).
- **Not quarantined** — a file carrying `com.apple.quarantine` (downloaded from
  the web / received) is NOT trust-eligible; the banner explains why and the user
  must remove quarantine deliberately (outside the app). Locally-authored files
  have no quarantine xattr → eligible.
- Pure decision (`HTMLTrustPolicy`), host-tested, with teeth — this is the
  security core; everything downstream keys off it.

## Bounded relaxation, per layer (only when trusted)

| Layer | Untrusted (today) | Trusted (local, opted-in) |
|---|---|---|
| **L0 size** | 4 MB cap | unchanged (still don't slurp huge docs) |
| **L1 sanitize** | strip `<script>/<style>/<iframe>/<object>/<embed>/<form>` | **keep `<script>` + `<style>`** (the bundle's own code/styles); STILL strip `<iframe>/<object>/<embed>` (remote/plugin vectors a self-contained app doesn't need) |
| **L2 JS** | default-deny | **enabled** |
| **L3 CSP** | `script-src 'none'`, `connect-src 'none'` | `script-src 'self' 'unsafe-inline' 'unsafe-eval'` (bundled apps use inline + eval); **`connect-src 'none'` KEPT** — see network below; `img/style/font` local+inline |
| **L3 subresource nav** | remote cancelled, `file:` fenced to doc dir | **unchanged** — remote still cancelled, `file:` still fenced to the doc's own directory (the anti-exfil fence stays) |
| **L4 links** | external→browser, local cancelled | unchanged |
| **WKWebView** | — | **hardened even when trusted**: `allowFileAccessFromFileURLs=false`, `allowUniversalAccessFromFileURLs=false`, `javaScriptCanOpenWindowsAutomatically=false` |

**The anti-exfiltration fence (surface #2) is NEVER relaxed.** A trusted page
runs its JS and renders, but `connect-src 'none'` + the subresource nav policy +
no universal/file-URL access mean it cannot read arbitrary local files or beacon
out. So even a *malicious* file the user mistakenly trusts can't exfiltrate —
it can only mis-render itself.

### Network (the browser-equivalent ⇄ no-vuln tension)

A browser would let a trusted page hit the network; that's also the exfil path.
Decision: **network stays OFF in plain trust-mode** (`connect-src 'none'`). Most
self-contained apps (bundled data + JS) render fully without it. If a page tries
to fetch remote and is blocked, the **failure surfacing** (below) tells the user
*exactly which host was blocked* and offers a SECOND, explicit "Allow network for
this page" escalation — so network is consent-gated and never silent. (Slice 3.)

## Failure surfacing (rider 2) — never a silent partial render

A `WKNavigationDelegate` + a JS error bridge feed a user-visible status:
- Trust OFF + `dependsOnSuppressedScript` true → banner: *"This page's scripts
  were removed for safety. [Trust & Run] (local file)."*
- Trust ON + something still fails → show **what** failed with detail: JS errors
  (message + line), CSP violations (blocked directive + URI), blocked
  sub-resources / network (the host), nav failures. **All detail HTML-escaped**
  before display (the error channel must not become an injection vector — rider 3).
- Quarantined / remote → banner explains why it's not trust-eligible.

## Slices

1. **Gate foundation (THIS slice)** — `HTMLTrustPolicy` pure decision
   (eligibility + fail-closed trust) + the trust store (per-path opt-in,
   default-off) model, host-tested with teeth. No relaxation yet — safe to land.
2. **Bounded relaxation** — trust-aware `sanitize(_,trusted:)` / `csp(trusted:)`
   / JS wiring + WKWebView hardening, gated solely on slice-1's decision.
   Render-path ⇒ review ceiling (T6/owner confirm on screen).
3. **Failure surfacing + the network second-escalation** — the nav/JS/CSP error
   bridge → user-visible escaped detail; consent-gated `connect-src`.

## Invariants (tested)
- Untrusted/remote/quarantined ⇒ byte-identical to today's hardened output.
- Trust is per-path, never wildcard; default OFF; any uncertainty ⇒ untrusted.
- The anti-exfil fence (connect-src none, file fenced, no universal access) holds
  in BOTH modes.
