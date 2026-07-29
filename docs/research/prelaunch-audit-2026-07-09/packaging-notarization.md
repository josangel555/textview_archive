# Pre-launch audit — Packaging, code-signing & notarization

Date: 2026-07-10 · Reviewer: packaging/notarization dimension agent
Repo: `/Users/me/Documents/workspaces/claude/markdown_viewer` (read-only review; empirical probes run from session scratchpad)

## Executive summary

The signing/packaging tooling is unusually well-documented and encodes real institutional lessons (inside-out signing, per-dylib identifiers, xattr/iCloud defenses, the `--verify-resources` clean-machine gate). But the review found **one empirically-proven P1 runtime break** and **one P1 process gap**:

1. **Library validation denies the lazy-grammar dylib `dlopen` in every locally-signed build — including the installed `/Applications/TextView.app`.** The local signing pass applies `--options runtime` (hardened runtime ⇒ library validation) with a self-signed cert that has **no Team ID**; dyld refuses to map the nested dylibs ("mapping process and mapped file (non-platform) have different Team IDs"). `GrammarLoader` swallows the failure and returns `nil`, so XML/JS/TS code-folding and structural search **silently degrade** in the exact artifact the owner launches daily. Reproduced with a minimal probe against `dist/TextView.app`. Every automated lane (CI, VM) signs **ad-hoc without the runtime flag**, so no test can see it — a structural false-green.
2. **The notarization pipeline has never been executed.** There is no Developer ID identity on this machine (`security find-identity -v -p codesigning` → `0 valid identities`), no release CI lane, and `scripts/sign-and-notarize.sh`'s preflight would die at line 71. Several latent issues (in-place signing of a previously-xattr-fragile tree, unchecked notarytool status, no post-staple Gatekeeper assessment) are queued behind that first run.

Secondary gaps: `THIRD_PARTY_NOTICES.md` is generated but never shipped despite the generator's stated contract; there is **no quarantine/Gatekeeper first-launch verification** anywhere (script, CI, or manual checklist — `MANUAL_TESTING.md`'s one codesign line is stale, expecting an ad-hoc `dist/MarkdownViewer.app`); the `mdv-serve` daemon + `mdv` CLI have no signed distribution path; and the version is frozen at `0.1.0`/`1`.

Verdict: **not ship-ready for public distribution as-is**, but the distance is short — the notarize script's core signing order is correct, and the fixes are mostly S/M.

## Methodology

Examined (full reads unless noted):

- `scripts/sign-and-notarize.sh` (214 lines), `scripts/build-app.sh` (498), `scripts/install-app.sh` (163), `scripts/verify-app.sh` (162), `scripts/setup-signing.sh` (157), `scripts/check-dylib-identifiers.sh` (46), `scripts/entitlements.plist`, `scripts/Info.plist`, `scripts/stage-frontends.sh`, `scripts/com.markdownviewer.mdv-serve.plist.template`, `scripts/mdv` (head), `scripts/gen-third-party-notices.sh` (head)
- `.github/workflows/pr.yml` (packaging steps), workflow directory listing
- Runtime seams: `Sources/ViewerCore/Highlight/GrammarLoader.swift`, `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift`, `Sources/ViewerCore/JSTransform.swift`; greps for `dlopen`, JavaScriptCore, AppleEvents/mic/camera API use, LSP binary downloads, LaunchAgent install paths
- **Empirical probes** (window-free, scratchpad-built):
  - `codesign -dvv` / `codesign -d --entitlements -` on `dist/TextView.app`, nested dylibs, and `/Applications/TextView.app` (read-only)
  - a hardened-runtime Swift probe signed with `MarkdownViewer Local Dev` that `dlopen`s `dist/.../libTreeSitterXMLLazy.dylib` — **denied** with the runtime flag, **succeeds** without it and under ad-hoc (isolates library validation as the mechanism)
  - explicit codesign of a copied resource-only `.bundle` (succeeds; creates `_CodeSignature`) — validates `sign-and-notarize.sh`'s per-bundle pass is viable
  - `security find-identity -v -p codesigning` (0 valid identities)
  - `_CodeSignature` presence scan across `dist` resource bundles (absent — sealed as plain resources by the `--deep` pass, as expected)

