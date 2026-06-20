# Adversarial Security Review — TextView / MarkdownViewer (2026-06-18)

Scope: the security dimension — secrets/env handling, network egress, URL/scheme
allowlists, path traversal & file writes, CSP, TCC/sandbox, command injection, and
deserialization of untrusted input. The codebase is, on the whole, unusually well
hardened for this dimension: `ProcessRunner`, `GitClient`, `PluginSubprocessHost`,
`EditorWriter`, the `URLSchemePolicy`/`URLSchemeRouter` pair, and the LSP override
trust gate (`LSPLanguage.overrideConfig`) all show deliberate, tested defenses with
sound threat models. The findings below are the genuine residual defects I could
substantiate. The headline issue is a stored-XSS chain in the **Export as HTML / Open
in Browser** path, where the renderer's regex HTML sanitizer (which has confirmed
bypasses) becomes the *sole* defense because the exported document deliberately ships
with no CSP. The remaining items are eroded defense-in-depth layers and one
information-disclosure (file-inlining) gap. I empirically verified the sanitizer
bypasses with a standalone Swift harness rather than reasoning about the regex on
paper.

### Stored XSS in exported / browser-opened HTML — sanitizer is the only defense and it is bypassable

**Severity:** high

**Location:** `Sources/ViewerCore/HtmlExport.swift:9-32` (CSP-free document) +
`Sources/ViewerUI/DocumentModel.swift:5082-5113` (`htmlExportForActiveMarkdown` /
`writeActiveMarkdownPreviewHTML`) + `Sources/ViewerCore/HTMLSanitizer.swift:218-274`
(bypassable sanitizer). Menu wiring: `Sources/MarkdownViewer/main.swift:1599-1609`
("Copy as HTML", "Export as HTML…", "Open in Browser").

**Why:** `htmlExportForActiveMarkdown` renders the active markdown via
`HTMLRenderer().render(text)` — whose embedded-HTML pass routes raw HTML through
`HTMLSanitizer.sanitize` — then wraps it with `HtmlExport.standaloneDocument`, which
**deliberately omits the Content-Security-Policy** (documented at
`HtmlExport.swift:9-10`) so external images render in a normal browser.
`writeActiveMarkdownPreviewHTML` then writes this document to a temp `file://` and
opens it in the user's real browser. In the in-app `WKWebView`, the strict
`default-src 'none'` CSP (no `script-src`) is the backstop that neutralizes a
sanitizer miss — but in the exported file / browser-preview path **that backstop is
gone**, so `HTMLSanitizer` is the only thing standing between hostile markdown and
JS execution in the victim's full browser (with that browser's privileges over the
temp `file://` origin: read sibling local files, exfiltrate via fetch, etc.).

The sanitizer is regex-based and has confirmed bypasses (verified with a Swift
harness against the exact `stripEventHandlers` / `neutralizeJavaScriptURLs`
patterns):

- `<a href="x"onmouseover="steal()">` — the `\s+on[a-z]+` pattern requires
  whitespace before the handler; an `on*` attribute placed immediately after a
  closing quote (a valid HTML token boundary) is **not** stripped.
- `<svg/onload="steal()">` — `/` is a valid attribute separator in HTML; the
  `\s+` requirement misses a handler separated by `/` rather than whitespace.
- `<a href="jav&#x09;ascript:alert(1)">` — an entity-encoded control char inside
  the scheme defeats the literal `javascript|vbscript|data:text/html` match, yet
  browsers decode the entity in the attribute value and execute the URL.

A markdown file from any untrusted source (a README in a cloned repo, a `.md`
emailed to the user) that contains one of these payloads survives sanitization,
lands verbatim in the exported `.html`, and executes the instant the victim uses
"Open in Browser" or opens the saved export. This is the exact "looks rendered but
isn't safe" class the project's own security docs warn about, but on the one render
surface where the CSP doesn't cover for the sanitizer.

**Fix:** Do not rely on a regex sanitizer as a sole boundary on the CSP-free path.
Two complementary changes: (1) Stop emitting raw author HTML into the export — for
the standalone/browser document, escape embedded HTML to text (or drop it) rather
than passing it through `HTMLSanitizer`; the in-app preview can keep richer HTML
because its CSP holds. (2) If raw HTML in exports is a hard product requirement,
parse-then-reserialize through a real allowlisting HTML parser (DOM-based, not
regex) and ship the export with a restrictive CSP `<meta>` that still permits the
external images the feature wants (`default-src 'none'; img-src https: data:;
style-src 'unsafe-inline'`), accepting that some browsers honor `<meta>` CSP. At
minimum, add the three bypass cases above as failing tests against `HTMLSanitizer`
and fix the regexes (anchor `on*` on `[\s/]`, decode entities before scheme
matching) so the defense-in-depth layer actually holds.

