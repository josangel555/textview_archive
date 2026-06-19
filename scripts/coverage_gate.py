#!/usr/bin/env python3
"""coverage_gate.py — parse `llvm-cov export` JSON and enforce line-coverage
thresholds, per shipping target and overall.

TSK-795 (homework → enforcement): the project measured ZERO code coverage and
had no way to enforce it in the build. This is the pure-logic half of the gate —
it reads the JSON `llvm-cov export` emits, attributes each source file to its
SwiftPM target (by `Sources/<Target>/` path segment), and fails (exit 2) if any
target — or the overall total — falls below its required line-coverage percent.

Why a separate, host-testable module (mirrors scripts/junit-convert.py + its
ViewerCoreTests.JUnitConverterTests): the threshold/attribution logic is the
part that can silently rot (a regex that stops matching a renamed target, an
off-by-one in the percent math reads green on a 0%-covered file). Keeping it
out of the .sh and pinning it with CoverageGateTests means a logic regression
fails the host gate, not just an eyeballed CI log.

Usage (reads llvm-cov export JSON on stdin, or a file path as $1):
    llvm-cov export -instr-profile=cov.profdata BIN | \
        python3 scripts/coverage_gate.py --min-total 0 --min-target 0

    python3 scripts/coverage_gate.py coverage.json --min-total 70

Options:
    --min-total PCT      Minimum overall line coverage (default 0 == report-only).
    --min-target PCT     Minimum per-shipping-target line coverage (default 0).
    --target NAME=PCT    Per-target override, repeatable (e.g. --target ViewerCore=80).
    --include-target N   Restrict the per-target gate to these targets, repeatable.
                         (Default: all targets under Sources/ that have any
                         exported region — test/Tree-sitter/C-shim targets too,
                         so use --include-target to scope to shipping libs.)
    --json-out PATH      Also write a machine-readable summary JSON here.

Exit codes:
    0   all thresholds met (or all thresholds are 0 == report-only mode)
    2   a threshold was not met
    3   malformed / empty input (no coverage data)

The "report-only" default (all minimums 0) is deliberate: wiring the gate into
the build at 0% first establishes the MEASUREMENT and the artifact without ever
turning a merge red on day one. Thresholds get ratcheted up once a baseline is
known — see docs/TEST_COVERAGE_2026-06-19.md.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Dict, List, Optional, Tuple

# Pull the SwiftPM target name out of an absolute source path. SwiftPM lays
# every first-party target under `Sources/<Target>/...`; nested dirs
# (Sources/ViewerCore/Highlight/...) still attribute to the top target.
_TARGET_RE = re.compile(r"/Sources/([^/]+)/")


def target_for_path(path: str) -> Optional[str]:
    """Return the SwiftPM target a source file belongs to, or None if the path
    isn't under a `Sources/<Target>/` tree (e.g. a checkout-of-tree dependency
    or a generated file). None-attributed files are excluded from per-target
    gating but still counted in the overall total."""
    m = _TARGET_RE.search(path)
    return m.group(1) if m else None


def _pct(covered: int, total: int) -> float:
    """Line coverage percent. A target with zero instrumented lines is treated
    as 100% (vacuously covered) — it cannot drag a threshold down, which is the
    correct behavior for an empty/header-only target."""
    if total == 0:
        return 100.0
    return 100.0 * covered / total


def summarize(report: dict) -> Tuple[Dict[str, Tuple[int, int]], Tuple[int, int]]:
    """Reduce an `llvm-cov export` JSON report to per-target and total
    (covered_lines, total_lines).

    llvm-cov's schema: report["data"][0]["files"][i] each carry a
    `summary.lines.{count,covered}`. We re-aggregate from the per-file
    summaries rather than trusting the report-level totals so the per-target
    split and the overall total come from the SAME source of truth (and so a
    future llvm-cov that drops the top-level `totals` block still works).
    """
    data = report.get("data") or []
    if not data:
        raise ValueError("no `data` array in llvm-cov export JSON")
    files = data[0].get("files") or []
    if not files:
        raise ValueError("no `files` in llvm-cov export JSON (empty coverage)")

    per_target: Dict[str, List[int]] = {}
    total_covered = 0
    total_lines = 0
    for f in files:
        lines = (f.get("summary") or {}).get("lines") or {}
        count = int(lines.get("count", 0))
        covered = int(lines.get("covered", 0))
        total_covered += covered
        total_lines += count
        tgt = target_for_path(f.get("filename", ""))
        if tgt is None:
            continue
        bucket = per_target.setdefault(tgt, [0, 0])
        bucket[0] += covered
        bucket[1] += count

    return ({k: (v[0], v[1]) for k, v in per_target.items()},
            (total_covered, total_lines))


def evaluate(
    report: dict,
    min_total: float,
    min_target: float,
    target_overrides: Dict[str, float],
    include_targets: Optional[List[str]],
) -> Tuple[bool, dict]:
    """Returns (passed, summary). `summary` is a dict suitable for printing /
    serializing: per-target rows, the total row, and a `failures` list naming
    every threshold miss (target/total, actual, required)."""
    per_target, (tot_cov, tot_lines) = summarize(report)
    total_pct = _pct(tot_cov, tot_lines)

    rows = []
    failures = []

    gated = set(include_targets) if include_targets else None
    for tgt in sorted(per_target):
        cov, lines = per_target[tgt]
        pct = _pct(cov, lines)
        required = target_overrides.get(tgt, min_target)
        is_gated = (gated is None) or (tgt in gated)
        rows.append({
            "target": tgt,
            "covered": cov,
            "lines": lines,
            "pct": round(pct, 2),
            "required": required if is_gated else None,
        })
        if is_gated and pct + 1e-9 < required:
            failures.append({
                "scope": tgt,
                "actual": round(pct, 2),
                "required": required,
            })

    if total_pct + 1e-9 < min_total:
        failures.append({
            "scope": "TOTAL",
            "actual": round(total_pct, 2),
            "required": min_total,
        })

    summary = {
        "targets": rows,
        "total": {
            "covered": tot_cov,
            "lines": tot_lines,
            "pct": round(total_pct, 2),
            "required": min_total,
        },
        "failures": failures,
    }
    return (len(failures) == 0, summary)


def format_table(summary: dict) -> str:
    out = []
    out.append(f"{'TARGET':<28} {'COVERED':>9} {'LINES':>9} {'PCT':>7} {'MIN':>6}")
    out.append("-" * 62)
    for row in summary["targets"]:
        req = "-" if row["required"] is None else f"{row['required']:g}"
        out.append(f"{row['target']:<28} {row['covered']:>9} {row['lines']:>9} "
                   f"{row['pct']:>6.2f}% {req:>6}")
    out.append("-" * 62)
    t = summary["total"]
    out.append(f"{'TOTAL':<28} {t['covered']:>9} {t['lines']:>9} "
               f"{t['pct']:>6.2f}% {t['required']:>6g}")
    return "\n".join(out)


def parse_target_override(s: str) -> Tuple[str, float]:
    if "=" not in s:
        raise argparse.ArgumentTypeError(f"--target expects NAME=PCT, got {s!r}")
    name, _, pct = s.partition("=")
    name = name.strip()
    if not name:
        raise argparse.ArgumentTypeError(f"--target NAME is empty in {s!r}")
    try:
        return name, float(pct)
    except ValueError:
        raise argparse.ArgumentTypeError(f"--target PCT not a number in {s!r}")


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", default="-",
                    help="llvm-cov export JSON file, or '-' for stdin (default)")
    ap.add_argument("--min-total", type=float, default=0.0)
    ap.add_argument("--min-target", type=float, default=0.0)
    ap.add_argument("--target", action="append", default=[],
                    type=parse_target_override, metavar="NAME=PCT")
    ap.add_argument("--include-target", action="append", default=None,
                    metavar="NAME")
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args(argv)

    raw = (sys.stdin.read() if args.input == "-"
           else open(args.input, "r", encoding="utf-8").read())
    if not raw.strip():
        print("coverage_gate: empty input (no coverage JSON)", file=sys.stderr)
        return 3
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"coverage_gate: input is not valid JSON: {e}", file=sys.stderr)
        return 3

    try:
        passed, summary = evaluate(
            report,
            min_total=args.min_total,
            min_target=args.min_target,
            target_overrides=dict(args.target),
            include_targets=args.include_target,
        )
    except ValueError as e:
        print(f"coverage_gate: {e}", file=sys.stderr)
        return 3

    print(format_table(summary))
    if summary["failures"]:
        print("")
        print("COVERAGE GATE FAILED:")
        for f in summary["failures"]:
            print(f"  - {f['scope']}: {f['actual']:.2f}% < required {f['required']:g}%")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2)

    return 0 if passed else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
