//! Thin-waist method dispatch (TSK-580): ONE safe-Rust entry that routes a
//! stable `u16` method id + request frame to the right stateless core function
//! and returns the response frame. The dispatch logic lives ONCE here, in safe
//! Rust, reusable by every front-end (the FFI `mdvcore_call` envelope, the TUI,
//! the web server, a future WASM shim) instead of being copy-pasted per
//! `extern "C"` symbol (the TSK-568 duplication finding).
//!
//! ## Method ids are ABI
//!
//! Like the FFI capability bits, a method id is assigned ONCE and NEVER
//! renumbered or reused — a remote/skewed client gates features on these. Add
//! NEW ids at the end; never edit an existing one. (Codegen of these into the
//! cbindgen header + a Swift constants file is a follow-up slice; this enum is
//! the single source of truth meanwhile.)
//!
//! ## Aux side-channel
//!
//! `call` takes an `aux` byte slice for the bulk-payload side channel (e.g. a
//! multi-MiB buffer to search / zero-copy borrowed inputs) so the 16 MiB frame
//! cap doesn't bite. The `req`-only stateless methods ignore `aux`;
//! [`Method::HexSearch`] is the first to consume it (the search buffer rides
//! `aux`, the `{query, mode}` params ride `req`).
//!
//! ## Raw-output methods
//!
//! Most methods return a MessagePack response *frame*. Two return **raw bytes**
//! instead — [`Method::IndentDetect`] (a tiny result string) and
//! [`Method::HexRender`] (a ~18 MB dump that would blow the 16 MiB frame cap and
//! whose double-encoding would be pure waste). For these, [`call`] returns the
//! raw bytes directly (no `encode_frame`); the FFI/front-end knows by method id
//! not to unframe, and the `MdvStatus` Ok-vs-fault code disambiguates a raw
//! payload from an error frame. Their bulk INPUT (the text / the bytes to dump)
//! rides `aux`; the small layout scalars ride `req`.

use crate::wire::WireFault;

/// Stable `u16` method ids. ABI — assign once, never renumber, never reuse.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// CodeMirror edit-batch apply (`cm_edit::apply_wire`).
    CmApply = 1,
    /// Unified-diff parse (`diff::parse_wire`).
    DiffParse = 2,
    /// Diff gutter marks (`diff::hunk_marks_wire`).
    DiffHunkMarks = 3,
    /// Fuzzy rank (`fuzzy::rank_wire`).
    FuzzyRank = 4,
    /// Find/search (`find_engine::search_wire`).
    FindSearch = 5,
    /// Markdown → HTML render (`markdown::render_wire`).
    MarkdownRender = 6,
    /// Transcript parse (`transcript::parse_wire`).
    TranscriptParse = 7,
    /// Transcript parse with forced redaction (`transcript::parse_wire_forced_redaction`).
    TranscriptParseForcedRedaction = 8,
    /// Tree-sitter highlight runs. Lives in the `mdvcore-highlight` crate (core
    /// does not depend on it), so the id is registered here for a UNIFIED id
    /// space but [`call`] does NOT route it — the FFI/front-end layer (which
    /// links highlight) intercepts this id before calling `call`.
    HighlightRuns = 9,
    /// Hex search over a bulk buffer (`hex::search_wire_aux`). The buffer to
    /// search rides the `aux` side-channel (frame-cap-exempt); `req` carries
    /// only `{query, mode}`. The FIRST method to consume `aux`.
    HexSearch = 10,
    /// Indent detection (`indent::detect_wire_aux`). RAW-OUTPUT: the source text
    /// rides `aux`, `{sample_lines}` rides `req`, and the result is the tiny
    /// result string as raw bytes (not a frame).
    IndentDetect = 11,
    /// Hex dump render (`hex::render_wire_aux`). RAW-OUTPUT: the bytes to dump
    /// ride `aux`, `{width, total_byte_count, is_truncated}` ride `req`, and the
    /// ~18 MB dump returns as raw bytes (frame-cap-exempt) — the bulk-output
    /// case the `aux` channel exists for.
    HexRender = 12,
    /// Formula evaluation (`formula::evaluate_wire`) — batch-evaluate formulas
    /// against a cell-grid snapshot (stateless; the grid rides `req`).
    FormulaEvaluate = 13,
    /// Formula whole-grid recalc (`formula::recalc_wire`) — evaluate every formula
    /// cell in dependency order, resolving refs to computed values (cycles → #CYCLE).
    FormulaRecalc = 14,
    /// Code-fold regions. Like [`Method::HighlightRuns`], the impl lives in the
    /// `mdvcore-highlight` crate, so this id is registered for the unified id
    /// space but [`call`] does NOT route it — the FFI layer intercepts it.
    FoldRegions = 15,
    /// CodeMirror edit-batch apply returning only the CHANGED REGION
    /// (`cm_edit::apply_delta_wire`) — the TSK-543 traffic-reduction seam. Core-
    /// routable here (the impl lives in core), unlike Highlight/Fold.
    CmApplyDelta = 16,
    /// Rendered-MD block DOM-patch (`html_patch::block_patch_wire`) — diff two
    /// renders into a `[Keep/Delete/Insert]` block patch for the persistent-WebView
    /// applier instead of a full `loadHTMLString` reload (TSK-838). Core-routable.
    HtmlBlockPatch = 17,
}

