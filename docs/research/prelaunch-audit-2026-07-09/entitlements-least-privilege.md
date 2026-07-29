# Pre-launch product review — Entitlements & sandbox posture (least privilege)

**Dimension:** Audit the deliberately non-sandboxed hardened-runtime choice: justify each
entitlement, TCC prompt copy, security-scoped bookmark handling, and whether any capability
can be dropped before ship.

**Date:** 2026-07-10
**Reviewer:** entitlements-least-privilege agent (read-only pass)
**Scope:** `scripts/entitlements.plist`, `scripts/Info.plist`, `scripts/build-app.sh`,
`scripts/sign-and-notarize.sh`, and every ViewerCore/ViewerUI subsystem that touches a
TCC-gated or privilege-bearing capability (MCP socket, AX/CGEvent synth, plugin/LSP/task
subprocesses, PTY terminal, `dlopen` grammar loader, URL scheme, screen capture, network).

---

## Executive summary

The entitlements posture is, on the whole, **deliberate, minimal, and well-reasoned** —
which is rare and worth stating plainly. The app ships **non-sandboxed with hardened
runtime** (a defensible choice for a "read any user file" developer tool), and the
`entitlements.plist` explicitly sets every dangerous opt-out (`allow-jit`,
`allow-unsigned-executable-memory`, `disable-library-validation`,
`disable-executable-page-protection`) to **`<false/>`**. That is stricter than "omit the
key" and signals intent. The `sign-and-notarize.sh` pass applies entitlements to the outer
`.app` **only**, never `--deep` onto nested dylibs (SIGN-06) — correct.

However, the **`entitlements.plist` file is inert in the day-to-day build path**: the
`build-app.sh` local-dev codesign does **not** pass `--entitlements` at all, so the
`<false/>` opt-outs the file documents are never actually stamped onto the binary the owner
runs from `/Applications`. Only the release `sign-and-notarize.sh` applies them. This is the
single most important finding (P1) — the security posture is only as good as the pass that
ships, and the two passes disagree.

The rest of the findings are about capabilities that are *reachable* precisely because the
app is unsandboxed, and whether the app's own containment fences are the real security
boundary (they are, and they are mostly good):

- The **always-on MCP unix-domain socket** (`chmod 0600`, same-user) hands any same-user
  process the app's full automation surface with **no auth token** — flagged in the
  security-core report; re-stated here as an entitlement-posture consequence (P1).
- **`dlopen` of grammar dylibs** works only because `disable-library-validation` semantics
  don't block *same-Team-signed* libraries — but the release path signs each grammar dylib
  with a **derived identifier under the app's Team**, so validation passes without the
  dangerous opt-out. Good. One residual risk: the loader's `dylibPath` search order includes
  `.build/<config>/` and a `GRAMMAR_DYLIB_DIR` env override (P2 — dev-only, should be
  compiled out of release).
- **TCC usage-description copy** is present for Documents/Desktop/Downloads/Removable/Network
  but is **generic and slightly inaccurate** now that the app is a full editor + terminal +
  task-runner, not just a viewer ("reads files … to display them"). Apple reviewers and
  privacy-conscious users read these (P2).
- **No `NSAppleEventsUsageDescription`, no Accessibility (`AXIsProcessTrusted`) prompt copy**,
  even though `UIEventSynth.typeKeys` posts real `CGEvent`s to `.cgSessionEventTap` and the AX
  driver walks other-process AX trees. These paths are gated to the VM/script harness, not
  production — but the gating is by env/flag, not by compilation, so the capability ships in
  the release binary (P2).

Net: **no P0.** One P1 that is a genuine ship-gate (entitlements not applied in the install
path), one P1 restatement of the socket-auth gap, and a cluster of P2 hardening items. The
sandbox-vs-TCC decision itself is sound and I do **not** recommend adopting App Sandbox before
launch (it would force a security-scoped-bookmark rewrite of the entire file-access model —
a one-way-door change, tracked as UX-11 in `docs/TRACK_A_READINESS_2026-05-30.md`).

---

## Methodology

**What I examined (static analysis, read-only):**

- `scripts/entitlements.plist` — the full file (33 lines); all four opt-outs.
- `scripts/Info.plist` — full file (192 lines): TCC usage strings, `NSServices`,
  `CFBundleURLTypes`, `UTExportedTypeDeclarations`, document types.
