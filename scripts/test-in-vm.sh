#!/usr/bin/env bash
# Run the full MarkdownViewer test suite from a clean checkout, in a way
# that works inside a fresh UTM-managed macOS VM.
#
# Required VM image: macOS 14 (Sonoma) or later, with Xcode CLI tools
# installed (`xcode-select --install`). Nothing else is assumed —
# Swift is bundled with the CLI tools, and the project pulls
# swift-markdown via SwiftPM on first build.
#
# Permissions the VM needs (configure during VM setup, NOT at test time):
#   - Accessibility:  not required (we don't use AppleScript / System Events)
#   - Screen Recording:  not required (in-app self-snapshot uses CGWindowList)
#   - Files and Folders: scoped to /tmp only (the suite uses /tmp for fixtures)
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
#   PNG + JSON dumps from any L4/L5 step at  /tmp/mdv-step-*.{json,png}
#   Auto-snapshot at  /tmp/mdv-auto.{json,png}

set -euo pipefail

MODE="${1:-all}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# Track results separately from the test runner so we can produce JUnit
# regardless of mode.
RESULTS_TXT="/tmp/mdv-test-output.txt"
RESULTS_XML="/tmp/mdv-test-results.xml"
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
  log "swift: $(swift --version | head -1)"
}

build_all() {
  log "swift build -c debug"
  swift build -c debug

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
case_re = re.compile(
    r"Test Case '-\[([^.\]]+)\.([^ \]]+) (\w+)\]' (passed|failed)\s*\(([0-9.]+) seconds\)"
)
cases = case_re.findall(text)
suites = {}
for module, cls, method, result, secs in cases:
    suites.setdefault(cls, []).append((method, result, float(secs)))
with open(output_path, "w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n')
    for cls, cs in suites.items():
        fails = sum(1 for _, r, _ in cs if r == "failed")
        total_time = sum(s for _, _, s in cs)
        f.write(f'  <testsuite name="{html.escape(cls)}" tests="{len(cs)}" failures="{fails}" time="{total_time:.3f}">\n')
        for method, result, secs in cs:
            f.write(f'    <testcase classname="{html.escape(cls)}" name="{html.escape(method)}" time="{secs:.3f}">')
            if result == "failed":
                f.write('<failure type="failure" message="see swift test output"/>')
            f.write('</testcase>\n')
        f.write('  </testsuite>\n')
    f.write('</testsuites>\n')
print(f"JUnit XML → {output_path}")
PY
}

run_tests() {
  local filter=("$@")
  if [[ ${#filter[@]} -eq 0 ]]; then
    log "swift test (all tests)"
    set +e
    swift test 2>&1 | tee "$RESULTS_TXT"
    local rc=${PIPESTATUS[0]}
    set -e
  else
    log "swift test ${filter[*]}"
    set +e
    swift test "${filter[@]}" 2>&1 | tee "$RESULTS_TXT"
    local rc=${PIPESTATUS[0]}
    set -e
  fi
  write_junit "$RESULTS_TXT" "$RESULTS_XML"
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
    # Everything except L4/L5 (which spawn the app + are slower).
    run_tests \
      --filter ViewerCoreTests --filter ViewerKitTests \
      --filter DocumentModelTests --filter SidebarModelTests \
      --filter MarkdownRenderedViewTests \
      --filter ContentViewHostingTests --filter DiagnosticDumpTests
    log "quick done in ${SECONDS}s"
    ;;
  all|*)
    ensure_tools
    build_all
    # Full suite. L4+L5 take ~50s of the total ~75s.
    run_tests
    log "all done in ${SECONDS}s"
    ;;
esac
