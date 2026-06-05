//! Regression tests for the Rust↔Swift A/B-parity drift in
//! `core::diff` split handling (audit findings S3 + S4).
//!
//! Both fixes mirror Swift's `split(separator:)`, whose default
//! `omittingEmptySubsequences: true` drops leading/empty pieces — behavior the
//! raw Rust `split` / `find(' ')` did not reproduce. These exercise the public
//! `diff::parse` entrypoint (the private `parse_coord` /
//! `parse_diff_git_paths` are reached through it) so the assertions live in an
//! integration test rather than touching the in-file `#[cfg(test)] mod tests`.
//!
//! Expected values are pinned to the Swift `DiffParser` reference behavior,
//! confirmed against `Sources/ViewerCore/Git/DiffParser.swift`.

use mdvcore_core::diff::{self, LineKind};

// ---------------------------------------------------------------------------
// S3 — parse_coord: empty / comma-led start coordinate.
//
// Swift `s.split(separator: ",")` omits empties, so `,3` -> ["3"] -> the lone
// piece is the START (count omitted -> 1). The pre-fix Rust kept the empty
// leading piece, mis-reading start=0 / count=3.
// ---------------------------------------------------------------------------

/// `@@ -,3 +1,1 @@`: the audit's probe. Swift yields old=(start 3, count 1).
#[test]
fn comma_led_old_coord_treats_first_number_as_start() {
    let diff = "diff --git a/f.txt b/f.txt\n@@ -,3 +1,1 @@\n context\n";
    let files = diff::parse(diff);
    assert_eq!(files.len(), 1);
    let h = &files[0].hunks[0];
    // Pre-fix Rust gave (old_start 0, old_count 3); Swift gives (3, 1).
    assert_eq!((h.old_start, h.old_count), (3, 1));
    assert_eq!((h.new_start, h.new_count), (1, 1));
}

/// Trailing-comma start (`3,`) collapses to start=3, count default 1 — and
/// matches the absent-count form (`3`) identically, the point of the fix.
#[test]
fn trailing_comma_and_absent_count_fall_back_identically() {
    let with_comma = "diff --git a/f b/f\n@@ -3, +5, @@\n c\n";
    let without = "diff --git a/f b/f\n@@ -3 +5 @@\n c\n";
    let a = diff::parse(with_comma);
    let b = diff::parse(without);
    let ha = &a[0].hunks[0];
    let hb = &b[0].hunks[0];
    assert_eq!((ha.old_start, ha.old_count), (3, 1));
    assert_eq!((ha.new_start, ha.new_count), (5, 1));
    assert_eq!(
        (ha.old_start, ha.old_count, ha.new_start, ha.new_count),
        (hb.old_start, hb.old_count, hb.new_start, hb.new_count),
    );
}

/// Interior empty piece (`10,,5`) is also dropped, mirroring Swift -> (10, 5).
#[test]
fn interior_empty_coord_piece_is_dropped() {
    let diff = "diff --git a/f b/f\n@@ -10,,5 +1,1 @@\n c\n";
    let files = diff::parse(diff);
    let h = &files[0].hunks[0];
    assert_eq!((h.old_start, h.old_count), (10, 5));
}

/// Well-formed coordinates are unaffected by the filter.
#[test]
fn well_formed_coords_unchanged() {
    let diff = "diff --git a/f b/f\n@@ -10,5 +12,7 @@ ctx\n c\n";
    let files = diff::parse(diff);
    let h = &files[0].hunks[0];
    assert_eq!((h.old_start, h.old_count), (10, 5));
    assert_eq!((h.new_start, h.new_count), (12, 7));
    assert_eq!(h.header, "ctx");
    assert_eq!(h.lines[0].kind, LineKind::Context);
}

// ---------------------------------------------------------------------------
// S4 — parse_diff_git_paths strategy-4 fallback: leading/empty space tokens.
//
// Strategy 4 is reached only after the quoted / equal-prefix / last-` b/`
// strategies all fail (i.e. a path with no `b/` segment). Swift's
// `split(separator: " ", maxSplits: 1)` drops the LEADING empty subsequence
// without spending the single split; the pre-fix Rust `find(' ')` split at the
// leading space, yielding an empty a-token.
// ---------------------------------------------------------------------------

/// Leading space + two space-separated tokens, no `b/` anywhere -> strategy 4.
/// Swift drops the leading empty, giving a=x.path b=y.path (both stripped).
#[test]
fn strategy4_drops_leading_space_token() {
    // No ` b/` and no `a/`-prefixed equal-prefix match -> falls to strategy 4.
    let diff = "diff --git  x.path y.path\n@@ -1,1 +1,1 @@\n c\n";
    let files = diff::parse(diff);
    assert_eq!(files.len(), 1);
    // Pre-fix Rust: old_path = "" (empty a-token). Swift / fixed: "x.path".
    assert_eq!(files[0].old_path, "x.path");
    assert_eq!(files[0].new_path, "y.path");
}

/// Double interior space: Swift's single split keeps the rest verbatim, so the
/// second token retains its leading space before `strip_path_prefix` trims it.
#[test]
fn strategy4_interior_double_space_keeps_remainder() {
    let diff = "diff --git x.path  y.path\n@@ -1,1 +1,1 @@\n c\n";
    let files = diff::parse(diff);
    assert_eq!(files[0].old_path, "x.path");
    // strip_path_prefix trims the leading space that Swift preserved in token 2.
    assert_eq!(files[0].new_path, "y.path");
}

/// A single token (no usable space split) falls back to `(rest, rest)` using
/// the ORIGINAL untrimmed `rest`, matching Swift's `return (rest, rest)`.
#[test]
fn strategy4_single_token_falls_back_to_original_rest() {
    let diff = "diff --git  lonely.path\n@@ -1,1 +1,1 @@\n c\n";
    let files = diff::parse(diff);
    // Swift returns the untrimmed rest verbatim on the < 2-token path.
    assert_eq!(files[0].old_path, " lonely.path");
    assert_eq!(files[0].new_path, " lonely.path");
}

/// The normal well-formed `a/… b/…` form still routes through an earlier
/// strategy and is unaffected by the strategy-4 change.
#[test]
fn well_formed_git_paths_unaffected() {
    let diff = "diff --git a/src/main.rs b/src/main.rs\n@@ -1,1 +1,1 @@\n c\n";
    let files = diff::parse(diff);
    assert_eq!(files[0].old_path, "src/main.rs");
    assert_eq!(files[0].new_path, "src/main.rs");
}
