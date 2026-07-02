//! Canvas M0 spike — the patch-loop demo engine (TSK-1343 / TSK-1352).
//!
//! Deliberately MINIMAL: a hardcoded ~200-node demo document, exactly two ops
//! (`setText` / `setStyle`), and a patch plan that mirrors the applied ops.
//! Its only job is to exercise the real boundary end-to-end —
//! `op frame → decode → state mutate → patch frame → FFI → JS DOM patch` —
//! so the M0 budgets can be measured before any schema freeze
//! (`docs/canvas/plans/M0-PLAN.md`; kill criterion in
//! `docs/canvas/06-MILESTONES-UAT.md` §M0).
//!
//! The REAL engine (flat record store, validation fence, tokens, lowering,
//! migrations) is M1 (`docs/canvas/02-CORE-ENGINE.md`) and replaces this
//! module's internals; the wire shapes here are throwaway-grade on purpose.
//!
//! Wire: MessagePack maps via [`crate::wire`] (`to_vec_named` framing rules).

pub mod lower;
pub mod ops;
pub mod props;
pub mod registry;
pub mod store;
pub mod tokens;

use crate::wire::{self, WireFault};
use serde::{Deserialize, Serialize};

/// Node kind for the demo document. M0 needs only containers and text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Frame,
    Text,
}

/// One demo node. Ids are the arena index (M0 simplification — stable,
/// opaque, prefixed ids arrive with the M1 store).
#[derive(Debug, Clone)]
struct Node {
    parent: Option<u32>,
    kind: Kind,
    text: String,
    /// Inline style pairs applied verbatim (`key`, `value`).
    styles: Vec<(String, String)>,
}

/// The M0 demo document: an arena of nodes plus a monotonically increasing
/// revision (bumped once per applied batch).
#[derive(Debug)]
pub struct Doc {
    nodes: Vec<Node>,
    rev: u64,
}

/// Number of sections in the demo doc.
const DEMO_SECTIONS: usize = 10;
/// Text children per section (section title + children + frames + root ≈ 200).
const DEMO_TEXTS_PER_SECTION: usize = 18;

/// Build the hardcoded demo document: root frame → `DEMO_SECTIONS` section
/// frames → each a title + `DEMO_TEXTS_PER_SECTION` text rows.
/// Node count: 1 + 10 + 10·(1 + 18) = **201** nodes, 3 levels deep.
#[must_use]
pub fn demo_doc() -> Doc {
    let mut nodes: Vec<Node> = Vec::with_capacity(201);
    nodes.push(Node {
        parent: None,
        kind: Kind::Frame,
        text: String::new(),
        styles: vec![
            ("display".to_owned(), "flex".to_owned()),
            ("flex-direction".to_owned(), "column".to_owned()),
            ("gap".to_owned(), "12px".to_owned()),
            ("padding".to_owned(), "24px".to_owned()),
        ],
    });
    for s in 0..DEMO_SECTIONS {
        // The demo arena is 201 nodes; the saturating fallback can never fire.
        let section_id = u32::try_from(nodes.len()).unwrap_or(u32::MAX);
        nodes.push(Node {
            parent: Some(0),
            kind: Kind::Frame,
            text: String::new(),
            styles: vec![
                ("display".to_owned(), "flex".to_owned()),
                ("flex-direction".to_owned(), "column".to_owned()),
                ("gap".to_owned(), "4px".to_owned()),
            ],
        });
        nodes.push(Node {
            parent: Some(section_id),
            kind: Kind::Text,
            text: format!("Section {s}"),
            styles: vec![("font-weight".to_owned(), "bold".to_owned())],
        });
        for t in 0..DEMO_TEXTS_PER_SECTION {
            nodes.push(Node {
                parent: Some(section_id),
                kind: Kind::Text,
                text: format!("Row {s}.{t}"),
                styles: Vec::new(),
            });
        }
    }
    Doc { nodes, rev: 0 }
}

impl Doc {
    /// Node count (test/measurement aid).
    #[must_use]
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    /// Current revision.
    #[must_use]
    pub fn rev(&self) -> u64 {
        self.rev
    }
}

