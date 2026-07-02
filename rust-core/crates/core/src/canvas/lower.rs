//! Canvas M1.S5 — lowering v1: records → HTML/CSS (TSK-1360; 02-CORE-ENGINE §9).
//!
//! Deterministic, pure, byte-stable: same store + tokens ⇒ identical HTML.
//! Every node emits a `div` (v1 substrate; `img` for images) stamped
//! `data-cv-id`; styles are inline declarations mapped from the S2 prop bag.
//! **Token references lower to `var(--cv-…)`** — the theme's custom-property
//! block (S4 `to_css_custom_props`) is emitted once at the page root, so a
//! token-value swap RETHEMES LIVE without re-lowering (the zero-op theme swap
//! UAT-M4 asserts). Literals emit verbatim.
//!
//! Geometry stays renderer-owned (01 §8): flex/grid math never happens here.

use super::props::{PropKey, Value};
use super::store::{Id, RecordKind, Store};
use super::tokens::TokenStore;

/// Minimal HTML text escape.
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

/// Attribute-value escape (double-quoted context).
fn escape_attr(s: &str, out: &mut String) {
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(ch),
        }
    }
}

/// A CSS value: a literal passes through; a token ref becomes `var(--cv-…)`.
fn css_value(value: &Value) -> Option<String> {
    match value {
        Value::Str(s) => Some(s.clone()),
        Value::Num(n) => Some(format!("{n}px")),
        Value::Bool(_) => None,
        Value::Token(path) => {
            let mut v = String::from("var(--cv-");
            for ch in path.chars() {
                v.push(if ch == '.' { '-' } else { ch });
            }
            v.push(')');
            Some(v)
        }
    }
}

/// Unitless numeric CSS value (grow/shrink/opacity/span).
fn css_number(value: &Value) -> Option<String> {
    match value {
        Value::Num(n) => Some(format!("{n}")),
        _ => css_value(value),
    }
}

/// Map one prop to its CSS declaration (the SHARED table — `patch.rs` uses
/// the same mapping so full lowering and incremental patches cannot drift).
/// `None` = the prop is not a style (content/structure props).
#[must_use]
pub fn css_decl(key: PropKey, value: &Value) -> Option<(&'static str, String)> {
    let name = key.name()?;
    let decl = |p: &'static str, v: Option<String>| v.map(|vv| (p, vv));
    match name {
        "fill" => decl("background", css_value(value)),
        "color" => decl("color", css_value(value)),
        "stroke" => decl("border", css_value(value)),
        "font" => decl("font", css_value(value)),
        "radius" => decl("border-radius", css_value(value)),
        "shadow" => decl("box-shadow", css_value(value)),
        "opacity" => decl("opacity", css_number(value)),
        "gap" => decl("gap", css_value(value)),
        "padding" => decl("padding", css_value(value)),
        "align" => decl("align-items", css_value(value)),
        "justify" => decl("justify-content", css_value(value)),
        "direction" => decl("flex-direction", css_value(value)),
        "wrap" => match value {
            Value::Bool(true) => Some(("flex-wrap", "wrap".to_owned())),
            _ => None,
        },
        "grow" => decl("flex-grow", css_number(value)),
        "shrink" => decl("flex-shrink", css_number(value)),
        "minW" => decl("min-width", css_value(value)),
        "maxW" => decl("max-width", css_value(value)),
        "minH" => decl("min-height", css_value(value)),
        "maxH" => decl("max-height", css_value(value)),
        "fit" => decl("object-fit", css_value(value)),
        _ => None, // text/src/ref/html/note/role/shape/span: not inline styles
    }
}

/// The full inline style string for a record (canonical prop order — the bag
/// is key-sorted, so this is deterministic by construction).
fn style_of(store: &Store, id: &Id) -> String {
    let Some(rec) = store.get(id) else {
        return String::new();
    };
    let mut css = String::new();
    // Containers are flex by default (auto-layout lowers to flexbox).
    if rec.kind.can_parent() {
        css.push_str("display:flex;");
        // Column unless direction says otherwise.
        let dir_key = PropKey::by_name("direction");
        let has_dir = dir_key.is_some_and(|k| rec.props.get(k).is_some());
        if !has_dir {
            css.push_str("flex-direction:column;");
        }
    }
    for (key, value) in rec.props.iter() {
        if let Some((prop, v)) = css_decl(key, value) {
            css.push_str(prop);
            css.push(':');
            css.push_str(&v);
            css.push(';');
        }
    }
    css
}

