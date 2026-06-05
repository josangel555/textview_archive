//! File-navigation ordering — the pure sort logic shared by every front-end's
//! directory pane (the ratatui TUI, the web server, and any future tier).
//!
//! The front-end owns the IO: it `read_dir`s, stats each entry, and fills an
//! [`Entry`] (`name` / `is_dir` / `mtime` / `size`). This module then orders the
//! slice the same way for all of them via [`sort_entries`], so the file panes
//! stay at parity *by construction* instead of each re-implementing the
//! dirs-first + per-key comparator.
//!
//! Sans-IO and time-free: no clock is read here (the `mtime` is supplied by the
//! caller as seconds-since-epoch), keeping the core deterministic and lint-clean
//! under the workspace `disallowed_methods` policy.
//!
//! The sort is **stable**: entries that compare equal under the active key keep
//! their incoming relative order. Each key also falls back to a case-insensitive
//! name comparison as a tie-break, so the result is deterministic regardless of
//! `read_dir` iteration order.

/// Which attribute the directory listing is ordered by.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SortKey {
    /// Case-insensitive by name, ascending (the default).
    Name,
    /// By modification time, most-recent first. Entries without an `mtime`
    /// (stat failed / unsupported) sort after those that have one.
    Modified,
    /// By byte size, largest first.
    Size,
}

impl SortKey {
    /// The next key in the cycle (`Name → Modified → Size → Name`), for a
    /// single-keystroke toggle in a front-end.
    #[must_use]
    pub fn next(self) -> Self {
        match self {
            SortKey::Name => SortKey::Modified,
            SortKey::Modified => SortKey::Size,
            SortKey::Size => SortKey::Name,
        }
    }

    /// A short, stable label for the active key (for a pane title / nav link).
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            SortKey::Name => "name",
            SortKey::Modified => "modified",
            SortKey::Size => "size",
        }
    }

    /// Parse a key from its [`SortKey::as_str`] label (e.g. a `?sort=` query),
    /// falling back to [`SortKey::Name`] for anything unrecognized.
    #[must_use]
    pub fn from_str_or_name(s: &str) -> Self {
        match s {
            "modified" => SortKey::Modified,
            "size" => SortKey::Size,
            _ => SortKey::Name,
        }
    }
}

/// Whether a directory entry named `name` should be listed given the current
/// "show hidden" state. The convention is Unix-dotfile: a leading `.` marks the
/// entry as hidden. `.` and `..` lead with a dot too, but front-ends synthesize
/// the parent row (`..`) separately and never feed it through here, so the rule
/// stays a simple prefix test.
///
/// When `show_hidden` is `true` everything passes; otherwise only entries whose
/// name does *not* begin with `.` are shown. Sans-IO and allocation-free.
///
/// ```
/// use mdvcore_core::nav::should_show;
/// assert!(should_show("main.rs", false));   // ordinary file: always shown
/// assert!(!should_show(".gitignore", false)); // dotfile: hidden by default
/// assert!(should_show(".gitignore", true));  // ...unless show_hidden is on
/// ```
#[must_use]
pub fn should_show(name: &str, show_hidden: bool) -> bool {
    show_hidden || !name.starts_with('.')
}