/// An M0 canvas op. Tagged MessagePack maps so Swift/JS `Codable`-style
/// decoders see `{op: "setText", id, text}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum CanvasOp {
    /// Replace a node's text content.
    #[serde(rename_all = "camelCase")]
    SetText { id: u32, text: String },
    /// Set one inline style property on a node.
    #[serde(rename_all = "camelCase")]
    SetStyle { id: u32, key: String, value: String },
}

/// The apply request frame: `{ops: [...]}`.
#[derive(Debug, Deserialize)]
struct ApplyRequest {
    ops: Vec<CanvasOp>,
}

/// One DOM patch instruction (M0: mirrors the applied op — the loop under
/// test is decode → mutate → encode → apply, not a diff algorithm).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Patch {
    #[serde(rename_all = "camelCase")]
    SetText { id: u32, text: String },
    #[serde(rename_all = "camelCase")]
    SetStyle { id: u32, key: String, value: String },
}

/// The patch-plan response frame: `{rev, patches: [...], rejected: [...]}`.
/// `rejected` carries ids of ops that referenced unknown nodes (applied ops
/// still land — the real all-or-nothing fence is M1).
#[derive(Debug, Serialize)]
struct PatchPlan {
    rev: u64,
    patches: Vec<Patch>,
    rejected: Vec<u32>,
}

/// Apply an op batch (length-prefixed MessagePack request frame) to `doc`,
/// returning the patch-plan response frame.
///
/// # Errors
/// [`WireFault`] on a malformed frame; application-level rejects ride the
/// response's `rejected` list instead.
pub fn apply_wire(doc: &mut Doc, req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: ApplyRequest = wire::decode_frame(req_frame)?;
    let mut patches = Vec::with_capacity(req.ops.len());
    let mut rejected = Vec::new();
    for op in req.ops {
        match op {
            CanvasOp::SetText { id, text } => match doc.nodes.get_mut(id as usize) {
                Some(node) => {
                    node.text.clone_from(&text);
                    patches.push(Patch::SetText { id, text });
                }
                None => rejected.push(id),
            },
            CanvasOp::SetStyle { id, key, value } => match doc.nodes.get_mut(id as usize) {
                Some(node) => {
                    match node.styles.iter_mut().find(|(k, _)| *k == key) {
                        Some(slot) => slot.1.clone_from(&value),
                        None => node.styles.push((key.clone(), value.clone())),
                    }
                    patches.push(Patch::SetStyle { id, key, value });
                }
                None => rejected.push(id),
            },
        }
    }
    if !patches.is_empty() {
        doc.rev = doc.rev.saturating_add(1);
    }
    wire::encode_frame(&PatchPlan {
        rev: doc.rev,
        patches,
        rejected,
    })
}

/// Minimal HTML escape for text content (M0 demo strings are ASCII, but the
/// escape keeps the emitter honest).
fn escape_text(s: &str, out: &mut String) {
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
}

/// One-shot lowering of the whole demo doc to HTML — every node emitted as a
/// `div` stamped `data-cv-id`, styles inline. Throwaway-grade (the real
/// lowering is M1); exists so the WebView hosts ~200 real DOM nodes.
#[must_use]
pub fn initial_html(doc: &Doc) -> String {
    // children[i] = ids of nodes whose parent == i, in arena order.
    let mut children: Vec<Vec<u32>> = vec![Vec::new(); doc.nodes.len()];
    for (idx, node) in doc.nodes.iter().enumerate() {
        if let Some(parent) = node.parent
            && let Some(slot) = children.get_mut(parent as usize)
        {
            // Arena ids are u32 by construction; the fallback can never fire.
            slot.push(u32::try_from(idx).unwrap_or(u32::MAX));
        }
    }
    let mut out = String::with_capacity(doc.nodes.len() * 96);
    emit_node(doc, &children, 0, &mut out);
    out
}

