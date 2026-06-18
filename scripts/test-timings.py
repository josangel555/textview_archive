#!/usr/bin/env python3
"""test-timings.py <swift-test-output.txt> [top_n]

Aggregate per-CLASS wall-clock from `swift test` output so the slowest test
classes are visible (TSK-836 — the measure-first half of the build/test-speed
work: you can't sensibly split or de-sleep the slowest classes until you know
which they are).

Parses the same `Test Case '-[Module.Class method]' <result> (N seconds).`
lines that junit-convert.py keys on, sums `seconds` per class, and prints a
table sorted slowest-first. INPUT MUST be SERIAL `swift test` output —
`--parallel` uses swiftpm's progress reporter and omits per-case timing
(see scripts/test-timings.sh). Deterministic ordering (time desc, then class name)
and pure stdout, so the aggregation is host-testable (TestTimingsTests, the
same Process-invocation pattern as JUnitConverterTests).

  python3 scripts/test-timings.py <out.txt> [top_n]   # top_n=0/omit → all
"""
import re
import sys

# Module.Class method — identical case shape to junit-convert.py (kept in sync
# on purpose: both consume raw `swift test` output).
_CASE_RE = re.compile(
    r"Test Case '-\[([^.\]]+)\.([^ \]]+) \w+\]' "
    r"(?:passed|failed|skipped)\s*\(([0-9.]+) seconds\)"
)


def aggregate(text):
    """[(class, total_seconds, test_count)] sorted by total desc, then name."""
    totals = {}  # class -> [total_seconds, count]
    for _module, cls, secs in _CASE_RE.findall(text):
        entry = totals.setdefault(cls, [0.0, 0])
        entry[0] += float(secs)
        entry[1] += 1
    rows = [(cls, total, count) for cls, (total, count) in totals.items()]
    rows.sort(key=lambda r: (-r[1], r[0]))
    return rows


def render(rows, top_n=0):
    """Format the report table (slowest first). top_n<=0 → every class."""
    shown = rows[:top_n] if top_n > 0 else rows
    grand = sum(total for _, total, _ in rows)
    cases = sum(count for _, _, count in rows)
    lines = [f"{'SECONDS':>9}  {'TESTS':>6}  {'AVG_MS':>8}  CLASS"]
    for cls, total, count in shown:
        avg_ms = (total / count * 1000.0) if count else 0.0
        lines.append(f"{total:9.3f}  {count:6d}  {avg_ms:8.1f}  {cls}")
    lines.append(
        f"{grand:9.3f}  {cases:6d}  {'':>8}  TOTAL ({len(rows)} classes)"
    )
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: test-timings.py <swift-test-output.txt> [top_n]\n")
        return 2
    top_n = int(argv[2]) if len(argv) > 2 else 0
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        text = f.read()
    print(render(aggregate(text), top_n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
