//! `CodeMirror` incremental-edit reducer — the Rust port of the Swift
//! `CMEditApplier` (migration plan slice #2). Pure, sans-IO, no deps.
//!
//! **UTF-16 semantics are load-bearing.** `CodeMirror` 6 indexes
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

use serde::{Deserialize, Serialize};

/// One `CodeMirror` change: replace the UTF-16 range `[from, to)` with `insert`.
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

/// Apply `edits` to `base` (a UTF-16-indexed `CodeMirror` doc mirror), returning
/// the resulting string or `None` if any edit is out of bounds, overlaps a
/// prior one, or yields ill-formed UTF-16. A non-`None` result is byte-identical
/// to what CM6 produces from the same batch — the parity contract the A/B test
/// pins against the Swift `CMEditApplier`.
#[must_use]
pub fn apply(base: &str, edits: &[CmEdit]) -> Option<String> {
    if edits.is_empty() {
        return Some(base.to_owned());
    }
    let base_units: Vec<u16> = base.encode_utf16().collect();
    let out = splice_units(&base_units, edits)?;
    // Validating decode: `String::from_utf16` errors on a lone surrogate (it
    // does NOT substitute U+FFFD), so a split-surrogate edit returns None and
    // the caller can resync rather than corrupt the buffer silently.
    String::from_utf16(&out).ok()
}

/// Splice `edits` into the UTF-16 `base` units, returning the resulting units or
/// `None` if any edit is out of bounds, overlaps a prior one, or is malformed.
/// This is the shared reducer kernel: [`apply`] (stateless) and [`CmDoc`]
/// (stateful) both route through it, so the stateful mirror is byte-for-byte
/// the same buffer a from-scratch full-doc apply produces — the golden
/// equivalence the differential test pins.
///
/// Surrogate validity of the RESULT is NOT checked here (a `Vec<u16>` can hold a
/// lone surrogate); the caller decodes-and-validates when it needs a `String`.
/// [`CmDoc`] keeps the units form and never decodes mid-stream, so its mirror
/// can transiently hold a lone surrogate only if an edit split a pair — and that
/// path is rejected up front by the same range checks (a split lands a `from`/`to`
/// between the two halves, which is a legal offset, so the result-decode guard in
/// [`apply`]/[`CmDoc::text`] is the backstop).
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss,
        reason = "TSK-575: the validation loop proves every from/to is in 0..=base_len, \
                  non-negative + well-ordered, before these splice casts; base.get \
                  also bounds-checks — provably no truncation or sign loss")]
fn splice_units(base: &[u16], edits: &[CmEdit]) -> Option<Vec<u16>> {
    let base_len = base.len() as i64;

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
    let mut out: Vec<u16> = Vec::with_capacity(base.len());
    let mut cursor: i64 = 0;
    for e in &sorted {
        if e.from > cursor
            && let Some(slice) = base.get(cursor as usize..e.from as usize) {
                out.extend_from_slice(slice);
            }
        out.extend(e.insert.encode_utf16());
        cursor = e.to;
    }
    if cursor < base_len
        && let Some(slice) = base.get(cursor as usize..base_len as usize) {
            out.extend_from_slice(slice);
        }
    Some(out)
}

// MARK: - Stateful doc mirror (TSK-543)

/// The changed window an [`CmDoc::apply_delta`] produced, in UTF-16 code units
/// of the POST-edit doc. `[from, from+len_after)` is the smallest contiguous
/// span that differs from the pre-edit doc; `removed` is how many units that
/// span replaced (so a consumer can re-tokenize / re-decorate only the affected
/// region instead of the whole buffer). The empty change (`from == 0`,
/// `len_after == 0`, `removed == 0`) results from an empty edit batch.
///
/// This is the wire datum that lets a stateful response carry only the *changed
/// region* — not the whole post-edit buffer — which is the core's half of the
/// "~10× typing traffic" reduction (the doc no longer crosses FFI in either
/// direction once the mirror lives in Rust).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChangedRegion {
    /// Start of the changed span, UTF-16 offset into the POST-edit doc.
    pub from: usize,
    /// Length of the changed span in the POST-edit doc (units inserted/kept).
    pub len_after: usize,
    /// Units the span replaced from the PRE-edit doc (a pure insert ⇒ 0).
    pub removed: usize,
}

