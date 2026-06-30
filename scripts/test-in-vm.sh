#!/usr/bin/env bash
# Run the full MarkdownViewer test suite from a clean checkout, in a way
# that works inside a fresh UTM-managed macOS VM.
#
# Required VM image: macOS 14 (Sonoma) or later, with Xcode CLI tools
# installed (`xcode-select --install`). Nothing else is assumed —
# Swift is bundled with the CLI tools, and the project pulls
# swift-markdown via SwiftPM on first build.
#
# Permissions to grant ONCE inside the VM (System Settings →
# Privacy & Security):
#   - Files and Folders → MarkdownViewer:
#       /tmp is enough. Tests write fixtures there. NOT Documents/
#       Desktop/Downloads — DocumentModel skips those on restore so
#       you won't see TCC prompts for them.
#   - (Optional) Screen Recording → Terminal/xctest:
#       only needed if you want the L4/L5 PNG snapshots to be
#       non-blank for visual inspection. Tests pass without it
#       (assertions read the JSON dumps, not the PNG).
#   - (Optional) Accessibility → Terminal/xctest:
#       not required by tests, but nice to have for debugging via
#       osascript queries against the live app.
#
# Usage:
#   bash scripts/test-in-vm.sh           # build + test (default)
#   bash scripts/test-in-vm.sh build     # build only
#   bash scripts/test-in-vm.sh test      # test only (must have built first)
#   bash scripts/test-in-vm.sh quick     # build + test, skip slow L4/L5
#   bash scripts/test-in-vm.sh smoke     # quickest sanity check
#
# Output:
#   JUnit XML at  /tmp/mdv-test-results.xml  (for CI consumption)
#   PNG + JSON dumps from L4/L5 steps are written to the per-user
#   tmpdir (`$TMPDIR`, normally /var/folders/.../T/) — files
#   `mdv-step-NN.{json,png}`, `mdv-auto.{json,png}`.

set -euo pipefail

MODE="${1:-all}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# Raise the open-files soft limit before any `swift test` (TSK-500). The default
# macOS soft limit in a non-login ssh session is 256; a single-process full-suite
# run (4220 tests) accumulates file descriptors across the run — leaky sources /
# child processes (FileWatcher DispatchSources, LSP/PTY/plugin pipes) pile up
# until temp-file creation fails with EMFILE ("could not open temp file"),
# cascading into ~158 FALSE file-IO failures while the code is actually fine
# (the same classes pass in isolation, e.g. XattrIOTests/TextFileLoaderTests).
# The hard limit is `unlimited`, so bump the soft limit high. Best-effort — never
# abort the run if a platform refuses the raise.
ulimit -n 16384 2>/dev/null || ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true
printf "==> open-files soft limit: %s\n" "$(ulimit -n)"

# Track results separately from the test runner so we can produce JUnit
# regardless of mode.
RESULTS_TXT="/tmp/mdv-test-output.txt"
RESULTS_XML="/tmp/mdv-test-results.xml"
# Separate result files for the env-gated WebView lane so it never clobbers the
# primary artifact (/tmp/mdv-test-results.xml) that CI uploads.
WEBVIEW_TXT="/tmp/mdv-webview-output.txt"
WEBVIEW_XML="/tmp/mdv-webview-results.xml"
SECONDS=0

log() { printf "==> %s\n" "$*"; }

ensure_tools() {
  if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: swift not found. Run: xcode-select --install" >&2
    exit 1
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: xcrun not found. Install Xcode CLI tools." >&2
    exit 1
  fi
  select_toolchain
  check_toolchain_marker
  log "swift: $(swift --version | head -1)"
}

# TSK-616: the shared .build must be SINGLE-TOOLCHAIN. A build with the
# default 6.1.2 (e.g. a pre-fix vm-profile.sh run) leaves modules the 6.3
# test compile cannot import — and the failure used to surface as a buried
# compile error behind an exit-0 wrapper. Each run stamps the selected
# toolchain into `.build/.mdv-toolchain`; a mismatch on the next run fails
# LOUDLY up front with the remediation, instead of 100 lines into a build.
check_toolchain_marker() {
  local marker=".build/.mdv-toolchain"
  local current="${TOOLCHAINS:-xcode-default}"
  if [[ -d .build/arm64-apple-macosx && -f "$marker" ]]; then
    local prev
    prev=$(cat "$marker")
    if [[ "$prev" != "$current" ]]; then
      echo "ERROR: .build was last built with toolchain '$prev' but this run selects '$current'." >&2
      echo "       Mixed-toolchain modules break the test compile (TSK-616)." >&2
      echo "       Remediate: bash scripts/test-in-vm.sh clean" >&2
      exit 2
    fi
  elif [[ -d .build/arm64-apple-macosx && ! -f "$marker" ]]; then
    log "WARNING: .build has products of unknown toolchain provenance (no marker)."
    log "         If the build fails with 'module compiled with Swift X cannot be"
    log "         imported', run: bash scripts/test-in-vm.sh clean"
  fi
  mkdir -p .build
  printf '%s' "$current" > "$marker"
}