/// Lower ONE record subtree to HTML (the fragment `patch.rs` uses for
/// insert patches, and the recursion unit for whole-page lowering).
#[must_use]
pub fn lower_subtree(store: &Store, id: &Id) -> String {
    let mut out = String::new();
    emit(store, id, &ExpandCtx::root(), &mut out);
    out
}

/// Component-expansion context (M4.S1): the id-namespace prefix for nodes
/// emitted INSIDE an instance expansion (`nd:inst/…`), and the depth cap
/// that bounds nesting (a cycle fence lives at apply-time; the cap is the
/// render-side backstop so even a corrupted doc cannot loop the lowerer).
struct ExpandCtx {
    prefix: String,
    depth: u8,
}

const MAX_EXPANSION_DEPTH: u8 = 8;

impl ExpandCtx {
    fn root() -> ExpandCtx {
        ExpandCtx { prefix: String::new(), depth: 0 }
    }
    fn enter(&self, instance_id: &Id) -> ExpandCtx {
        ExpandCtx {
            prefix: format!("{}{}/", self.prefix, instance_id.as_str()),
            depth: self.depth.saturating_add(1),
        }
    }
    /// The DOM id for `id` in this context (namespaced inside expansions).
    fn dom_id(&self, id: &Id) -> String {
        if self.prefix.is_empty() {
            id.as_str().to_owned()
        } else {
            format!("{}{}", self.prefix, id.as_str())
        }
    }
}

fn emit(store: &Store, id: &Id, ctx: &ExpandCtx, out: &mut String) {
    let Some(rec) = store.get(id) else { return };

    // Component INSTANCE: expand its definition's subtree with namespaced
    // ids (M4-PLAN §S1 — expansion at lowering: editing the definition
    // updates every instance by construction). Unknown/dangling refs render
    // a visible placeholder (lint already warns via dangling-ref).
    if rec.kind == RecordKind::Component {
        let target = PropKey::by_name("ref")
            .and_then(|k| rec.props.get(k))
            .and_then(|v| match v {
                Value::Str(s) => Id::parse(s).ok(),
                _ => None,
            });
        out.push_str("<div data-cv-id=\"");
        escape_attr(&ctx.dom_id(id), out);
        out.push_str("\" data-cv-kind=\"component\"");
        let style = style_of(store, id);
        if !style.is_empty() {
            out.push_str(" style=\"");
            escape_attr(&style, out);
            out.push('"');
        }
        out.push('>');
        if ctx.depth >= MAX_EXPANSION_DEPTH {
            out.push_str("<!-- expansion depth cap -->");
        } else if let Some(def) = target.filter(|t| store.get(t).is_some()) {
            let inner = ctx.enter(id);
            for kid in store.children(&def) {
                emit(store, &kid, &inner, out);
            }
        } else {
            out.push_str("<!-- unresolved component -->");
        }
        out.push_str("</div>");
        return;
    }

    let style = style_of(store, id);
    let get = |name: &str| PropKey::by_name(name).and_then(|k| rec.props.get(k));

    match rec.kind {
        RecordKind::Image => {
            out.push_str("<img data-cv-id=\"");
            escape_attr(&ctx.dom_id(id), out);
            out.push('"');
            if let Some(Value::Str(src)) = get("src") {
                out.push_str(" src=\"");
                escape_attr(src, out);
                out.push('"');
            }
            if !style.is_empty() {
                out.push_str(" style=\"");
                escape_attr(&style, out);
                out.push('"');
            }
            out.push('>');
        }
        _ => {
            out.push_str("<div data-cv-id=\"");
            escape_attr(&ctx.dom_id(id), out);
            out.push('"');
            // Kind marker for the runtime/debugging (stable vocabulary).
            out.push_str(" data-cv-kind=\"");
            out.push_str(super::registry::kind_name(rec.kind));
            out.push('"');
            if !style.is_empty() {
                out.push_str(" style=\"");
                escape_attr(&style, out);
                out.push('"');
            }
            out.push('>');
            match rec.kind {
                RecordKind::Text => {
                    if let Some(Value::Str(text)) = get("text") {
                        escape_text(text, out);
                    }
                }
                RecordKind::Hole => {
                    if let Some(Value::Str(note)) = get("note") {
                        escape_text(note, out);
                    }
                }
                // Embed/component: placeholders in v1 lowering (sandboxed
                // iframe + expansion arrive with their slices).
                _ => {}
            }
            for kid in store.children(id) {
                emit(store, &kid, ctx, out);
            }
            out.push_str("</div>");
        }
    }
}