- `scripts/build-app.sh` — the codesign block (lines ~300-390): local-dev signing, `--deep`,
  `--timestamp=none`, ad-hoc fallback. Confirmed **no `--entitlements` flag**.
- `scripts/sign-and-notarize.sh` — full file: inside-out signing, entitlements applied to the
  outer `.app` only (line 166), hardened runtime + secure timestamp.
- `scripts/install-mdv-cli.sh` — the `mdv` shim (delegates to `/usr/bin/open -a`, no new
  entitlement).
- MCP surface: `Sources/ViewerCore/Automation/MCPSocketListener.swift` (bind, `chmod 0600`,
  same-user model), `MCPSocketBridge.swift`, `MCPToolCatalog.swift` (`validatedExistingURL`
  jail, `run_task`, `move_file`, `open_path`), startup wiring in
  `Sources/MarkdownViewer/main.swift`.
- Privilege-bearing subprocess spawns: `Plugins/PluginSubprocessHost.swift` (scrubbed env,
  symlink-escape containment), `LSP/LSPDiscovery.swift` (PATH/Homebrew/xcrun resolution +
  ownership check), `TaskRunner/RunSpec.swift` + `MCPToolCatalog.runTask`, `Terminal/PTYProcess.swift`.
- AX / event synthesis: `Sources/ViewerUI/Automation/UIEventSynth.swift`,
  `AXUIElementNode.swift`, `Sources/ViewerCore/Automation/AXDriverCore.swift`,
  `Sources/MarkdownViewer/ScriptRunner.swift`.
- `dlopen`: `Sources/ViewerCore/Highlight/GrammarLoader.swift` (RTLD_LAZY|RTLD_LOCAL, search
  order).
- Screen capture: `Sources/ViewerUI/DiagnosticDump.swift` (same-process `cacheDisplay`, no
  Screen-Recording TCC).
- URL scheme: `Sources/ViewerCore/URLSchemeRouter.swift` + `Security/URLSchemePolicy.swift`.
- Persistence: `Sources/ViewerCore/BookmarksStore.swift` (plain paths, not security-scoped
  bookmark data — the tell that the app is not sandboxed).
- Network posture: grep for `URLSession` (3 hits), `NSAppTransportSecurity` (absent — default
  ATS), `BrowserNavigationPolicy.swift` (loopback lock).
- Cross-referenced `docs/research/prelaunch-audit-2026-07-09/security-core.v2.md` and
  `attack-surface.v2.md` to avoid double-reporting and to inherit their socket findings.

**How much:** ~30 files opened, ~15 targeted greps. No tests run (static-only per constraint).
Did not build or inspect a signed bundle's actual entitlement blob (no fresh signed release in
`dist/` to `codesign -d --entitlements`).

---

## Findings

### F1 — `build-app.sh` codesign does NOT apply `entitlements.plist`; the `<false/>` opt-outs never reach the installed binary
- **Severity:** P1
- **File:** `scripts/build-app.sh:365-388` (the `codesign --force --deep … --options runtime`
  block and the ad-hoc fallback); contrast `scripts/sign-and-notarize.sh:160-167`.
- **Evidence:** The local-dev signing pass in `build-app.sh` runs
  `codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp=none
  "$SIGN_STAGE"` with **no `--entitlements` argument**. Grep confirms the string
  `entitlements` appears in `build-app.sh` **only in comments**, never as a flag. The
  validation ladder in `CLAUDE.md` step (4) is `build-app.sh debug --install` → this is the
  bundle the owner launches from `/Applications`. Only `sign-and-notarize.sh` (the
  release/notarize path, requiring a Developer ID cert the project does not yet have) passes
  `--entitlements "$ENTITLEMENTS"`.
- **Impact:** The carefully-authored `entitlements.plist` — the artifact this whole review
  centers on — is **inert for every build the owner and testers actually run**. With
  `--options runtime` but no entitlements file, the binary gets hardened-runtime defaults,
  which happen to *also* disallow the dangerous opt-outs, so the *effective* posture is
  similar. BUT: (a) the posture is now implicit/undocumented rather than the explicit
  `<false/>` the file promises; (b) any future entitlement the app genuinely needs (e.g. an
  `NSAppleEventsUsageDescription`-paired temporary exception, or a JIT entitlement for a
  scripting engine) would be silently missing in dev builds and only appear at notarization,
  producing a "works when signed for release, broken in dev" skew — exactly the class of trap
  `CLAUDE.md` warns about with the VM toolchain. There is also no test asserting the shipped
  entitlement blob matches `entitlements.plist`.
