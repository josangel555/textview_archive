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
//! `call` takes an `aux` byte slice reserved for the bulk-payload side channel
//! (e.g. hex render's ~18 MB output / zero-copy borrowed inputs) so the 16 MiB
//! frame cap doesn't bite. The stateless methods routed in this first slice
//! carry everything in `req` and ignore `aux`; a bulk method will consume it.

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
}

impl Method {
    /// The next id a new method gets — pinned by a test so adding a method here
    /// without bumping it (or renumbering an existing one) fails loudly.
    pub const NEXT_FREE_ID: u16 = 9;

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
            _ => None,
        }
    }
}

/// Dispatch a request to its stateless method, returning the response frame —
/// byte-identical to calling the underlying `*_wire` fn directly (the per-method
/// extern symbols delegate to the same fns, so the envelope and the old symbols
/// agree exactly during the coexistence window).
///
/// `aux` is reserved for the bulk side channel and is unused by these methods.
///
/// # Errors
/// Whatever the routed method returns ([`WireFault`] on a wire/encode fault).
pub fn call(method: Method, req: &[u8], aux: &[u8]) -> Result<Vec<u8>, WireFault> {
    let _ = aux; // reserved; consumed by bulk methods in a later slice
    match method {
        Method::CmApply => crate::cm_edit::apply_wire(req),
        Method::DiffParse => crate::diff::parse_wire(req),
        Method::DiffHunkMarks => crate::diff::hunk_marks_wire(req),
        Method::FuzzyRank => crate::fuzzy::rank_wire(req),
        Method::FindSearch => crate::find_engine::search_wire(req),
        Method::MarkdownRender => crate::markdown::render_wire(req),
        Method::TranscriptParse => crate::transcript::parse_wire(req),
        Method::TranscriptParseForcedRedaction => {
            crate::transcript::parse_wire_forced_redaction(req)
        }
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
        // renumbering one) breaks this. TranscriptParseForcedRedaction is the
        // current last id.
        assert_eq!(Method::TranscriptParseForcedRedaction as u16 + 1, Method::NEXT_FREE_ID);
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

    #[derive(serde::Serialize)]
    struct DiffReq<'a> {
        text: &'a str,
    }
}
