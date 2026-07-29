# Wall-type struggles — hard macOS/platform walls (markdown_viewer, 2026-05-14 → 07-10)

Dimension: external, largely non-negotiable platform boundaries — TCC, notarization/signing,
WKWebView process model, SwiftPM module staleness, LaunchServices/AX driving limits, macOS
shell (GNU-less BSD userland). Distinguishing feature vs. other struggle classes: these are
walls the agent **cannot code its way around** — only design around, budget for, or route
through a different validation vehicle.

Evidence base: `LESSONS.md` (grepped: TCC×35, WKWebView/WebKit×51, codesign/hardened-runtime/
dlopen×20, SwiftPM staleness×38, LaunchServices×6, AX/AXUIElement×5, compositor×4),
`docs/research/prelaunch-audit-2026-07-09/packaging-notarization.md`,
`docs/research/prelaunch-audit-2026-07-09/entitlements-least-privilege.md`,
`docs/research/prelaunch-audit-2026-07-09/accessibility.v2.md`, and the corpus batch reports
(`summaries/docs/d-lessons-1of2.md`, `d-lessons-2of2.md`).

---

## Taxonomy — the distinct types in this dimension

### 1. TCC identity/re-prompt churn (ad-hoc signing keyed on cdhash)
**Frequency: very high (35 LESSONS.md hits) · Severity: medium (dev-loop friction, not a ship-blocker once fixed).**
Ad-hoc code signing (`codesign --sign -`) gives the binary a fresh code-directory hash on
every rebuild; TCC (Documents/Downloads/Desktop/Screen-Recording/Full-Disk grants) keys ad-hoc
grants on `cdhash`, so **every rebuild looked like a brand-new app** and re-prompted for every
protected folder. Evidence: `LESSONS.md:843-888` ("TCC re-prompt-on-every-rebuild: ad-hoc
signing is keyed on cdhash"), `LESSONS.md:1024-1034` ("TCC on ad-hoc-signed builds"),
`LESSONS.md:1181-1203` (don't change `CFBundleIdentifier`, don't write to `~/Documents` from
automated paths).

### 2. TCC + screen-capture attribution ambiguity in headless/CI-style launch contexts
**Frequency: high · Severity: high (blocked an entire test tier for weeks).**
macOS 15's "Screen Capture Privacy" redacts window content from `screencapture` when the
launching process's TCC ownership is ambiguous — specifically a process spawned via
`sudo launchctl asuser <uid>` (root launcher, user-owned session) reads as ownership-ambiguous
and gets its windows blacked out even though the window is genuinely on-screen and the
capturing process itself holds the Screen-Recording grant. Evidence: `LESSONS.md:1366-1385`
(root cause), `LESSONS.md:3217` ("VM pixel lane: TCC screencapture is attributed to xctest, NOT
/bin/bash"), `LESSONS.md:224/246` (T5 pixel capture denied under `test` mode, works only under
`all`/`build_all`'s root+GUI context — and even that grant "lapsed" after a rebuild changed the
cdhash, TSK-1334, owner-only to restore because SIP blocks agent TCC-database writes).

### 3. Hardened-runtime library validation vs. self-signed certs (no Team ID) — silent dlopen failure
**Frequency: 1 confirmed instance, but P1 severity — silently degrades the daily-driver app.**
`--options runtime` (hardened runtime) implies library validation, which requires nested
dylibs to share the *signing binary's Team ID*. A self-signed local cert has **no Team ID**, so
`dlopen` of the lazy-loaded tree-sitter grammar dylibs (XML/JS/TS) is denied at runtime in
`/Applications/TextView.app` — every build the owner actually launches. `GrammarLoader`
swallows the failure (returns `nil`, log-only), so nobody sees the degradation, and **every
automated lane signs ad-hoc without `--options runtime`**, so the failure mode is invisible to
CI/VM entirely (a structural false-green, not just a missed test). Evidence:
`docs/research/prelaunch-audit-2026-07-09/packaging-notarization.md` F1 (empirically
reproduced with a minimal dlopen probe) and F5 (root cause: zero automated lanes exercise the
hardened-runtime signing path at all).

### 4. Notarization pipeline — never run, never rehearsed
**Frequency: N/A (zero executions to date) · Severity: high latent risk (multiple stacked untested failure modes).**
No Developer ID identity exists on the dev machine (`security find-identity` → 0 valid
identities); `sign-and-notarize.sh`'s preflight would die immediately. In-place signing on
`dist/` (not a de-xattr'd staged copy, unlike the sibling `build-app.sh`/`verify-app.sh`)
recreates the exact iCloud-xattr race the project already paid to fix once (F6); no
post-staple Gatekeeper/quarantine first-launch check exists anywhere (F3); notarytool exit
status is never asserted (F7). Evidence: `packaging-notarization.md` executive summary + F2/F3/
F6/F7; `CLAUDE.md` "Local signing only... no Developer ID until shipping public."

### 5. WKWebView process-model walls (three distinct sub-failures under one "it's a web view" umbrella)
**Frequency: 51 LESSONS.md hits across several distinct mechanisms · Severity: high (multi-day rabbit holes, twice).**
- **5a. WebContent jetsam-kill under the VM GUI lane.** The CM6 editor's `WKWebView`
  WebContent XPC process gets marked `none-NotVisible` → jetsam priority 0 → idle-killed
  mid-test, specifically for the *editor* (heavy) WebContent, not the lighter rendered-preview
  one (which finishes before the killer fires). Root-caused via the RunningBoard unified log,
  not guesswork. Evidence: `LESSONS.md:278-282` (TSK-1046/1047, "a multi-day rabbit hole").
- **5b. `evaluateJavaScript` async-throws variant is flaky (`WKError` code 5).** The
  `async throws -> Any` overload deterministically throws for `undefined`/object results and
  *intermittently* throws even for plain Number/Bool — flake-killed reads that "should" be
  trivial. The completion-handler variant + `withCheckedContinuation` does not have the bug.
  Evidence: `LESSONS.md:284-286`.
- **5c. Full-screen `screencapture -x` doesn't composite window content in the VM GUI
  session** — only the desktop/menu bar. AppKit reports the window healthy
  (`visible=true onActiveSpace=true occluded=false`), yet the WKWebView content never
  reaches the WindowServer framebuffer read by a naive full-screen capture. `T5 PixelTestCase`
  works only because it captures **by window-ID** (`screencapture -l<id>`), which forces a
  per-window render independent of framebuffer compositing. Cost: 4 diagnostic rounds.
  Evidence: `LESSONS.md:223`.
- **5d. Synthesized CGEvents do not reach WKWebView text insertion.** CGEvent keydowns
  traverse WindowServer → app fine (a ⌘-chord test passed) but WebContent only accepts
  genuine hardware key events or JS-injected input for *text insertion* specifically —
  confirmed even after explicit `makeFirstResponder` + JS `.focus()`. Evidence:
  `LESSONS.md:479`.

### 6. Compositor occlusion — opaque `NSViewRepresentable` painting over SwiftUI siblings
**Frequency: 4 direct LESSONS.md hits, but flagged as "the project's single most expensive,
most-referenced lesson" by the corpus batch report · Severity: critical (recurred 4 times
before being structurally fixed).**
An opaque, layer-backed `NSViewRepresentable` (WKWebView, terminal surface, any AppKit
representable) composites its own `CALayer` **over** earlier-painted SwiftUI siblings sharing a
container — even when geometrically non-overlapping — and it's **position-dependent** (fine if
drawn after the surface, blanked if drawn before). `ImageRenderer`/`cacheDisplay`/headless
frame-walks give a **false green** for this class: `ImageRenderer` rasterizes SwiftUI's own
tree in isolation (draws a placeholder for the representable, no opaque layer to occlude);
`cacheDisplay` is blind to CA layers entirely (renders black). The only authoritative signal is
real WindowServer pixels via `screencapture -l<windowID>` (T5). Evidence: `CLAUDE.md`
"Compositor occlusion + the ImageRenderer false-green trap (TSK-488)" section (verbatim in this
repo's own instructions — it recurred 4 times before this rule existed);
`summaries/docs/d-lessons-1of2.md` top-highlight line.

### 7. SwiftPM cross-module staleness — two distinct staleness classes, both segfault-shaped
**Frequency: 38 LESSONS.md hits · Severity: high (SIGSEGV that looks exactly like an FFI bug, wastes root-cause time).**
- **7a. Cross-toolchain module staleness.** A bare `swift build` on the VM uses the default
  Swift 6.1.2 toolchain and writes a 6.1.2-compiled `.swiftmodule` into `.build`; the next
  6.3-toolchain test run reuses it by timestamp (SwiftPM's incremental build does not detect
  cross-toolchain mismatch) → `module compiled with Swift 6.1.2 cannot be imported by the
  Swift 6.3 compiler`. Evidence: `LESSONS.md:206`.
- **7b. Cross-module enum/type-layout staleness → SIGSEGV.** Adding a case mid-enum to an
  FFI-adjacent type (`RustCore.CoreError`) recompiles the *Sources* consumers but not the
  *Tests* target's object files that pattern-match the enum; the stale test objects segfault
  (signal 11) on a **pure-Swift** `throw CoreError.panic` with **no FFI involved** — looking
  exactly like an FFI/unwinding bug. Evidence: `LESSONS.md:3576-3583` ("SwiftPM staleness
  class #2"); the project's own `CLAUDE.md` codifies the fix as a standing rule ("touch every
  file that references it — INCLUDING the Tests/ targets' files").

### 8. AX/automation-driving limits — some interactions are structurally not synthesizable
**Frequency: low count but structural (defines a permanent "off-limits tier" in the test pyramid) · Severity: high (shapes the whole validation architecture).**
Faithful pointer-drag gestures are **not synthesizable in-process** (4 VM rounds spent trying,
TSK-1188) — this becomes the one permanently owner/human-gated tier
(`feedback_agent_driven_uat.md`, `CLAUDE.md`'s "the ONLY off-limits tier"). Separately,
`osascript activate` cannot always pull focus past a foregrounded System Settings/modal app
over the `launchctl asuser` bridge — TCC blocks programmatic AppleScript control in some
configurations. Evidence: `LESSONS.md:210` (canvas edit AX-gated), `LESSONS.md:1313-1316`.

### 9. GNU-less macOS shell / BSD userland friction
**Frequency: low direct count in LESSONS.md but codified as a standing exemplar list in
`CLAUDE.md` · Severity: low per-incident, moderate cumulative (small tax on nearly every
session).**
No GNU `timeout`; `grep` special-char literals need `-F`; `ps -p` doesn't combine with `-axo`;
zsh eats bare `==`/globs in echoed args; heredocs into `ssh` need single-quoted tags. Evidence:
`CLAUDE.md` "macOS/zsh shell exemplars (QoL — the 29-error class from the session
meta-analysis)" — explicitly named as a recurring class large enough to warrant its own
section, sourced from the 791-tool-error struggle metaanalysis.

### 10. Entitlements/least-privilege drift between dev and release signing passes
**Frequency: 1 confirmed instance, P1 · Severity: medium (currently masked by hardened-runtime defaults, but a landmine for the next entitlement).**
The authored `entitlements.plist` (all four dangerous opt-outs explicitly `<false/>`) is never
actually applied by the local-dev `build-app.sh` codesign pass (no `--entitlements` flag at
all) — only the release `sign-and-notarize.sh` path applies it, and that path has never run
(#4). The *effective* posture happens to be similar today only because hardened-runtime
defaults are also restrictive, but the moment a real entitlement is needed (e.g. a temporary
JIT exception), it will be silently absent in every build the owner tests and appear for the
first time at notarization. Evidence: `entitlements-least-privilege.md` F1.

### 11. Accessibility-identifier vs. VoiceOver-label conflation
**Frequency: systemic (99 `accessibilityIdentifier` vs. 30 `accessibilityLabel` occurrences) · Severity: P2/P3 (no ship-blockers, but a category error worth naming).**
Heavy investment in `accessibilityIdentifier` (feeds the project's own AX-automation driver)
is easy to mistake for genuine accessibility, but it is **invisible to VoiceOver** — a
test/automation handle only. The gap concentrates exactly where you'd predict: icon-only
controls that carry an identifier (for the agent driver) but no label (for a screen-reader
user). System accommodations (`accessibilityReduceTransparency`,
`accessibilityShouldIncreaseContrast`, `accessibilityDifferentiateWithoutColor`) are read
**zero times** despite 200+ translucency sites. Evidence: `accessibility.v2.md` executive
summary.

---

## What worked — practices that earned their keep

- **Switching from ad-hoc to a real (even self-signed) signing identity permanently fixed
  the TCC re-prompt churn.** TCC keys grants on `(identifier, cert-leaf-hash)` for a proper
  identity — stable across rebuilds, unlike `cdhash`. One-time re-prompt cost, then indefinite
  stability (cert good for 10 years). `scripts/setup-signing.sh` automates cert creation.
  Evidence: `LESSONS.md:860-888`.
- **Window-ID-targeted screencapture (`screencapture -l<windowID>`) instead of full-screen
  capture** sidesteps both the framebuffer-compositing gap (#5c) and forces a real per-window
  render — this became the *only* trustworthy pixel-validation path (T5 `PixelTestCase`).
  Evidence: `LESSONS.md:223`.
- **A structural, statically-checkable rule beats a runtime detector for compositor
  occlusion**: "grep for `NSRulerView`/`hasVerticalRuler`/`: NSLayoutManager`" is cheap,
  has no false-greens, costs nothing to enforce, and is *stronger* than the T5 pixel test
  (which only runs nightly/pre-release). Evidence: `CLAUDE.md` compositor section, "The rule
  is cheaper and stronger than the test."
  - Companion: a codified **negative-control switch**
    (`MDVNegativeControl.isBroken("<NAME>")` / `MDV_ENABLE_BROKEN_<NAME>=1`) proves a pixel
    test actually has teeth (deliberately breaks the invariant, confirms red, restores) —
    repeatable and committed, vs. hand-reverting once and hoping it stays proven.
- **In-process `WebViewTestCase` (mount the WKWebView inside the test process) instead of
  spawned-app UAT** completely sidesteps the jetsam-kill wall (#5a) — the sibling suites all
  pass on the VM once moved to this vehicle. This is a genuine "route around the wall," not
  just a mitigation: in-process WebView tests never have a WebContent XPC process that can be
  jetsam-killed for being backgrounded. Evidence: `LESSONS.md:278-282`.
- **Completion-handler `evaluateJavaScript` + `withCheckedContinuation`, extracting the
  Sendable value inside the handler**, eliminates the async-throws flake (#5b) entirely
  rather than retrying around it. Evidence: `LESSONS.md:284-286`.
- **The "T5-pixel-blocked ≠ render-blocked" split** — recognizing that only the pixel-exact/
  occlusion-composite slice of a render feature is actually wall-blocked, and that render
  build + in-process/DOM/T4 structural validation is always agent-doable — unblocked ~3
  features per tick that had been wrongly blanket-parked as "owner's lane." This is the single
  highest-leverage *process* countermeasure to a wall: narrow the blocked slice instead of
  deferring the whole feature. Evidence: `LESSONS.md:208`.
- **`--verify-resources` / `--verify-grammars`-style headless self-checks that run the real
  binary and hard-fail the build** turn a clean-machine-only crash class into a build-time
  gate. `--verify-resources` was born from an actual crash (`Bundle.module` resolving from a
  dev `.build` path) and is wired into both `build-app.sh` and CI. The audit's suggested fix
  for the dlopen wall (#3) is exactly this pattern extended one step further.
  Evidence: `LESSONS.md:248-252`; `packaging-notarization.md` F1 suggested fix.
- **Explicit "off-limits tier" boundary (AX-driven only) instead of a fuzzy "render is
  hard, defer to human" instinct** kept the agent doing 95%+ of render/UI work itself; only
  drag-gestures and similar genuinely non-synthesizable interactions are parked. Evidence:
  `CLAUDE.md` OWNER DIRECTIVE 2026-06-29; `LESSONS.md:210`.

---

## What hurt — costly failures and their mechanism

- **The lazy-grammar dlopen failure (#3) is invisible in every automated lane simultaneously,
  by construction** — not bad luck. CI and the VM sign ad-hoc (no cert exists there), which
  happens to *not* trigger `--options runtime`'s library-validation Team-ID check; only the
  owner's host has the real cert, and hardened-runtime signing with a *Team-ID-less*
  self-signed cert is precisely the one configuration that fails. The mechanism: **the wall
  only bites the one signing configuration nobody tests.** Root cause is a false-equivalence
  assumption (ad-hoc-vs-self-signed "should be similar enough") that nobody verified
  empirically until the audit's dlopen probe. Cost: silent feature degradation (code folding/
  structural search for 3 languages) shipped to the daily-driver app for an unknown duration.
- **The VM GUI-lane screencapture-attribution wall (#2) cost 4 diagnostic rounds** because
  the AppKit-level signal (window `visible=true`, `occluded=false`) actively lied about
  capturability — the wall isn't "no window," it's "window genuinely exists and is genuinely
  invisible to one specific capture mechanism for TCC-ownership reasons unrelated to the
  window's real state." Diagnosis required going to the RunningBoard unified log, not the
  obvious AppKit APIs. This is the general shape of a *wall* struggle vs. a *bug* struggle:
  the failure signal is orthogonal to the actual application state.
- **`--options runtime` local signing was chosen for TCC stability (#1's fix) without
  re-auditing every consequence of hardened-runtime enforcement** — the fix for one wall (TCC
  churn) silently created the conditions for another (dlopen denial, #3). Walls interact:
  fixing one can open a different one, and neither is visible without an explicit empirical
  probe of the *combined* configuration.
- **Notarization risk is entirely unquantified** (#4) because it has literally never run —
  every latent issue (in-place xattr race, unchecked notarytool status, missing post-staple
  Gatekeeper check) is queued to surface **serially, for the first time, at the worst possible
  moment** (days before a real launch), each one costing a full multi-minute build-sign-submit
  cycle to diagnose. The cost isn't the individual fixes (all S/M per the audit) — it's that
  they compound and are undiscovered until crunch time.
- **The compositor-occlusion bug recurred FOUR times** before the structural (grep-based) rule
  existed, specifically because the standard verification tools (`ImageRenderer`,
  `cacheDisplay`, headless frame-walks) all give **false greens** for this exact class — the
  team kept re-verifying with tools structurally blind to the bug. The cost wasn't finding the
  bug each time; it was that each recurrence looked "fixed and tested" until the next real
  pixel check.
- **AX-drag non-synthesizability cost 4 VM rounds (TSK-1188) before being accepted as a hard
  wall** rather than a solvable harness problem — the natural instinct ("just try a different
  synthesis approach") burns real time against something that is genuinely, structurally
  off-limits (WKWebView/AppKit-level, not a test-harness bug).

---

## Design implications for the rebuild — concrete and actionable

**Avoidable by design (fix architecture, don't just budget for it):**

1. **Sign with a real identity (even self-signed with a Team ID substitute or a cheap
   Developer ID from day one) — never ad-hoc, ever, not even in early dev.** The TCC-churn
   wall (#1) is 100% avoidable by never taking the ad-hoc path in the first place; retrofitting
   cost real sessions here. If the budget allows, get the $99/yr Developer ID Apple Developer
   Program membership on day 1 of the rebuild and sign with it everywhere (dev and release) —
   it eliminates both #1 and the ad-hoc/hardened-runtime split that caused #3.
2. **Make every automated signing lane (CI, VM, local dev) use the SAME signing
   configuration the ship path uses**, from the first commit. The rebuild's #3-equivalent
   only existed because ad-hoc CI signing and cert-backed owner signing silently diverged.
   Pin one signing recipe; if a machine can't get the cert, that machine's build output is
   explicitly flagged "not representative," not silently trusted.
3. **Prefer in-process embedding of any secondary process surface (WebView content,
   terminal PTY, subprocess UI) for the TEST harness's default vehicle, and reserve
   spawned-app / VM-GUI validation for the narrow slice that genuinely needs real window
   compositing.** This is the single biggest lever against the WKWebView jetsam-kill (#5a)
   and framebuffer-compositing (#5c) walls — both dissolve when the test never leaves the
   test process. Design the app's WebView/terminal surfaces with an explicit "mount headless
   in a test host" seam from day 1 (this project retrofitted `WebViewTestCase` after burning a
   multi-day rabbit hole first).
4. **Encode the compositor-occlusion rule as a lint/grep-based CI check from the FIRST
   NSViewRepresentable + SwiftUI co-hosting**, not after 4 recurrences. Concretely: any
   SwiftUI stack that hosts both a SwiftUI-drawn sibling and an opaque `NSViewRepresentable`
   must apply `.compositingGroup().zIndex()` to both, in every layout branch, and a grep-based
   pre-commit/CI check should flag a representable + sibling pair without it.
5. **Budget the ABI/module-layout staleness class (#7b) out by keeping the FFI boundary
   type set small, additive-only, and versioned from day 1** (this rebuild's cross-language
   Rust↔Swift boundary makes #7b structurally likely to recur — every enum case addition on
   either side of the boundary is a staleness trap). Add a build-graph rule/CI check that
   touches (or forces recompilation of) every consumer, including Test targets, on any FFI
   type change — don't rely on remembering the manual `touch`.
6. **Decide the sandbox posture (App Sandbox vs. non-sandboxed hardened runtime) as a
   deliberate day-1 architecture call, not a default.** This project correctly reasoned that
   App Sandbox would force a security-scoped-bookmark rewrite of the entire file-access model
   — a one-way-door change — and deferred it (defensible for a "read any user file" dev tool).
   The rebuild should make this call explicitly and early, since retrofitting sandboxing after
   the file-access model is built out is far more expensive than deciding up front.

**Inherent cost to budget for (cannot be designed away, only planned around):**

7. **Notarization WILL surface stacked, previously-invisible failures the first time it
   runs — schedule a dedicated notarization dry-run session well before any real launch
   date, not as a last step.** Treat it as its own workstream with its own time budget, run
   end-to-end at least once as soon as a Developer ID cert exists (don't wait for "launch-
   ready" feature completeness first).
8. **Accept AX-driven interaction (real pointer-drag, and likely more classes like it —
   multi-touch gestures, native drag-and-drop between windows) as a PERMANENT validation
   tier requiring either a human or a genuinely different automation technology (not CGEvent
   synthesis).** Don't re-litigate this each time a new AX-blocked feature appears; design the
   test pyramid with this tier named explicitly from day 1 (as this project eventually did:
   "the AX tier" as one of a small, fixed set of lanes) so agents stop burning multi-round
   diagnostic budgets rediscovering it.
9. **TCC/screencapture attribution in ANY root-vs-user-launch-bridge context (sudo,
   launchctl asuser, CI runners impersonating a GUI session) is fragile and version-
   sensitive (macOS 15's Screen Capture Privacy is a moving target).** Budget recurring
   diagnostic time for this whenever the OS updates; don't assume a working recipe stays
   working across macOS versions.
10. **Some GNU-vs-BSD shell friction is permanent tax on any macOS-based agent workflow** —
    don't try to eliminate it; instead seed the new project's CLAUDE.md/agent instructions
    with the known gotcha list on day 1 (this repo only compiled its list after ~29 errors
    across many sessions; port the list, don't rediscover it).

---

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **Sign with a real (non-ad-hoc) identity from the FIRST build, in every environment
   (dev machine, CI, VM) — never ad-hoc, even temporarily.** TCC grants are keyed on
   `(bundle-identifier, cert-leaf-hash)`; ad-hoc's per-build `cdhash` guarantees permission
   re-prompt churn, and it also silently diverges CI/VM's signing behavior from the shipped
   configuration (masking hardened-runtime-only bugs like dlopen/library-validation denial).
2. **Whenever you flip a hardened-runtime / entitlement / signing flag to fix one problem,
   write and run an empirical probe of the new combined configuration before trusting it** —
   don't reason from "should be equivalent." (This project's TCC fix for #1 silently created
   #3; nobody probed the combination until a dedicated audit did.)
3. **For any WebView/AppKit-representable content, add an in-process test-mount seam
   (headless-hostable inside the test binary) on day 1** — never make the spawned-app /
   real-window path the *only* way to validate that surface. Reserve spawned-app / VM-GUI
   capture strictly for pixel-exact and true-compositing checks.
4. **Any SwiftUI container that co-hosts an opaque `NSViewRepresentable` (WebView, terminal,
   any AppKit surface) with SwiftUI-drawn siblings MUST get `.compositingGroup().zIndex()`
   on every sibling in every layout branch — enforce with a grep-based CI check, not a
   pixel test alone** (pixel tests run nightly at best; the static rule runs on every diff and
   has zero false-greens). `ImageRenderer`/`cacheDisplay`/any headless frame-walk is NEVER
   proof this class is fixed — only real WindowServer pixels (`screencapture -l<windowID>`)
   are authoritative.
5. **Treat any cross-language (Rust↔Swift FFI or equivalent) type-layout change as touching
   every consumer including Test targets** — wire a build/CI rule that forces recompilation
   of dependents on any FFI-boundary type change rather than relying on SwiftPM's
   (timestamp-based, cross-toolchain/staleness-blind) incremental build.
6. **Name the AX-driven / non-synthesizable-gesture tier explicitly and permanently in the
   test-pyramid design from day 1** — don't let each new drag/multi-touch/native-drag-and-drop
   feature re-litigate "is this really blocked?" from scratch.
7. **Schedule a full notarization dry-run (Developer ID acquired, one real submit→staple→
   quarantine-launch cycle) as its own early milestone, independent of feature completeness**
   — never let "notarize for the first time" collide with a real launch deadline.
8. **Port the accumulated macOS/zsh shell gotcha list (no GNU timeout, `grep -F` for
   literals, `ps -p` + `-axo` incompatibility, zsh glob-eating, single-quoted heredoc tags
   into `ssh`) into the new project's agent instructions on day 1** rather than re-earning it
   error-by-error.