# TSK-439: the VM's default Xcode `swift` (6.1.2) is STRICTER than the host on
# region-isolation and FAILS to compile the test target (`try await
# super.setUp()` in @MainActor test classes = "sending non-Sendable self").
# Owner approved upgrading the VM toolchain to 6.2+. Rather than hardcode a
# build-specific id, pick the NEWEST installed `swift-6.x-RELEASE` toolchain and
# export TOOLCHAINS so every swift/xcrun call uses it. No-op if none beyond the
# bundled Xcode toolchain is present (e.g. CI on a clean host).
select_toolchain() {
  local newest tcid
  # `|| true`: the no-match glob makes `ls` fail → under `set -euo pipefail` the
  # assignment would abort (NOT the no-op the comment promises). Swallow it.
  newest=$(ls -d /Library/Developer/Toolchains/swift-6.*-RELEASE.xctoolchain 2>/dev/null \
             | sort -V | tail -1 || true)
  [[ -n "$newest" && -f "$newest/Info.plist" ]] || return 0
  tcid=$(plutil -extract CFBundleIdentifier raw "$newest/Info.plist" 2>/dev/null) || return 0
  [[ -n "$tcid" ]] || return 0
  export TOOLCHAINS="$tcid"
  log "toolchain: $(basename "$newest") ($tcid)"
}

build_all() {
  log "swift build -c debug"
  swift build -c debug

  # build-app.sh runs the pre-install smoke gate (ViewModeMatrixSmokeTests)
  # unless MDV_SKIP_SMOKE_GATE=1. Callers that immediately run the full sweep
  # next (which re-covers that suite) export it to avoid the duplicate T4 run.
  log "bash scripts/build-app.sh debug (assembles dist/MarkdownViewer.app)"
  bash "$SCRIPT_DIR/build-app.sh" debug

  log "bash scripts/verify-app.sh"
  bash "$SCRIPT_DIR/verify-app.sh"
}

# Strip ANSI + transform pass/fail to a (Linux-friendly) JUnit XML.
# Logic lives in scripts/junit-convert.py (extracted for host testability —
# JUnitConverterTests pin the skipped-representation + crashed-case-RED
# contracts; TSK-162).
write_junit() {
  local input="$1" output="$2"
  python3 "$SCRIPT_DIR/junit-convert.py" "$input" "$output"
}

