//! Perf-floor RATCHET comparison logic (audit TSK-588) — pure, sans-IO, and
//! host-testable.
//!
//! ## Why a ratchet, not absolute thresholds
//!
//! The synthesis (§5 #8) explicitly REJECTED `criterion` and absolute
//! wall-clock thresholds: a fixed `parse must be < 5 ms` assert is hostage to
//! whatever else the runner is doing (the project's own merge gate already
//! treats `FoldBench`/`CrossFileSearchBench` wall-clock asserts as flaky under
//! load — see CLAUDE.md). The robust shape is a RATCHET: compare each run
//! against the PREVIOUS committed baseline and fail only when a measurement
//! regresses past a generous tolerance. A regression that survives the
//! tolerance is a real, reproducible slowdown; transient machine load stays
//! under it. When an intentional change shifts the floor, the baseline is
//! regenerated (`--update`) and committed alongside the code — the diff IS the
//! reviewable record of the perf change.
//!
//! ## What lives here vs. in the bench binary
//!
//! This module is the DETERMINISTIC HEART: the baseline data model, its
//! text (de)serialization, and the [`compare`] ratchet. It reads no clock and
//! does no I/O, so it passes the core's sans-IO lint wall (`disallowed_methods`
//! bans `Instant::now`) and is exercised by ordinary host unit tests with real
//! TEETH — a planted regression MUST be flagged, a within-tolerance jitter MUST
//! NOT, a new metric MUST be reported as un-baselined rather than silently
//! passing. The actual TIMING (which needs the clock) lives in the
//! `mdvcore-serve` `perf_floor` bin, which calls [`compare`] with the numbers
//! it measured.
//!
//! ## Format
//!
//! The baseline is a trivially diffable line-based text file (NO `serde_json`
//! dependency — minimal-deps posture): one `name<TAB>nanos_per_op` record per
//! line, `#`-comment and blank lines ignored. Names are stable metric ids; the
//! value is the median nanoseconds-per-op the bench measured.

use std::collections::BTreeMap;

/// Default ratchet tolerance: a measurement may be up to this fraction SLOWER
/// than its baseline before it counts as a regression. 0.5 = +50%. Deliberately
/// generous — the goal is to catch an order-of-a-change algorithmic regression
/// (an accidental O(n)→O(n²), a dropped cache) reproducibly across noisy
/// hosted runners, NOT to police single-digit-percent micro-noise. The bench
/// bin can override per-invocation.
pub const DEFAULT_TOLERANCE: f64 = 0.5;

/// One measured metric: a stable `name` and its median nanoseconds-per-op.
#[derive(Debug, Clone, PartialEq)]
pub struct Measurement {
    /// Stable metric id (e.g. `csv.parse_arena.100kx10`). Used as the ratchet
    /// key, so it must not change when the baseline carries over.
    pub name: String,
    /// Median nanoseconds per op for this metric in this run.
    pub ns_per_op: f64,
}

/// A baseline: the previous run's measurements keyed by metric name. A
/// `BTreeMap` so [`Baseline::to_text`] emits a stable, diff-friendly order.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Baseline {
    entries: BTreeMap<String, f64>,
}

/// The verdict for one metric when compared against the baseline.
#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    /// Within tolerance (faster, equal, or only marginally slower). Carries the
    /// observed ratio `current / baseline` (1.0 = unchanged, <1 = faster).
    Ok { ratio: f64 },
    /// Slower than `baseline * (1 + tolerance)` — a real regression. Carries
    /// the baseline ns, the current ns, and the observed ratio.
    Regressed {
        /// Baseline nanoseconds-per-op.
        baseline_ns: f64,
        /// Current nanoseconds-per-op.
        current_ns: f64,
        /// `current_ns / baseline_ns` (> `1 + tolerance`).
        ratio: f64,
    },
    /// No baseline entry for this metric (a newly added bench). Reported, not
    /// failed — the operator regenerates the baseline to adopt it.
    New,
}

