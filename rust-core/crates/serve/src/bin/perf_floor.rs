//! `perf_floor` — the hand-rolled perf-floor RATCHET bench (audit TSK-588).
//!
//! Times the hot pure-logic paths the rust-core audit flagged (CSV arena
//! parse, per-keystroke filter scan, in-file find, hex render, unified-diff
//! parse) and ratchets each against the PREVIOUS committed baseline via
//! [`mdvcore_core::bench::compare`]. The ratchet logic, its (de)serialization,
//! and its TEETH live in `mdvcore-core::bench` (host-unit-tested, clock-free);
//! THIS bin is only the clock + the fixtures.
//!
//! Why this is a separate lane, NOT the merge gate: wall-clock asserts are
//! flaky under machine load (CLAUDE.md treats `FoldBench` failures as flaky),
//! so this runs on a dedicated GH-hosted runner (the UTM VM has no Rust). The
//! merge gate stays window/clock-free.
//!
//! Usage:
//!   cargo run -p mdvcore-serve --bin perf_floor               # compare vs baseline
//!   cargo run -p mdvcore-serve --bin perf_floor -- --update   # regenerate baseline
//!   cargo run -p mdvcore-serve --bin perf_floor -- --tolerance 0.75
//!   cargo run -p mdvcore-serve --bin perf_floor -- --baseline /path/to/file
//!
//! Exit status: 0 = no regression (or --update), 1 = at least one metric
//! regressed past tolerance, 2 = bad arguments / IO error.

use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use mdvcore_core::bench::{self, Baseline, Measurement, Verdict, DEFAULT_TOLERANCE};
use mdvcore_core::filter::{Query, Scope};
use mdvcore_core::{csv, diff, find, hex};

/// Default baseline path, relative to the workspace root (where `cargo run`
/// executes). Committed so the ratchet has a floor on a fresh checkout.
const DEFAULT_BASELINE: &str = "rust-core/crates/serve/benches/perf_floor_baseline.txt";

/// Per-metric measurement budget. Each metric runs `WARMUP` discarded
/// iterations, then `SAMPLES` timed ones; the MEDIAN sample is reported (median
/// is robust to a single scheduler hiccup in a way the mean is not). WARMUP is
/// deliberately generous: the very first samples right after a `cargo build`
/// pay cold instruction/data caches and post-compile machine load, which on a
/// busy runner can read 3-4x slow — discarding them keeps the median honest
/// without inflating the ratchet tolerance to hide real regressions.
const WARMUP: usize = 25;
/// Number of timed samples whose median is reported.
const SAMPLES: usize = 15;

fn main() -> ExitCode {
    let args: Args = match Args::parse(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(msg) => {
            eprintln!("perf_floor: {msg}");
            eprintln!("usage: perf_floor [--update] [--tolerance F] [--baseline PATH]");
            return ExitCode::from(2);
        }
    };

    let measurements = measure_all();

    if args.update {
        let baseline = Baseline::from_measurements(&measurements);
        return match write_baseline(&args.baseline_path, &baseline) {
            Ok(()) => {
                println!(
                    "perf_floor: wrote {} metric(s) to {}",
                    baseline.len(),
                    args.baseline_path.display()
                );
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!(
                    "perf_floor: failed to write baseline {}: {e}",
                    args.baseline_path.display()
                );
                ExitCode::from(2)
            }
        };
    }

    let baseline = match read_baseline(&args.baseline_path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!(
                "perf_floor: failed to read baseline {} ({e}).\n\
                 Run with --update to create it first.",
                args.baseline_path.display()
            );
            return ExitCode::from(2);
        }
    };

    let reports = bench::compare(&baseline, &measurements, args.tolerance);
    let mut regressed = false;
    println!(
        "perf_floor: {} metric(s) vs baseline (tolerance +{:.0}%)",
        reports.len(),
        args.tolerance * 100.0
    );
    for r in &reports {
        match &r.verdict {
            Verdict::Ok { ratio } => println!("  ok       {:<32} {:>6.2}x", r.name, ratio),
            Verdict::New => println!("  new      {:<32} (no baseline — run --update)", r.name),
            Verdict::Regressed {
                baseline_ns,
                current_ns,
                ratio,
            } => {
                regressed = true;
                println!(
                    "  REGRESS  {:<32} {:>6.2}x  ({:.0}ns -> {:.0}ns)",
                    r.name, ratio, baseline_ns, current_ns
                );
            }
        }
    }

    if regressed {
        eprintln!("perf_floor: FAIL — at least one metric regressed past tolerance.");
        ExitCode::from(1)
    } else {
        println!("perf_floor: OK — no regressions.");
        ExitCode::SUCCESS
    }
}

/// Parsed CLI args.
struct Args {
    update: bool,
    tolerance: f64,
    baseline_path: PathBuf,
}

impl Args {
    fn parse(mut iter: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut update = false;
        let mut tolerance = DEFAULT_TOLERANCE;
        let mut baseline_path = PathBuf::from(DEFAULT_BASELINE);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--update" => update = true,
                "--tolerance" => {
                    let v = iter.next().ok_or("--tolerance needs a value")?;
                    tolerance = v
                        .parse::<f64>()
                        .map_err(|_| format!("invalid --tolerance: {v}"))?;
                }
                "--baseline" => {
                    let v = iter.next().ok_or("--baseline needs a path")?;
                    baseline_path = PathBuf::from(v);
                }
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        Ok(Self {
            update,
            tolerance,
            baseline_path,
        })
    }
}

