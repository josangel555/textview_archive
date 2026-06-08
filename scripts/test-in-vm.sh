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
ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true
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
  log "swift: $(swift --version | head -1)"
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
  newest=$(ls -d /Library/Developer/Toolchains/swift-6.*-RELEASE.xctoolchain 2>/dev/null \
             | sort -V | tail -1)
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
write_junit() {
  local input="$1" output="$2"
  python3 - "$input" "$output" <<'PY'
import re, sys, html
input_path, output_path = sys.argv[1], sys.argv[2]
text = open(input_path).read()
# Find test cases of the form:
#   Test Case '-[Module.Class methodName]' passed (X.X seconds).
# Include `skipped` so XCTSkip self-skips (heavy-tier gating, the WebView
# #192 gate) are represented as <skipped/> rather than silently dropped.
case_re = re.compile(
    r"Test Case '-\[([^.\]]+)\.([^ \]]+) (\w+)\]' (passed|failed|skipped)\s*\(([0-9.]+) seconds\)"
)
cases = case_re.findall(text)
suites = {}
for module, cls, method, result, secs in cases:
    suites.setdefault(cls, []).append((method, result, float(secs)))

# Cross-check the per-case count against xctest's own "Executed N tests"
# summary. A test that CRASHES the worker (SIGABRT / hang→timeout) emits no
# terminating passed/failed/skipped line, so it never produces a <testcase>
# and the JUnit would falsely read green. xctest prints one summary per suite
# plus a grand total; the grand total is the largest N seen.
summary_re = re.compile(r"Executed (\d+) test")
summary_counts = [int(n) for n in summary_re.findall(text)]
expected = max(summary_counts) if summary_counts else 0
parsed = len(cases)

with open(output_path, "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n')
    for cls, cs in suites.items():
        fails = sum(1 for _, r, _ in cs if r == "failed")
        skips = sum(1 for _, r, _ in cs if r == "skipped")
        total_time = sum(s for _, _, s in cs)
        f.write(f'  <testsuite name="{html.escape(cls)}" tests="{len(cs)}" failures="{fails}" skipped="{skips}" time="{total_time:.3f}">\n')
        for method, result, secs in cs:
            f.write(f'    <testcase classname="{html.escape(cls)}" name="{html.escape(method)}" time="{secs:.3f}">')
            if result == "failed":
                f.write('<failure type="failure" message="see swift test output"/>')
            elif result == "skipped":
                f.write('<skipped/>')
            f.write('</testcase>\n')
        f.write('  </testsuite>\n')
    # Synthetic failure when the parsed cases disagree with the summary total,
    # so a crashed/missing case turns the artifact RED instead of silent-green.
    if expected > parsed:
        msg = (f"count mismatch: xctest reported {expected} executed, "
               f"but only {parsed} terminating test-case lines were parsed "
               f"({expected - parsed} crashed/missing — likely a SIGABRT or timeout)")
        f.write('  <testsuite name="JUnitConverter" tests="1" failures="1" skipped="0" time="0.000">\n')
        f.write('    <testcase classname="JUnitConverter" name="caseCountMatchesSummary" time="0.000">')
        f.write(f'<failure type="count-mismatch" message="{html.escape(msg)}"/>')
        f.write('</testcase>\n')
        f.write('  </testsuite>\n')
    f.write('</testsuites>\n')
print(f"JUnit XML → {output_path}")
if expected > parsed:
    print(f"WARNING: parsed {parsed} test cases but summary reported {expected} "
          f"executed — {expected - parsed} crashed/missing", file=sys.stderr)
PY
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
    swift test "$@"
    return $?
  fi
  local uid; uid=$(stat -f %u /dev/console)
  local inner="cd $(printf '%q' "$ROOT_DIR") && ulimit -n 8192"
  [[ -n "${TOOLCHAINS:-}" ]] && inner+=" && export TOOLCHAINS=$(printf '%q' "$TOOLCHAINS")"
  inner+=" && exec swift test"
  local a
  for a in "$@"; do inner+=" $(printf '%q' "$a")"; done
  printf '%s\n' "${MDV_VM_SUDO_PASS:?MDV_VM_GUI_SESSION=1 needs MDV_VM_SUDO_PASS}" \
    | sudo -S launchctl asuser "$uid" /bin/bash -lc "$inner"
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
  log "MDV_RUN_WEBVIEW_TESTS=1 swift test (WebView lane)"
  set +e
  MDV_RUN_WEBVIEW_TESTS=1 swift test --parallel \
    --filter ViewerUITests.ComponentVisualTests \
    --filter ViewerUITests.ContentViewHostingTests \
    --filter ViewerUITests.DiagnosticDumpTests \
    --filter ViewerUITests.FindBarTests \
    --filter ViewerUITests.FormatToggleTests \
    --filter ViewerUITests.MermaidHostingTests \
    --filter ViewerUITests.RenderedFindBarTests \
    2>&1 | tee "$WEBVIEW_TXT"
  local rc=${PIPESTATUS[0]}
  set -e
  write_junit "$WEBVIEW_TXT" "$WEBVIEW_XML"
  return $rc
}

case "$MODE" in
  build)
    ensure_tools
    build_all
    log "build done in ${SECONDS}s"
    ;;
  test)
    ensure_tools
    run_tests
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