/// Subsequence-match `needle` against each name in `entries`, returning the
/// matching `(index, score)` pairs ordered best-first — the shared scorer behind
/// every front-end's type-to-narrow / quick-file-find box (the TUI's `f` prompt,
/// the web `?filter=` query). No new dependency: a hand-rolled subsequence
/// matcher with a prefix bonus, not a fuzzy-crate.
///
/// **Matching.** A name matches when every character of `needle` appears in it,
/// in order, left-to-right (a *subsequence* — gaps allowed). `case_sensitive`
/// chooses whether the comparison folds ASCII case. An **empty needle matches
/// everything** (score `0`), so a front-end can feed the raw box content
/// straight through: an empty box lists the whole directory unchanged.
///
/// **Scoring** (higher is better) rewards tighter, earlier, less-scattered hits:
///   - **Prefix bonus** — the needle is a leading run of the name
///     (`"ma"` vs `"main.rs"`): a large constant so prefix hits always outrank
///     mid-string ones. A *full* exact match (needle == name) adds a further
///     bonus so an exact hit tops its own prefixes.
///   - **Contiguity** — adjacent matched characters score more than scattered
///     ones (a run of the needle beats the same letters spread across the name).
///   - **Earliness** — the closer the first matched character is to the start,
///     the higher the score.
///
/// **Order.** Results are sorted by score descending; ties break by ascending
/// original index, so equal-scoring entries keep their incoming (already
/// sorted) relative order — the sort is stable and the tie-break deterministic.
///
/// Sans-IO, time-free, allocation-light (one `Vec` of matches). Non-matching
/// entries are omitted entirely (the returned `Vec` is the narrowed set).
///
/// ```
/// use mdvcore_core::nav::filter_entries;
/// let names = ["main.rs", "lib.rs", "README.md", "mod.rs"];
/// let hits = filter_entries(&names, "mr", false);
/// // "main.rs" and "README.md" and "mod.rs" all contain m..r as a subsequence;
/// // best-first ordering puts the strongest match at the front.
/// assert!(!hits.is_empty());
/// assert_eq!(hits[0].0, 0); // "main.rs" — earliest, tightest m→r
/// // An empty needle keeps every entry, in input order, all at score 0.
/// let all = filter_entries(&names, "", false);
/// assert_eq!(all.len(), names.len());
/// assert!(all.iter().all(|&(_, s)| s == 0));
/// ```
#[must_use]
pub fn filter_entries(entries: &[&str], needle: &str, case_sensitive: bool) -> Vec<(usize, i32)> {
    // Empty needle: keep everything, in input order, neutral score. Front-ends
    // feed the raw box straight in, so this is the "box is empty" fast path.
    if needle.is_empty() {
        return entries.iter().enumerate().map(|(i, _)| (i, 0)).collect();
    }
    let mut hits: Vec<(usize, i32)> = entries
        .iter()
        .enumerate()
        .filter_map(|(i, name)| score_match(name, needle, case_sensitive).map(|s| (i, s)))
        .collect();
    // Best score first; ties keep ascending input index (stable + deterministic).
    hits.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    hits
}

/// Bonus when `needle` is a leading run of the candidate (prefix match). Large
/// enough that any prefix hit outranks any non-prefix subsequence hit.
const PREFIX_BONUS: i32 = 1_000;
/// Extra bonus on top of [`PREFIX_BONUS`] when the candidate equals the needle
/// outright, so an exact match tops every name it is a prefix of.
const EXACT_BONUS: i32 = 500;
/// Reward for two matched characters landing adjacent in the candidate — favors
/// a contiguous run of the needle over the same letters scattered apart.
const ADJACENT_BONUS: i32 = 8;
/// Per-character penalty on how far into the candidate the first match lands —
/// earlier first-hits score higher (capped so a long name can't underflow).
const LEADING_GAP_PENALTY: i32 = 2;

/// Score `name` against `needle` as a subsequence, or `None` if `needle` is not
/// a subsequence of `name`. Higher is a better match (see [`filter_entries`] for
/// the scoring contract). Pure: no allocation, single left-to-right pass per
/// string. ASCII-case folding only (mirrors the rest of `nav`'s name handling).
fn score_match(name: &str, needle: &str, case_sensitive: bool) -> Option<i32> {
    // Walk both as bytes with an ASCII case fold; the subsequence semantics are
    // byte-wise, which is correct for ASCII filenames and never splits a UTF-8
    // code point (we only compare/advance whole bytes, never index into one).
    let fold = |b: u8| if case_sensitive { b } else { b.to_ascii_lowercase() };
    let hay = name.as_bytes();
    let pat = needle.as_bytes();

    let mut score: i32 = 0;
    let mut pi = 0usize; // index into the needle
    let mut last_match: Option<usize> = None; // position in `name` of the previous hit
    let mut first_match: Option<usize> = None;
    for (hi, &hb) in hay.iter().enumerate() {
        let Some(&pb) = pat.get(pi) else { break };
        if fold(hb) == fold(pb) {
            if let Some(prev) = last_match {
                if hi == prev + 1 {
                    score += ADJACENT_BONUS;
                }
            }
            if first_match.is_none() {
                first_match = Some(hi);
            }
            last_match = Some(hi);
            pi += 1;
        }
    }
    // Not every needle byte was consumed → not a subsequence.
    if pi != pat.len() {
        return None;
    }

    // Earliness: penalize how deep the first matched char sits (clamped at 0).
    if let Some(start) = first_match {
        let penalty = i32::try_from(start).unwrap_or(i32::MAX).saturating_mul(LEADING_GAP_PENALTY);
        score = score.saturating_sub(penalty);
    }
    // Prefix / exact bonuses: a leading run, and the all-equal case on top.
    if is_prefix(hay, pat, case_sensitive) {
        score = score.saturating_add(PREFIX_BONUS);
        if hay.len() == pat.len() {
            score = score.saturating_add(EXACT_BONUS);
        }
    }
    Some(score)
}