- **Suggested fix:** Add `--entitlements "$SCRIPT_DIR/entitlements.plist"` to the
  `build-app.sh` local-dev `codesign` invocation (the `--deep` pass is the outer-bundle sign
  here, so it lands on the app; if the derived-identifier concern from SIGN-06 applies, split
  the dylib sign out first as `sign-and-notarize.sh` already does). Add a headless gate check
  that runs `codesign -d --entitlements - dist/TextView.app` and diffs against the plist.
- **Fix size:** S (one flag + a guard script). M if the `--deep` split is needed to keep
  entitlements off nested dylibs.
- **Fix risk:** careful — signing changes can break launch/TCC-grant stability; test that the
  `MarkdownViewer Local Dev` grant survives a rebuild after the change.

### F2 — Always-on MCP unix socket grants the full automation surface to any same-user process with no auth (entitlement-posture consequence)
- **Severity:** P1
- **File:** `Sources/ViewerCore/Automation/MCPSocketListener.swift:13-16, 69-110`;
  started unconditionally at `Sources/MarkdownViewer/main.swift:225`.
- **Evidence:** `startMCPSocketListener()` is called on every normal GUI launch (not behind a
  flag or preference). The listener binds `~/Library/Application Support/MarkdownViewer/mcp.sock`,
  `chmod 0600`, and each accepted connection gets a full `MCPServer` over the same
  `MCPToolCatalog` that can `open_path`, `run_task` (spawn build tasks), `move_file`,
  `rename_symbol`, drive the live UI, and read visible/file text. The docstring states the
  security model verbatim: *"same-user only … no auth token in v1."*
- **Impact:** Because the app is **unsandboxed**, this socket inherits the user's full file
  and process authority. Any same-user code — a malicious npm postinstall, a downloaded
  helper, unsandboxed same-user malware — can connect and drive the app: exfiltrate any file
  under `$HOME` via `open_path` + `visible_text`, or execute discovered project tasks via
  `run_task`. `chmod 0600` stops *other users*, not *other same-user processes* (the actual
  macOS threat model for a dev machine). This is the exact same issue raised in
  `security-core.v2.md`; I re-state it here because it is the headline *consequence* of the
  no-sandbox posture and belongs in the entitlements review's risk ledger.
- **Suggested fix:** (a) gate the listener behind an explicit opt-in preference/flag
  (default off) so it isn't a resident attack surface for users who never drive the app via
  MCP; and/or (b) add a per-launch capability token: write a random token into the 0600
  socket dir readable only by a client the user explicitly launches, and require it in
  `initialize`. Minimum: document the residual risk in the shipping security notes.
- **Fix size:** M (opt-in flag) / L (token handshake + client plumbing).
- **Fix risk:** careful — changes the `--mcp-connect` UX; the bridge's stateless-reconnect
  assumption (MCPSocketBridge serve loop) must still hold.

### F3 — TCC usage-description strings are generic and understate the app's actual capabilities
- **Severity:** P2
- **File:** `scripts/Info.plist:41-50`.
- **Evidence:** All five folder-access strings read variations of *"TextView reads files from
  your X folder to display them."* The app is no longer display-only: it is a full editor
  (writes files), a terminal host (PTY spawns `zsh`), a task runner (`run_task` executes
  Makefile/npm tasks), an LSP client (spawns language servers), and a git client.
- **Impact:** Two problems. (1) **Accuracy/consent:** a user granting "Documents" access based
  on "to display them" is not being told the app can also *write* and *execute* under that
  tree — thin consent that a privacy reviewer or a security-conscious user will notice. (2)
  **App Store / notarization review copy:** Apple's reviewers read these; "to display them" on
  an app that writes and runs tasks invites a rejection or a clarification request. There is no
  `NSDocumentsFolderUsageDescription`-style string mentioning writes.
- **Suggested fix:** Reword to reflect read+write+run, e.g. *"TextView reads and edits files in
  your Documents folder, and may run project tasks you invoke there."* Keep each one honest to
  what the app does in that location.
- **Fix size:** S.
- **Fix risk:** safe (string-only).