/// Lower a whole page: the theme's custom-property block once at the root,
/// then the page subtree.
#[must_use]
pub fn lower_page(store: &Store, tokens: &TokenStore, page: &Id) -> String {
    let mut out = String::new();
    out.push_str("<style>:root{\n");
    out.push_str(&tokens.to_css_custom_props());
    out.push_str("}</style>");
    emit(store, page, &ExpandCtx::root(), &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::ops::{CanvasOp, DocState};
    use crate::canvas::store::Position;

    fn id(s: &str) -> Id {
        Id::parse(s).expect("id")
    }
    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    /// A small fixture doc built through the REAL op layer.
    fn fixture() -> (DocState, Id) {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:hero")),
                    kind: RecordKind::Frame,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![
                        (key("fill"), Value::Token("color.surface".to_owned())),
                        (key("padding"), Value::Token("space.lg".to_owned())),
                        (key("gap"), Value::Num(8.0)),
                    ],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:title")),
                    kind: RecordKind::Text,
                    parent: id("nd:hero"),
                    pos: Position::Last,
                    props: vec![
                        (key("text"), Value::Str("Hello <Canvas> & co".to_owned())),
                        (key("font"), Value::Token("font.h1".to_owned())),
                        (key("color"), Value::Token("color.fg".to_owned())),
                    ],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:pic")),
                    kind: RecordKind::Image,
                    parent: id("nd:hero"),
                    pos: Position::Last,
                    props: vec![
                        (key("src"), Value::Str("assets/x.png".to_owned())),
                        (key("fit"), Value::Str("cover".to_owned())),
                        (key("opacity"), Value::Num(0.9)),
                    ],
                },
            ],
        )
        .expect("fixture");
        (d, pg)
    }

    #[test]
    fn lowering_is_deterministic_and_stamps_every_node() {
        let (d, pg) = fixture();
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert_eq!(html, lower_page(&d.store, &tokens, &pg), "byte-stable");
        assert_eq!(html.matches("data-cv-id=").count(), 4, "page + 3 nodes");
        assert!(html.contains("data-cv-kind=\"frame\""));
    }

    #[test]
    fn token_refs_lower_to_css_vars_and_theme_block_is_emitted() {
        let (d, pg) = fixture();
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        // Symbolic refs — NOT baked literals (live retheme guarantee).
        assert!(html.contains("background:var(--cv-color-surface)"));
        assert!(html.contains("padding:var(--cv-space-lg)"));
        assert!(html.contains("font:var(--cv-font-h1)"));
        assert!(!html.contains("background:#f5f5f7"), "no baked literal");
        // The theme block carries the actual values once, at the root.
        assert!(html.contains("--cv-color-surface: #f5f5f7;"));
    }

    #[test]
    fn content_is_escaped_and_images_emit_attrs() {
        let (d, pg) = fixture();
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("Hello &lt;Canvas&gt; &amp; co"));
        assert!(html.contains("<img data-cv-id=\"nd:pic\""));
        assert!(html.contains("src=\"assets/x.png\""));
        assert!(html.contains("object-fit:cover"));
        assert!(html.contains("opacity:0.9"));
    }

    #[test]
    fn containers_default_to_column_flex_and_numbers_get_px() {
        let (d, pg) = fixture();
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("display:flex;flex-direction:column;"));
        assert!(html.contains("gap:8px"));
    }

    // MARK: M4.S1 — component expansion

    /// Build: a cmp:card definition (frame > title + body texts) + two
    /// instances on the page.
    fn component_fixture() -> (DocState, Id) {
        let (mut d, pg) = {
            let mut d = DocState::new();
            let pg = Id::page(1);
            d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
            (d, pg)
        };
        let card = Id::parse("cmp:card").expect("cmp id");
        d.store.insert_root(card.clone(), RecordKind::Frame).expect("cmp root");
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:card-title")),
                    kind: RecordKind::Text,
                    parent: card.clone(),
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str("Card title".into()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:inst-a")),
                    kind: RecordKind::Component,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("ref"), Value::Str("cmp:card".into()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:inst-b")),
                    kind: RecordKind::Component,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("ref"), Value::Str("cmp:card".into()))],
                },
            ],
        )
        .expect("fixture");
        (d, pg)
    }

    #[test]
    fn instances_expand_their_definition_with_namespaced_ids() {
        let (d, pg) = component_fixture();
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        // Both instances render the definition's content...
        assert_eq!(html.matches(">Card title<").count(), 2, "{html}");
        // ...with NAMESPACED inner ids (stable + collision-free).
        assert!(html.contains("data-cv-id=\"nd:inst-a/nd:card-title\""));
        assert!(html.contains("data-cv-id=\"nd:inst-b/nd:card-title\""));
        // The definition itself is NOT rendered on the page (separate root).
        assert!(!html.contains("data-cv-id=\"nd:card-title\""), "no un-namespaced leak");
    }

    #[test]
    fn definition_edit_updates_every_instance_by_construction() {
        let (mut d, pg) = component_fixture();
        let tokens = TokenStore::default_theme();
        d.apply(
            1,
            &[CanvasOp::Update {
                id: id("nd:card-title"),
                set: vec![(key("text"), Value::Str("Edited once".into()))],
                unset: vec![],
            }],
        )
        .expect("edit the definition");
        let html = lower_page(&d.store, &tokens, &pg);
        assert_eq!(html.matches(">Edited once<").count(), 2,
                   "one definition edit, every instance updated");
        assert_eq!(html.matches(">Card title<").count(), 0);
    }

    #[test]
    fn dangling_refs_render_placeholders_and_depth_is_capped() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(
            0,
            &[CanvasOp::Insert {
                id: Some(id("nd:ghost")),
                kind: RecordKind::Component,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:missing".into()))],
            }],
        )
        .expect("ghost");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("unresolved component"));

        // Depth cap: a self-instantiating definition (the apply-time cycle
        // fence is S1b; the RENDER-side cap must already refuse to loop).
        let looper = Id::parse("cmp:loop").expect("id");
        d.store.insert_root(looper.clone(), RecordKind::Frame).expect("root2");
        d.apply(
            1,
            &[CanvasOp::Insert {
                id: Some(id("nd:selfref")),
                kind: RecordKind::Component,
                parent: looper.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:loop".into()))],
            }],
        )
        .expect("self-instantiating definition");
        d.apply(
            2,
            &[CanvasOp::Insert {
                id: Some(id("nd:top")),
                kind: RecordKind::Component,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:loop".into()))],
            }],
        )
        .expect("top instance");
        let html2 = lower_page(&d.store, &tokens, &pg);
        assert!(html2.contains("expansion depth cap"), "the lowerer must not loop");
    }

    #[test]
    fn subtree_fragment_matches_page_slice() {
        let (d, _pg) = fixture();
        let frag = lower_subtree(&d.store, &id("nd:title"));
        assert!(frag.starts_with("<div data-cv-id=\"nd:title\""));
        assert!(frag.ends_with("</div>"));
        let tokens = TokenStore::default_theme();
        let page = lower_page(&d.store, &tokens, &id("pg:1"));
        assert!(page.contains(&frag), "fragment lowering = the page's slice");
    }
}