/// Whether `pat` is a leading run of `hay` under the active case folding —
/// allocation-free, byte-wise (ASCII fold), and never panics (`get` + early-out).
fn is_prefix(hay: &[u8], pat: &[u8], case_sensitive: bool) -> bool {
    if pat.len() > hay.len() {
        return false;
    }
    let fold = |b: u8| if case_sensitive { b } else { b.to_ascii_lowercase() };
    for (i, &pb) in pat.iter().enumerate() {
        match hay.get(i) {
            Some(&hb) if fold(hb) == fold(pb) => {}
            _ => return false,
        }
    }
    true
}

/// A directory entry, with the metadata the sort keys read. The front-end fills
/// this from `read_dir` + `metadata`; the core never touches the filesystem.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Entry {
    /// Display name (the file/dir basename, e.g. `"main.rs"` or `".."`).
    pub name: String,
    /// Whether the entry is a directory (drives the dirs-first grouping).
    pub is_dir: bool,
    /// Modification time as whole seconds since the Unix epoch, or `None` when
    /// the front-end couldn't stat it. `None` sorts last under `Modified`.
    pub mtime: Option<u64>,
    /// Byte size (directories are typically `0`; only meaningful for files).
    pub size: u64,
}

/// Order `entries` in place by `key`, optionally grouping directories ahead of
/// files. **Stable**: equal entries keep their relative order.
///
/// Grouping (`dirs_first`) is the outermost comparison, so it always wins over
/// the key. Within a group the active key decides, with a case-insensitive name
/// comparison as the final tie-break:
///   - [`SortKey::Name`]: case-insensitive ascending.
///   - [`SortKey::Modified`]: most-recent first (`None` mtime sorts last).
///   - [`SortKey::Size`]: largest first.
pub fn sort_entries(entries: &mut [Entry], key: SortKey, dirs_first: bool) {
    entries.sort_by(|a, b| cmp(a, b, key, dirs_first));
}

/// The total ordering [`sort_entries`] applies — exposed so a front-end whose
/// own row type is richer than [`Entry`] (e.g. it also carries display state)
/// can sort an index-tagged mirror with the *same* comparator instead of
/// re-deriving the dirs-first + per-key + name-tie-break logic. Pass a stable
/// sort (`sort_by` / `sort_by_key`) for the stability guarantee to hold.
#[must_use]
pub fn cmp(a: &Entry, b: &Entry, key: SortKey, dirs_first: bool) -> core::cmp::Ordering {
    if dirs_first {
        // `true` (a dir) must come before `false` (a file): reverse the bool
        // order so dirs lead. Equal-ness falls through to the key.
        let group = b.is_dir.cmp(&a.is_dir);
        if group != core::cmp::Ordering::Equal {
            return group;
        }
    }
    match key {
        SortKey::Name => name_cmp(a, b),
        SortKey::Modified => {
            // Most-recent first → reverse the natural ascending order. A missing
            // mtime is treated as "oldest" so it sorts last.
            mtime_rank(a).cmp(&mtime_rank(b)).reverse().then_with(|| name_cmp(a, b))
        }
        SortKey::Size => b.size.cmp(&a.size).then_with(|| name_cmp(a, b)),
    }
}

/// Rank an entry's mtime so a missing one (`None`) is always the oldest. Used
/// under `Modified` where the result is reversed for most-recent-first: a `None`
/// ranks below every real timestamp and thus lands last after the reverse.
fn mtime_rank(e: &Entry) -> u64 {
    e.mtime.unwrap_or(0)
}