**VERDICT: CONFIRMED** — Re-verified the chain end-to-end. `htmlExportForActiveMarkdown`
(`DocumentModel.swift:5082`) calls `HTMLRenderer().render(text)`, whose
`visitHTMLBlock`/`visitInlineHTML` (`HTMLRenderer.swift:417,510`) emit author HTML
through `HTMLSanitizer.sanitize` *unescaped*; the body is wrapped by
`HtmlExport.standaloneDocument`, which deliberately ships NO CSP (`HtmlExport.swift:9-10`);
`writeActiveMarkdownPreviewHTML` writes it to a temp `file://` opened in the real browser
(menu items confirmed at `main.swift:1599,1603,1608`). All three sanitizer bypasses
reproduced with a standalone Swift harness against the exact `stripEventHandlers`/
`neutralizeJavaScriptURLs` source: `<a href="x"onmouseover=...>` (BYPASS), `<svg/onload=...>`
(BYPASS), `jav&#x09;ascript:` (BYPASS), while the whitespace control IS stripped and plain
`javascript:` IS neutralized. On the no-CSP export path the sanitizer is the sole defense, so
this is a real stored-XSS reachable via untrusted markdown. High stands.

### HTMLSanitizer event-handler / javascript-URL regex bypasses

**Severity:** medium

**Location:** `Sources/ViewerCore/HTMLSanitizer.swift:218-234` (`stripEventHandlers`,
the `(?i)\s+on[a-z]+...` pattern) and `Sources/ViewerCore/HTMLSanitizer.swift:249-274`
(`neutralizeJavaScriptURLs`).

**Why:** Independent of the export path above, these are concrete correctness defects
in a function the codebase treats as a defense-in-depth layer for *all* embedded
markdown HTML and for raw `.html` file rendering (`HTMLDocumentPolicy.sanitize`).
Verified bypasses: (a) `\s+on` fails to match an event handler that abuts a quote
(`href="x"onclick=...`) or is separated by `/` (`<svg/onload=...>`); (b) the
`javascript|vbscript|data:text/html` literal match in `neutralizeJavaScriptURLs` is
defeated by entity-encoded characters inside the scheme (`jav&#x09;ascript:`), which
browsers decode and execute. Inside the in-app WebViews the CSP currently absorbs
these (so this is medium, not high there), but a sanitizer that silently lets event
handlers and `javascript:` URLs through is a latent foot-gun: any future loosening of
the CSP, any new render surface, or the export path above turns these straight into
XSS. The doc comment claims the residual surface is "CSS-only UI confusion attacks" —
that claim is false given these handler/URL bypasses.

**Fix:** Change the handler anchor from `\s+` to `[\s/]` (and also catch the
quote-adjacent case by tokenizing attributes rather than regex-scanning the whole
tag body). In `neutralizeJavaScriptURLs`, HTML-entity-decode the attribute value (or
strip whitespace/control chars and `&#...;` sequences) *before* the scheme compare,
and compare the decoded scheme prefix up to `:`. Better still, since the file already
has a quote-aware `tagEnd` tokenizer, walk attributes structurally and drop any
attribute whose name (case-insensitively, after trimming separators) begins with
`on`, and any URL-bearing attribute whose decoded scheme isn't on an allowlist.

**VERDICT: CONFIRMED** — The two correctness defects reproduced directly against the
shipped regexes: `\s+on[a-z]+` misses both the quote-adjacent (`href="x"onclick=`) and
slash-separated (`<svg/onload=`) handler forms; `neutralizeJavaScriptURLs`'s literal
scheme match is defeated by an entity-encoded control char inside the scheme
(`jav&#x09;ascript:`), which a browser decodes and executes. The `(?i)\s+on` anchor and
the literal `javascript|vbscript|data:text/html` token are exactly as cited. The doc
comment's "CSS-only UI confusion" residual-risk claim is indeed false given these. In-app
the CSP absorbs them (hence medium); on the export path they become live XSS. Medium stands.

### Exported HTML inlines arbitrary local files via unfenced image `src`

**Severity:** low

**Location:** `Sources/ViewerUI/DocumentModel.swift:5088-5093`
(`inlineLocalImages` closure) and `Sources/ViewerCore/HtmlExport.swift:56-93`.