fn read_baseline(path: &Path) -> std::io::Result<Baseline> {
    let text = std::fs::read_to_string(path)?;
    Ok(Baseline::from_text(&text))
}

fn write_baseline(path: &Path, baseline: &Baseline) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, baseline.to_text())
}

/// Time `op` once: warmup, then the median of `SAMPLES` runs, reported as
/// nanoseconds per op (the op runs `iters` inner times per sample, amortizing
/// timer granularity for fast ops). `black_box` defeats dead-code elimination
/// so the optimizer can't delete the work being measured.
fn time_op<F: FnMut()>(name: &str, iters: u32, mut op: F) -> Measurement {
    for _ in 0..WARMUP {
        op();
    }
    let mut samples: Vec<Duration> = Vec::with_capacity(SAMPLES);
    for _ in 0..SAMPLES {
        #[allow(
            clippy::disallowed_methods,
            reason = "TSK-588: a perf bench MUST read the clock — this is the one \
                      crate allowed to (the sans-IO core ban keeps the timing OUT \
                      of mdvcore-core; the ratchet LOGIC there stays clock-free)."
        )]
        let start = Instant::now();
        for _ in 0..iters {
            op();
        }
        #[allow(
            clippy::disallowed_methods,
            reason = "TSK-588: paired with the start read above."
        )]
        let elapsed = start.elapsed();
        samples.push(elapsed);
    }
    samples.sort_unstable();
    // Median sample. SAMPLES >= 1 so the index is in range; `.get` keeps this
    // panic-free for the no-panic lint wall, falling back to zero (which the
    // ratchet treats as "no usable floor") on the impossible empty case.
    let median = samples
        .get(samples.len() / 2)
        .copied()
        .unwrap_or(Duration::ZERO);
    // `as_secs_f64() * 1e9` gives nanos as f64 WITHOUT a u128→f64 cast (which
    // the serve crate's cast deny-ratchet, TSK-575, would reject). iters >= 1.
    let ns_per_op = median.as_secs_f64() * 1e9 / f64::from(iters.max(1));
    Measurement {
        name: name.to_string(),
        ns_per_op,
    }
}

/// Build all measurements. Fixtures are generated deterministically so the
/// numbers are comparable run-to-run.
fn measure_all() -> Vec<Measurement> {
    let csv_text = make_csv(2_000, 8);
    let diff_text = make_diff(400);
    let find_text = make_lines(2_000, "the quick brown fox jumps over the lazy dog needle");
    // 64 KiB of cycling 0..=255 bytes. `% 256` is always in u8 range, so the
    // truncation can never lose data; `try_from(...).unwrap_or(0)` proves it to
    // the cast deny-ratchet without a bare `as`.
    let hex_bytes: Vec<u8> = (0..64_usize * 1024)
        .map(|i| u8::try_from(i % 256).unwrap_or(0))
        .collect();

    // Pre-parse the table once for the filter-scan metric (the per-keystroke
    // path is the SCAN, not the parse — keep them separate metrics).
    let arena = csv::parse_arena(&csv_text);
    let query = Query {
        text: "row1".to_string(),
        scope: Scope::All,
    };

    vec![
        time_op("csv.parse_arena.2000x8", 20, || {
            black_box(csv::parse_arena(black_box(&csv_text)));
        }),
        time_op("csv.filter_scan.2000x8", 50, || {
            black_box(arena.matching_indices(black_box(&query)));
        }),
        time_op("find.matches.2000lines", 50, || {
            black_box(find::find_matches(
                black_box(&find_text),
                black_box("needle"),
                find::Case::Insensitive,
            ));
        }),
        time_op("hex.render_all.64k", 20, || {
            black_box(hex::render_all(black_box(&hex_bytes), 16, hex_bytes.len(), false));
        }),
        time_op("diff.parse.400hunks", 50, || {
            black_box(diff::parse(black_box(&diff_text)));
        }),
    ]
}

/// A deterministic CSV with `rows` body rows and `cols` columns.
fn make_csv(rows: usize, cols: usize) -> String {
    let mut s = String::new();
    for c in 0..cols {
        if c > 0 {
            s.push(',');
        }
        s.push_str(&format!("col{c}"));
    }
    s.push('\n');
    for r in 0..rows {
        for c in 0..cols {
            if c > 0 {
                s.push(',');
            }
            s.push_str(&format!("row{r}-c{c}"));
        }
        s.push('\n');
    }
    s
}

/// `n` copies of `line`, newline-separated (for the find metric).
fn make_lines(n: usize, line: &str) -> String {
    let mut s = String::with_capacity(n * (line.len() + 1));
    for _ in 0..n {
        s.push_str(line);
        s.push('\n');
    }
    s
}

/// A synthetic unified diff with `hunks` single-line-change hunks.
fn make_diff(hunks: usize) -> String {
    let mut s = String::from("diff --git a/f b/f\n--- a/f\n+++ b/f\n");
    for h in 0..hunks {
        let n = h + 1;
        s.push_str(&format!("@@ -{n},1 +{n},1 @@\n"));
        s.push_str(&format!("-old line {h}\n"));
        s.push_str(&format!("+new line {h}\n"));
        s.push_str(&format!(" context {h}\n"));
    }
    s
}