/// Case-insensitive name comparison, the universal tie-break.
fn name_cmp(a: &Entry, b: &Entry) -> core::cmp::Ordering {
    a.name.to_lowercase().cmp(&b.name.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, is_dir: bool, mtime: Option<u64>, size: u64) -> Entry {
        Entry { name: name.into(), is_dir, mtime, size }
    }

    fn names(entries: &[Entry]) -> Vec<&str> {
        entries.iter().map(|e| e.name.as_str()).collect()
    }

    #[test]
    fn name_key_is_case_insensitive_ascending() {
        let mut e = vec![
            entry("Banana", false, None, 0),
            entry("apple", false, None, 0),
            entry("Cherry", false, None, 0),
        ];
        sort_entries(&mut e, SortKey::Name, false);
        assert_eq!(names(&e), vec!["apple", "Banana", "Cherry"]);
    }

    #[test]
    fn dirs_first_groups_dirs_ahead_of_files() {
        let mut e = vec![
            entry("zeta.txt", false, None, 0),
            entry("alpha", true, None, 0),
            entry("beta.txt", false, None, 0),
            entry("gamma", true, None, 0),
        ];
        sort_entries(&mut e, SortKey::Name, true);
        // Dirs (alpha, gamma) lead, sorted by name; then files (beta, zeta).
        assert_eq!(names(&e), vec!["alpha", "gamma", "beta.txt", "zeta.txt"]);
        // Invariant: no file precedes any directory.
        let first_file = e.iter().position(|x| !x.is_dir).unwrap_or(e.len());
        assert!(e[..first_file].iter().all(|x| x.is_dir), "dirs lead the slice");
        assert!(e[first_file..].iter().all(|x| !x.is_dir), "files trail the slice");
    }

    #[test]
    fn dirs_first_off_interleaves_by_key() {
        let mut e = vec![
            entry("zeta.txt", false, None, 0),
            entry("alpha", true, None, 0),
            entry("beta.txt", false, None, 0),
        ];
        sort_entries(&mut e, SortKey::Name, false);
        // Pure name order ignores is_dir entirely.
        assert_eq!(names(&e), vec!["alpha", "beta.txt", "zeta.txt"]);
    }

    #[test]
    fn modified_key_is_most_recent_first() {
        let mut e = vec![
            entry("old.txt", false, Some(100), 0),
            entry("new.txt", false, Some(300), 0),
            entry("mid.txt", false, Some(200), 0),
        ];
        sort_entries(&mut e, SortKey::Modified, false);
        assert_eq!(names(&e), vec!["new.txt", "mid.txt", "old.txt"]);
    }

    #[test]
    fn modified_key_puts_missing_mtime_last() {
        let mut e = vec![
            entry("unknown.txt", false, None, 0),
            entry("recent.txt", false, Some(500), 0),
            entry("ancient.txt", false, Some(1), 0),
        ];
        sort_entries(&mut e, SortKey::Modified, false);
        // Real timestamps lead newest-first; the None-mtime entry sorts last.
        assert_eq!(names(&e), vec!["recent.txt", "ancient.txt", "unknown.txt"]);
    }

    #[test]
    fn size_key_is_largest_first() {
        let mut e = vec![
            entry("small.txt", false, None, 10),
            entry("big.txt", false, None, 9000),
            entry("mid.txt", false, None, 500),
        ];
        sort_entries(&mut e, SortKey::Size, false);
        assert_eq!(names(&e), vec!["big.txt", "mid.txt", "small.txt"]);
    }

    #[test]
    fn name_tie_break_under_size() {
        // Equal sizes fall back to case-insensitive name ascending.
        let mut e = vec![
            entry("Charlie.txt", false, None, 42),
            entry("alpha.txt", false, None, 42),
            entry("bravo.txt", false, None, 42),
        ];
        sort_entries(&mut e, SortKey::Size, false);
        assert_eq!(names(&e), vec!["alpha.txt", "bravo.txt", "Charlie.txt"]);
    }

    #[test]
    fn name_tie_break_under_modified() {
        let mut e = vec![
            entry("Charlie.txt", false, Some(7), 0),
            entry("alpha.txt", false, Some(7), 0),
            entry("bravo.txt", false, Some(7), 0),
        ];
        sort_entries(&mut e, SortKey::Modified, false);
        assert_eq!(names(&e), vec!["alpha.txt", "bravo.txt", "Charlie.txt"]);
    }

    #[test]
    fn sort_is_stable_for_fully_equal_entries() {
        // Same key value AND same name (case-insensitively): incoming order is
        // preserved. We distinguish otherwise-equal entries by size to observe
        // which copy landed where, while keeping the sort key (Name) blind to it.
        let mut e = vec![
            entry("dup", false, None, 1),
            entry("dup", false, None, 2),
            entry("dup", false, None, 3),
        ];
        sort_entries(&mut e, SortKey::Name, false);
        // A stable sort leaves the three equal "dup" entries in input order.
        assert_eq!(e.iter().map(|x| x.size).collect::<Vec<_>>(), vec![1, 2, 3]);
    }

    #[test]
    fn dirs_first_with_size_key() {
        // Grouping wins over the key: a small dir still precedes a huge file.
        let mut e = vec![
            entry("huge.bin", false, None, 1_000_000),
            entry("d", true, None, 0),
        ];
        sort_entries(&mut e, SortKey::Size, true);
        assert_eq!(names(&e), vec!["d", "huge.bin"]);
    }

    #[test]
    fn sortkey_cycle_and_labels() {
        assert_eq!(SortKey::Name.next(), SortKey::Modified);
        assert_eq!(SortKey::Modified.next(), SortKey::Size);
        assert_eq!(SortKey::Size.next(), SortKey::Name);
        assert_eq!(SortKey::Name.as_str(), "name");
        assert_eq!(SortKey::Modified.as_str(), "modified");
        assert_eq!(SortKey::Size.as_str(), "size");
        assert_eq!(SortKey::from_str_or_name("size"), SortKey::Size);
        assert_eq!(SortKey::from_str_or_name("modified"), SortKey::Modified);
        assert_eq!(SortKey::from_str_or_name("bogus"), SortKey::Name);
    }

    #[test]
    fn empty_slice_is_a_noop() {
        let mut e: Vec<Entry> = Vec::new();
        sort_entries(&mut e, SortKey::Name, true);
        assert!(e.is_empty());
    }

    #[test]
    fn should_show_hides_dotfiles_by_default() {
        assert!(should_show("main.rs", false));
        assert!(should_show("README", false));
        assert!(!should_show(".gitignore", false));
        assert!(!should_show(".env", false));
        assert!(!should_show(".hidden_dir", false));
    }

    #[test]
    fn should_show_reveals_dotfiles_when_enabled() {
        assert!(should_show("main.rs", true));
        assert!(should_show(".gitignore", true));
        assert!(should_show(".env", true));
        assert!(should_show("..", true));
    }

    #[test]
    fn should_show_only_a_leading_dot_is_hidden() {
        // A dot anywhere but the front is not a hidden marker.
        assert!(should_show("file.txt", false));
        assert!(should_show("a.b.c", false));
        assert!(should_show("v1.2.3.tar.gz", false));
        // Empty name has no leading dot, so it is not hidden.
        assert!(should_show("", false));
    }

    #[test]
    fn should_show_treats_dot_dirs_as_hidden() {
        // `.` and `..` carry a leading dot; front-ends synthesize the parent row
        // themselves and don't route it here, but the rule is consistent if they did.
        assert!(!should_show(".", false));
        assert!(!should_show("..", false));
    }

    // MARK: - filter_entries (type-to-narrow / quick file find)

    /// Just the surviving indices, in returned (best-first) order.
    fn filter_idx(entries: &[&str], needle: &str, cs: bool) -> Vec<usize> {
        filter_entries(entries, needle, cs).into_iter().map(|(i, _)| i).collect()
    }

    #[test]
    fn filter_empty_needle_keeps_all_in_input_order() {
        let names = ["main.rs", "lib.rs", "README.md"];
        let hits = filter_entries(&names, "", false);
        // Every entry survives, in input order, at the neutral score.
        assert_eq!(hits, vec![(0, 0), (1, 0), (2, 0)]);
    }

    #[test]
    fn filter_empty_slice_is_empty() {
        let names: [&str; 0] = [];
        assert!(filter_entries(&names, "rs", false).is_empty());
        // Empty needle over an empty slice is still empty (no panic on the fast path).
        assert!(filter_entries(&names, "", false).is_empty());
    }

    #[test]
    fn filter_matches_subsequence_not_just_substring() {
        // "mr" is NOT a substring of "main.rs" but IS a subsequence (m…r).
        let names = ["main.rs", "zzz", "lib.rs"];
        let idx = filter_idx(&names, "mr", false);
        assert!(idx.contains(&0), "main.rs matches m→r as a subsequence");
        assert!(!idx.contains(&1), "zzz has no m or r");
        // "lib.rs" has an 'r' but no 'm' before it → no match.
        assert!(!idx.contains(&2), "lib.rs lacks an 'm' preceding the 'r'");
    }

    #[test]
    fn filter_non_subsequence_is_dropped() {
        // Needle longer than / not orderable within the name → omitted entirely.
        let names = ["abc", "cab"];
        // "ba" is a subsequence of neither ("abc" has a…b but not b…a; "cab" has b…? no a after).
        let idx = filter_idx(&names, "ba", false);
        assert!(idx.is_empty(), "neither name contains b then a in order: {idx:?}");
    }

    #[test]
    fn filter_prefix_bonus_outranks_mid_string_match() {
        // Both contain "ma" as a subsequence, but only "main.rs" has it as a
        // PREFIX — the prefix bonus must float it to the top regardless of the
        // other name's incidental adjacency.
        let names = ["lemma.txt", "main.rs"];
        let idx = filter_idx(&names, "ma", false);
        assert_eq!(idx.first(), Some(&1), "prefix match (main.rs) ranks first: {idx:?}");
        assert!(idx.contains(&0), "the mid-string match still appears, just lower");
    }

    #[test]
    fn filter_exact_match_tops_its_own_prefixes() {
        // "mod" is a prefix of "module.rs" AND an exact match of "mod" — the
        // exact bonus must put the exact hit first.
        let names = ["module.rs", "mod", "modal.css"];
        let idx = filter_idx(&names, "mod", false);
        assert_eq!(idx.first(), Some(&1), "exact 'mod' ranks above its prefixes: {idx:?}");
    }

    #[test]
    fn filter_contiguous_run_beats_scattered_match() {
        // "ab" is contiguous in "abacus" (positions 0,1) and scattered in
        // "xaxbx" (positions 1,3). With both non-prefix... actually "abacus"
        // is a prefix, so to isolate contiguity vs scatter we lead both names
        // with a non-matching char.
        let names = ["zxaxbx", "zabxx"];
        let idx = filter_idx(&names, "ab", false);
        // Neither is a prefix; the contiguous "ab" in "zabxx" (idx 1) outranks
        // the scattered a…b in "zxaxbx" (idx 0).
        assert_eq!(idx.first(), Some(&1), "contiguous match ranks first: {idx:?}");
    }

    #[test]
    fn filter_earlier_match_outranks_later() {
        // Same contiguous "ab", but earlier in the first name. Earliness wins.
        let names = ["abxxxx", "xxxxab"];
        let scores = filter_entries(&names, "ab", false);
        // Both match; the earlier (and prefix) one scores strictly higher.
        let s0 = scores.iter().find(|(i, _)| *i == 0).map_or(i32::MIN, |(_, s)| *s);
        let s1 = scores.iter().find(|(i, _)| *i == 1).map_or(i32::MIN, |(_, s)| *s);
        assert!(s0 > s1, "earlier match scores higher: {s0} vs {s1}");
        assert_eq!(scores.first().map(|(i, _)| *i), Some(0), "earliest first: {scores:?}");
    }

    #[test]
    fn filter_tie_breaks_by_ascending_input_index() {
        // Three identical names → identical scores → the sort must fall back to
        // ascending input index (stable, deterministic), not shuffle them.
        let names = ["dup", "dup", "dup"];
        let idx = filter_idx(&names, "du", false);
        assert_eq!(idx, vec![0, 1, 2], "equal scores keep input order: {idx:?}");
    }

    #[test]
    fn filter_case_insensitive_by_default_param() {
        let names = ["MainView.swift", "other"];
        // Case-insensitive: lowercase needle matches the mixed-case name.
        let ci = filter_idx(&names, "main", false);
        assert_eq!(ci.first(), Some(&0), "case-insensitive matches MainView: {ci:?}");
        // Case-sensitive: the lowercase needle no longer prefixes the capitalized name.
        let cs = filter_idx(&names, "main", true);
        assert!(!cs.contains(&0), "case-sensitive 'main' does NOT match 'MainView': {cs:?}");
        // ...but the exact-case needle does.
        let cs2 = filter_idx(&names, "Main", true);
        assert_eq!(cs2.first(), Some(&0), "case-sensitive 'Main' matches: {cs2:?}");
    }

    #[test]
    fn filter_scores_are_all_returned_with_indices() {
        // Contract check: every returned tuple carries a real score and a valid
        // index into the input slice; no out-of-range or duplicate indices.
        let names = ["alpha", "beta", "gamma", "delta"];
        let hits = filter_entries(&names, "a", false);
        assert!(hits.iter().all(|&(i, _)| i < names.len()), "indices in range");
        let mut seen: Vec<usize> = hits.iter().map(|&(i, _)| i).collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), hits.len(), "no duplicate indices");
    }
}