**Why:** When "Export as HTML" inlines local images, it resolves each `<img src>` via
`baseDir.appendingPathComponent(decoded).standardizedFileURL` with **no containment
check** to the document's directory, then base64-embeds whatever it reads. A markdown
document with `![](../../../../etc/passwd)` — or any sensitive local file given an
image extension, e.g. `![](../../.ssh/id_rsa.png)` if such a name exists — gets its
bytes inlined into the exported file. The export runs with the app's full file
access, so traversal reaches anything the user can read. The blast radius is limited
(the user initiates the export of their own document and chooses the destination), so
this is low — but a markdown received from an untrusted party, exported and then
shared, could smuggle out a local file the user never intended to include. This is
the same "no `file://` beyond the doc tree" fence that `HTMLDocumentPolicy.
isWithinDocumentTree` already implements for the HTML-file path; the export path
lacks the equivalent.

**Fix:** Before inlining, resolve the image URL and require it to be contained in the
document's directory subtree (reuse `HTMLDocumentPolicy.isWithinDocumentTree` or the
component-prefix check from `LSPLanguage.isPath(_:inSubtreeOf:)`). Skip (leave as a
relative ref, or drop) any image that escapes the tree.

**VERDICT: CONFIRMED** — `DocumentModel.swift:5088-5093` resolves each `<img src>` via
`baseDir.appendingPathComponent(decoded).standardizedFileURL` and reads it with
`Data(contentsOf:)` with NO containment check; `HtmlExport.inlineLocalImages`
(`HtmlExport.swift:56-78`) base64-embeds whatever `readData` returns. `standardizedFileURL`
resolves `..`, so `![](../../../../etc/passwd)` (any readable file with an image extension)
inlines into the export. The asymmetry the finding cites is real: the in-app `.html` path
DOES fence with `HTMLDocumentPolicy.isWithinDocumentTree` (`HTMLDocumentPolicy.swift:178-181,
229-246`), the export inlining path does not. Low is the right severity (user exports their
own doc to a chosen destination), but the gap is genuine. Low stands.

### LSP `lsp.json` override: untrusted `args` reach the trusted discovered server

**Severity:** medium

**Location:** `Sources/ViewerCore/LSP/LSPLanguage.swift:378-393` (untrusted-command
fallback path) and `Sources/ViewerCore/LSP/LSPWorkspaceOverrides.swift:113-195`
(loader).

**Why:** `lsp.json` lives *inside* the workspace, so a hostile repo controls it. The
interim trust gate (`isOverrideCommandTrusted`) correctly refuses to spawn a
*command* that lives inside the workspace or in a group/world-writable dir — closing
the obvious "`./node_modules/.bin/evil`" RCE. But when the command is refused, the
code still falls back to the discovered, trusted server binary **and applies the
repo-supplied `args` to it**: `arguments: defaultArguments + entry.arguments`
(line 389). Many language servers expose flags that load code or config from a
repo-relative path — e.g. a server that takes a `--plugin <path>`, `--require
<module>`, `-r`, or `--tsserver <path>` style argument, or one that honors a config
file whose location is given on the command line. A hostile `lsp.json` can therefore
get a *trusted* binary to load attacker-controlled code from the workspace without
ever naming an untrusted executable — the args, not the binary, become the injection
vector. The `env` from the override is likewise merged in on this path
(`overrideConfig` line 365), so a repo can also set server-specific env that points
at in-repo plugins/config. The scrubbed base env helps with credential leakage but
not with this arg/env-driven code-load.

**Fix:** On the untrusted-command fallback, do **not** apply the repo's `args`/`env`
to the discovered server — use only `defaultArguments` and the scrubbed base env.
Repo-supplied `args`/`env` should only be honored when the *command itself* passed
the trust gate (the user is then taking over spawn config knowingly). Until the
planned trust-UI ships, the conservative posture is "an untrusted `lsp.json`
contributes nothing," not "it contributes everything except the binary path." Add a
test asserting the fallback `Config.arguments == defaultArguments` and
`environment == scrubbedLaunchEnvironment()` when the override command is untrusted.

**VERDICT: CONFIRMED** — `overrideConfig`'s untrusted-command fallback
(`LSPLanguage.swift:387-392`) spawns the discovered trusted binary with
`arguments: defaultArguments + entry.arguments` (repo args appended) and
`environment: environment`, where `environment = overrides.mergedEnvironment(...) ?? baseEnv`
(line 365-366) and `mergedEnvironment` (`LSPWorkspaceOverrides.swift:230-243`) layers the
repo's `env` ON TOP of the scrubbed base. So a refused-command `lsp.json` still injects its
`args` + `env` into a trusted server. The trust gate (`isOverrideCommandTrusted`) only gates
the *binary path*, not args/env. The vector is real (node-based servers honor `NODE_OPTIONS`
in env — `PATH`/`NODE_OPTIONS`-class vars are not name-scrubbed; many servers take
`--require`/`--plugin`/config-path flags). Medium stands.

### LSP `which` / `xcrun` / bundled binary resolution skips the writable-dir safety check inconsistently

**Severity:** low