## Findings

### F1 · P1 — Hardened-runtime library validation breaks lazy-grammar `dlopen` in every locally-signed build (installed app affected)

- **Files:** `scripts/build-app.sh:365-369` (local sign: `--options runtime`, identity `MarkdownViewer Local Dev`), `Sources/ViewerCore/Highlight/GrammarLoader.swift:150-154` (graceful-nil on dlopen failure), `scripts/entitlements.plist:27-28` (`disable-library-validation` = false, and entitlements are not applied in the local pass anyway)
- **Evidence (empirical):**
  - `codesign -dvv /Applications/TextView.app` → `flags=0x10000(runtime)`, `Authority=MarkdownViewer Local Dev`, `TeamIdentifier=not set`. Same for `dist/TextView.app` and its nested dylibs.
  - A probe binary signed with the same identity + `--options runtime` gets:
    `dlopen(...libTreeSitterXMLLazy.dylib...) ... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`
  - The identical probe **without** `--options runtime`, or ad-hoc signed, dlopens fine — the mechanism is library validation (implied by hardened runtime), which requires a matching non-nil Team ID for non-platform libraries. A self-signed cert has no Team ID, so the app can never load its own dylibs.
- **Impact:** In the daily-driver `/Applications/TextView.app`, `GrammarLoader.load()` returns `nil` for XML/JavaScript/TypeScript — code folding and structural search for those languages silently degrade (log-only, `GrammarLoader.swift:152`). Nobody sees it because (a) the failure is swallowed, (b) the VM and CI sign via the **ad-hoc fallback without the runtime flag** (`build-app.sh:384-388` — the `MarkdownViewer Local Dev` cert exists only on the owner's host), so library validation is never enforced in any automated lane (see F5). Conversely the future Developer ID build (same real Team ID on app + dylibs via `sign-and-notarize.sh:119-127`) will work — a dev/release behavior inversion.
- **Suggested fix (S, careful):** Drop `--options runtime` from the local self-signed pass in `build-app.sh` (hardened runtime is required only for notarization; TCC stability comes from the stable identity, not the flag). Alternatively keep the flag and sign locally with a dev entitlements file setting `com.apple.security.cs.disable-library-validation=true` (do NOT let that file leak into the notarize pass). Either way, add a `--verify-grammars` headless self-check next to `--verify-resources` (`build-app.sh:406-412`) that dlopens each declared grammar from the assembled bundle and hard-fails the build — that tooth would have caught this on day one and guards the Developer ID transition too.

### F2 · P1 — Notarization pipeline has never been executed; no Developer ID identity, no release lane

- **Files:** `scripts/sign-and-notarize.sh:62-83` (preflight), `.github/workflows/` (no release/notarize workflow: only `pr.yml`, `coverage.yml`, `nightly-*.yml`), `CLAUDE.md` ("Local signing only … no Developer ID until shipping public")
- **Evidence:** `security find-identity -v -p codesigning` → `0 valid identities` (no Apple-issued cert; the self-signed one is policy-filtered, per `setup-signing.sh:31-36`). The script's preflight (`sign-and-notarize.sh:71` / `:77-83`) dies without a Developer ID cert + a `MV_NOTARY` keychain profile — neither exists. No CI workflow references the script.
- **Impact:** For a *pre-launch* review, the entire distribution path — hardened-runtime Developer ID signing of 3 dylibs + 11 resource bundles, notary submission, stapling, Gatekeeper acceptance — is untested code. Latent failure modes (F4, F6, F7) will all surface serially on the first real run, likely days before a launch.
- **Suggested fix (M, careful):** Owner acquires the Developer ID Application cert + app-specific password (inherently an owner action; park a board ticket). Then do a full dry run end-to-end, capture the result, and wire a manually-triggered release workflow (or documented runbook) that ends with the post-staple assessments from F3. The cert/profile setup is a one-way-door only in the sense that the Team ID becomes the identity TCC/users key on — pick the final team before first public build.

### F3 · P2 — No post-staple Gatekeeper/quarantine first-launch verification anywhere

- **Files:** `scripts/sign-and-notarize.sh:172-173` (the only `spctl` call — pre-notarization, failure tolerated), `:203-213` (staple → zip → done; the "clean Mac" check is a printed suggestion), `MANUAL_TESTING.md:148` (sole codesign checklist line — stale: expects an **ad-hoc** signature on the pre-rename `dist/MarkdownViewer.app`)
- **Evidence:** After `stapler staple`/`stapler validate` there is no `spctl --assess --type execute` (which passes post-staple on the build machine), no quarantine round-trip (`xattr -w com.apple.quarantine` on an unzipped copy + assess + headless launch), and no checklist item covering download-unzip-first-launch, App Translocation, or the TCC first-prompt flow under a quarantined launch.
- **Impact:** The one scenario every real user hits first — download zip → unzip in `~/Downloads` → double-click (translocated, quarantined) — is validated by nothing. Historical precedent in this repo (the M5-Pro `Bundle.module` crash that motivated `--verify-resources`) shows clean-machine-only failures are a live class here.
- **Suggested fix (S, safe):** Append to `sign-and-notarize.sh` after stapling: `spctl --assess --type execute --verbose` (hard fail), then a quarantine simulation — `ditto` the stapled app to a temp dir, `xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));audit;$(uuidgen)"`, re-assess, and run `Contents/MacOS/MarkdownViewer --verify-resources` from the quarantined copy (headless). Add a first-launch section to `MANUAL_TESTING.md` and fix the stale line 148.

### F4 · P2 — `THIRD_PARTY_NOTICES.md` is generated but never shipped, despite the generator's stated contract

- **Files:** `scripts/gen-third-party-notices.sh:16-19` ("scripts/build-app.sh (owned by G14) copies the generated file into Contents/Resources/ of the assembled bundle"), `scripts/build-app.sh` (no reference to `NOTICES`/`THIRD_PARTY` anywhere — verified by grep)
- **Evidence:** `dist/TextView.app/Contents/Resources/` contains no notices file (listing captured 2026-07-10). The generator's own header documents a copy step that does not exist.
- **Impact:** The distribution zip ships MIT/BSD-licensed components (CodeMirror 6, Mermaid, swift-markdown, tree-sitter grammars, …) without the attribution their licenses require to accompany distribution. Legal-compliance gap that only matters — but matters absolutely — at public ship.
- **Suggested fix (S, safe):** In `build-app.sh`, copy `$ROOT_DIR/THIRD_PARTY_NOTICES.md` into `Contents/Resources/` (mirroring the `CAPABILITIES.md` copy at `build-app.sh:256-259`), fail loud if missing on `release`, and run `gen-third-party-notices.sh --check` in `pr.yml` so it can't go stale. Ideally surface it from the About/Help UI.

### F5 · P2 — Hardened-runtime signing is exercised in zero automated lanes (the false-green that hid F1)

- **Files:** `scripts/build-app.sh:384-388` (ad-hoc fallback signs **without** `--options runtime`, and with `|| true` swallowing failure), `.github/workflows/pr.yml:115-118` (CI runs `build-app.sh debug` + `verify-app.sh` — runners have no local cert → ad-hoc path), `scripts/verify-app.sh:132-144` (verifies signature validity but never asserts the runtime flag, timestamp, or Team ID expectations)
- **Evidence:** Only machines with the `MarkdownViewer Local Dev` keychain cert (the owner's host) produce runtime-flagged bundles; CI and the VM produce non-hardened ad-hoc bundles. So T4/T5/VM UAT and `verify-app.sh` all validate an artifact with materially different dyld enforcement than the one the owner runs — and than the one that will ship.
- **Impact:** Any hardened-runtime-sensitive regression (dlopen/library validation, DYLD_* stripping, unsigned-memory) is structurally invisible until it hits the owner's machine or the first notarized build. F1 lived here undetected.
- **Suggested fix (M, careful):** Make the lanes sign like the ship path: run `setup-signing.sh` (throwaway self-signed cert) in CI and on the VM so `build-app.sh` takes the identity+runtime-flag path, and extend `verify-app.sh` with mode-aware asserts (release artifact must have `flags=...(runtime)`; grammar-dlopen self-check per F1). Also remove the `|| true` on the ad-hoc codesign so a signing failure can't produce a silently unsigned bundle.

### F6 · P2 — `sign-and-notarize.sh` signs and verifies in place in `dist/`, contradicting the repo's own TSK-449 lesson

- **Files:** `scripts/sign-and-notarize.sh:117-167` (all codesign passes operate directly on `$APP_DIR` in `dist/`), `:170-171` (in-place `codesign --verify --deep --strict`); contrast `build-app.sh:336-375` (signs a `ditto --noextattr` clean copy in a non-synced TMPDIR precisely because `--options runtime` rejects xattr detritus) and `verify-app.sh:120-131` (verifies a de-xattr'd copy for the same reason)
- **Evidence:** The two sibling scripts encode the lesson ("file provider re-stamps FinderInfo in REAL TIME, racing codesign … intermittent 'resource fork … not allowed'", `build-app.sh:337-342`); the notarize script predates/skips it. iCloud sync is currently OFF (2026-07-07 verification), which lowers—but does not eliminate—the risk (`strip`, Finder browsing, any future sync re-enable re-stamp xattrs).
- **Impact:** First-run flakiness of the highest-stakes script: an xattr-stamped tree makes the Developer ID `--options runtime` sign or the strict verify fail spuriously mid-pipeline, after the (multi-minute) build.
- **Suggested fix (S, safe):** Mirror `build-app.sh`: stage the assembled bundle into a `mktemp -d` under `/private/tmp` via `ditto --norsrc --noextattr --noacl --noqtn` + `xattr -cr`, run every codesign/verify/zip step against the staged copy, and move the stapled result back to `dist/`.

### F7 · P2 — Notary submission status is not asserted; no diagnostics captured on rejection

- **Files:** `scripts/sign-and-notarize.sh:199-201` (`xcrun notarytool submit … --wait` with no status check), `:204` (proceeds straight to `stapler staple`)
- **Evidence:** The script never inspects the submission's terminal status (`Accepted` vs `Invalid`) nor fetches `notarytool log`. notarytool's exit code on an `Invalid` outcome has been inconsistent across Xcode releases; the only backstop is `stapler staple` failing (no ticket) — which aborts via `set -e` but with a misleading error and zero information about *why* Apple rejected it.
- **Impact:** A rejected submission (the most likely first-run outcome for a never-notarized app — e.g. a nested Mach-O missed by the enumeration, or a timestamp issue) produces "staple failed" instead of the per-file rejection report Apple provides.
- **Suggested fix (S, safe):** Use `--output-format json`, capture the submission `id`, assert `status == "Accepted"`, and on any other status run `xcrun notarytool log <id> --keychain-profile "$NOTARY_PROFILE"` into `dist/notary-log-<id>.json` before dying.

### F8 · P2 — `mdv-serve` daemon and `mdv` CLI have no signed/notarizable distribution path

- **Files:** `scripts/com.markdownviewer.mdv-serve.plist.template:9-11` ("the daemon binary lives OUTSIDE the app bundle … install-app.sh --with-daemon copies it from rust-core/link/"), `scripts/install-app.sh:127-155` (copies a cargo-built, unsigned `mdv-serve` to `~/Library/Application Support/MarkdownViewer/bin/` + installs a LaunchAgent), `:112-125` (`--with-cli` symlinks `scripts/mdv` from the repo checkout into `/usr/local/bin`), `scripts/stage-frontends.sh` (stages `mdv-tui`/`mdv-web`/`mdv-serve` into `dist/bin/`, never signed)
- **Evidence:** None of the Rust front-end binaries are signed anywhere (`stage-frontends.sh` has no codesign; `sign-and-notarize.sh` only touches the .app). The CLI is a symlink into the git checkout. Nothing places any of them in the notarized artifact.
- **Impact:** Post-launch, the remote-core/daemon and CLI features are unreachable for real users: the only install path requires a repo checkout and dev scripts, and a separately-downloaded unsigned+unnotarized `mdv-serve` would be blocked by Gatekeeper on a clean machine (quarantined, no ticket). If the daemon is ever embedded in the bundle instead, it must be hardened-runtime signed as nested code and fits inside the 80 MB cap decision (TSK-1214 adjacency).
- **Suggested fix (M, careful):** Decide the ship shape (embed in `Contents/MacOS/`/`Contents/Helpers/` and sign in the notarize pass — notarization covers nested helpers; or a separate notarized artifact with its own `notarytool submit`). At minimum sign the staged binaries with the same identity + `--options runtime` + timestamp in `sign-and-notarize.sh`, and make the app install the daemon from its own bundle rather than from `rust-core/link/`. Deferring the feature at launch is also coherent — then gate the UI affordances on daemon availability.

### F9 · P3 — Version frozen at 0.1.0/1; no bump automation; colliding artifact names

- **Files:** `scripts/Info.plist:23-26` (`CFBundleShortVersionString=0.1.0`, `CFBundleVersion=1` — static since creation), `scripts/sign-and-notarize.sh:188-191` (zip named `TextView-0.1.0.zip` from that value)
- **Impact:** Every notarized build produces an identically-named zip; crash reports, TCC records, and user bug reports can't distinguish builds; future update tooling (Sparkle or manual) has no monotonic build number to compare.
- **Suggested fix (S, safe):** Stamp `CFBundleVersion` from `git rev-list --count HEAD` (or a date-serial) at assemble time in `build-app.sh`, keep `CFBundleShortVersionString` human-managed, and include the short SHA in the zip name.

### F10 · P3 — `verify-app.sh` asserts nothing about hardened runtime, timestamp, or entitlements

- **Files:** `scripts/verify-app.sh:132-144` (signature validity + authority INFO only)
- **Evidence:** The bundle validator (also the CI gate, `pr.yml:117-118`) passes equally for ad-hoc non-hardened, self-signed hardened, and Developer ID bundles; the secure-timestamp guard exists only inside `sign-and-notarize.sh:181-183`.
- **Impact:** Signing-mode regressions (runtime flag dropped/added, entitlements accidentally stamped on dylibs, wrong identity) are invisible to the gate that exists to catch bundle regressions.
- **Suggested fix (S, safe):** Add mode-aware checks: report/assert `flags` contains `runtime` when the authority is non-ad-hoc; assert nested dylibs carry no entitlements; on release, assert `Timestamp=` present when the authority is Developer ID.

### F11 · P3 — Notarization zips built with `--sequesterRsrc`, deviating from Apple's documented command

- **Files:** `scripts/sign-and-notarize.sh:195-196` and `:208-209`
- **Evidence:** Apple's notarization docs specify `ditto -c -k --keepParent`. `--sequesterRsrc` adds `__MACOSX/` sidecar entries when resource forks/xattrs exist. The tree should be clean (F6 fix makes it certainly so), making the flag at best a no-op and at worst a source of archive cruft some unzip tools surface to users.
- **Suggested fix (S, safe):** Drop `--sequesterRsrc` from both `ditto` invocations.

### F12 · P3 — Quarantined third-party plugin binaries will fail to spawn, with no user-facing guidance

- **Files:** `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift:180-184` (direct `Process` exec of the plugin's `bin` from the user-writable plugin folder), `PLUGINS.md` (no mention of quarantine/Gatekeeper — verified by grep)
- **Evidence:** A plugin downloaded via browser carries `com.apple.quarantine`; macOS blocks exec of quarantined unsigned Mach-O binaries (script+interpreter plugins are unaffected). The host will report a generic `spawnFailed`.
- **Impact:** Post-launch plugin installs "mysteriously" fail for native-binary plugins; support burden.
- **Suggested fix (S, safe):** Detect the quarantine xattr on the resolved executable at spawn-failure time and surface an actionable message (`xattr -d com.apple.quarantine <path>` guidance); document in PLUGINS.md.

### F13 · P3 — `entitlements.plist` is an all-false no-op and its rationale comment is now contradicted by F1

- **Files:** `scripts/entitlements.plist:13-31` (four `cs.*` keys, all `<false/>` — semantically identical to absence; comment claims "Everything we do … works within the default hardened-runtime constraints", which the grammar-dlopen denial disproves for the self-signed case), `scripts/sign-and-notarize.sh:160-167` (only consumer)
- **Impact:** Documentation-as-config that misstates reality; whoever debugs F1 in a release context will be misdirected by the comment. Also `JSTransform.swift` (JavaScriptCore `JSContext`) runs interpreter-only without `allow-jit` — acceptable, but worth stating in the comment so a future perf investigation doesn't rediscover it.
- **Suggested fix (S, safe):** Rewrite the comment: hardened runtime + library validation require the ship build's dylibs to share the app's Team ID (satisfied by the Developer ID pass); note the deliberate no-JIT JSC tradeoff; either keep the explicit-false keys as documentation or drop the file and pass no entitlements.

## Positive observations

- **Inside-out signing order in `sign-and-notarize.sh` is correct and well-reasoned:** nested dylibs first with derived per-file identifiers (`:119-127`), resource bundles (`:129-136`), defensive sweep for stray Mach-O (`:141-157`), outer app last with entitlements only there and no `--deep` (`:160-167`). Verified empirically that resource-only bundles sign cleanly (creates `_CodeSignature`) thanks to the TSK-1257 Info.plist stamping in `build-app.sh:278-303`.
- **Staple-then-zip order is correct** (`:203-209`) — the distributed zip contains the stapled app, so offline first-launch works without a CloudKit ticket lookup.
- **The SIGN-14 pre-submit timestamp guard** (`:181-183`) catches a `--timestamp=none` build before wasting a notary round-trip.
- **`check-dylib-identifiers.sh` (TSK-157)** is a real, non-vacuous tooth against the `--deep --identifier` identifier-collision footgun, run on every local build (`build-app.sh:379`).
- **`--verify-resources` (TSK-1257)** is an exemplary clean-machine gate: it runs the real binary headlessly and fails the build if any resource resolves from `.build/` — born from an actual clean-machine crash, wired into both `build-app.sh:406-412` and `verify-app.sh:154-158`, and CI (`pr.yml:115-118`).
- **The xattr/iCloud signing defenses** (clean-TMPDIR staging `build-app.sh:343-375`, `ditto --noextattr` install `install-app.sh:48-61`, de-xattr'd verify `verify-app.sh:120-131`) encode a hard-won lesson and were kept after sync was disabled — correct cheap insurance.
- **Static-linking the Rust core** is explicitly justified against the hardened-runtime dyld Team-ID constraint (`build-app.sh:217-223`) — the author understood the exact failure class F1 exposes; only the lazy-grammar dylibs escaped that reasoning.
- **Info.plist hygiene is strong:** TCC usage descriptions for all protected folders + removable/network volumes (`scripts/Info.plist:41-50`), LSMinimumSystemVersion cross-checked against `Package.swift` in `verify-app.sh:49-61`, stable TCC-friendly bundle id, document types, URL schemes, exported UTIs.
- **No runtime download-and-execute paths:** LSP servers are PATH-resolved with install guidance (`LSPLanguage.swift:89`), plugins are containment-checked subprocesses (SEC-007 symlink resolution, `PluginSubprocessHost.swift:161-178`), grammar dylibs ship in the bundle. Nothing fetches executable code at runtime — a clean notarization story.

## Coverage gaps (not examined)

- **Did not run** `sign-and-notarize.sh`, any notary submission, or any UI/VM lane (constraints; and no Developer ID identity exists to test with).
- Did not audit the VM signing state directly (inference from `build-app.sh`'s ad-hoc fallback + absent cert; the VM was not queried).
- Did not review DMG/installer alternatives, Sparkle/update-framework design, or App Store sandbox feasibility (no code exists for any of these — noted, not audited).
- Did not verify the macOS 26 SDK ↔ `LSMinimumSystemVersion 15.0` availability-annotation surface (compile-level concern, different lens).
- Rust binary (`mdv-tui`/`mdv-web`/`mdv-serve`) internals, the `pm`/`serve` crate security posture, and supply-chain (covered by other dimensions).
- TCC behavior differences between self-signed and Developer ID identities on users' machines (requires a clean machine).