### F4 — CGEvent posting + other-process AX traversal ship in the release binary, gated only by env/flags, with no Accessibility/AppleEvents usage strings
- **Severity:** P2
- **File:** `Sources/ViewerUI/Automation/UIEventSynth.swift:283-302` (`typeKeys` →
  `CGEvent(...).post(tap: .cgSessionEventTap)`); `Sources/ViewerUI/Automation/AXUIElementNode.swift:22-24`
  (`AXUIElementCreateApplication(pid)`); `Sources/MarkdownViewer/ScriptRunner.swift:203-225`
  (the `ui-type`/`ui-key` verbs).
- **Evidence:** `typeKeys` builds real `CGEvent` keystrokes and posts them to the session
  event tap; `AXUIElementNode.application(pid:)` walks another process's live AX tree. Both are
  reachable through the `--script` runner / `MDV_SCRIPT_PATH` env (gated at
  `main.swift:531`, `ScriptRunner`), which is a **runtime** flag, not a compile-time exclusion.
  There is **no** `NSAppleEventsUsageDescription` and no `AXIsProcessTrusted()` prompt copy
  anywhere (grep returned only the LSP-roadmap doc). The code comments correctly note
  `.cgSessionEventTap` posting "needs Accessibility TCC" off the asuser bridge.
- **Impact:** The capability to synthesize input events and read other apps' AX trees exists in
  the shipped binary. It is *inert* without the harness env vars and without a granted
  Accessibility permission, so real-world exploitability is low — but from a least-privilege
  standpoint, a production build should not carry an automation-driver path that only a runtime
  env var separates from activation. If Accessibility is ever granted to the app (e.g. a user
  reuses a grant), the `--script` env path becomes a same-user input-injection primitive.
- **Suggested fix:** Compile the `ui-type`/`ui-key`/CGEvent-posting and other-process AX
  traversal behind a build flag (`#if MDV_AUTOMATION_HARNESS`) excluded from release, OR at
  minimum assert at startup that these paths are unreachable unless a dedicated
  `MDV_TEST_INSTANCE`-style build. If any production feature genuinely needs AppleEvents/AX,
  add the paired usage string and an explicit `AXIsProcessTrusted` gate with user-facing copy.
- **Fix size:** M.
- **Fix risk:** careful — must not break the VM UAT harness that depends on these verbs.

### F5 — Grammar `dlopen` search path includes dev-only locations and an env override that should be compiled out of release
- **Severity:** P2
- **File:** `Sources/ViewerCore/Highlight/GrammarLoader.swift:176-200` (the `dylibPath`
  search order + `GRAMMAR_DYLIB_DIR` env override).
- **Evidence:** The loader resolves grammar dylibs via, in order: `Bundle.main/Contents/Frameworks`,
  the executable's sibling `Frameworks`, `.build/<config>/`, and a `GRAMMAR_DYLIB_DIR` env
  override (which, when set, becomes the *only* path checked). It `dlopen`s with
  `RTLD_LAZY | RTLD_LOCAL` and never `dlclose`s (correct for language handles).
- **Impact:** In a hardened-runtime binary **without** `disable-library-validation`, macOS
  requires every `dlopen`ed Mach-O to be signed by the **same Team** as the host (or be a
  platform binary). The release path signs each grammar dylib under a derived Team identifier
  (`sign-and-notarize.sh:117-127`), so production `dlopen` succeeds legitimately — good, no
  opt-out needed. BUT the `GRAMMAR_DYLIB_DIR` env override and the `.build/` fallback are
  **dev/test conveniences that ship in the release binary**. An attacker who can set the app's
  environment (e.g. via a poisoned launch) could point `GRAMMAR_DYLIB_DIR` at an attacker dir;
  library validation would still *reject* an unsigned/other-Team dylib there (so this is
  defense-in-depth, not an open hole), but a least-privilege release should not honor an
  env-var dylib redirect at all.
- **Suggested fix:** `#if DEBUG`-gate the `GRAMMAR_DYLIB_DIR` override and the `.build/`
  fallback so release resolves **only** from `Bundle.main/Contents/Frameworks`. This also makes
  the "missing dylib" contract deterministic in production.
- **Fix size:** S.
- **Fix risk:** safe (release-only tightening; dev tests keep the override under DEBUG).