impl Method {
    /// The next id a new method gets — pinned by a test so adding a method here
    /// without bumping it (or renumbering an existing one) fails loudly.
    pub const NEXT_FREE_ID: u16 = 18;

    /// Map a raw `u16` to a [`Method`], or `None` for an id this build doesn't
    /// know (a forward-compat caller sent a newer method) — the FFI envelope
    /// turns `None` into a status, never UB.
    #[must_use]
    pub fn from_u16(raw: u16) -> Option<Method> {
        match raw {
            1 => Some(Method::CmApply),
            2 => Some(Method::DiffParse),
            3 => Some(Method::DiffHunkMarks),
            4 => Some(Method::FuzzyRank),
            5 => Some(Method::FindSearch),
            6 => Some(Method::MarkdownRender),
            7 => Some(Method::TranscriptParse),
            8 => Some(Method::TranscriptParseForcedRedaction),
            9 => Some(Method::HighlightRuns),
            10 => Some(Method::HexSearch),
            11 => Some(Method::IndentDetect),
            12 => Some(Method::HexRender),
            13 => Some(Method::FormulaEvaluate),
            14 => Some(Method::FormulaRecalc),
            15 => Some(Method::FoldRegions),
            16 => Some(Method::CmApplyDelta),
            17 => Some(Method::HtmlBlockPatch),
            _ => None,
        }
    }
}

