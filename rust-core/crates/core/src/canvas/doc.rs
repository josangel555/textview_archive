//! Canvas M1.S5c — the REAL canvas document façade (TSK-1360): what the FFI
//! handle wraps once the M0 demo module retires. One value = the op-engine
//! state + the token store + the root page; the three entry points the
//! boundary needs (open / lower / apply-frame).

use super::ops::DocState;
use super::store::{Id, RecordKind};
use super::tokens::TokenStore;
use super::{lower, wire};
use crate::wire::WireFault;

/// The engine-side document: revisioned op state + theme + root page.
#[derive(Debug)]
pub struct CanvasDoc {
    pub state: DocState,
    pub tokens: TokenStore,
    pub root: Id,
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
        wire::apply_wire(&mut self.state, &self.tokens, req)
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