### F6 — No compiled record / gate that the shipped entitlement set matches the documented posture
- **Severity:** P2
- **File:** `scripts/entitlements.plist` (whole file); no corresponding test in `Tests/`.
- **Evidence:** Grep for `entitlements` across `Tests/` returned nothing. There is no gate that
  asserts the four opt-outs are `<false/>` in the *actually signed* bundle, nor that no
  additional entitlements crept in. Combined with F1 (the file isn't even applied in the dev
  path), the documented posture is entirely convention-enforced.
- **Impact:** A future change that adds `com.apple.security.cs.allow-jit` (e.g. someone wiring
  in a JS engine) or flips `disable-library-validation` to load a third-party dylib would pass
  CI silently — there is no teeth. For a security-sensitive posture the project otherwise
  guards aggressively (bundle-size caps, dylib-identifier checks, negative-control switches),
  the *entitlements* have none.
- **Suggested fix:** Add a headless gate script (sibling to `check-dylib-identifiers.sh`) that,
  post-sign, runs `codesign -d --entitlements :- dist/TextView.app` and fails if any
  `allow-jit` / `allow-unsigned-executable-memory` / `disable-library-validation` /
  `disable-executable-page-protection` is `true`, or if an unexpected entitlement key appears.
- **Fix size:** S.
- **Fix risk:** safe.

### F7 — `run_task` executes discovered project tasks over the always-on socket — an unsandboxed code-execution surface reachable without UI
- **Severity:** P2
- **File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:417, 451-475` (`runTask`,
  shell-free spawn via `/usr/bin/env`).
- **Evidence:** `run_task` resolves an id against a fresh `RunnableTaskDiscovery` pass (an
  allowlist of Makefile/npm/etc. targets under the jailed project root) and spawns it
  shell-free through `/usr/bin/env`, bounded by a timeout and output cap. The `path` is
  `validatedExistingURL`-jailed to `$HOME`/temp. It is reachable via the always-on MCP socket
  (F2).
- **Impact:** This is code execution, correctly constrained to *discovered* tasks under a jailed
  root and shell-free — genuinely good hardening. But because it rides the unauthenticated
  socket (F2) and the app is unsandboxed, a same-user attacker who can write a `Makefile`/
  `package.json` anywhere under `$HOME` and then call `run_task` gets arbitrary execution with
  the user's authority. The containment is "only allowlisted tasks," but the allowlist is
  attacker-influenceable (they control the project files). Least-privilege mitigation is at the
  socket-auth layer (F2), not here — noting it so the risk is traced end-to-end.
- **Suggested fix:** Covered by F2 (socket auth/opt-in). Additionally consider a per-session
  user confirmation for the first `run_task` in a project root.
- **Fix size:** (defer to F2).
- **Fix risk:** careful.

### F8 — Auto-snapshot / diagnose flags write artifacts and bypass state-flush `exit()` — dev flags present in the release binary
- **Severity:** P3
- **File:** `Sources/MarkdownViewer/Diagnostics.swift:115-165` (`scheduleAutoSnapshot`),
  `main.swift:590-607` (`--diagnose`, `--auto-snapshot`).
- **Evidence:** `--auto-snapshot` and `--diagnose` are parsed from argv in the production
  binary. `scheduleAutoSnapshot` writes `mdv-auto.{json,png}` into the per-user tmpdir with
  `0600` perms (OBS-2 — good) and calls raw `exit()` bypassing session flush; the comment
  (S4, lines 119-131) documents this is safe only because the flag never opens a real
  workspace.
- **Impact:** Low: artifacts are 0600 in the per-user tmpdir (not `/tmp`), and the paths are
  dev-only. The residual concern is purely least-privilege surface: diagnostic dump paths that
  serialize the view tree ship in release and are one argv flag away. No privilege escalation.
- **Suggested fix:** `#if DEBUG`-gate `--auto-snapshot`/`--diagnose` argv handling, or leave as
  is and document. Low priority.
- **Fix size:** S.
- **Fix risk:** safe.

---

## Positive observations

- **`entitlements.plist` sets every dangerous opt-out to `<false/>` explicitly** rather than
  omitting them (`scripts/entitlements.plist:23-30`). This is stronger and more auditable than
  the common "omit the key" approach, and the header comment articulates *why* the app is
  non-sandboxed and *why* WKWebView needs nothing extra. Exemplary intent-documentation.
