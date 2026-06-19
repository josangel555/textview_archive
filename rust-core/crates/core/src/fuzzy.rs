//! Fuzzy matcher — the Rust port of the Swift `FuzzyMatcher` (TSK-633).
//! Pure, sans-IO, ZERO deps (owner decision 2026-06-11: char-level, no
//! grapheme crate; `unicode-segmentation` is the pre-approved fallback only
//! if grapheme fidelity ever demonstrably matters).
//!
//! **Index unit caveat (deliberate divergence):** the Swift original walks
//! `Character`s (grapheme clusters); this port walks `char`s (Unicode scalar
//! values). For the real corpus (file names, command titles — ASCII-dominant)
//! scores and order are identical; on grapheme-heavy strings (emoji + ZWJ
//! sequences, combining marks) the matched INDICES are scalar offsets, not
//! grapheme offsets, and a consumer that highlights glyphs must map them.
//! The A/B parity tests pin score+order on an ASCII corpus and order-only
//! tolerance elsewhere.
//!
//! Scoring rules (must stay EXACTLY in lockstep with the Swift twin until
//! the Swift side is deleted — every constant is part of the parity
//! contract):
//! - empty query matches everything with score 0;
//! - all query chars must appear in target, in order, case-insensitive;
//! - per matched char: +1 base; +6 at a word boundary (start, or after one
//!   of `/ _ - . ` space); +4 consecutive-run; +3 strong prefix (index 0)
//!   ELSE +1 if index < 5.

use serde::{Deserialize, Serialize};

/// One match result: the score plus the matched char (scalar) indices.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    pub score: i64,
    /// Scalar-value indices into the target (see the unit caveat above).
    pub indices: Vec<u32>,
}

/// Case-insensitive char equality via full `to_lowercase` sequences (matches
/// Swift's per-Character `lowercased()` comparison for the single-scalar
/// case; multi-scalar lowercase expansions compare sequence-wise).
fn ci_eq(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

fn is_boundary(ch: char) -> bool {
    matches!(ch, '/' | '_' | '-' | '.' | ' ')
}

/// Score `query` against `target`. `None` = no match. Mirrors the Swift
/// `FuzzyMatcher.match(_:against:)` exactly (see the scoring table above).
#[must_use]
pub fn match_query(query: &str, target: &str) -> Option<Match> {
    if query.is_empty() {
        return Some(Match { score: 0, indices: Vec::new() });
    }
    let q: Vec<char> = query.chars().collect();
    match_query_chars(&q, target)
}

/// `match_query` with a PRE-COLLECTED, non-empty query, so `rank` collects the
/// query's chars ONCE instead of once per candidate (TSK-996).
#[allow(clippy::cast_possible_truncation,
        reason = "TSK-575: ti is a char position within a fuzzy candidate (filename/path) — \
                  bounded far below u32::MAX")]
fn match_query_chars(q: &[char], target: &str) -> Option<Match> {
    let t: Vec<char> = target.chars().collect();
    if t.is_empty() {
        return None;
    }

    let mut qi = 0usize;
    let mut matched: Vec<u32> = Vec::new();
    let mut score: i64 = 0;
    // Sentinel -2 so index 0 is never "consecutive" with the start state.
    let mut last_matched_at: i64 = -2;

    for (ti, &ch) in t.iter().enumerate() {
        // Lint-clean indexing (the no-panic wall denies `[]`): qi is always
        // < q.len() here by construction, but prove it to the compiler.
        let Some(&qc) = q.get(qi) else { break };
        if ci_eq(ch, qc) {
            matched.push(ti as u32);
            let mut bonus: i64 = 1;
            // `ti == 0` short-circuits before `ti - 1` can underflow.
            if ti == 0 || t.get(ti - 1).copied().is_some_and(is_boundary) {
                bonus += 6; // word-boundary bonus
            }
            if ti as i64 == last_matched_at + 1 {
                bonus += 4; // consecutive bonus
            }
            if ti == 0 {
                bonus += 3; // strong prefix bonus
            } else if ti < 5 {
                bonus += 1; // prefer matches near the start
            }
            score += bonus;
            last_matched_at = ti as i64;
            qi += 1;
        }
    }

    if qi != q.len() {
        return None;
    }
    Some(Match { score, indices: matched })
}

/// Rank `candidates` against `query`: matching candidates sorted by score
/// DESCENDING with STABLE tie-breaking on input order (the Swift B13/A10
/// contract — unstable ties made the palette flicker). Returns
/// `(candidate_index, match)` pairs.
#[must_use]
#[allow(clippy::cast_possible_truncation,
        reason = "TSK-575: i is a candidate index; the candidate count (file list) is \
                  bounded far below u32::MAX")]
pub fn rank<'a, I>(query: &str, candidates: I) -> Vec<(u32, Match)>
where
    I: IntoIterator<Item = &'a str>,
{
    // Collect the query's chars ONCE, not once per candidate (TSK-996).
    let q: Vec<char> = query.chars().collect();
    let mut scored: Vec<(u32, Match)> = candidates
        .into_iter()
        .enumerate()
        .filter_map(|(i, c)| {
            let m = if q.is_empty() {
                Some(Match { score: 0, indices: Vec::new() })
            } else {
                match_query_chars(&q, c)
            };
            m.map(|m| (i as u32, m))
        })
        .collect();
    // sort_by is stable in Rust; key = score desc, ties keep input order.
    scored.sort_by(|a, b| b.1.score.cmp(&a.1.score));
    scored
}