**Location:** `Sources/ViewerCore/LSP/LSPDiscovery.swift:65-101`
(`resolveBinary`), `122-136` (`isBinarySafeToSpawn`).

**Why:** `isBinarySafeToSpawn` (refuse a server whose containing dir is
group/world-writable — the S3.1 hardening) is applied to the augmented-prefix
candidates (line 84) and the `which` result (line 96), but **not** to the bundled
fallback (`Contents/Resources/lsp/<name>`, line 72 — acceptable, app-controlled) nor
to the `sourcekit-lsp` path resolved via `xcrun -f` (`locateSourceKitLSP`,
lines 22-34). More importantly, the check only inspects the binary's *immediate*
parent directory mode; it does not consider an ancestor directory being
world-writable (e.g. `/tmp/x/bin/server` where `/tmp/x` is `0777` but `/tmp/x/bin` is
`0755` — an attacker who can write `/tmp/x` can `rename` `bin`). Given GUI apps
inherit a minimal `$PATH`, the practical exposure is small, and the design comment
explicitly scopes the check to "the obviously-bad `0o777` lab-machine scenario," so
this is low — but the inconsistency means a maliciously-configured `$PATH` entry that
resolves via `which` is checked while an equivalent `xcrun`-resolved path is not, and
the single-level dir check is weaker than the doc implies.

**Fix:** Apply `isBinarySafeToSpawn` to every resolved server path (including the
`xcrun` result), and widen it to walk the binary's ancestor directories up to a
trusted root, refusing if any ancestor is group/world-writable (mirroring the
component-wise containment logic already in `LSPLanguage.isPath`).

**VERDICT: CONFIRMED** — `isBinarySafeToSpawn` IS applied to augmented-prefix candidates
(`LSPDiscovery.swift:84`) and the `which` result (line 96), but NOT to either
`locateSourceKitLSP` path — the `xcrun -f` result (lines 22-28) and the
`/usr/bin/sourcekit-lsp` fallback (lines 30-33) return their URLs directly with no check.
The check also inspects only the immediate parent (`(path as NSString).deletingLastPathComponent`,
line 123), not ancestors, so the 0777-ancestor/0755-leaf rename-swap it describes is not
caught. Both factual claims hold. Practical exposure is small (xcrun resolves into the
SIP-/root-owned Xcode toolchain; GUI PATH is minimal), which is why the finding self-rates
low — the inconsistency and single-level limit are real. Low stands.

### ffmpeg locator honors `$PATH` without the writable-dir safety check applied elsewhere

**Severity:** low

**Location:** `Sources/ViewerCore/Audio/FFmpegLocator.swift:35-46` (PATH probe) and
`Sources/ViewerCore/Audio/AudioExporter.swift:156-185` (`runFFmpeg`).

**Why:** `FFmpegLocator.resolve` walks `$PATH` and spawns the first `ffmpeg` it
finds, with no equivalent of `LSPDiscovery.isBinarySafeToSpawn` — so a
group/world-writable directory early on `$PATH` could host a hostile `ffmpeg` that
runs (with a four-var env allowlist, but still arbitrary code) when the user exports
MP3. The exposure is small (MP3 export is an explicit, infrequent user action; GUI
`$PATH` is usually minimal; the user can pin an explicit path in Settings) and the
spawn correctly uses an args array (no shell) plus a scrubbed env, so it's low. Also
note: in `runFFmpeg`, the user-chosen output `url.path` is passed as a positional
argument; an output path beginning with `-` would be parsed by ffmpeg as an option
rather than a filename (an argument-injection nuisance, not RCE, since paths come
from `NSSavePanel`).

**Fix:** Run discovered `ffmpeg` candidates through the same writable-dir ownership
check as LSP binaries. Defensively, separate the ffmpeg output path from option
parsing with a `--` end-of-options sentinel before `url.path`
(`["-f", "mp3", "--", url.path]`) so an unusual output filename can't be reinterpreted
as a flag.

**VERDICT: CONFIRMED** — `FFmpegLocator.resolve` (`FFmpegLocator.swift:35-42`) walks `$PATH`
and returns the first executable `ffmpeg` with no `isBinarySafeToSpawn`-equivalent
ownership check (`LSPDiscovery` has one; this does not). `runFFmpeg`
(`AudioExporter.swift:167-185`) correctly uses an args array (no shell) and a 4-var env
allowlist (`PATH/HOME/TMPDIR/LANG`), and `url.path` is passed as a positional arg with no
`--` sentinel (lines 159-161), so a path beginning with `-` is parsed as a flag. All claims
accurate; exposure is small (explicit infrequent MP3 export, minimal GUI PATH, output path
from `NSSavePanel`), so low is correct. Low stands.
