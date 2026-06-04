//! CodeMirror incremental-edit reducer — the Rust port of the Swift
//! `CMEditApplier` (migration plan slice #2). Pure, sans-IO, no deps.
//!
//! **UTF-16 semantics are load-bearing.** CodeMirror 6 indexes
//! `EditorState.doc` in UTF-16 code units, and the edit `from`/`to` offsets are
//! in those units. Rust `str` is UTF-8, so we operate on a `Vec<u16>`
//! (`encode_utf16`) to match CM's indexing exactly — the same reason the Swift
//! original walks `text.utf16`. A naive byte/char port would silently corrupt
//! edits on astral-plane (surrogate-pair) or multi-byte input.
//!
//! All edits in a batch reference offsets **before** the batch is applied (CM's
//! multi-change `Transaction` convention): we sort by `from` ascending and walk
//! forward. Overlapping or out-of-bounds ranges are **rejected** (`None`) rather
//! than silently merged — the caller's response is a full-text resync. A final
//! *validating* UTF-16 decode returns `None` on any ill-formed result (e.g. an
//! edit that split a surrogate pair into a lone surrogate) instead of
//! substituting U+FFFD and permanently diverging the buffer.

/// One CodeMirror change: replace the UTF-16 range `[from, to)` with `insert`.
/// `from`/`to` are signed to faithfully reject a negative offset from a buggy
/// encoder (mirrors the Swift `e.from < 0` guard).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CmEdit {
    /// Start offset, in UTF-16 code units, into the pre-edit doc.
    pub from: i64,
    /// End offset (exclusive), in UTF-16 code units, into the pre-edit doc.
    pub to: i64,
    /// Replacement text.
    pub insert: String,
}

impl CmEdit {
    /// Convenience constructor.
    pub fn new(from: i64, to: i64, insert: impl Into<String>) -> Self {
        Self { from, to, insert: insert.into() }
    }
}