/// The result for one metric.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    /// The metric this report is about.
    pub name: String,
    /// The verdict.
    pub verdict: Verdict,
}

impl Report {
    /// Whether this report is a hard failure (a [`Verdict::Regressed`]). A
    /// [`Verdict::New`] is informational, never a failure.
    #[must_use]
    pub fn is_regression(&self) -> bool {
        matches!(self.verdict, Verdict::Regressed { .. })
    }
}

impl Baseline {
    /// An empty baseline (the very first run — every metric reports `New`).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a baseline directly from a set of measurements (used by the bench
    /// bin's `--update` path and by tests). Duplicate names keep the LAST value.
    #[must_use]
    pub fn from_measurements(measurements: &[Measurement]) -> Self {
        let mut entries = BTreeMap::new();
        for m in measurements {
            entries.insert(m.name.clone(), m.ns_per_op);
        }
        Self { entries }
    }

    /// The baseline ns-per-op for `name`, if present.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<f64> {
        self.entries.get(name).copied()
    }

    /// Number of baselined metrics.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the baseline carries no metrics.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Parse a baseline from its line-based text form. Blank lines and lines
    /// whose first non-whitespace char is `#` are ignored. Each remaining line
    /// is `name<TAB>nanos`; a malformed numeric value or a line missing the tab
    /// is skipped (a corrupt baseline degrades to "fewer baselined metrics" —
    /// those report `New` — rather than crashing the run).
    #[must_use]
    pub fn from_text(text: &str) -> Self {
        let mut entries = BTreeMap::new();
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            // Split on the FIRST tab so a metric name can't accidentally eat
            // the value; names themselves never contain a tab (they are dotted
            // ids the bench controls).
            let Some((name, value)) = trimmed.split_once('\t') else {
                continue;
            };
            let name = name.trim();
            if name.is_empty() {
                continue;
            }
            let Ok(ns) = value.trim().parse::<f64>() else {
                continue;
            };
            if ns.is_finite() && ns >= 0.0 {
                entries.insert(name.to_string(), ns);
            }
        }
        Self { entries }
    }

    /// Serialize to the line-based text form, sorted by metric name (the
    /// `BTreeMap` gives a stable order so re-`--update`ing an unchanged run
    /// produces a zero-line diff). A header comment documents the format.
    #[must_use]
    pub fn to_text(&self) -> String {
        let mut out = String::new();
        out.push_str("# mdvcore perf-floor baseline (audit TSK-588).\n");
        out.push_str("# Format: <metric-name>\\t<median-nanos-per-op>. Ratchet, not absolute.\n");
        out.push_str("# Regenerate with: cargo run -p mdvcore-serve --bin perf_floor -- --update\n");
        for (name, ns) in &self.entries {
            // Whole nanoseconds: the ratchet tolerance dwarfs sub-ns precision,
            // and integer values keep the committed baseline diff stable.
            // `{:.0}` rounds-to-nearest and emits no fractional part, WITHOUT a
            // float→int cast (keeps the core's cast deny-ratchet, TSK-575, clean).
            out.push_str(name);
            out.push('\t');
            out.push_str(&format!("{ns:.0}"));
            out.push('\n');
        }
        out
    }
}