- **Entitlements are applied to the outer `.app` only, never `--deep` onto nested dylibs**
  (`sign-and-notarize.sh:107-127, 160-167`, SIGN-06). Each grammar dylib is signed with a
  **derived per-file identifier** under the app's Team, so hardened-runtime library validation
  passes *without* `disable-library-validation` — the correct way to ship `dlopen`ed plugins.
- **No `NSAppTransportSecurity` / `NSAllowsArbitraryLoads` key** — the app keeps default ATS.
  The built-in browser tab is locked to loopback origins by `BrowserNavigationPolicy.swift`
  rather than by weakening ATS globally.
- **MCP + URL-scheme file access is jailed to `$HOME` + per-user temp** with symlink-escape
  resolution on both operands (`MCPToolCatalog.validatedExistingURL:1153-1187`,
  `URLSchemePolicy.containedPath:38-79`). Containment is checked *before* existence to avoid an
  existence oracle. The anchored-prefix bug class (`hasPrefix(temp)` admitting a sibling) is
  explicitly closed.
- **Plugin subprocess host scrubs the environment** (no `PATH`/`USER`/`*_TOKEN`) and enforces
  physical symlink-resolved containment of the `bin` inside the plugin folder
  (`PluginSubprocessHost.swift:161-184, 446-458`) — SEC-007.
- **LSP binary discovery gates even the `xcrun`-resolved path** through a writable-dir
  ownership check (`LSPDiscovery.swift:15-46`, S3.1/TSK-963) rather than trusting `xcrun`
  output blindly.
- **Same-process window capture uses `cacheDisplay`, not ScreenCaptureKit** — so the app needs
  **no Screen-Recording TCC entitlement** (`DiagnosticDump.swift:310-323`). Correct least-privilege
  choice; the permission is only for capturing *other* processes.
- **Persisted bookmarks/recent-paths are plain path strings, not security-scoped bookmark
  data** (`BookmarksStore.swift`) — consistent with the non-sandboxed model, and avoids
  hoarding scoped-access tokens the app doesn't need.
- **The `mdv` CLI shim delegates to `/usr/bin/open -a`** and explicitly needs no new entitlement
  (`install-mdv-cli.sh:14-16`).
- **MCP socket is `chmod 0600` and unlinks stale nodes on bind** (`MCPSocketListener.swift:96,
  74`); the walkthrough URL-scheme route **prompts before auto-driving** the UI
  (`URLSchemeRouter.swift:16-21`, `main.swift:680-688`) — a drive-by web link cannot silently
  automate the app.

---

## Coverage gaps (not examined / out of scope for this pass)

- **Did not inspect a freshly-signed release bundle's actual entitlement blob.** There is no
  current Developer-ID-signed bundle in `dist/` to run `codesign -d --entitlements -` against;
  F1/F6 are inferred from the *scripts*, not from a signed artifact. A follow-up should build
  via `sign-and-notarize.sh` on a machine with a Developer ID cert and diff the real blob.
- **No dynamic/runtime TCC testing.** Did not launch the app to observe which TCC prompts
  actually fire, in what order, or whether the grant persists across rebuilds (the
  `MarkdownViewer Local Dev` cert claim). VM-only per constraints.
- **PTY terminal privilege inheritance** (`Terminal/PTYProcess.swift`) examined only for
  existence, not for env-scrubbing parity with the plugin host — the spawned login shell
  presumably inherits the app's full environment. Worth a dedicated look (a terminal in an
  unsandboxed app is by design a full shell; the question is only whether it leaks app-internal
  env like tokens).
- **`serve`/`mdv-serve` daemon launchd posture** (`rust-core/crates/serve/src/lifecycle.rs`)
  examined only for socket binding (launchd-activation vs self-bind); did not audit its own
  entitlements/plist template (`scripts/vm-uitest/com.markdownviewer.uitest.plist.template` is
  a test artifact, not the daemon's shipping agent).
- **Network egress inventory** was surveyed by grep only (`URLSession` in `HTTPClientCore`,
  `FeedFetcher`, `MCPServer`) — did not trace whether feed-fetching or the HTTP client honors a
  no-arbitrary-origin policy. Relevant to a future outbound-network entitlement decision but
  orthogonal to the current no-sandbox posture.
- **Did not evaluate the App Sandbox migration itself** beyond confirming it is a documented,
  deliberately-deferred one-way-door (UX-11). The recommendation stands: do not adopt before
  launch.
