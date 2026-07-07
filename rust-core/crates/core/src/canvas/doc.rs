//! Canvas M1.S5c — the REAL canvas document façade (TSK-1360): what the FFI
//! handle wraps once the M0 demo module retires. One value = the op-engine
//! state + the token store + the root page; the three entry points the
//! boundary needs (open / lower / apply-frame).

use super::ops::{DocState, UndoOp};
use super::store::{Id, RecordKind};
use super::tokens::TokenStore;
use super::{deck, dsl, io, lower, wire};
use crate::wire::WireFault;

/// Undo history depth (bounded — the undo unit is an apply batch).
const UNDO_DEPTH: usize = 64;

/// The engine-side document: revisioned op state + theme + root page.
#[derive(Debug)]
pub struct CanvasDoc {
    /// The revisioned element store.
    pub state: DocState,
    /// The design-token store.
    pub tokens: TokenStore,
    /// The root page id.
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
        match dsl::parse_fragment_full(source, &self.root) {
            Ok((ops, token_statements)) => {
                // Token statements are DOCUMENT settings (M4.S4): applied
                // before the ops; failures reject the whole request BEFORE
                // any record mutation (token errors are teaching-shaped).
                let theme_changed = !token_statements.is_empty();
                for statement in &token_statements {
                    if let Err(e) = self.apply_token_statement(statement) {
                        return wire::dsl_rejection(
                            &self.state,
                            &dsl::DslError { line: 1, message: e },
                        );
                    }
                }
                let rev_before = self.state.rev();
                let resp = wire::respond_with_theme(
                    &mut self.state, &self.tokens, base_rev, &ops, theme_changed)?;
                self.capture_undo(rev_before);
                Ok(resp)
            }
            Err(e) => wire::dsl_rejection(&self.state, &e),
        }
    }

    /// Apply one token statement (rename = deprecate-and-alias). Not
    /// undoable via the record stack in v1 (tokens are global settings;
    /// renames keep old refs resolving by construction).
    fn apply_token_statement(&mut self, statement: &dsl::TokenStatement) -> Result<(), String> {
        use super::tokens::TokenError;
        let describe = |e: TokenError| -> String {
            match e {
                TokenError::BadPath(p) => format!("bad token path '{p}' (seg.seg, lowercase)"),
                TokenError::Unknown(p) => format!("unknown token '{p}'"),
                TokenError::Cycle(p) => format!("alias cycle at '{p}'"),
            }
        };
        match statement {
            dsl::TokenStatement::Set { path, css } => {
                self.tokens.set_literal(path, css).map_err(describe)
            }
            dsl::TokenStatement::Alias { path, target } => {
                self.tokens.set_alias(path, target).map_err(describe)?;
                // An alias that immediately cycles is a store fault — refuse
                // now with the teaching shape rather than at render.
                if let Err(e) = self.tokens.resolve(path) {
                    return Err(describe(e));
                }
                Ok(())
            }
            dsl::TokenStatement::Rename { old, new } => {
                self.tokens.deprecate_and_alias(old, new).map_err(describe)
            }
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

    /// The FRAGMENT export of one node's subtree (M5.S3): HTML with the
    /// theme block omitted and var(--cv-*) refs inlined as literals. None
    /// when the node does not exist.
    pub fn render_fragment(&self, id: &Id) -> Option<String> {
        self.state.store.get(id)?;
        Some(lower::render_fragment(&self.state.store, &self.tokens, id))
    }

    /// The deck timeline as canonical JSON (M6.S3) — per-slide step counts
    /// and visible-id snapshots (the declarative verification surface).
    #[must_use]
    pub fn timeline_json(&self) -> String {
        deck::timeline_json(&self.state.store)
    }

    /// The self-contained offline deck export (M6.S6) — theme + slides +
    /// inlined player, zero network.
    #[must_use]
    pub fn export_deck(&self) -> String {
        deck::export_html(&self.state.store, &self.tokens, &self.root)
    }

    /// The paginated PRINT-layout deck export (M6.S6 tail) — one slide per
    /// page via Print▸Save-as-PDF, no player.
    #[must_use]
    pub fn export_deck_print(&self) -> String {
        deck::export_print_html(&self.state.store, &self.tokens, &self.root)
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

    // MARK: M4.S4 — token statements + the zero-op retheme

    #[test]
    fn token_statements_retheme_with_one_patch_and_no_record_ops() {
        let mut doc = CanvasDoc::new_empty();
        doc.apply_dsl(0, "text #t \"themed\" color=$color.accent").expect("seed");
        let rev_before = doc.state.rev();
        // A token-only batch: rev must NOT move; the response carries the
        // SetTheme patch and nothing else.
        let resp = doc
            .apply_dsl(rev_before, "token set base.blue #123456")
            .expect("token set");
        assert_eq!(doc.state.rev(), rev_before, "tokens are doc settings, not record ops");
        let text = String::from_utf8_lossy(&resp);
        assert!(text.contains("setTheme"), "the retheme patch rides the response");
        assert!(text.contains("#123456"), "with the NEW values");
        // The lowering reflects it (color.accent aliases base.blue).
        assert!(doc.html().contains("--cv-base-blue: #123456;"));
        // Rename keeps old refs resolving (the M1 law through the DSL).
        doc.apply_dsl(rev_before, "token rename color.accent color.primary")
            .expect("rename");
        assert!(doc.html().contains("--cv-color-accent:"), "old path still emits");
        assert!(doc.html().contains("--cv-color-primary:"));
        // Teaching rejections: bad path + unknown rename source.
        let rej = doc.apply_dsl(rev_before, "token set NotAPath x").expect("frame");
        assert!(String::from_utf8_lossy(&rej).contains("bad token path"));
        let rej2 = doc.apply_dsl(rev_before, "token rename color.never color.x").expect("frame");
        assert!(String::from_utf8_lossy(&rej2).contains("unknown token"));
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