/// Compare a run's `measurements` against `baseline` at `tolerance` (fractional
/// slowdown allowed; see [`DEFAULT_TOLERANCE`]). Returns one [`Report`] per
/// measurement, in input order.
///
/// Ratchet rule per metric:
/// - No baseline entry → [`Verdict::New`] (informational).
/// - `current <= baseline * (1 + tolerance)` → [`Verdict::Ok`].
/// - otherwise → [`Verdict::Regressed`].
///
/// A baseline of `0` (or non-positive) is treated as "no usable floor" → the
/// metric reports `Ok` with ratio `1.0` (you cannot ratchet against a zero
/// floor; the next `--update` records a real number). `tolerance` is clamped to
/// `>= 0`.
#[must_use]
pub fn compare(baseline: &Baseline, measurements: &[Measurement], tolerance: f64) -> Vec<Report> {
    let tol = if tolerance.is_finite() && tolerance > 0.0 {
        tolerance
    } else {
        0.0
    };
    measurements
        .iter()
        .map(|m| {
            let verdict = match baseline.get(&m.name) {
                None => Verdict::New,
                Some(base) if base <= 0.0 => Verdict::Ok { ratio: 1.0 },
                Some(base) => {
                    let ratio = m.ns_per_op / base;
                    if m.ns_per_op <= base * (1.0 + tol) {
                        Verdict::Ok { ratio }
                    } else {
                        Verdict::Regressed {
                            baseline_ns: base,
                            current_ns: m.ns_per_op,
                            ratio,
                        }
                    }
                }
            };
            Report {
                name: m.name.clone(),
                verdict,
            }
        })
        .collect()
}

