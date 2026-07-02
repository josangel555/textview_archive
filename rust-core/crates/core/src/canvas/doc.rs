//! Canvas M1.S5c — the REAL canvas document façade (TSK-1360): what the FFI
//! handle wraps once the M0 demo module retires. One value = the op-engine
//! state + the token store + the root page; the three entry points the
//! boundary needs (open / lower / apply-frame).

use super::ops::{DocState, UndoOp};
use super::store::{Id, RecordKind};
use super::tokens::TokenStore;
use super::{dsl, io, lower, wire};
use crate::wire::WireFault;

/// Undo history depth (bounded — the undo unit is an apply batch).
const UNDO_DEPTH: usize = 64;

/// The engine-side document: revisioned op state + theme + root page.
#[derive(Debug)]
pub struct CanvasDoc {
    pub state: DocState,
    pub tokens: TokenStore,
    pub root: Id,
    /// Inverse batches, most recent last (bounded to [`UNDO_DEPTH`]).
    undo_stack: Vec<Vec<UndoOp>>,
}

impl CanvasDoc {
    /// An empty document: the default theme + one root page `pg:1`.
    #[must_use]
    pub fn new_empty() -> Self {
        let mut state = DocState::new();
        let root = Id::page(1);
        let _ = state.store.insert_root(root.clone(), RecordKind::Page);
        CanvasDoc {
            state,
            tokens: TokenStore::default_theme(),
            root,
            undo_stack: Vec::new(),
        }
    }

    /// Wrap restored parts (persistence load path).
    #[must_use]
    pub fn from_parts(state: DocState, tokens: TokenStore, root: Id) -> Self {
        CanvasDoc {
            state,
            tokens,
            root,
            undo_stack: Vec::new(),
        }
    }

    /// Lower the whole document (theme block + root page subtree).
    #[must_use]
    pub fn html(&self) -> String {
        lower::lower_page(&self.state.store, &self.tokens, &self.root)
    }

    /// Apply a `{baseRev, ops}` request frame → `{rev, patches}` /
    /// structured-rejection frame (see `canvas::wire`).
    ///
    /// # Errors
    /// [`WireFault`] on malformed frames only; refused batches return Ok
    /// frames carrying the rejection.
    pub fn apply_frame(&mut self, req: &[u8]) -> Result<Vec<u8>, WireFault> {
        let rev_before = self.state.rev();
        let resp = wire::apply_wire(&mut self.state, &self.tokens, req)?;
        self.capture_undo(rev_before);
        Ok(resp)
    }

    /// Apply a DSL fragment under the root page against `base_rev` — same
    /// response/rejection frames as `apply_frame`; parse failures come back
    /// as `{rejected: "dsl", detail: "line N: …"}`.
    ///
    /// # Errors
    /// [`WireFault`] only if response ENCODING fails.
    pub fn apply_dsl(&mut self, base_rev: u64, source: &str) -> Result<Vec<u8>, WireFault> {
        match dsl::parse_fragment(source, &self.root) {
            Ok(ops) => {
                let rev_before = self.state.rev();
                let resp = wire::respond(&mut self.state, &self.tokens, base_rev, &ops)?;
                self.capture_undo(rev_before);
                Ok(resp)
            }
            Err(e) => wire::dsl_rejection(&self.state, &e),
        }
    }

    /// Undo the most recent applied batch. Returns the new revision, or
    /// `None` when the stack is empty. The shell re-renders from `html()`
    /// (full re-lower — undo is rare; patch-level undo can come later).
    pub fn undo(&mut self) -> Option<u64> {
        let inverses = self.undo_stack.pop()?;
        self.state.undo(inverses);
        Some(self.state.rev())
    }

    /// Canonical JSON (persistence).
    #[must_use]
    pub fn save(&self) -> String {
        io::save(self)
    }

    /// Project the whole document into canonical DSL: component definitions
    /// first (so `use` lines re-parse against defined components), then the
    /// root page's content.
    #[must_use]
    pub fn render_dsl(&self) -> String {
        let mut out = dsl::render_definitions(&self.state.store);
        out.push_str(&dsl::render(&self.state.store, &self.root));
        out
    }

    /// Project ONE anchored node's subtree (`canvas_read {anchor}`), or None
    /// for an unknown id.
    #[must_use]
    pub fn render_dsl_node(&self, id: &Id) -> Option<String> {
        self.state.store.get(id)?;
        Some(dsl::render_subtree(&self.state.store, id))
    }

    /// Full-document lint as a `{lint: […]}` frame.
    ///
    /// # Errors
    /// [`WireFault`] if encoding fails.
    pub fn lint_frame(&self) -> Result<Vec<u8>, WireFault> {
        wire::lint_frame(&self.state, &self.tokens)
    }

    /// Pull the just-applied batch's inverse off the engine and onto the
    /// bounded history (no-op when nothing mutated).
    fn capture_undo(&mut self, rev_before: u64) {
        if self.state.rev() == rev_before {
            return;
        }
        if let Some(inverses) = self.state.take_last_inverses() {
            if self.undo_stack.len() >= UNDO_DEPTH {
                self.undo_stack.remove(0);
            }
            self.undo_stack.push(inverses);
        }
    }
}

impl Default for CanvasDoc {
    fn default() -> Self {
        Self::new_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// UAT-M1 at the core level: build via DSL → edit → undo → save → load →
    /// re-render identical (06-MILESTONES-UAT §M1).
    #[test]
    fn uat_m1_journey_build_edit_undo_save_load() {
        let mut doc = CanvasDoc::new_empty();
        // Build.
        let resp = doc
            .apply_dsl(0, "frame #hero gap=8 {\n  text #title \"v1\"\n}\n")
            .expect("build");
        assert!(!resp.is_empty());
        assert_eq!(doc.state.rev(), 1);
        assert!(doc.html().contains(">v1<"));
        // Edit.
        doc.apply_dsl(1, "set #title \"v2\"").expect("edit");
        assert!(doc.html().contains(">v2<"));
        // Undo the edit.
        assert_eq!(doc.undo(), Some(3), "undo is itself a revision");
        assert!(doc.html().contains(">v1<"), "undo restored the text");
        // Save → load → identical lowering + DSL projection.
        let saved = doc.save();
        let loaded = super::super::io::load(&saved).expect("load");
        assert_eq!(loaded.html(), doc.html());
        assert_eq!(loaded.render_dsl(), doc.render_dsl());
        assert!(loaded.render_dsl().contains("frame #hero"));
        // DSL parse failure = structured rejection frame, state untouched.
        let rej = doc.apply_dsl(3, "wormhole #x").expect("rejection frame");
        assert!(!rej.is_empty());
        assert_eq!(doc.state.rev(), 3);
    }

    #[test]
    fn undo_stack_is_bounded_and_empty_pop_is_none() {
        let mut doc = CanvasDoc::new_empty();
        assert_eq!(doc.undo(), None);
        for i in 0..70 {
            let rev = doc.state.rev();
            doc.apply_dsl(rev, &format!("text #t{i} \"x\"")).expect("apply");
        }
        let mut undone = 0;
        while doc.undo().is_some() {
            undone += 1;
        }
        assert_eq!(undone, 64, "history bounded to UNDO_DEPTH");
    }

    #[test]
    fn empty_doc_has_root_page_theme_and_rev_zero() {
        let doc = CanvasDoc::new_empty();
        assert_eq!(doc.state.rev(), 0);
        assert_eq!(doc.state.store.len(), 1);
        let html = doc.html();
        assert!(html.contains("data-cv-id=\"pg:1\""));
        assert!(html.contains("--cv-color-accent: #0a84ff;"));
    }
}
