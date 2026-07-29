# Scripts Layer — Build, Test & CI Orchestration
**Analysis date:** 2026-07-11 | **Repo:** markdown_viewer  
**Scope:** scripts/ (62 files, ~5K LOC total)

---

## File Inventory

### Core Build Scripts

**scripts/build-app.sh** (497 LOC) — Orchestrates dist/TextView.app assembly
- Invokes build-rust-core.sh → swift build → lazy-grammar dylib staging → codesigning → resource-bundle Info.plist generation → bundle-size cap → pre-install smoke gate
- Notable: Rust staticlib force-relink (TSK-1547 stale-link tooth), toolchain selection for VM Swift 6.3, XAttribute stripping for iCloud repos (TSK-449), resource-bundle self-check (--verify-resources), separate signing temp dir to avoid file-provider races
- carry: **KEEP** — production-grade orchestration; many patterns directly portable (resource bundling, size caps, codesign xattr dance, offline mode, smoke gate integration)

**scripts/build-rust-core.sh** (192 LOC) — Build Rust core staticlib + cbindgen header
- Stages libmdvcore_ffi.a to rust-core/link/, Sources/CMdvCore/mdvcore.h via cbindgen; handles no-cargo case (pre-staged artifacts for VM); content-hash comparison to avoid unnecessary rebuilds (TSK-848); force-deletes link products on staticlib change (TSK-1547); touches bridge-source headers for relink (TSK-626)
- Notable: CARGO_TARGET_DIR outside worktree for hygiene, panic=unwind requirement for GUI host (Architecture invariant #4), Cargo.lock --locked guard (TSK-783 supply-chain), mdv-serve daemon staging
- carry: **KEEP** — staticlib staging, header staleness guards, cross-platform pre-staging pattern all directly applicable

**scripts/build-icon.sh** (47 LOC) — Regenerate AppIcon.icns from SVG
- Invokes scripts/render-icon.swift → iconutil
- carry: **KEEP** — thin wrapper, straightforward

### Testing & Verification Scripts

**scripts/test-headless-gate.sh** (128 LOC) — Merge gate: headless tiers only
- Runs swift test with separate scratch dir (.build-gate) to avoid index-store thrashing; sentinel-based TierGateObserver enforcement to detect heavy-tier leakage; prerequisite: Rust staticlib + mdv-serve loopback binary (TSK-855)
- Notable: --disable-index-store for 63s rebuild time savings, --num-workers 18 tuning (TSK-847), tier isolation pattern with sentinel file
- carry: **KEEP** — tier enforcement + sentinel pattern is solid for any multi-tier suite

**scripts/test-in-vm.sh** (446 LOC) — Full VM-based test suite orchestration
- Modes: all, build, test, quick, smoke, webview, pixel, clean; toolchain marker consistency check (TSK-616); file descriptor limit management (TSK-500); GUI session via launchctl asuser (TSK-501, TSK-819); root-ownership cleanup (TSK-502, TSK-1245); WebView lane isolated serially (TSK-1236); JUnit XML output; stale-dist guards for T5 pixel tests (TSK-1279)
- Notable: Multi-modal orchestration (each mode has a clear purpose), launchctl asuser bridge for WindowServer access, root-chown remediation for sudo'd builds, WebView parallelism avoidance (fd exhaustion)
- carry: **KEEP** — sophisticated orchestration; modes, file-descriptor management, GUI session bridge, root-cleanup all portable

**scripts/verify-app.sh** (161 LOC) — Post-build bundle validation
- Checks: executable presence, Info.plist lint, required keys, LSMinimumSystemVersion vs Package.swift, document types, TCC usage descriptions, resource bundles, lazy-grammar dylib count (SIGN-13 vs Package.swift), code signature integrity (--verify --deep --strict), signature authorities, resource-bundle resolution via --verify-resources (SIGN-14)
- Notable: XAttribute-stripped copy in non-synced tmp dir to verify what actually ships (TSK-449, TSK-1257); SIGN-13 guard catches silent grammar build/copy failures
- carry: **KEEP** — validation patterns are comprehensive and defensive

**scripts/setup-signing.sh** (156 LOC) — Create self-signed codesigning cert
- One-time setup; creates "MarkdownViewer Local Dev" identity in login keychain so TCC grants survive rebuilds (ad-hoc grants keyed on cdhash, real certs keyed on identity+leaf-hash)
- carry: **KEEP** — straightforward cert setup, useful for any macOS dev app

**scripts/sign-and-notarize.sh** (213 LOC) — Developer ID signing + notarization
- Auto-discovers Developer ID Application cert, assembles release bundle, signs inside-out (dylibs with derived identifiers → resource bundles → remaining Mach-Os → main app with entitlements ONLY), verifies signature + timestamp locally before submit, submits to Apple notary service, polls, staples, zips for distribution
- Notable: No error-swallowing during signing, derived identifiers (not app identifier) for nested dylibs, no entitlements on nested code (SIGN-06 notarization red flag), timestamp gate before upload (SIGN-14)
- carry: **KEEP** — inside-out signing flow is well-structured and defensive

**scripts/check-bundle-size.sh** (167 LOC) — Dual-cap size guardrail (total + executable)
- Fails build if bundle exceeds 80 MB total or 65 MB executable; separate exec cap catches silent regression to static-linking (e.g., grammar baked into exec instead of dylib); detailed history of bumps with justifications
- Notable: Env-var overrides (BUDGET_MB, EXEC_BUDGET_MB); clear diagnostic output with du commands; exit code 2 for budget failure
- carry: **KEEP** — dual-cap pattern catches different bloat classes

**scripts/check-dylib-identifiers.sh** (40 LOC) — Guard against main-bundle-id on nested dylibs
- Verifies codesign --deep did NOT stamp main bundle ID onto grammar dylibs (would fail notarization)
- carry: **KEEP** — defensive gate

### VM Testing & Profiling

**scripts/vm-smoke.sh** (169 LOC) — Build + launch + screencapture on UTM VM
- Rsyncs to VM, builds dist/, launches in GUI session via launchctl asuser, captures PNG back to host
- Known: macOS 15 TCC redacts TextView window content in capture (sudo launchctl asuser context not reconciled)
- carry: **KEEP** — bridge pattern useful for all VM-based GUI work

**scripts/vm-profile.sh** (217 LOC) — xctrace signpost profile recording on VM
- Orchestrates VM build + launch under xctrace record --instrument 'os_signpost'; modes: open (cold open), resize (with window resizing under trace), nav (multi-file with sidebar toggling), reopen (cold→switch away→switch back for warm re-display path); pulls .trace back to host
- Notable: Separate modes isolate different perf scenarios (cold vs warm, resize storms, navigation)
- carry: **KEEP** — multi-modal profiling orchestration is sophisticated

**scripts/vm-diagnose.sh** (101 LOC) — Diagnostic info from VM (Swift version, dyld cache, fd limits, disk)
- carry: **KEEP** — utility script

**scripts/vm-uitest.sh** (223 LOC) — Launch UI tests on VM with AX reader
- Invokes vm-uitest/ax-reader.swift to read Accessibility attributes + scripting hooks; invokes vm-uitest/aqua-runner.sh to exercise flows
- carry: **KEEP** — AX-driven UAT orchestration

### Validation & Coverage

**scripts/test-bounded.sh** (96 LOC) — Run one test suite with wall-time + memory bounds
- Timeout + memory-limit enforcement; useful for detecting leaks / hanging tests
- carry: **KEEP** — simple bounded runner

**scripts/test-timings.sh** (47 LOC) + **test-timings.py** (69 LOC) — Profile per-test timings
- Extracts test timings from xctest output, plots histograms, identifies slow outliers
- carry: **KEEP** — timing analysis

**scripts/coverage-gate.sh** (173 LOC) + **coverage_gate.py** (249 LOC) — Measure + enforce code coverage
- Runs headless sweep with --enable-code-coverage, exports JSON via llvm-cov, Python gate reads thresholds; report-only mode by default (exit 0), ratchetable via env
- Notable: Coverage off by default (instrumentation overhead); separate from merge gate; Python logic pinned by ViewerCoreTests.CoverageGateTests
- carry: **KEEP** — optional coverage measurement with Python logic separation

**scripts/coverage.sh** (89 LOC) — Legacy coverage runner (older pattern)
- carry: **REDO** — superseded by coverage-gate.sh

### Rust Core Gates

**scripts/rust-core-gate.sh** (74 LOC) — Rust-specific tests (fuzz, property tests, supply-chain)
- Runs cargo test, cargo fuzz, cargo-deny, cargo-audit on rust-core workspace
- carry: **KEEP** — useful for Rust audit gates

**scripts/rust-perf-floor.sh** (58 LOC) — Asserts Rust engine performance floor
- Runs benches with wall-time threshold assertions
- carry: **KEEP** — perf guardrail pattern

### Specialty Scripts

**scripts/check-no-secrets.sh** (45 LOC) — Guard against leaked secrets (keys, tokens, passwords)
- Regex-based scan for common patterns
- carry: **KEEP** — defensive pre-commit

**scripts/gen-third-party-notices.sh** (220 LOC) — Generate THIRD_PARTY_NOTICES.md
- Aggregates licenses from SwiftPM + CocoaPods (via pod license)
- carry: **KEEP** — license aggregation

**scripts/install-mdv-cli.sh** (78 LOC) — Install mdv CLI symlink to ~/.local/bin or /usr/local/bin
- carry: **REDO** — now subsumed into install-app.sh --with-cli

**scripts/swiftpm-advisory-watch.sh** (158 LOC) — Poll swift.org for new security advisories
- Fetches https://swiftorg-downloads.s3.amazonaws.com/swift-advisories.json; diffs against last-seen; alerts on new CVEs
- Notable: Cron-friendly (one-shot advisory poll)
- carry: **KEEP** — proactive advisory monitoring

**scripts/reset-and-launch.sh** (35 LOC) — Reset app state + launch for manual testing
- carry: **KEEP** — test automation utility

**scripts/reset-tcc.sh** (38 LOC) — Clear TCC privacy grants to force re-prompting
- carry: **KEEP** — TCC reset utility

**scripts/flamegraph.sh** (47 LOC) + **mem-profile.sh** (118 LOC) + **heap-dump.sh** (65 LOC) — Perf profiling utilities
- Flamegraph: instruments → -D stackshot, convert to flamegraph.io format
- Mem-profile: Instruments memory profiler
- Heap-dump: Dumps heap snapshots
- carry: **KEEP** — perf utilities

**scripts/ui-snapshot.sh** (99 LOC) — Capture window pixel data
- Invokes screencapture + ffmpeg to extract per-frame images
- carry: **KEEP** — frame capture utility

**scripts/visual-smoke.sh** (106 LOC) — Visual regression smoke check (on host or VM)
- Launches app, exercises a set of file type × view mode combinations, captures PNGs, compares pixel-level diffs
- carry: **KEEP** — visual regression pattern

**scripts/junit-convert.py** (69 LOC) — Transform xctest output → JUnit XML
- Strips ANSI, converts pass/fail/skip lines to XML; pinned by JUnitConverterTests
- carry: **KEEP** — CI artifact format

**scripts/lib/ccache-env.sh** (78 LOC) — Wrapper to route TreeSitter C compiles through ccache/sccache
- Exported CC wrapper so SwiftPM's TreeSitter grammar compiles cache
- carry: **KEEP** — compiler cache wiring

**scripts/lib/restage-header.sh** (90+ LOC) — Rust header staleness guard (TSK-626)
- Detects real header changes, touches bridge sources + test targets to force relink on ABI change
- carry: **KEEP** — critical for cross-module ABI stability

**scripts/lib/sample_flamegraph.py** (30 LOC) — Helper to convert Instruments output to flamegraph.io format
- carry: **KEEP** — flamegraph conversion

### Configuration Files

**scripts/Info.plist** — Bundle metadata (CFBundleIdentifier, name, UTIs, TCC descriptions)
- carry: **KEEP** — standard macOS app plist

**scripts/entitlements.plist** — Hardened-runtime entitlements
- carry: **KEEP** — code-signing entitlements

**scripts/com.markdownviewer.mdv-serve.plist.template** — LaunchAgent template for daemon socket activation
- Substitutes __HOME__ at install time; launchd owns 0600 per-user socket, spawns mdv-serve on first connect
- carry: **KEEP** — daemon socket activation pattern

**scripts/hooks/monitor-log.sh** — Git hook to monitor build logs for warnings/errors
- carry: **KEEP** — log monitoring pattern

### Workflows (Pre-Launch Multi-Agent Scripts)

**scripts/workflows/prelaunch-audit.js** — ~45-dimension quality review + worktree fixes
**scripts/workflows/wf-feature-readiness.js** — Feature gaps analysis → hierarchical tree
**scripts/workflows/wf-uat-tests.js** — Author AX+UI-UAT tests on concurrent worktrees → serial VM validation
**scripts/workflows/wf-finish-50.js** — Complete next ~50 board tasks via worktree batches

- Notable: Worktree isolation for concurrent agents; model split (Fable high-pri, Opus bulk); fixes to branches, not auto-land on main; output to docs/research/
- carry: **KEEP** — worktree-isolated multi-agent orchestration pattern is valuable

### Miscellaneous

**scripts/mdv** (15 LOC) — CLI wrapper (shebang, usage, open -a MarkdownViewer)
- carry: **KEEP** — thin CLI opener

**scripts/codemirror-build/package.json** — npm build config for esbuild
- Bundles CodeMirror 6 + language packs + Vim mode → codemirror.js + codemirror.css
- carry: **KEEP** — npm-based bundler config

**scripts/codemirror-build/entry.js** (131 LOC) — esbuild entry point
- Exports window.CM global with all CM6 modules + language packs (Lezer official + legacy stream)
- carry: **KEEP** — bundler entry pattern

**scripts/.DS_Store** — macOS Finder metadata
- carry: **AVOID** — gitignore this

---

## Module Summary

The scripts/ layer is a **production-grade orchestration subsystem** coordinating:

1. **Build pipeline:** Rust core staticlib (with staleness guards) → Swift compilation → app assembly → resource bundling → code signing → notarization
2. **Testing tiers:** Headless merge gate (separate .build-gate for index-store efficiency) → VM-based UI/live tiers (T4/T5) with launchctl asuser bridge → coverage measurement
3. **Validation gates:** Bundle structure, Info.plist, code signature, dylib identifiers, grammar counts, resource resolution, size caps
4. **Perf instrumentation:** xctrace profiling, flamegraph conversion, memory profilers, timing analysis
5. **VM orchestration:** Rsync, toolchain selection, file-descriptor limits, root-ownership cleanup, GUI session bridge (launchctl asuser), TCC grant management
6. **Supply-chain:** Rust staticlib content-hash comparison (avoid rebuilds), Cargo.lock --locked guard, advisory polling, secret scanning

**Key architecture decisions:**
- Rust staticlib static-linked (not dylib) to avoid Team-ID mismatches under hardened runtime
- Separate size caps (total + exec) to detect static-linking regressions
- Lazy-grammar dylibs (Contents/Frameworks/) keep exec small, regressible via exec cap
- Resource bundles stamped with minimal Info.plist for codesign --deep --strict
- XAttribute stripping for iCloud-synced repos (file-provider detritus)
- Separate scratch dir (.build-gate) to avoid index-store thrashing
- Sentinel-based tier enforcement (TierGateObserver) detects heavy-tier leakage
- Header staleness trap (TSK-626) via touch-based bridge-source forcing
- Stale-link tooth (TSK-1547) catches SwiftPM relink skips

---

## Patterns Worth Porting

### 1. **Dual-capacity size guardrail** (check-bundle-size.sh)
- Total bundle cap + executable-specific cap
- Catches two bloat classes: overall growth vs silent static-linking regression
- Env-var overrides (BUDGET_MB, EXEC_BUDGET_MB) for flexibility
- **Portable to:** Any macOS/iOS app, any closure-heavy bundled resource

### 2. **Rust staticlib staging with staleness guard** (build-rust-core.sh)
- Content-hash comparison (cmp -s) to detect real changes
- Force-delete link products on staticlib change (TSK-1547) — catch SwiftPM relink skips
- Touch bridge-source headers to trigger re-export compilation
- Handles pre-staged artifacts for offline/VM builds
- **Portable to:** Any Swift+Rust FFI project

### 3. **Header staleness trap** (lib/restage-header.sh, TSK-626)
- Detects real ABI changes, touches ALL callers + test targets to force recompile
- Prevents stale test objects against re-laid-out enums (SIGSEGV-as-FFI-bug)
- **Portable to:** Any cross-module ABI boundary with generated headers

### 4. **Sentinel-based tier enforcement** (test-headless-gate.sh, TierGateObserver)
- Runtime test-type checking; write violations to sentinel file
- Fail gate if sentinel non-empty — detects tier mis-filing at test time
- **Portable to:** Any multi-tier test suite (headless, integration, E2E)

### 5. **launchctl asuser bridge for GUI tests** (test-in-vm.sh, vm-smoke.sh)
- Spawns test/app inside console user's GUI session (preserves WindowServer access)
- Handles env forwarding, pwd, ulimit in inner shell
- Manages sudo password (MDV_VM_SUDO_PASS) via stdin
- Remediates root-owned .build after GUI runs
- **Portable to:** Any macOS testing of UI-opening processes on a VM

### 6. **File-descriptor limit management** (test-in-vm.sh, TSK-500)
- Raises soft ulimit to 16384 (hard limit unlimited on macOS)
- Graceful fallback for hosts that refuse the raise
- Prevents EMFILE cascade across WebContent/GPU helpers + child processes
- **Portable to:** Any multi-process test suite (WebView, browser automation, LSP)

### 7. **Separate scratch dir per phase** (build-app.sh, test-in-vm.sh)
- .build-gate for merge gate (index-store OFF)
- .build for interactive dev (index-store ON)
- Avoids index-store thrashing (63s rebuild tax)
- **Portable to:** SwiftPM workflows needing index-store flexibility

### 8. **XAttribute stripping for iCloud-synced repos** (build-app.sh, install-app.sh, verify-app.sh, TSK-449)
- Mirror app via `ditto --noextattr --noacl --noqtn` into non-synced tmpdir
- Clear com.apple.FinderInfo even after ditto (belt-and-suspenders)
- Verify what actually ships, not what's in the synced tree
- Prevents codesign --options runtime rejects (xattr detritus)
- **Portable to:** Any project in ~/Documents / file-provider-synced trees

### 9. **Inside-out code signing** (sign-and-notarize.sh)
- Sign dylibs with derived identifiers (not app identifier)
- Sign resource bundles
- Sign remaining Mach-Os
- Sign app last with entitlements ONLY (not on nested code)
- Pre-verify locally before notary upload
- Catch missing timestamp (SIGN-14) before submit
- **Portable to:** Any macOS app with nested code + notarization

### 10. **Multi-modal orchestration** (test-in-vm.sh: all/build/test/quick/smoke/webview/pixel/clean)
- Each mode has a clear purpose + distinct pre-conditions
- Useful for targeted validation (e.g., pixel mode = T5 only, no full suite)
- **Portable to:** Any testing framework needing flexible run modes

### 11. **JUnit XML conversion** (junit-convert.py, TSK-162)
- ANSI stripping + test-line parsing into XML
- Handles skipped + crashed cases (separate codes)
- Pinned by hosted tests (JUnitConverterTests)
- **Portable to:** Any CI pipeline needing xctest→junit conversion

### 12. **Compiler cache wiring** (lib/ccache-env.sh)
- Optional sccache/ccache routing for TreeSitter C compiles
- Graceful degradation if no cache tool installed
- ~30 MB parse-table files benefit from caching
- **Portable to:** Any SwiftPM project with large C/C++ grammar dependencies

---

## Anti-Patterns / Regrets

### 1. **Legacy coverage.sh superseded by coverage-gate.sh**
- Old pattern did not enforce thresholds; new one is pluggable + ratchetable
- **Lesson:** Build gating from day 1, separate from measurement

### 2. **install-mdv-cli.sh → install-app.sh --with-cli**
- CLI symlink migrated into main install script
- **Lesson:** Combine related install concerns into one driver

### 3. **No hardcoded secrets in scripts**
- Credentials read from environment or keychain
- check-no-secrets.sh guards against accidental leaks
- **Lesson:** Automation tooling must never embed secrets

### 4. **Swift 6.1.2 vs 6.3 ABI skew (TSK-439, TSK-616)**
- Marker file tracks toolchain provenance; mismatch fails loudly
- Multiple places guard against this (build-app.sh, test-in-vm.sh)
- **Lesson:** Cross-machine builds need explicit toolchain tracking

---

## Gotchas & Surprises

### 1. **Stale-link tooth (TSK-1547) is critical**
- SwiftPM sees identical recompiled objects and skips relink
- Only way to force link edge is to delete the exe when staticlib changes
- Observed: canvas engine fix compiled clean yet /Applications shipped old Rust code
- **Mitigation:** build-rust-core.sh + build-app.sh coordinate via cmp + rm

### 2. **Header staleness (TSK-626) SIGSEGVs at runtime**
- Test objects compiled against old enum layout crash when FFI boundary re-lays-out
- Looks like FFI unwinding bug; actually a staleness trap
- **Mitigation:** Touch all referent files on header change; pin with host test (RustCoreHeaderRestageTests)

### 3. **Root-owned .build from GUI-session runs (TSK-502, TSK-1245)**
- launchctl asuser runs xctest as ROOT
- SwiftPM writes root-owned files
- Next non-root build fails ("Operation not permitted")
- Silent test skipping (0 tests run) if not remediated first
- **Mitigation:** test-in-vm.sh chown-remediates before test mode; covers both root-owned cases

### 4. **Index-store thrashing (TSK-846, TSK-832)**
- --disable-index-store (gate) vs --auto-index-store (interactive) are incompatible
- Sharing one .build forces 63s re-plan on every gate↔interactive switch
- **Mitigation:** Separate .build-gate; gate uses --disable-index-store + shared --scratch-path

### 5. **File-descriptor exhaustion (TSK-500, TSK-1236, TSK-1283)**
- WebContent + GPU + networking helpers per WebView suite × 12 parallel workers → EMFILE
- Default ssh session limit is 256 fds (host login session is higher)
- **Mitigation:** Raise ulimit to 16384 (with fallback); run WebView lane serially; per-user tmpdir separation

### 6. **VM screencapture TCC redaction (macOS 15 Sequoia)**
- sudo launchctl asuser context creates ownership mismatch
- WindowServer redacts the launched app's pixels in capture
- Workaround: Eyeball via UTM display window directly (manual smoke)
- **Status:** Acknowledged limitation; AX-structural tests unaffected

### 7. **macOS file-provider races (TSK-449)**
- ~/Documents iCloud sync re-stamps com.apple.FinderInfo in REAL TIME
- codesign in dist/ → file-provider re-stamps → next codesign rejects xattrs
- **Mitigation:** Sign in /private/tmp (not file-provider-synced), ditto to dist/

### 8. **Offline VM build needs pre-staged artifacts**
- rustc, cargo not available on VM → build rust on host → rsync .a + header + mdv-serve
- build-rust-core.sh detects no-cargo, uses pre-staged if present
- **Status:** Documented; standard for offline CI

### 9. **LaunchServices caching lag**
- New bundle at /Applications may not appear in Spotlight immediately
- lsregister -f forces immediate registration
- **Mitigation:** build-app.sh + install-app.sh both call lsregister

### 10. **TreeSitter grammar dylib orphan creep (TSK-1235)**
- Old Package.swift grammars leave orphan .dylib files in .build
- build-app.sh's glob copies ALL *Lazy.dylib instead of only declared ones
- verify-app.sh's SIGN-13 count mismatch catches this
- **Mitigation:** build-app.sh now derives allowlist from Package.swift; verify-app.sh enforces match

### 11. **Bundled notarization lag**
- notarytool submit can take several minutes
- Script polls with --wait; don't run interactively expecting instant return
- **Status:** Documented; acceptable for release workflow

---

## Rebuild Notes

### Approach for a greenfield Swift/Rust app

**Tier 0: Minimal viable build** (~500 LOC)
- build-app.sh equivalent: orchestrate swift build → assemble .app → sign locally
- build-rust-core.sh equivalent: cargo build --profile dist → stage .a + header
- Minimal Info.plist + entitlements
- No resource bundles, no lazy dylibs yet

**Tier 1: Validation gates** (~300 LOC)
- verify-app.sh equivalent: bundle structure + signature checks
- check-bundle-size.sh equivalent: size guardrails (total + exec caps)
- Local pre-sign verification before any shipping attempt
- **Design up front:** What are your bloat risks? Size caps should reflect them.

**Tier 2: Testing + merge gate** (~300 LOC)
- test-headless-gate.sh equivalent: headless tiers only, separate .build-gate
- Tier enforcement sentinel (if multi-tier suites planned)
- **Design up front:** How many test tiers will you have? Reserve tier flags now.

**Tier 3: VM orchestration** (~500 LOC, platform-specific)
- Rsync + build on VM only if you have a VM
- launchctl asuser bridge if you need GUI session access
- File-descriptor limit management
- **Design up front:** Do you need VM-based UI/live testing? If yes, plan the bridge early.

**Tier 4: Code signing + distribution** (~300 LOC)
- setup-signing.sh equivalent (self-signed) → Developer ID signing later
- sign-and-notarize.sh equivalent (inside-out signing)
- Timestamp verification before submit
- **Design up front:** What's your signing identity strategy? Local dev vs shipping?

**Tier 5: Perf instrumentation** (~200 LOC, optional)
- Flamegraph capture + conversion
- xctrace orchestration if profiling needs VM
- Memory/heap profilers
- **Design up front:** Will you need flame graphs? Signpost-anchor your hot code early.

**Key architectural decisions to make early:**

1. **Rust staticlib vs dylib linking?**
   - Static keeps exec self-contained; better for hardened-runtime + TCC stability
   - Trade: Bundle grows by ~3 MB; register reclaim options (lazy-load, dedup)
   - **Recommendation:** Start static; profile bloat post-launch

2. **Lazy-loaded dylibs for plugins/grammars?**
   - Reduces startup, supports hot-reload, keeps exec focused
   - Complexity: dylib identifier management, Contents/Frameworks layout, install_name_tool setup
   - **Recommendation:** Only if startup > 500ms or plugins are a feature

3. **Resource bundle layout?**
   - SwiftPM auto-generates .bundle dirs (CSS, JS, data files)
   - Bundle.module fallback (TSK-1257) can crash on clean machine if pointing to .build
   - Design: self-check via --verify-resources, stamp Info.plist into each bundle
   - **Recommendation:** Mirror build-app.sh's approach

4. **Separate scratch dirs (.build vs .build-gate)?**
   - Avoids 63s index-store thrash on every gate↔interactive switch
   - Small upfront cost (2 GB extra disk for .build-gate); huge time ROI
   - **Recommendation:** Implement immediately if SwiftPM indexing is slow

5. **Toolchain consistency (Swift 6.1 vs 6.3)?**
   - If VM ships different Swift than host, mark it early
   - Marker file (TSK-616) catches mismatches loudly
   - **Recommendation:** If multi-machine, track toolchain in .build marker from day 1

6. **Code-signing identity stability for TCC?**
   - Ad-hoc (hash-based): re-prompts forever
   - Self-signed (identity-based): survives rebuilds indefinitely
   - **Recommendation:** Run setup-signing.sh before first TCC grant; dev cost ~5 min

7. **File-descriptor limits for test parallelism?**
   - Default 256 fds insufficient for WebView × 12 parallel workers
   - Raising to 16384 (with fallback) is safe; costs nothing
   - **Recommendation:** Implement ulimit raise in test-runner from day 1

8. **XAttribute stripping for iCloud repos?**
   - If repo in ~/Documents, file-provider will stamp xattrs in real time
   - codesign --options runtime rejects them (false failure)
   - **Mitigation:** Sign in /tmp, ditto to dist/ (TSK-449)
   - **Recommendation:** Document this if shipping team might ~/Documents repos

---

## Quality Signals & Lessons

### Positive Patterns
1. **Fail-fast with clear diagnostics:** Every script that can fail does so immediately with actionable error messages (exit 2 for build-time gates)
2. **No silent failures:** Error-swallowing (||true, 2>/dev/null) is rare and justified (e.g., lsregister best-effort)
3. **Defensive layering:** Multiple gates catch the same class (e.g., stale-link tooth, force-relink, verify-app signature)
4. **Comprehensive documentation:** Comments justify why (e.g., why panic=unwind, why dual size caps, why separate scratch dir)
5. **Testable logic:** Key algorithms (header staleness, JUnit conversion, tier detection) are pinned by hosted unit tests
6. **Platform awareness:** Scripts handle macOS specifics (plutil, codesign, launchctl, TCC) correctly; no blind Unix assumptions
7. **VM-first design:** Scripts explicitly support both host + VM; VM is first-class, not an afterthought

### Lessons for Rebuild
1. **Invest in validation gates early.** verify-app.sh patterns catch real problems (dylib orphans, missing resources, signature regressions).
2. **Size caps are a cheap insurance policy.** Separate exec cap catches static-linking regressions; total cap catches other bloat. Both active from day 1.
3. **Mark every workaround with a ticket number.** TSK-* references make it easy to grep for known issues, revisit decisions, avoid re-discovering fixes.
4. **Tier isolation pays off.** Sentinel-based enforcement (TierGateObserver) catches test filing mistakes without false positives.
5. **VM orchestration complexity is worth it.** launchctl asuser bridge unlocks UI testing on CI without disrupting local dev.
6. **Content-hash comparison + force-delete is the stale-link tooth.** TSK-1547 caught a real regression (old Rust code shipping); cmp + rm is cheap insurance.
7. **Header staleness (TSK-626) is subtle and crashes at runtime.** Host-level tests (RustCoreHeaderRestageTests) catch ABI drift before users see SIGSEGVs.

---

## Summary

The scripts layer is **production-ready and battle-hardened**. It codifies a year of macOS app build/test/signing lessons (TSK-626, TSK-1547, TSK-449, TSK-500, etc.) into defensive orchestration. For a greenfield rebuild:

**Carry forward:**
- Dual-capacity size guardrails (total + exec)
- Rust staticlib staging with staleness guards
- Sentinel-based tier enforcement for test suites
- launchctl asuser bridge for VM GUI testing
- File-descriptor limit management
- XAttribute stripping for iCloud repos
- Inside-out code signing flow
- Multi-modal orchestration patterns
- JUnit XML conversion

**Revisit / redo:**
- Coverage measurement (now separate, pluggable gate)
- Install orchestration (consolidate --with-cli + --with-daemon into main flow)
- Profiling modes (vm-profile.sh modes could be simplified)

**Avoid:**
- Hardcoded secrets
- Error-swallowing in critical paths
- Single-tier test suites (plan for headless + live tiers early)
- Shared .build between incompatible index-store configs

**Key upfront design decisions:**
- Static vs dylib Rust linking (recommend: static)
- Lazy-loaded grammars or not (recommend: only if startup > 500ms)
- Separate scratch dirs for gate vs interactive (recommend: yes)
- Toolchain consistency strategy (recommend: marker file if multi-machine)
- Self-signed vs ad-hoc signing (recommend: self-signed immediately)