/// Whether any report in `reports` is a hard regression. The bench bin maps
/// `true` to a non-zero exit so a CI lane fails on a real slowdown.
#[must_use]
pub fn has_regression(reports: &[Report]) -> bool {
    reports.iter().any(Report::is_regression)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(name: &str, ns: f64) -> Measurement {
        Measurement {
            name: name.to_string(),
            ns_per_op: ns,
        }
    }

    #[test]
    fn round_trips_through_text() {
        let base = Baseline::from_measurements(&[m("a.b", 1234.0), m("c.d", 56.0)]);
        let text = base.to_text();
        let reparsed = Baseline::from_text(&text);
        assert_eq!(reparsed.get("a.b"), Some(1234.0));
        assert_eq!(reparsed.get("c.d"), Some(56.0));
        assert_eq!(reparsed.len(), 2);
    }

    #[test]
    fn to_text_is_stable_sorted_for_clean_diffs() {
        // Inserting in a scrambled order must still emit name-sorted lines so a
        // re-`--update` of an unchanged run produces a zero-line diff.
        let a = Baseline::from_measurements(&[m("z", 1.0), m("a", 2.0), m("m", 3.0)]);
        let text = a.to_text();
        let lines: Vec<&str> = text.lines().filter(|l| !l.starts_with('#')).collect();
        assert_eq!(lines, vec!["a\t2", "m\t3", "z\t1"]);
    }

    #[test]
    fn from_text_ignores_comments_blanks_and_malformed() {
        let text = "\
# a comment\n\
\n\
good\t100\n\
no-tab-here\n\
bad-num\tNaNxyz\n\
   \n\
  spaced \t 200 \n";
        let b = Baseline::from_text(text);
        assert_eq!(b.get("good"), Some(100.0));
        assert_eq!(b.get("spaced"), Some(200.0));
        assert_eq!(b.get("no-tab-here"), None, "tab-less line skipped");
        assert_eq!(b.get("bad-num"), None, "unparseable value skipped");
        assert_eq!(b.len(), 2);
    }

    #[test]
    fn from_text_rejects_negative_and_nonfinite() {
        let b = Baseline::from_text("neg\t-5\ninf\tinf\nok\t10\n");
        assert_eq!(b.get("ok"), Some(10.0));
        assert_eq!(b.get("neg"), None, "negative ns skipped");
        assert_eq!(b.get("inf"), None, "non-finite ns skipped");
    }

    // ---- the TEETH: the ratchet must actually catch a regression ----

    #[test]
    fn within_tolerance_passes() {
        let base = Baseline::from_measurements(&[m("op", 100.0)]);
        // +49% at the default 50% tolerance — must NOT fail (noise headroom).
        let reports = compare(&base, &[m("op", 149.0)], DEFAULT_TOLERANCE);
        assert_eq!(reports.len(), 1);
        assert!(!reports[0].is_regression(), "+49% must stay under +50% tol");
        assert!(!has_regression(&reports));
    }

    #[test]
    fn regression_past_tolerance_is_flagged() {
        // THE PLANTED REGRESSION. If `compare` ever stops catching a 2x
        // slowdown past tolerance, this test goes red — that is the teeth.
        let base = Baseline::from_measurements(&[m("op", 100.0)]);
        let reports = compare(&base, &[m("op", 200.0)], DEFAULT_TOLERANCE);
        assert!(reports[0].is_regression(), "2x slowdown must be a regression");
        assert!(has_regression(&reports));
        match &reports[0].verdict {
            Verdict::Regressed {
                baseline_ns,
                current_ns,
                ratio,
            } => {
                assert_eq!(*baseline_ns, 100.0);
                assert_eq!(*current_ns, 200.0);
                assert!((*ratio - 2.0).abs() < 1e-9);
            }
            other => unreachable!("expected Regressed, got {other:?}"),
        }
    }

    #[test]
    fn boundary_exactly_at_tolerance_is_ok_just_past_is_not() {
        let base = Baseline::from_measurements(&[m("op", 100.0)]);
        // Exactly baseline*(1+tol) = 150 → OK (<=). 150.001 → regression.
        assert!(!compare(&base, &[m("op", 150.0)], 0.5)[0].is_regression());
        assert!(compare(&base, &[m("op", 150.001)], 0.5)[0].is_regression());
    }

    #[test]
    fn faster_than_baseline_is_ok_with_sub_one_ratio() {
        let base = Baseline::from_measurements(&[m("op", 100.0)]);
        let reports = compare(&base, &[m("op", 40.0)], DEFAULT_TOLERANCE);
        match reports[0].verdict {
            Verdict::Ok { ratio } => assert!((ratio - 0.4).abs() < 1e-9),
            ref other => unreachable!("expected Ok, got {other:?}"),
        }
    }

    #[test]
    fn unbaselined_metric_reports_new_not_pass_or_fail() {
        let base = Baseline::from_measurements(&[m("known", 100.0)]);
        let reports = compare(&base, &[m("brand.new", 999.0)], DEFAULT_TOLERANCE);
        assert_eq!(reports[0].verdict, Verdict::New);
        assert!(!reports[0].is_regression(), "a new metric never fails the run");
        assert!(!has_regression(&reports));
    }

    #[test]
    fn zero_baseline_cannot_ratchet_and_does_not_fail() {
        // A zero floor (e.g. a sub-ns op rounded to 0 in a prior run) must not
        // make every subsequent run a "regression" — it reports Ok until the
        // next --update records a real number.
        let base = Baseline::from_measurements(&[m("op", 0.0)]);
        let reports = compare(&base, &[m("op", 1234.0)], DEFAULT_TOLERANCE);
        assert!(!reports[0].is_regression());
    }

    #[test]
    fn negative_or_nonfinite_tolerance_clamps_to_zero() {
        // A bad --tolerance must degrade to the strictest ratchet (0%), never
        // silently disable the gate by going infinite.
        let base = Baseline::from_measurements(&[m("op", 100.0)]);
        // At tol=0, any slowdown at all is a regression.
        assert!(compare(&base, &[m("op", 101.0)], -3.0)[0].is_regression());
        assert!(compare(&base, &[m("op", 101.0)], f64::NAN)[0].is_regression());
        // ...but equal-or-faster still passes.
        assert!(!compare(&base, &[m("op", 100.0)], -3.0)[0].is_regression());
    }

    #[test]
    fn reports_preserve_input_order() {
        let base = Baseline::new();
        let reports = compare(&base, &[m("c", 1.0), m("a", 2.0), m("b", 3.0)], 0.5);
        let names: Vec<&str> = reports.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["c", "a", "b"]);
    }

    #[test]
    fn empty_baseline_makes_every_metric_new() {
        let base = Baseline::new();
        assert!(base.is_empty());
        let reports = compare(&base, &[m("a", 1.0), m("b", 2.0)], 0.5);
        assert!(reports.iter().all(|r| r.verdict == Verdict::New));
        assert!(!has_regression(&reports));
    }
}
