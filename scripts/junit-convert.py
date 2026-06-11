#!/usr/bin/env python3
"""junit-convert.py <swift-test-output.txt> <out.xml>

Strip ANSI + transform `swift test` pass/fail output into a (Linux-friendly)
JUnit XML. Extracted from test-in-vm.sh's write_junit so the conversion logic
is host-testable (JUnitConverterTests) — TSK-162: the original embedded
converter silently dropped skipped AND crashed cases, so the nightly VM
lane's uploaded artifact under-reported.

Contracts pinned by JUnitConverterTests:
  * `skipped` cases (XCTSkip — heavy-tier gating, the WebView #192 gate)
    are represented as <skipped/> rather than silently dropped.
  * A case that CRASHES the worker (SIGABRT / hang->timeout) emits no
    terminating line; the parsed-case count is cross-checked against
    xctest's own "Executed N tests" summary and a mismatch emits a
    synthetic FAILING testcase, so the artifact reads RED, not green.
"""
import re, sys, html

input_path, output_path = sys.argv[1], sys.argv[2]
text = open(input_path).read()
# Find test cases of the form:
#   Test Case '-[Module.Class methodName]' passed (X.X seconds).
case_re = re.compile(
    r"Test Case '-\[([^.\]]+)\.([^ \]]+) (\w+)\]' (passed|failed|skipped)\s*\(([0-9.]+) seconds\)"
)
cases = case_re.findall(text)
suites = {}
for module, cls, method, result, secs in cases:
    suites.setdefault(cls, []).append((method, result, float(secs)))

# xctest prints one "Executed N tests" summary per suite plus a grand total;
# the grand total is the largest N seen.
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