/// Apply `edits` to `base` (a UTF-16-indexed CodeMirror doc mirror), returning
/// the resulting string or `None` if any edit is out of bounds, overlaps a
/// prior one, or yields ill-formed UTF-16. A non-`None` result is byte-identical
/// to what CM6 produces from the same batch — the parity contract the A/B test
/// pins against the Swift `CMEditApplier`.
pub fn apply(base: &str, edits: &[CmEdit]) -> Option<String> {
    if edits.is_empty() {
        return Some(base.to_owned());
    }

    let base_units: Vec<u16> = base.encode_utf16().collect();
    let base_len = base_units.len() as i64;

    // Stable sort ascending by (from, to) — CM's iterChangedRanges is already
    // sorted, but JS may reorder during debounce accumulation.
    let mut sorted: Vec<&CmEdit> = edits.iter().collect();
    sorted.sort_by(|a, b| a.from.cmp(&b.from).then(a.to.cmp(&b.to)));

    // Validate pre-edit ranges: in-bounds, well-ordered, non-overlapping.
    let mut last_to: i64 = -1;
    for e in &sorted {
        if e.from < 0 || e.to > base_len || e.from > e.to {
            return None;
        }
        if e.from < last_to {
            return None; // overlap with a prior edit
        }
        last_to = e.to;
    }

    // Walk the base, splicing inserts in. Indices are valid by the checks above
    // (each `from >= cursor` because sorted + non-overlapping, and `to <= len`).
    let mut out: Vec<u16> = Vec::with_capacity(base_units.len());
    let mut cursor: i64 = 0;
    for e in &sorted {
        if e.from > cursor {
            out.extend_from_slice(&base_units[cursor as usize..e.from as usize]);
        }
        out.extend(e.insert.encode_utf16());
        cursor = e.to;
    }
    if cursor < base_len {
        out.extend_from_slice(&base_units[cursor as usize..base_len as usize]);
    }

    // Validating decode: `String::from_utf16` errors on a lone surrogate (it
    // does NOT substitute U+FFFD), so a split-surrogate edit returns None and
    // the caller can resync rather than corrupt the buffer silently.
    String::from_utf16(&out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_batch_returns_base() {
        assert_eq!(apply("hello", &[]).as_deref(), Some("hello"));
    }

    #[test]
    fn single_insert_delete_replace() {
        // insert "X" at offset 2: he|llo -> heXllo
        assert_eq!(apply("hello", &[CmEdit::new(2, 2, "X")]).as_deref(), Some("heXllo"));
        // delete [1,3): hello -> hlo
        assert_eq!(apply("hello", &[CmEdit::new(1, 3, "")]).as_deref(), Some("hlo"));
        // replace [0,5) with "bye": hello -> bye
        assert_eq!(apply("hello", &[CmEdit::new(0, 5, "bye")]).as_deref(), Some("bye"));
    }

    #[test]
    fn multiple_edits_use_pre_edit_offsets() {
        // "abcdef": insert "-" at 1, delete [3,5) -> "a-bcf"
        let edits = [CmEdit::new(1, 1, "-"), CmEdit::new(3, 5, "")];
        assert_eq!(apply("abcdef", &edits).as_deref(), Some("a-bcf"));
    }

    #[test]
    fn unsorted_input_is_sorted() {
        let edits = [CmEdit::new(3, 5, ""), CmEdit::new(1, 1, "-")];
        assert_eq!(apply("abcdef", &edits).as_deref(), Some("a-bcf"));
    }

    #[test]
    fn overlap_rejected() {
        // [1,3) and [2,4) overlap.
        assert_eq!(apply("abcdef", &[CmEdit::new(1, 3, "x"), CmEdit::new(2, 4, "y")]), None);
    }

    #[test]
    fn adjacent_non_overlapping_ok() {
        // [1,2) then [2,3) touch but don't overlap.
        assert_eq!(apply("abcdef", &[CmEdit::new(1, 2, "X"), CmEdit::new(2, 3, "Y")]).as_deref(),
                   Some("aXYdef"));
    }

    #[test]
    fn out_of_bounds_rejected() {
        assert_eq!(apply("abc", &[CmEdit::new(-1, 0, "")]), None);   // from < 0
        assert_eq!(apply("abc", &[CmEdit::new(0, 4, "")]), None);    // to > len
        assert_eq!(apply("abc", &[CmEdit::new(2, 1, "")]), None);    // from > to
    }

    #[test]
    fn crlf_preserved() {
        assert_eq!(apply("a\r\nb", &[CmEdit::new(0, 0, "X")]).as_deref(), Some("Xa\r\nb"));
    }

    #[test]
    fn astral_plane_offsets_are_utf16() {
        // "🧠" is one scalar = TWO UTF-16 code units. base "🧠x" has len 3.
        let base = "🧠x";
        assert_eq!(base.encode_utf16().count(), 3);
        // Insert "!" after the emoji (offset 2, just past the surrogate pair).
        assert_eq!(apply(base, &[CmEdit::new(2, 2, "!")]).as_deref(), Some("🧠!x"));
        // Delete the whole emoji [0,2).
        assert_eq!(apply(base, &[CmEdit::new(0, 2, "")]).as_deref(), Some("x"));
    }

    #[test]
    fn splitting_a_surrogate_pair_yields_none() {
        // Cutting [0,1) of "🧠" leaves the low surrogate alone -> ill-formed
        // UTF-16 -> validating decode refuses (no U+FFFD).
        assert_eq!(apply("🧠", &[CmEdit::new(0, 1, "")]), None);
        // Likewise inserting between the two surrogate halves.
        assert_eq!(apply("🧠", &[CmEdit::new(1, 1, "x")]), None);
    }

    #[test]
    fn insert_only_at_end() {
        assert_eq!(apply("abc", &[CmEdit::new(3, 3, "Z")]).as_deref(), Some("abcZ"));
    }
}