/// A rust-owned, UTF-16-indexed mirror of one `CodeMirror` document. The whole
/// point (TSK-543): once the core holds the doc, the keystroke path sends only
/// edit *deltas* across the boundary — `apply_delta` mutates this mirror in
/// place — instead of shipping the entire buffer per edit batch in BOTH
/// directions (~10× typing traffic). The mirror stays in code-unit form and is
/// only decoded to a `String` on demand ([`CmDoc::text`]).
///
/// Reject-and-resync contract (unchanged from [`apply`]): an out-of-bounds,
/// overlapping, or otherwise malformed batch leaves the mirror UNTOUCHED and
/// returns `None` — the caller's cue to push a full resync. The mirror is never
/// left half-mutated, so a rejected batch is a clean no-op, not a divergence.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CmDoc {
    /// The document as UTF-16 code units — CM6's native indexing.
    units: Vec<u16>,
}

impl CmDoc {
    /// Create a mirror seeded from `text` (the one full-doc transfer that
    /// bootstraps a session; every subsequent edit is a delta).
    #[must_use]
    pub fn new(text: &str) -> Self {
        Self { units: text.encode_utf16().collect() }
    }

    /// Document length in UTF-16 code units (CM6's `doc.length`).
    #[must_use]
    pub fn len_utf16(&self) -> usize {
        self.units.len()
    }

    /// Decode the unit range `[from, to)` LOSSILY (`String::from_utf16_lossy`)
    /// — the windowed-read primitive (TSK-1517). A window may split a
    /// surrogate pair at either seam; viewers tolerate the replacement char.
    /// Bounds are re-clamped here so the accessor is total, never a panic.
    #[must_use]
    pub fn units_lossy(&self, from: usize, to: usize) -> String {
        let end = to.min(self.units.len());
        let start = from.min(end);
        self.units
            .get(start..end)
            .map(String::from_utf16_lossy)
            .unwrap_or_default()
    }

    /// The current mirror decoded to a `String`, or `None` if the units form an
    /// ill-formed UTF-16 sequence (a lone surrogate — the same backstop
    /// [`apply`] applies). A clean mirror always decodes.
    #[must_use]
    pub fn text(&self) -> Option<String> {
        String::from_utf16(&self.units).ok()
    }

    /// Apply an edit batch to the mirror IN PLACE, returning the
    /// [`ChangedRegion`] it touched, or `None` on a rejected batch (the mirror
    /// is left untouched — atomic apply-or-reject).
    ///
    /// The resulting mirror is byte-for-byte the `Vec<u16>` that
    /// `splice_units(&pre_units, edits)` produces, which is the SAME kernel
    /// [`apply`] uses — so a sequence of `apply_delta` calls is provably
    /// equivalent to a single from-scratch [`apply`] of the cumulative text,
    /// the golden contract the differential test pins.
    pub fn apply_delta(&mut self, edits: &[CmEdit]) -> Option<ChangedRegion> {
        if edits.is_empty() {
            return Some(ChangedRegion { from: 0, len_after: 0, removed: 0 });
        }
        let next = splice_units(&self.units, edits)?;
        let region = changed_region(&self.units, &next);
        self.units = next;
        Some(region)
    }
}

/// Compute the smallest contiguous changed span between `before` and `after`
/// (both UTF-16 unit slices) as a [`ChangedRegion`] in `after`'s coordinates:
/// strip the common prefix and the common suffix, and what remains in `after`
/// is the changed window; what remains in `before` is `removed`.
///
/// This is a pure derivation from the two buffers, independent of how many
/// edits were in the batch — so the changed region is exact even when the batch
/// reordered or coalesced (CM debounce). For a single-keystroke edit it
/// collapses to the inserted/removed character span, which is what makes the
/// stateful response cheap.
fn changed_region(before: &[u16], after: &[u16]) -> ChangedRegion {
    // Common prefix length. `.get()` keeps this panic-free for the no-panic FFI
    // lint wall (indices are loop-bounded but the get-form locks it in).
    let mut prefix = 0usize;
    let max_prefix = before.len().min(after.len());
    while prefix < max_prefix && before.get(prefix) == after.get(prefix) {
        prefix += 1;
    }
    // Common suffix length, not overlapping the prefix on either side. Index
    // from the end via checked subtraction + `.get()`.
    let mut suffix = 0usize;
    let max_suffix = max_prefix - prefix;
    while suffix < max_suffix {
        let b = before.len().checked_sub(1 + suffix).and_then(|i| before.get(i));
        let a = after.len().checked_sub(1 + suffix).and_then(|i| after.get(i));
        if b.is_none() || a.is_none() || b != a {
            break;
        }
        suffix += 1;
    }
    ChangedRegion {
        from: prefix,
        len_after: after.len() - prefix - suffix,
        removed: before.len() - prefix - suffix,
    }
}