# Run `swift test …`. When MDV_VM_GUI_SESSION=1, run it INSIDE the console
# user's Aqua/GUI session via `launchctl asuser` so the live-UI tiers
# (T4 LiveAppTestCase / T5 PixelTestCase / *UATTests / VisualRegression) realize
# real windows instead of occlusion-failing — the TSK-501 residual after the
# ulimit fix. PROVEN: ViewModeMatrixSmokeTests went 3/3 via asuser vs occluded
# over plain ssh. Default (env unset) is a direct call, so the headless `test`
# path is byte-for-byte unchanged. The env/cwd/ulimit must be set INSIDE the
# spawned shell (asuser drops env passed via /usr/bin/env — same trick as
# vm-smoke.sh). Needs MDV_VM_SUDO_PASS for `sudo -S` (never hardcode the secret).
swift_test() {
  if [[ "${MDV_VM_GUI_SESSION:-0}" != "1" ]]; then
    # MDV_RUN_WEBVIEW_TESTS stripped from the MAIN sweep here too (TSK-1236) —
    # the live-WKWebView suites belong only to run_webview_tests (serial).
    env -u MDV_RUN_WEBVIEW_TESTS swift test "$@"
    return $?
  fi
  local uid; uid=$(stat -f %u /dev/console)
  # Match the OUTER shell's open-files limit (line ~53): the asuser GUI session
  # is a FRESH shell whose default soft limit is low, and the inner used to cap
  # at 8192 — but the GUI-session MAIN sweep runs the live UI tiers (T4/T5/UAT)
  # which spawn real apps + WebContent/GPU helpers, each holding many fds. As the
  # suite grew, 8192 was exceeded → an EMFILE ("Too many open files") cascade of
  # ~180 FALSE file-IO failures across the later suites (TSK-1283; same class as
  # TSK-500/1236). Raise to 16384 with graceful fallback so the limit can only go
  # up, never below the prior 8192.
  local inner="cd $(printf '%q' "$ROOT_DIR") && { ulimit -n 16384 2>/dev/null || ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true; }"
  # NOTE (TSK-953): the live-app UAT cross-user temp problem is fixed in the
  # TEST HARNESS, not here. The asuser bridge runs xctest as ROOT but the app
  # spawns as the console user; root's per-user temp (`/var/folders/.../T`) is
  # 0700 AND SIP-restricted (`SF_RESTRICTED` — even root cannot `chmod` it), so
  # there is nothing to open from this side. Instead LaunchHarness roots its
  # fixtures under the spawn user's HOME (readable by that user AND inside the
  # MCP open_path containment fence — TSK-954) and AppLauncher chowns the run
  # dir to the console user, so the app reads + writes fixtures in place.
  [[ -n "${TOOLCHAINS:-}" ]] && inner+=" && export TOOLCHAINS=$(printf '%q' "$TOOLCHAINS")"
  # Forward MDV_* knobs (MDV_PIXEL_DEBUG_DIR, MDV_RUN_WEBVIEW_TESTS, …) into
  # the asuser shell — `launchctl asuser` drops the caller's environment, so
  # without this re-export the pixel suites silently lose their debug/capture
  # configuration. The sudo secret is deliberately NOT forwarded.
  local v
  for v in $(compgen -v | grep '^MDV_' || true); do
    [[ "$v" == "MDV_VM_SUDO_PASS" || "$v" == "MDV_VM_SUDO_PASSWORD" ]] && continue
    # Do NOT forward MDV_RUN_WEBVIEW_TESTS into the MAIN sweep (TSK-1236): the
    # live-WKWebView suites are process-isolated to their OWN dedicated lane
    # (run_webview_tests, serial). If this knob leaks into the main `swift test`,
    # those suites un-skip and run there too — under --parallel — multiplying
    # WebContent/GPU helper fds past the open-files limit → an EMFILE cascade of
    # FALSE failures in the main sweep. The dedicated lane sets it inline itself.
    [[ "$v" == "MDV_RUN_WEBVIEW_TESTS" ]] && continue
    inner+=" && export $v=$(printf '%q' "${!v}")"
  done
  inner+=" && exec swift test"
  local a
  for a in "$@"; do inner+=" $(printf '%q' "$a")"; done
  printf '%s\n' "${MDV_VM_SUDO_PASS:?MDV_VM_GUI_SESSION=1 needs MDV_VM_SUDO_PASS}" \
    | sudo -S launchctl asuser "$uid" /bin/bash -lc "$inner"
  local rc=$?
  # TSK-819: the `launchctl asuser` bridge runs xctest (and the inner build) as
  # ROOT, so SwiftPM writes root-owned files into the shared .build (TSK-502).
  # The NEXT non-root build (build-app.sh / a plain `swift build`) then dies on
  # `ModuleCache …: Operation not permitted`. Restore console-uid ownership so
  # the shared tree stays usable without a manual `sudo chown`. Best-effort: a
  # chown failure must not mask the test exit code.
  printf '%s\n' "$MDV_VM_SUDO_PASS" \
    | sudo -S chown -R "$uid" "$ROOT_DIR/.build" 2>/dev/null || true
  return $rc
}