// ---------------------------------------------------------------------------
// Wire layer — the `ffi_frame_body!` shape: request frame in, response out.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct RankRequest {
    query: String,
    candidates: Vec<String>,
}

#[derive(Serialize)]
struct WireMatch {
    index: u32,
    score: i64,
    indices: Vec<u32>,
}

#[derive(Serialize)]
struct RankResponse {
    matches: Vec<WireMatch>,
}

/// `{query, candidates:[String]}` request frame → `{matches:[{index, score,
/// indices}]}` response frame, sorted per [`rank`]. Input size is bounded by
/// the wire decode cap; scoring is O(query × target) per candidate.
pub fn rank_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: RankRequest = crate::wire::decode_frame(req_frame)?;
    let matches = rank(&req.query, req.candidates.iter().map(String::as_str))
        .into_iter()
        .map(|(index, m)| WireMatch { index, score: m.score, indices: m.indices })
        .collect();
    crate::wire::encode_frame(&RankResponse { matches })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_query_matches_everything_with_zero() {
        let m = match_query("", "anything").unwrap();
        assert_eq!(m.score, 0);
        assert!(m.indices.is_empty());
    }

    #[test]
    fn empty_target_never_matches_nonempty_query() {
        assert!(match_query("a", "").is_none());
    }

    #[test]
    fn requires_all_chars_in_order() {
        assert!(match_query("abc", "a_b_c").is_some());
        assert!(match_query("acb", "abc").is_none());
        assert!(match_query("abcd", "abc").is_none());
    }

    #[test]
    fn scoring_matches_the_swift_table() {
        // "ab" vs "ab": a → 1 +6(start-boundary) +3(prefix) = 10;
        //               b → 1 +4(consecutive) +1(ti<5) = 6. Total 16.
        assert_eq!(match_query("ab", "ab").unwrap().score, 16);
        // "b" vs "a_b": boundary after '_' → 1 + 6 + 1(ti=2<5) = 8.
        assert_eq!(match_query("b", "a_b").unwrap().score, 8);
        // "b" vs "axb": no boundary → 1 + 1(ti=2<5) = 2.
        assert_eq!(match_query("b", "axb").unwrap().score, 2);
    }

    #[test]
    fn case_insensitive_both_directions() {
        assert!(match_query("ABC", "abc").is_some());
        assert!(match_query("abc", "ABC").is_some());
        // Indices land on the ORIGINAL target positions.
        assert_eq!(match_query("ab", "AB").unwrap().indices, vec![0, 1]);
    }

    #[test]
    fn indices_are_scalar_positions() {
        // 'é' is one scalar; matched 's' sits at scalar index 2.
        let m = match_query("s", "rés").unwrap();
        assert_eq!(m.indices, vec![2]);
    }

    #[test]
    fn rank_sorts_by_score_desc_with_stable_ties() {
        // "readme.md" (boundary-rich) must outrank "xreadme"; two identical
        // candidates keep input order (stable-tie contract).
        let out = rank("rm", ["xrm", "r_m", "xrm"]);
        assert_eq!(out[0].0, 1, "boundary match ranks first");
        assert_eq!(out[1].0, 0, "stable tie: earlier input first");
        assert_eq!(out[2].0, 2);
        assert_eq!(out[1].1.score, out[2].1.score);
    }

    #[test]
    fn rank_drops_non_matches() {
        let out = rank("zz", ["abc", "az", "zz"]);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].0, 2);
    }

    #[test]
    fn rank_equals_per_candidate_match_query() {
        // TSK-996: hoisting the query Vec<char> out of the per-candidate loop
        // must not change results — rank == match_query on each candidate.
        let cands = ["foobar", "fzbz", "nope", "fb", "", "F_Bar"];
        for query in ["fb", "", "z", "FB"] {
            let ranked: Vec<(u32, i64)> =
                rank(query, cands.iter().copied()).iter().map(|(i, m)| (*i, m.score)).collect();
            let mut expected: Vec<(u32, i64)> = cands.iter().enumerate()
                .filter_map(|(i, c)| match_query(query, c)
                    .map(|m| (u32::try_from(i).unwrap(), m.score)))
                .collect();
            expected.sort_by(|a, b| b.1.cmp(&a.1));
            assert_eq!(ranked, expected, "rank vs per-candidate mismatch for query {query:?}");
        }
    }

    #[test]
    fn wire_round_trip() {
        #[derive(Serialize)]
        struct Req<'a> {
            query: &'a str,
            candidates: Vec<&'a str>,
        }
        let req = crate::wire::encode_frame(&Req {
            query: "rm",
            candidates: vec!["x", "r_m"],
        })
        .unwrap();
        let resp = rank_wire(&req).unwrap();
        // Decode the response frame body back out.
        #[derive(Deserialize, Debug)]
        struct WMatch {
            index: u32,
            score: i64,
            indices: Vec<u32>,
        }
        #[derive(Deserialize, Debug)]
        struct Resp {
            matches: Vec<WMatch>,
        }
        let out: Resp = crate::wire::decode_frame(&resp).unwrap();
        assert_eq!(out.matches.len(), 1);
        assert_eq!(out.matches[0].index, 1);
        assert_eq!(out.matches[0].indices, vec![0, 2]);
        assert!(out.matches[0].score > 0);
    }

    #[test]
    fn rank_wire_rejects_garbage() {
        assert!(rank_wire(&[0xFF, 0xFF, 0xFF, 0x7F, 0x01]).is_err());
    }
}