// MARK: - Wire seam (stateless FFI request/response)

/// Request payload: the base doc + the edit batch. Deserialized from the
/// MessagePack named-map frame the Swift side builds (matching `to_vec_named`).
/// Borrowed `base` (TSK-561): the whole document crosses per edit batch, so
/// the owned copy was the largest single allocation on the keystroke path.
/// The edits' `insert` strings stay owned — they are keystroke-sized.
#[derive(Serialize, Deserialize)]
struct ApplyRequest<'a> {
    #[serde(borrow)]
    base: std::borrow::Cow<'a, str>,
    edits: Vec<EditWire>,
}

/// One edit as it crosses the wire (named fields, mirrors Swift `CMEdit`).
#[derive(Serialize, Deserialize)]
struct EditWire {
    from: i64,
    to: i64,
    insert: String,
}

/// Response payload: the applied text, or `null` when the batch was rejected
/// (out-of-bounds / overlap / ill-formed) — the caller's cue to full-resync.
#[derive(Serialize, Deserialize)]
struct ApplyResponse {
    text: Option<String>,
}

/// Stateless wire seam for the FFI shim `mdvcore_cm_apply`: decode a
/// length-prefixed MessagePack request frame `{base, edits:[{from,to,insert}]}`,
/// apply the batch, and encode a response frame `{text: Option<String>}`. Pure +
/// sans-IO, so it is fully cargo-testable without the C edge; the FFI layer adds
/// only the pointer/`MdvBuf`/panic-guard plumbing.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized request frame or an
/// encode failure. (A *rejected edit batch* is NOT an error — it returns Ok with
/// `text: None`.)
pub fn apply_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ApplyRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let edits: Vec<CmEdit> = req
        .edits
        .into_iter()
        .map(|e| CmEdit { from: e.from, to: e.to, insert: e.insert })
        .collect();
    let text = apply(&req.base, &edits);
    crate::wire::encode_frame(&ApplyResponse { text })
}

// MARK: - Stateful delta wire seam (TSK-543)

/// Changed-region wire record (positional-friendly named map). Mirrors
/// [`ChangedRegion`]; `null` in the response means the batch was rejected.
#[derive(Serialize, Deserialize)]
struct ChangedRegionWire {
    from: u64,
    len_after: u64,
    removed: u64,
}

/// Response payload for the stateful delta apply: the changed region (so the
/// host re-tokenizes only that span), plus the new doc length. The whole buffer
/// does NOT cross the wire — that is the traffic win. `changed: null` means the
/// batch was rejected (the host full-resyncs). On a clean apply the host knows
/// the resulting mirror length without shipping the doc.
#[derive(Serialize, Deserialize)]
struct DeltaResponse {
    changed: Option<ChangedRegionWire>,
    /// Length of the post-edit doc in UTF-16 code units (CM6 `doc.length`),
    /// 0 on a rejected batch. Lets the host sanity-check drift cheaply.
    len_utf16: u64,
}

/// Stateful delta-apply wire seam (the TSK-543 foundation): decode a
/// `{base, edits:[{from,to,insert}]}` request frame, build a [`CmDoc`] mirror
/// from `base`, apply the deltas IN PLACE, and encode a `{changed, len_utf16}`
/// response frame — the CHANGED REGION, never the whole buffer.
///
/// This is the transport-agnostic core for the eventual session-keyed FFI
/// export (where `base` is sent ONCE at session open and subsequent calls carry
/// only the deltas + the session id, so the doc crosses the boundary zero times
/// per keystroke). Pure + sans-IO, fully cargo-testable without the C edge.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized request frame or an
/// encode failure. (A *rejected edit batch* is NOT an error — `changed: null`.)
#[allow(clippy::cast_possible_truncation,
        reason = "usize→u64 widens losslessly on every supported target (usize is \
                  ≤ 64 bits); the changed-region offsets/lengths are bounded by the \
                  doc length, itself bounded by the 16 MiB wire cap")]