run_tests() {
  local filter=("$@")
  if [[ ${#filter[@]} -eq 0 ]]; then
    log "swift test (all tests)${MDV_VM_GUI_SESSION:+ [GUI session]}"
    set +e
    swift_test 2>&1 | tee "$RESULTS_TXT"
    local rc=${PIPESTATUS[0]}
    set -e
  else
    log "swift test ${filter[*]}${MDV_VM_GUI_SESSION:+ [GUI session]}"
    set +e
    swift_test "${filter[@]}" 2>&1 | tee "$RESULTS_TXT"
    local rc=${PIPESTATUS[0]}
    set -e
  fi
  write_junit "$RESULTS_TXT" "$RESULTS_XML"
  return $rc
}

# The in-process live-WKWebView suites are process-isolated out of the bare
# `swift test` sweep (#192) AND self-skip via XCTSkip unless
# MDV_RUN_WEBVIEW_TESTS=1. They therefore need their own invocation with the
# gate armed, exactly as nightly-vm.yml's "WebView lane" step does — otherwise
# naming them in a filter list silently skips 100% of them (false-green render
# coverage). Results go to a separate file so the primary artifact is untouched.
run_webview_tests() {
  log "MDV_RUN_WEBVIEW_TESTS=1 swift test (WebView lane, serial)"
  set +e
  # Targeted single-suite run (MDV_WEBVIEW_FILTER) — validate ONE WebView/hosting suite
  # without the full ~20-suite serial lane (which can exceed a short CI/agent timeout).
  if [[ -n "${MDV_WEBVIEW_FILTER:-}" ]]; then
    log "targeted webview filter: ${MDV_WEBVIEW_FILTER}"
    MDV_RUN_WEBVIEW_TESTS=1 swift test --filter "${MDV_WEBVIEW_FILTER}" 2>&1 | tee "$WEBVIEW_TXT"
    local frc=${PIPESTATUS[0]}
    set -e
    write_junit "$WEBVIEW_TXT" "$WEBVIEW_XML"
    return $frc
  fi
  # SERIAL (no --parallel): each live-WKWebView suite realizes WebContent+GPU+
  # Networking helper processes, each holding many fds. Run in parallel, the
  # concurrent xctest workers multiply that past the open-files limit → an EMFILE
  # ("Too many open files") cascade of FALSE file-IO failures across the later
  # suites (TSK-1236, same fd-exhaustion class as TSK-500). Serial bounds the
  # live WKWebViews to one suite at a time — correctness over speed for these
  # resource-heavy integration suites.
  MDV_RUN_WEBVIEW_TESTS=1 swift test \
    --filter ViewerUITests.ComponentVisualTests \
    --filter ViewerUITests.ContentViewHostingTests \
    --filter ViewerUITests.DiagnosticDumpTests \
    --filter ViewerUITests.EditorReplaceWebViewTests \
    --filter ViewerUITests.EditorThemeParityTests \
    --filter ViewerUITests.BlameGutterWebViewTests \
    --filter ViewerUITests.FindBarTests \
    --filter ViewerUITests.FormatToggleTests \
    --filter ViewerUITests.FoldGutterWebViewTests \
    --filter ViewerUITests.MermaidHostingTests \
    --filter ViewerUITests.MermaidRenderProbeTests \
    --filter ViewerUITests.MultiCursorWebViewTests \
    --filter ViewerUITests.PaneRetentionMountProbeTests \
    --filter ViewerUITests.PDFExportWebViewTests \
    --filter ViewerUITests.PaneScrollRestoreWebViewTests \
    --filter ViewerUITests.EditorScrollRestoreWebViewTests \
    --filter ViewerUITests.EditorCursorBlinkWebViewTests \
    --filter ViewerUITests.BlockPatchApplyWebViewTests \
    --filter ViewerUITests.BlockPatchAlignmentProbeTests \
    --filter ViewerUITests.RenderedFindBarTests \
    --filter ViewerUITests.RenderedFindClearWebViewTests \
    --filter ViewerUITests.ScriptConsoleHostingTests \
    --filter ViewerUITests.StructuralSearchHostingTests \
    --filter ViewerUITests.TaskRunnerHostingTests \
    --filter ViewerUITests.TerminalCommandPaletteHostingTests \
    --filter ViewerUITests.WalkthroughDiagramOverlayHostingTests \
    2>&1 | tee "$WEBVIEW_TXT"
  local rc=${PIPESTATUS[0]}
  set -e
  write_junit "$WEBVIEW_TXT" "$WEBVIEW_XML"
  return $rc
}

case "$MODE" in
  clean)
    # TSK-616: targeted remediation of a toolchain-poisoned .build.
    # Removes ONLY the compiled products + the index store (which
    # `swift package clean` does NOT touch and which can keep serving
    # stale-toolchain modules). `checkouts/` and `repositories/` are
    # PRESERVED — the VM is an offline rsync mirror and cannot re-fetch
    # dependencies if they are lost. NEVER rm -rf the whole .build here.
    # Self-heal root-owned residue first — the TSK-502 class: sudo'd
    # launchctl-asuser runs (xctrace profiling, GUI-lane tests) write
    # root-owned index files into .build, which an unprivileged rm then
    # can't remove. Same in-sudo chown remediation vm-profile.sh uses.
    if find .build -not -user "$(whoami)" -print -quit 2>/dev/null | grep -q .; then
      log "root-owned files in .build (TSK-502 class) — chown -R $(whoami) via sudo"
      printf '%s\n' "${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}" | sudo -S chown -R "$(whoami)" .build
    fi
    log "removing .build/arm64-apple-macosx + .build/index-build (+ toolchain marker)"
    rm -rf .build/arm64-apple-macosx .build/index-build .build/.mdv-toolchain
    log "kept: $(ls .build 2>/dev/null | tr '\n' ' ')"
    log "clean done in ${SECONDS}s"
    ;;
  build)
    ensure_tools
    build_all
    log "build done in ${SECONDS}s"
    ;;
  test)
    ensure_tools
    # TSK-1245: self-heal root-owned .build (TSK-502 class) BEFORE testing. A
    # prior GUI-lane `build` (build-app.sh runs as root via launchctl-asuser)
    # leaves root-owned files in .build; a following `swift test` then SILENTLY
    # runs 0 XCTest tests ("Test run with 0 tests in 0 suites" + no XCTest body)
    # — a false-negative that masquerades as a pass. Same guarded in-sudo chown
    # the `clean` mode uses; only fires when root-owned residue is present (no-op
    # otherwise). Verified 2026-06-22 (run byrtcus2k): chown+test ran the MFV
    # suite where the immediately-prior `build && test` had run 0.
    if find .build -not -user "$(whoami)" -print -quit 2>/dev/null | grep -q .; then
      log "TSK-1245: root-owned files in .build — chown -R $(whoami) via sudo before test"
      printf '%s\n' "${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}" | sudo -S chown -R "$(whoami)" .build
    fi
    # Forward everything after the mode word (e.g. `test --filter Suite`)
    # to `swift test`. run_tests already handled a filter list — the
    # dispatch just never passed it, so filters were silently ignored
    # and every `test --filter X` ran the FULL suite (TSK-618 triage).
    # NOTE (TSK-1279): T5 PIXEL tests (PixelTestCase + screencapture) SKIP in
    # `test` mode — screencapture comes back TCC-denied here (observed 3/3 T5
    # skipped, e.g. SourceViewVisualRegressionTests), whereas the `all` mode
    # CAPTURES them (the build_all root/GUI context; the chown above changes
    # .build ownership and the screencapture responsible-process context). Use
    # `all` for T5-PIXEL validation; `test`/`webview` are correct for WebView/DOM
    # tests (#192 lane, no screencapture) and pure-logic.
    run_tests "${@:2}"
    log "test done in ${SECONDS}s"
    ;;
  smoke)
    ensure_tools
    build_all
    # Just the model + core unit tests. ~1s total.
    run_tests --filter ViewerCoreTests --filter ViewerKitTests \
              --filter DocumentModelTests --filter SidebarModelTests
    log "smoke done in ${SECONDS}s"
    ;;
  quick)
    ensure_tools
    build_all
    # Everything except L4/L5 (which spawn the app + are slower). The WebView
    # suites (ContentViewHostingTests/DiagnosticDumpTests/…) are NOT named here:
    # they self-skip without MDV_RUN_WEBVIEW_TESTS=1, so listing them in the
    # bare sweep would run zero of them (false-green). They run in the dedicated
    # gated lane below instead, so quick actually exercises the render/host path.
    rc=0
    run_tests \
      --filter ViewerCoreTests --filter ViewerKitTests \
      --filter DocumentModelTests --filter SidebarModelTests \
      --filter MarkdownRenderedViewTests || rc=$?
    run_webview_tests || rc=$?
    log "quick done in ${SECONDS}s"
    exit $rc
    ;;
  webview)
    ensure_tools
    # Just the gated in-process live-WKWebView lane (run_webview_tests), WITHOUT
    # the full `all` sweep — for TARGETED render validation. The WebView suites
    # self-skip without MDV_RUN_WEBVIEW_TESTS=1 (which run_webview_tests arms),
    # and MDV_* knobs forward via the asuser env bridge in the GUI lane — so e.g.
    #   MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUST_FOLD=1 \
    #     bash scripts/test-in-vm.sh webview
    # confirms the RUST fold gutter renders (FoldGutterWebViewTests) without
    # re-running the 4000-test `all` sweep just to exercise ~10 fold tests.
    rc=0
    run_webview_tests || rc=$?
    log "webview done in ${SECONDS}s"
    exit $rc
    ;;
  all|*)
    ensure_tools
    # The full sweep below re-covers ViewModeMatrixSmokeTests, so skip the
    # pre-install smoke gate that build-app.sh would otherwise run (avoids the
    # T4 live-app matrix executing twice in the slowest lane).
    MDV_SKIP_SMOKE_GATE=1 build_all
    # Full suite. L4+L5 take ~50s of the total ~75s. The bare sweep process-
    # isolates the WebView suites out (#192), so run them in their own gated
    # lane afterward for parity with nightly-vm.yml.
    rc=0
    run_tests || rc=$?
    run_webview_tests || rc=$?
    log "all done in ${SECONDS}s"
    exit $rc
    ;;
esac