/// Emit `id`'s div (open tag + text + children + close). Recursion depth is
/// the tree depth (3 in the demo doc).
fn emit_node(doc: &Doc, children: &[Vec<u32>], id: u32, out: &mut String) {
    let Some(node) = doc.nodes.get(id as usize) else {
        return;
    };
    out.push_str("<div data-cv-id=\"");
    out.push_str(&id.to_string());
    out.push('"');
    if !node.styles.is_empty() {
        out.push_str(" style=\"");
        for (k, v) in &node.styles {
            out.push_str(k);
            out.push(':');
            out.push_str(v);
            out.push(';');
        }
        out.push('"');
    }
    out.push('>');
    if node.kind == Kind::Text {
        escape_text(&node.text, out);
    }
    if let Some(kids) = children.get(id as usize) {
        for kid in kids {
            emit_node(doc, children, *kid, out);
        }
    }
    out.push_str("</div>");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply_ops(doc: &mut Doc, ops: &[CanvasOp]) -> Vec<u8> {
        #[derive(Serialize)]
        struct Req<'a> {
            ops: &'a [CanvasOp],
        }
        let frame = wire::encode_frame(&Req { ops }).expect("encode request");
        apply_wire(doc, &frame).expect("apply")
    }

    #[derive(Debug, Deserialize)]
    struct PlanEcho {
        rev: u64,
        patches: Vec<PatchEcho>,
        rejected: Vec<u32>,
    }
    #[derive(Debug, Deserialize, PartialEq, Eq)]
    #[serde(tag = "op", rename_all = "camelCase")]
    enum PatchEcho {
        #[serde(rename_all = "camelCase")]
        SetText { id: u32, text: String },
        #[serde(rename_all = "camelCase")]
        SetStyle { id: u32, key: String, value: String },
    }

    #[test]
    fn demo_doc_has_expected_shape() {
        let doc = demo_doc();
        assert_eq!(doc.node_count(), 201);
        assert_eq!(doc.rev(), 0);
        let html = initial_html(&doc);
        assert_eq!(html.matches("data-cv-id=").count(), 201);
        assert!(html.contains("data-cv-id=\"0\""));
        assert!(html.contains("Section 9"));
        assert!(html.contains("Row 9.17"));
    }

    #[test]
    fn set_text_mutates_state_and_emits_exact_patch() {
        let mut doc = demo_doc();
        let plan_frame = apply_ops(
            &mut doc,
            &[CanvasOp::SetText {
                id: 2,
                text: "Hello <world>".to_owned(),
            }],
        );
        let plan: PlanEcho = wire::decode_frame(&plan_frame).expect("decode plan");
        assert_eq!(plan.rev, 1);
        assert!(plan.rejected.is_empty());
        assert_eq!(
            plan.patches,
            vec![PatchEcho::SetText {
                id: 2,
                text: "Hello <world>".to_owned()
            }]
        );
        // State really mutated: re-lower reflects the new (escaped) text.
        let html = initial_html(&doc);
        assert!(html.contains("Hello &lt;world&gt;"));
    }

    #[test]
    fn set_style_updates_existing_key_and_appends_new() {
        let mut doc = demo_doc();
        apply_ops(
            &mut doc,
            &[
                CanvasOp::SetStyle {
                    id: 2,
                    key: "font-weight".to_owned(),
                    value: "normal".to_owned(),
                },
                CanvasOp::SetStyle {
                    id: 2,
                    key: "color".to_owned(),
                    value: "red".to_owned(),
                },
            ],
        );
        let html = initial_html(&doc);
        // Node 2 specifically: existing key updated in place, new key appended
        // (the other 9 section titles legitimately stay bold).
        assert!(html.contains("data-cv-id=\"2\" style=\"font-weight:normal;color:red;\""));
        assert_eq!(html.matches("font-weight:bold;").count(), 9);
    }

    #[test]
    fn unknown_id_is_rejected_not_fatal_and_rev_tracks_applied_only() {
        let mut doc = demo_doc();
        let plan_frame = apply_ops(
            &mut doc,
            &[CanvasOp::SetText {
                id: 9999,
                text: "x".to_owned(),
            }],
        );
        let plan: PlanEcho = wire::decode_frame(&plan_frame).expect("decode plan");
        assert_eq!(plan.rejected, vec![9999]);
        assert!(plan.patches.is_empty());
        assert_eq!(plan.rev, 0, "no applied patches => rev unchanged");
    }

    #[test]
    fn malformed_frame_is_a_wire_fault() {
        let mut doc = demo_doc();
        assert!(apply_wire(&mut doc, &[0xFF, 0x00, 0x01]).is_err());
    }
}