pub fn apply_delta_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ApplyRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let edits: Vec<CmEdit> = req
        .edits
        .into_iter()
        .map(|e| CmEdit { from: e.from, to: e.to, insert: e.insert })
        .collect();
    let mut doc = CmDoc::new(&req.base);
    let resp = match doc.apply_delta(&edits) {
        Some(region) => DeltaResponse {
            changed: Some(ChangedRegionWire {
                from: region.from as u64,
                len_after: region.len_after as u64,
                removed: region.removed as u64,
            }),
            len_utf16: doc.len_utf16() as u64,
        },
        None => DeltaResponse { changed: None, len_utf16: 0 },
    };
    crate::wire::encode_frame(&resp)
}

/// The one changed span plus its replacement text — the datum a disk-reload
/// hands to a single CM6 dispatch. See [`changed_region_between`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReloadEdit {
    /// The region of the OLD doc that changed (`from`/`removed` describe the
    /// pre-edit span; `len_after` the replacement length).
    pub region: ChangedRegion,
    /// The UTF-16 replacement units for that region.
    pub replacement: Vec<u16>,
}

/// The single-span minimal edit that turns `old` into `new` — the core of the
/// S7 external-reload reconciliation (TSK-1522). When a file changes on disk,
/// the naive path replaces the WHOLE editor doc (a full reload splice that
/// nukes the selection/scroll and re-lays-out the world). Instead: keep the
/// common UTF-16 prefix and suffix, and emit ONE [`ChangedRegion`] for the
/// divergent middle so a single CM6 dispatch applies exactly what changed.
///
/// Offsets/lengths are UTF-16 code units (CM6-native, same as [`ChangedRegion`]
/// and `apply_delta`). Returns `None` when `old == new` (no external change —
/// no dispatch needed). A pure function: no IO, no session state.
pub fn changed_region_between(old: &str, new: &str) -> Option<ReloadEdit> {
    let o: Vec<u16> = old.encode_utf16().collect();
    let n: Vec<u16> = new.encode_utf16().collect();
    if o == n {
        return None; // no external change
    }
    let shorter = o.len().min(n.len());
    // Longest common UTF-16 prefix (zip stops at the shorter — panic-free).
    let p = o.iter().zip(n.iter()).take_while(|&(a, b)| a == b).count();
    // Longest common UTF-16 suffix, bounded by `shorter - p` so it can't
    // overlap the prefix (also keeps `saturating_sub` exact below).
    let s = o
        .iter()
        .rev()
        .zip(n.iter().rev())
        .take(shorter - p)
        .take_while(|&(a, b)| a == b)
        .count();
    let len_after = n.len().saturating_sub(p + s);
    let replacement: Vec<u16> = n.iter().skip(p).take(len_after).copied().collect();
    Some(ReloadEdit {
        region: ChangedRegion {
            from: p,
            len_after,
            removed: o.len().saturating_sub(p + s),
        },
        replacement,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// Apply a `ReloadEdit` back onto `old` (UTF-16 splice) — the CM6 dispatch
    /// the region describes — and decode to a `String`. Test-only reference.
    fn apply_reload(old: &str, edit: &ReloadEdit) -> String {
        let o: Vec<u16> = old.encode_utf16().collect();
        let from = edit.region.from;
        let removed = edit.region.removed;
        let mut out: Vec<u16> = o.iter().take(from).copied().collect();
        out.extend_from_slice(&edit.replacement);
        out.extend(o.iter().skip(from + removed).copied());
        String::from_utf16(&out).unwrap()
    }

    #[test]
    fn reload_identical_is_none() {
        assert_eq!(changed_region_between("same", "same"), None);
        assert_eq!(changed_region_between("", ""), None);
    }

    #[test]
    fn reload_middle_insert() {
        // "hello world" -> "hello brave world": insert "brave " at offset 6.
        let e = changed_region_between("hello world", "hello brave world").unwrap();
        assert_eq!(e.region.from, 6);
        assert_eq!(e.region.removed, 0);
        assert_eq!(e.region.len_after, 6);
        assert_eq!(apply_reload("hello world", &e), "hello brave world");
    }

    #[test]
    fn reload_middle_delete() {
        let e = changed_region_between("hello brave world", "hello world").unwrap();
        assert_eq!(e.region.from, 6);
        assert_eq!(e.region.removed, 6); // "brave " removed
        assert_eq!(e.region.len_after, 0);
        assert_eq!(apply_reload("hello brave world", &e), "hello world");
    }

    #[test]
    fn reload_middle_replace() {
        let e = changed_region_between("abcXYZdef", "abcQQdef").unwrap();
        assert_eq!(e.region.from, 3);
        assert_eq!(e.region.removed, 3); // XYZ
        assert_eq!(e.region.len_after, 2); // QQ
        assert_eq!(apply_reload("abcXYZdef", &e), "abcQQdef");
    }

    #[test]
    fn reload_from_empty_and_to_empty() {
        let e = changed_region_between("", "hello").unwrap();
        assert_eq!(e.region.from, 0);
        assert_eq!(e.region.removed, 0);
        assert_eq!(apply_reload("", &e), "hello");
        let e2 = changed_region_between("hello", "").unwrap();
        assert_eq!(e2.region.from, 0);
        assert_eq!(e2.region.removed, 5);
        assert_eq!(apply_reload("hello", &e2), "");
    }

    #[test]
    fn reload_prefix_suffix_dont_overlap_on_repeats() {
        // "aaaa" -> "aa": prefix+suffix must not double-count shared 'a's.
        let e = changed_region_between("aaaa", "aa").unwrap();
        assert_eq!(apply_reload("aaaa", &e), "aa");
        assert_eq!(e.region.removed, 2);
        assert_eq!(e.region.len_after, 0);
    }

    #[test]
    fn reload_astral_utf16_units() {
        // 😀 is a surrogate pair (2 UTF-16 units); offsets stay in code units.
        let e = changed_region_between("a😀b", "a😀😀b").unwrap();
        assert_eq!(apply_reload("a😀b", &e), "a😀😀b");
    }

    proptest! {
        /// ROUND-TRIP: applying the emitted region back onto `old` must
        /// reconstruct `new`, for arbitrary strings — the S7 correctness
        /// contract (one dispatch = the whole reload). `None` ⇔ old == new.
        #[test]
        fn reload_roundtrip_any(old in ".{0,80}", new in ".{0,80}") {
            match changed_region_between(&old, &new) {
                None => prop_assert_eq!(old, new),
                Some(e) => prop_assert_eq!(apply_reload(&old, &e), new),
            }
        }
    }

    proptest! {
        /// The optimized batch `apply` (prefix-sum offset tracking in
        /// `splice_units`) must equal a NAIVE descending-splice reference for any
        /// sequence of valid, non-overlapping, in-bounds edits — the golden
        /// differential contract, but over random multi-edit combinatorics the
        /// example tests can't cover. ASCII base keeps every offset a char
        /// boundary (astral/surrogate edges are pinned by the example tests);
        /// this stresses the cumulative-offset bookkeeping across many edits.
        #[test]
        fn apply_matches_naive_reference(
            base in "[a-z]{0,40}",
            ops in proptest::collection::vec((0usize..6, 0usize..4, "[A-Z]{0,3}"), 0..8),
        ) {
            let len = base.encode_utf16().count();
            // Build non-overlapping edits (all in original/pre-edit coords) by
            // walking a cursor forward; cursor = to guarantees no overlap.
            let mut edits = Vec::new();
            let mut cursor = 0usize;
            for (gap, del, ins) in &ops {
                cursor += *gap;
                if cursor > len { break; }
                let to = (cursor + *del).min(len);
                edits.push(CmEdit::new(
                    i64::try_from(cursor).unwrap(),
                    i64::try_from(to).unwrap(),
                    ins.clone(),
                ));
                cursor = to;
            }
            let got = apply(&base, &edits);
            // Naive reference: splice DESCENDING so earlier offsets stay valid.
            let mut units: Vec<u16> = base.encode_utf16().collect();
            for e in edits.iter().rev() {
                let from = usize::try_from(e.from).unwrap();
                let to = usize::try_from(e.to).unwrap();
                let ins: Vec<u16> = e.insert.encode_utf16().collect();
                units.splice(from..to, ins);
            }
            let naive = String::from_utf16(&units).ok();
            prop_assert_eq!(got, naive);
        }
    }

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

    // --- wire seam (what the FFI shim drives) ---

    fn req_frame(base: &str, edits: &[(i64, i64, &str)]) -> Vec<u8> {
        let r = ApplyRequest {
            base: base.into(),
            edits: edits.iter().map(|&(f, t, i)| EditWire { from: f, to: t, insert: i.to_string() }).collect(),
        };
        crate::wire::encode_frame(&r).unwrap()
    }
    fn resp_text(frame: &[u8]) -> Option<String> {
        let r: ApplyResponse = crate::wire::decode_frame(frame).unwrap();
        r.text
    }

    #[test]
    fn wire_round_trip_applies() {
        let out = apply_wire(&req_frame("hello", &[(2, 2, "X")])).unwrap();
        assert_eq!(resp_text(&out).as_deref(), Some("heXllo"));
    }

    #[test]
    fn wire_round_trip_astral() {
        let out = apply_wire(&req_frame("🧠x", &[(2, 2, "!")])).unwrap();
        assert_eq!(resp_text(&out).as_deref(), Some("🧠!x"));
    }

    #[test]
    fn wire_rejected_batch_is_ok_with_null_text() {
        // Overlap → apply returns None → response carries text:null (NOT a wire error).
        let out = apply_wire(&req_frame("abcdef", &[(1, 3, "x"), (2, 4, "y")])).unwrap();
        assert_eq!(resp_text(&out), None);
    }

    #[test]
    fn wire_malformed_frame_errors() {
        assert!(apply_wire(&[0x00, 0x01]).is_err());        // too short for prefix
        assert!(apply_wire(&[]).is_err());
    }

    // --- stateful CmDoc mirror (TSK-543) ---

    #[test]
    fn cmdoc_new_and_text_round_trip() {
        let d = CmDoc::new("hello 🧠 world");
        assert_eq!(d.text().as_deref(), Some("hello 🧠 world"));
        // "🧠" is 2 UTF-16 units, so len is 13 chars - 1 + 2 = "hello " (6) +
        // 2 + " world" (6) = 14.
        assert_eq!(d.len_utf16(), "hello 🧠 world".encode_utf16().count());
    }

    #[test]
    fn cmdoc_apply_delta_mutates_in_place() {
        let mut d = CmDoc::new("hello");
        let region = d.apply_delta(&[CmEdit::new(2, 2, "X")]).unwrap();
        assert_eq!(d.text().as_deref(), Some("heXllo"));
        // A pure 1-unit insert at offset 2: changed span is [2,3) in the new
        // doc, replacing 0 units.
        assert_eq!(region, ChangedRegion { from: 2, len_after: 1, removed: 0 });
    }

    #[test]
    fn cmdoc_empty_batch_is_noop_empty_region() {
        let mut d = CmDoc::new("abc");
        let region = d.apply_delta(&[]).unwrap();
        assert_eq!(region, ChangedRegion { from: 0, len_after: 0, removed: 0 });
        assert_eq!(d.text().as_deref(), Some("abc"));
    }

    #[test]
    fn cmdoc_rejected_batch_leaves_mirror_untouched() {
        // Overlapping edits are rejected; the mirror must NOT be half-mutated —
        // apply-or-reject is atomic, the caller's resync cue is a clean state.
        let mut d = CmDoc::new("abcdef");
        assert_eq!(d.apply_delta(&[CmEdit::new(1, 3, "x"), CmEdit::new(2, 4, "y")]), None);
        assert_eq!(d.text().as_deref(), Some("abcdef"), "rejected batch must not mutate");
        assert_eq!(d.len_utf16(), 6);
        // Out-of-bounds is also rejected, also a no-op.
        assert_eq!(d.apply_delta(&[CmEdit::new(0, 99, "")]), None);
        assert_eq!(d.text().as_deref(), Some("abcdef"));
    }

    #[test]
    fn cmdoc_changed_region_is_minimal_span() {
        // Edit in the middle of an otherwise-unchanged doc: the changed region
        // strips the common prefix AND suffix.
        let mut d = CmDoc::new("the quick brown fox");
        // Replace "quick" [4,9) with "slow" → "the slow brown fox".
        let region = d.apply_delta(&[CmEdit::new(4, 9, "slow")]).unwrap();
        assert_eq!(d.text().as_deref(), Some("the slow brown fox"));
        // Common prefix "the " (4). Replaced 5 units with 4. Common suffix is
        // " brown fox" — but the derivation is from buffer diff, so:
        assert_eq!(region.from, 4);
        assert_eq!(region.len_after, 4);  // "slow"
        assert_eq!(region.removed, 5);    // "quick"
    }

    #[test]
    fn cmdoc_changed_region_pure_delete() {
        let mut d = CmDoc::new("abcXYZdef");
        // Delete "XYZ" [3,6).
        let region = d.apply_delta(&[CmEdit::new(3, 6, "")]).unwrap();
        assert_eq!(d.text().as_deref(), Some("abcdef"));
        assert_eq!(region, ChangedRegion { from: 3, len_after: 0, removed: 3 });
    }

    /// THE golden contract (TSK-543): applying a SEQUENCE of deltas to the
    /// stateful mirror must equal a single from-scratch full-doc [`apply`] of
    /// the cumulative text — keystroke-at-a-time equals one big batch. This is
    /// what proves the stateful path can replace the full-doc-per-edit path
    /// without diverging.
    /// UTF-16 offset of the first occurrence of `needle` in `hay` — test helper
    /// so the golden sequence reads in terms of "where the cursor is".
    fn u16_off(hay: &str, needle: &str) -> i64 {
        let byte = hay.find(needle).expect("needle present");
        let prefix = hay.get(..byte).expect("byte is on a char boundary");
        i64::try_from(prefix.encode_utf16().count()).expect("offset fits i64")
    }

    #[test]
    fn cmdoc_sequence_equals_from_scratch_apply() {
        // A realistic typing/edit sequence over an astral-plane-containing doc.
        // Each batch is computed against the doc AS IT STANDS at that step
        // (mirroring how CM emits pre-edit offsets), then replayed identically
        // onto BOTH the stateful mirror and a from-scratch string.
        let initial = "fn main() {\n    let x = 🧠;\n}\n";

        // Build the steps by walking a reference string forward — so the
        // offsets are exactly the ones a real editor would emit.
        let mut ref_text = initial.to_string();
        let mut steps: Vec<Vec<CmEdit>> = Vec::new();

        // Step 1: type "42 + " right before the emoji.
        let off = u16_off(&ref_text, "🧠");
        let s1 = vec![CmEdit::new(off, off, "42 + ")];
        ref_text = apply(&ref_text, &s1).unwrap();
        steps.push(s1);

        // Step 2: append a trailing comment line at end of doc.
        let end = i64::try_from(ref_text.encode_utf16().count()).unwrap();
        let s2 = vec![CmEdit::new(end, end, "// done\n")];
        ref_text = apply(&ref_text, &s2).unwrap();
        steps.push(s2);

        // Step 3: delete the emoji (its two-unit surrogate pair) → replace "z".
        let emoji_off = u16_off(&ref_text, "🧠");
        let s3 = vec![CmEdit::new(emoji_off, emoji_off + 2, "z")];
        ref_text = apply(&ref_text, &s3).unwrap();
        steps.push(s3);

        // Stateful path: seed once, then apply each delta to the SAME mirror.
        let mut doc = CmDoc::new(initial);
        for batch in &steps {
            doc.apply_delta(batch).expect("each delta applies cleanly");
        }
        let stateful = doc.text().expect("clean mirror decodes");

        // From-scratch reference: replay the exact same edits onto a string,
        // one batch at a time, via the stateless full-doc `apply`.
        let mut scratch = initial.to_string();
        for batch in &steps {
            scratch = apply(&scratch, batch).expect("each batch applies cleanly");
        }

        assert_eq!(stateful, scratch, "stateful mirror diverged from from-scratch apply");
        assert_eq!(stateful, ref_text, "both paths must match the forward reference");
        assert_eq!(doc.len_utf16(), scratch.encode_utf16().count());
    }

    /// Randomised differential fuzz: a long stream of in-bounds single edits on
    /// the stateful mirror must always match the from-scratch apply. A
    /// deterministic LCG keeps it reproducible (no dev-dependency on `rand`).
    #[test]
    fn cmdoc_fuzz_matches_from_scratch() {
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            // High bits of an LCG are the well-distributed ones; mask to 32 so
            // the value provably fits a usize on every target (no truncation).
            usize::try_from((state >> 33) & 0xFFFF_FFFF).unwrap()
        };
        let inserts = ["x", "ab", "🧠", "\n", "", "λ", "  "];

        let mut doc = CmDoc::new("seed text");
        let mut scratch = String::from("seed text");
        for _ in 0..500 {
            let units: Vec<u16> = scratch.encode_utf16().collect();
            let len = units.len();
            // A UTF-16 offset is a valid char boundary unless the unit BEFORE it
            // is a high surrogate (0xD800..=0xDBFF) — that would split a pair,
            // which is a separately-tested reject path we avoid here.
            let is_boundary = |i: usize| -> bool {
                match i.checked_sub(1).and_then(|p| units.get(p)) {
                    Some(&u) => !(0xD800..=0xDBFF).contains(&u),
                    None => true, // i == 0 or past the end
                }
            };
            let mut from = next() % (len + 1);
            while !is_boundary(from) {
                from += 1;
            }
            let mut to = from + next() % (len - from + 1);
            while !is_boundary(to) {
                to += 1;
            }
            let to = to.min(len);
            let ins = inserts.get(next() % inserts.len()).copied().unwrap_or("");
            let batch = [CmEdit::new(
                i64::try_from(from).unwrap(),
                i64::try_from(to).unwrap(),
                ins,
            )];

            let region = doc.apply_delta(&batch);
            let reference = apply(&scratch, &batch);
            // Both paths must AGREE on accept-vs-reject. Compare the accept-ness
            // directly (Option booleans) so a divergence fails on `assert_eq!`
            // rather than a `panic!` arm (no-panic lint wall, even in tests).
            assert_eq!(
                region.is_some(),
                reference.is_some(),
                "apply_delta/apply disagreed on accept at from={from} to={to} ins={ins:?}"
            );
            if let Some(r) = reference {
                scratch = r;
                assert_eq!(
                    doc.text().as_deref(),
                    Some(scratch.as_str()),
                    "mirror diverged at from={from} to={to} ins={ins:?}"
                );
            }
        }
    }

    // --- stateful delta wire seam (TSK-543) ---

    fn delta_resp(frame: &[u8]) -> DeltaResponse {
        crate::wire::decode_frame(frame).unwrap()
    }

    #[test]
    fn delta_wire_returns_changed_region_not_whole_buffer() {
        // Insert "X" at offset 2 of "hello": the response carries the changed
        // REGION (from=2, len_after=1, removed=0) + new length, NOT "heXllo".
        let out = apply_delta_wire(&req_frame("hello", &[(2, 2, "X")])).unwrap();
        let r = delta_resp(&out);
        let c = r.changed.expect("clean apply yields a region");
        assert_eq!((c.from, c.len_after, c.removed), (2, 1, 0));
        assert_eq!(r.len_utf16, 6);
    }

    #[test]
    fn delta_wire_rejected_batch_is_null_changed() {
        let out = apply_delta_wire(&req_frame("abcdef", &[(1, 3, "x"), (2, 4, "y")])).unwrap();
        let r = delta_resp(&out);
        assert!(r.changed.is_none(), "rejected batch carries changed:null");
        assert_eq!(r.len_utf16, 0);
    }

    #[test]
    fn delta_wire_astral_changed_region() {
        // Replace the emoji [0,2) of "🧠x" with "y" → changed region from=0,
        // len_after=1, removed=2; new length 2.
        let out = apply_delta_wire(&req_frame("🧠x", &[(0, 2, "y")])).unwrap();
        let r = delta_resp(&out);
        let c = r.changed.unwrap();
        assert_eq!((c.from, c.len_after, c.removed), (0, 1, 2));
        assert_eq!(r.len_utf16, 2);
    }

    #[test]
    fn delta_wire_malformed_frame_errors() {
        assert!(apply_delta_wire(&[0x00, 0x01]).is_err());
        assert!(apply_delta_wire(&[]).is_err());
    }
}