/// Dispatch a request to its stateless method, returning the response bytes —
/// byte-identical to calling the underlying `*_wire` fn directly (the per-method
/// extern symbols delegate to the same fns, so the envelope and the old symbols
/// agree exactly during the coexistence window).
///
/// For frame-shaped methods the bytes are a MessagePack response frame; for the
/// raw-output methods ([`Method::IndentDetect`], [`Method::HexRender`]) they are
/// raw bytes (see the module docs) — the caller knows which by method id.
///
/// `aux` is the bulk side channel: the `req`-only methods ignore it;
/// [`Method::HexSearch`] consumes it as the buffer to search, and the
/// raw-output methods consume it as their bulk input (text / bytes to dump).
///
/// # Errors
/// Whatever the routed method returns ([`WireFault`] on a wire/encode fault).
pub fn call(method: Method, req: &[u8], aux: &[u8]) -> Result<Vec<u8>, WireFault> {
    match method {
        Method::CmApply => crate::cm_edit::apply_wire(req),
        Method::CmApplyDelta => crate::cm_edit::apply_delta_wire(req),
        Method::DiffParse => crate::diff::parse_wire(req),
        Method::DiffHunkMarks => crate::diff::hunk_marks_wire(req),
        Method::FuzzyRank => crate::fuzzy::rank_wire(req),
        Method::FindSearch => crate::find_engine::search_wire(req),
        Method::MarkdownRender => crate::markdown::render_wire(req),
        Method::TranscriptParse => crate::transcript::parse_wire(req),
        Method::TranscriptParseForcedRedaction => {
            crate::transcript::parse_wire_forced_redaction(req)
        }
        // Not routable from core (the impl lives in the `mdvcore-highlight`
        // crate). The FFI/front-end intercepts this id before calling `call`;
        // this arm is the defensive guard if someone routes it through core
        // directly — a clear error, never a panic.
        Method::HighlightRuns => Err(WireFault::Decode(
            "highlight_runs is dispatched at the front-end layer, not core".to_string(),
        )),
        Method::HexSearch => crate::hex::search_wire_aux(req, aux),
        // Raw-output methods: bulk input on `aux`, scalars on `req`, raw bytes out.
        Method::IndentDetect => crate::indent::detect_wire_aux(req, aux),
        Method::HexRender => crate::hex::render_wire_aux(req, aux),
        Method::FormulaEvaluate => crate::formula::evaluate_wire(req),
        Method::FormulaRecalc => crate::formula::recalc_wire(req),
        Method::HtmlBlockPatch => crate::html_patch::block_patch_wire(req),
        // Not routable from core (impl in mdvcore-highlight); the FFI layer
        // intercepts this id, same as HighlightRuns.
        Method::FoldRegions => Err(WireFault::Decode(
            "fold_regions is dispatched at the front-end layer, not core".to_string(),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_u16_round_trips_known_ids_and_rejects_unknown() {
        for raw in 1u16..Method::NEXT_FREE_ID {
            let m = Method::from_u16(raw).expect("known id maps");
            assert_eq!(m as u16, raw, "the id maps back to itself");
        }
        assert!(Method::from_u16(0).is_none(), "0 is reserved (no method)");
        assert!(Method::from_u16(Method::NEXT_FREE_ID).is_none(), "next-free id is not yet a method");
        assert!(Method::from_u16(u16::MAX).is_none());
    }

    #[test]
    fn next_free_id_is_one_past_the_last_method() {
        // Pins the ABI: adding a Method without bumping NEXT_FREE_ID (or
        // renumbering one) breaks this. HtmlBlockPatch is the current last id.
        assert_eq!(Method::HtmlBlockPatch as u16 + 1, Method::NEXT_FREE_ID);
    }

    #[test]
    fn dispatch_is_byte_identical_to_the_direct_call() {
        // A real diff request frame → both paths must produce the same frame.
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n";
        let req = crate::wire::encode_frame(&DiffReq { text }).unwrap();
        let via_dispatch = call(Method::DiffParse, &req, &[]).unwrap();
        let direct = crate::diff::parse_wire(&req).unwrap();
        assert_eq!(via_dispatch, direct, "the envelope routes to the same logic");
    }

    #[test]
    fn dispatch_routes_hex_search_over_the_aux_channel() {
        // The buffer to search rides `aux`; `req` carries only {query, mode}.
        // The envelope result must be byte-identical to hex_search_frame called
        // directly. TEETH: if search_wire_aux searched `req` instead of `aux`
        // (or aux were dropped), there would be no matches and this diverges.
        let data = [0xDEu8, 0xAD, 0x00, 0xDE, 0xAD]; // 0xDEAD at offsets 0 and 3
        let req = crate::wire::encode_frame(&crate::hex::SearchAuxRequest {
            query: "dead",
            mode: 0, // hex-byte-pair
        })
        .unwrap();
        let via = call(Method::HexSearch, &req, &data).unwrap();
        let direct =
            crate::hex::hex_search_frame(&data, "dead", crate::hex::HexSearchMode::Hex).unwrap();
        // `data` was passed as the `aux` arg (3rd positional), NOT wrapped in
        // `req` — so this byte-identical match proves the aux channel carried
        // the search buffer through dispatch to hex_search_frame.
        assert_eq!(via, direct, "hex search routes aux→data, req→{{query,mode}}");
    }

    #[test]
    fn dispatch_routes_indent_detect_raw_output_over_aux() {
        // RAW-OUTPUT method: text rides `aux`, {sample_lines} rides `req`, and
        // the result is the raw string bytes (NOT a frame). Byte-identical to
        // indent::detect. TEETH: if the text were read from `req` instead of
        // `aux` (or aux dropped), detect would see empty text → "—" ≠ "Spaces (4)".
        let text = "    a\n    b\n";
        let req = crate::wire::encode_frame(&crate::indent::DetectAuxRequest {
            sample_lines: 50,
        })
        .unwrap();
        let via = call(Method::IndentDetect, &req, text.as_bytes()).unwrap();
        assert_eq!(via, crate::indent::detect(text, 50).into_bytes());
        assert_eq!(String::from_utf8(via).unwrap(), "Spaces (4)");
    }

    #[test]
    fn dispatch_routes_hex_render_raw_output_over_aux() {
        // RAW-OUTPUT method: bytes ride `aux`, layout scalars ride `req`, raw
        // dump bytes out (frame-cap-exempt). Byte-identical to render_all.
        // TEETH: dropping aux → render_all over &[] → empty dump ≠ the real dump.
        let data = [0x41u8, 0x42, 0x43];
        let req = crate::wire::encode_frame(&crate::hex::RenderAuxRequest {
            width: 4,
            total_byte_count: data.len() as u64,
            is_truncated: false,
        })
        .unwrap();
        let via = call(Method::HexRender, &req, &data).unwrap();
        let direct = crate::hex::render_all(&data, 4, data.len(), false).into_bytes();
        assert_eq!(via, direct, "hex render routes aux→bytes, req→{{width,…}}, raw out");
        assert!(!via.is_empty(), "a non-empty buffer renders a non-empty dump");
    }

    #[test]
    fn core_call_refuses_highlight_runs() {
        // HighlightRuns is registered for the unified id space but lives in a
        // separate crate; core::call must NOT route it (the FFI intercepts it
        // first) — a clear Err, never a panic.
        assert!(matches!(
            call(Method::HighlightRuns, &[], &[]),
            Err(crate::wire::WireFault::Decode(_))
        ));
    }

    #[derive(serde::Serialize)]
    struct DiffReq<'a> {
        text: &'a str,
    }

    // --- Property test (TSK-585 lane): dispatch robustness (FFI boundary) -----
    use proptest::prelude::*;

    proptest! {
        /// call never panics on ANY method + arbitrary req/aux frame bytes — the
        /// FFI dispatch boundary decodes untrusted frames, so a malformed frame
        /// must return Err(WireFault), never crash. No fuzz target for the router.
        #[test]
        fn call_never_panics_on_arbitrary_frames(
            method in proptest::sample::select(vec![
                Method::CmApply, Method::DiffParse, Method::DiffHunkMarks, Method::FuzzyRank,
                Method::FindSearch, Method::MarkdownRender, Method::TranscriptParse,
                Method::TranscriptParseForcedRedaction, Method::HighlightRuns, Method::HexSearch,
                Method::IndentDetect, Method::HexRender, Method::FormulaEvaluate,
                Method::FormulaRecalc, Method::FoldRegions, Method::CmApplyDelta,
                Method::HtmlBlockPatch,
            ]),
            req in proptest::collection::vec(any::<u8>(), 0..64),
            aux in proptest::collection::vec(any::<u8>(), 0..32),
        ) {
            let _ = call(method, &req, &aux);
        }
    }
}
