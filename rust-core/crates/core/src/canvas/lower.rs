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
    // Containers are flex by default (auto-layout lowers to flexbox); a
    // `columns` prop switches to an N-equal-column grid (post-M6, closing the
    // gauntlet's hand-assembled-grid finding — minmax(0,1fr) so cells can
    // shrink below content width).
    if rec.kind.can_parent() {
        let cols = PropKey::by_name("columns")
            .and_then(|k| rec.props.get(k))
            .and_then(|v| match v {
                Value::Num(n) if *n >= 1.0 => {
                    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss,
                            reason = "clamped 1..=64")]
                    Some((*n).min(64.0) as u32)
                }
                _ => None,
                _ => None,
            });
        if let Some(n) = cols {
            css.push_str("display:grid;grid-template-columns:repeat(");
            css.push_str(&n.to_string());
            css.push_str(",minmax(0,1fr));");
        } else {
            css.push_str("display:flex;");
            let dir_key = PropKey::by_name("direction");
            let has_dir = dir_key.is_some_and(|k| rec.props.get(k).is_some());
            if !has_dir {
                css.push_str("flex-direction:column;");
            }
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
    /// Text overrides active for THIS expansion (anchor id string → text) —
    /// parsed once from the instance's `overrides` JSON (M4.S2). Innermost
    /// instance wins for nested expansions.
    text_overrides: Vec<(String, String)>,
}

const MAX_EXPANSION_DEPTH: u8 = 8;

impl ExpandCtx {
    fn root() -> ExpandCtx {
        ExpandCtx { prefix: String::new(), depth: 0, text_overrides: Vec::new() }
    }
    fn enter(&self, instance_id: &Id, overrides: Vec<(String, String)>) -> ExpandCtx {
        ExpandCtx {
            prefix: format!("{}{}/", self.prefix, instance_id.as_str()),
            depth: self.depth.saturating_add(1),
            text_overrides: overrides,
        }
    }
    fn override_for(&self, id: &Id) -> Option<&str> {
        self.text_overrides
            .iter()
            .find(|(anchor, _)| anchor == id.as_str())
            .map(|(_, text)| text.as_str())
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
        // A component instance can itself be a nav link (M5.S6).
        emit_link_attr(&|name| PropKey::by_name(name).and_then(|k| rec.props.get(k)), out);
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
            let overrides = PropKey::by_name("overrides")
                .and_then(|k| rec.props.get(k))
                .and_then(|v| match v {
                    Value::Str(json) => parse_overrides(json),
                    _ => None,
                })
                .unwrap_or_default();
            let inner = ctx.enter(id, overrides);
            for kid in store.children(&def) {
                emit(store, &kid, &inner, out);
            }
        } else {
            out.push_str("<!-- unresolved component -->");
        }
        out.push_str("</div>");
        return;
    }

    // Table (M4.S7a): a real <table> from the JSON data prop; malformed
    // data renders a placeholder (lint warns — lowering stays total).
    if rec.kind == RecordKind::Table {
        emit_table(rec, &ctx.dom_id(id), store, id, out);
        return;
    }
    // Code (M4.S7a): escaped <pre><code>, language as a data attribute.
    if rec.kind == RecordKind::Code {
        emit_code(rec, &ctx.dom_id(id), store, id, out);
        return;
    }
    // Chart (M4.S7b): deterministic rust-side SVG from the VL-subset spec.
    if rec.kind == RecordKind::Chart {
        let style = style_of(store, id);
        out.push_str("<div data-cv-id=\"");
        escape_attr(&ctx.dom_id(id), out);
        out.push_str("\" data-cv-kind=\"chart\"");
        if !style.is_empty() {
            out.push_str(" style=\"");
            escape_attr(&style, out);
            out.push('"');
        }
        out.push('>');
        let spec = PropKey::by_name("spec")
            .and_then(|k| rec.props.get(k))
            .and_then(|v| match v {
                Value::Str(s) => super::chart::parse_spec(s),
                _ => None,
            });
        match spec {
            Some(parsed) => out.push_str(&super::chart::render_svg(&parsed)),
            None => out.push_str("<!-- invalid chart spec -->"),
        }
        out.push_str("</div>");
        return;
    }
    // Diagram (M4.S7b): mermaid SOURCE, escaped, class-hooked for the shell
    // integration (live mermaid render = a shell concern, tracked).
    if rec.kind == RecordKind::Diagram {
        let style = style_of(store, id);
        out.push_str("<pre data-cv-id=\"");
        escape_attr(&ctx.dom_id(id), out);
        out.push_str("\" data-cv-kind=\"diagram\" class=\"mermaid-source\"");
        if !style.is_empty() {
            out.push_str(" style=\"");
            escape_attr(&style, out);
            out.push('"');
        }
        out.push('>');
        if let Some(Value::Str(text)) = PropKey::by_name("text")
            .and_then(|k| rec.props.get(k))
        {
            escape_text(text, out);
        }
        out.push_str("</pre>");
        return;
    }

    let style = style_of(store, id);
    let get = |name: &str| PropKey::by_name(name).and_then(|k| rec.props.get(k));
    // Artboard chrome (M5.S2): role=artboard frames read as design
    // viewports — an outline + a label strip (the note text), all
    // token-colored so chrome rethemes with the document. Ordinary frames
    // are untouched (the thin-mode law: chrome keys on the PROP).
    let is_artboard = rec.kind.can_parent()
        && matches!(get("role"), Some(Value::Str(s)) if s == "artboard");

    match rec.kind {
        RecordKind::Image => {
            out.push_str("<img data-cv-id=\"");
            escape_attr(&ctx.dom_id(id), out);
            out.push('"');
            emit_link_attr(&get, out);
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
            emit_link_attr(&get, out);
            if is_artboard {
                let mut chromed = style.clone();
                chromed.push_str(
                    "outline:1px solid var(--cv-color-border);outline-offset:4px;",
                );
                out.push_str(" style=\"");
                escape_attr(&chromed, out);
                out.push('"');
            } else if !style.is_empty() {
                out.push_str(" style=\"");
                escape_attr(&style, out);
                out.push('"');
            }
            out.push('>');
            if is_artboard && let Some(Value::Str(label)) = get("note") {
                // The label strip: plain chrome (no data-cv-id — it is not
                // an addressable node; selection/geometry stay content-true).
                out.push_str(
                    "<div style=\"font:600 11px -apple-system, sans-serif;\
                     color:var(--cv-color-muted);margin:-2px 0 6px 0\">",
                );
                escape_text(label, out);
                out.push_str("</div>");
            }
            match rec.kind {
                RecordKind::Text => {
                    if let Some(replacement) = ctx.override_for(id) {
                        escape_text(replacement, out);
                    } else if let Some(Value::Str(text)) = get("text") {
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

/// M5.S6 — prototype nav: emit data-cv-link when the node carries a linkTo
/// prop (the runtime scrolls to the referenced node on click).
fn emit_link_attr<'a>(get: &impl Fn(&str) -> Option<&'a Value>, out: &mut String) {
    if let Some(Value::Str(target)) = get("linkTo") {
        out.push_str(" data-cv-link=\"");
        escape_attr(target, out);
        out.push('"');
    }
    // M6.S4 — the deck player reads role + step off the DOM (role=slide finds
    // slides; step drives the reveal, mirroring timeline_state exactly).
    if let Some(Value::Str(role)) = get("role") {
        out.push_str(" data-cv-role=\"");
        escape_attr(role, out);
        out.push('"');
    }
    if let Some(Value::Num(step)) = get("step")
        && *step >= 0.0
    {
        out.push_str(" data-cv-step=\"");
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss,
                reason = "clamped non-negative")]
        let s = (*step).min(f64::from(u16::MAX)) as u16;
        out.push_str(&s.to_string());
        out.push('"');
    }
    // M6.S5 — identity-morph tag: the player FLIP-pairs nodes sharing it.
    if let Some(Value::Str(morph)) = get("morphId") {
        out.push_str(" data-cv-morph=\"");
        escape_attr(morph, out);
        out.push('"');
    }
}

fn emit_table(
    rec: &super::store::Record,
    dom_id: &str,
    store: &Store,
    id: &Id,
    out: &mut String,
) {
    let style = style_of(store, id);
    out.push_str("<table data-cv-id=\"");
    escape_attr(dom_id, out);
    out.push_str("\" data-cv-kind=\"table\"");
    if !style.is_empty() {
        out.push_str(" style=\"");
        escape_attr(&style, out);
        out.push('"');
    }
    out.push('>');
    let data = PropKey::by_name("data")
        .and_then(|k| rec.props.get(k))
        .and_then(|v| match v {
            Value::Str(s) => parse_table_data(s),
            _ => None,
        });
    let headers = PropKey::by_name("headers")
        .and_then(|k| rec.props.get(k))
        .is_some_and(|v| matches!(v, Value::Bool(true)));
    match data {
        Some(rows) => {
            for (i, row) in rows.iter().enumerate() {
                out.push_str("<tr>");
                let cell_tag = if headers && i == 0 { "th" } else { "td" };
                for cell in row {
                    out.push('<');
                    out.push_str(cell_tag);
                    out.push('>');
                    escape_text(cell, out);
                    out.push_str("</");
                    out.push_str(cell_tag);
                    out.push('>');
                }
                out.push_str("</tr>");
            }
        }
        None => out.push_str("<!-- invalid table data -->"),
    }
    out.push_str("</table>");
}

/// Lint's validity probe for table data (M4.S7a).
#[must_use]
pub fn table_data_is_valid(json: &str) -> bool {
    parse_table_data(json).is_some()
}

/// Table data: a JSON array of rows of stringifiable cells.
fn parse_table_data(json: &str) -> Option<Vec<Vec<String>>> {
    let crate::json::JsonValue::Array(rows) = crate::json::parse(json).ok()? else {
        return None;
    };
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let crate::json::JsonValue::Array(cells) = row else { return None };
        let mut cells_out = Vec::with_capacity(cells.len());
        for cell in cells {
            match cell {
                crate::json::JsonValue::Str(s) => cells_out.push(s),
                crate::json::JsonValue::Int(i) => cells_out.push(i.to_string()),
                crate::json::JsonValue::Float(f) => cells_out.push(f.to_string()),
                crate::json::JsonValue::Bool(b) => cells_out.push(b.to_string()),
                _ => return None,
            }
        }
        out.push(cells_out);
    }
    Some(out)
}

fn emit_code(
    rec: &super::store::Record,
    dom_id: &str,
    store: &Store,
    id: &Id,
    out: &mut String,
) {
    let style = style_of(store, id);
    out.push_str("<pre data-cv-id=\"");
    escape_attr(dom_id, out);
    out.push_str("\" data-cv-kind=\"code\"");
    if let Some(Value::Str(lang)) = PropKey::by_name("language")
        .and_then(|k| rec.props.get(k))
    {
        out.push_str(" data-cv-lang=\"");
        escape_attr(lang, out);
        out.push('"');
    }
    if !style.is_empty() {
        out.push_str(" style=\"");
        escape_attr(&style, out);
        out.push('"');
    }
    out.push_str("><code>");
    if let Some(Value::Str(text)) = PropKey::by_name("text")
        .and_then(|k| rec.props.get(k))
    {
        escape_text(text, out);
    }
    out.push_str("</code></pre>");
}

/// Parse the instance `overrides` JSON (a flat object of anchor-id →
/// replacement text) via the in-house parser. None on any malformed shape
/// (the fence rejects at apply; lowering stays lenient/total).
fn parse_overrides(json: &str) -> Option<Vec<(String, String)>> {
    let parsed = crate::json::parse(json).ok()?;
    let crate::json::JsonValue::Object(pairs) = parsed else {
        return None;
    };
    Some(
        pairs
            .into_iter()
            .filter_map(|(k, v)| match v {
                crate::json::JsonValue::Str(s) => Some((k, s)),
                _ => None,
            })
            .collect(),
    )
}

/// Validate every instance's `overrides` table (M4.S2 fence): must be a
/// flat JSON object of string→string whose anchor keys NAME NODES INSIDE
/// the referenced definition. Returns a teaching description on failure.
#[must_use]
pub fn find_invalid_override(store: &Store) -> Option<String> {
    let mut ids: Vec<&Id> = store.ids().collect();
    ids.sort();
    for id in ids {
        let Some(rec) = store.get(id) else { continue };
        if rec.kind != RecordKind::Component {
            continue;
        }
        let Some(Value::Str(json)) = PropKey::by_name("overrides")
            .and_then(|k| rec.props.get(k))
        else {
            continue;
        };
        let Some(table) = parse_overrides(json) else {
            return Some(format!(
                "instance '{}': overrides must be a flat JSON object of \
                 \"anchor-id\": \"text\"",
                id.as_str()
            ));
        };
        let def = PropKey::by_name("ref")
            .and_then(|k| rec.props.get(k))
            .and_then(|v| match v {
                Value::Str(s) => Id::parse(s).ok(),
                _ => None,
            });
        let Some(def) = def.filter(|d| store.get(d).is_some()) else {
            // Dangling refs are lint's domain; overrides on them wait.
            continue;
        };
        for (anchor, _) in &table {
            let Ok(anchor_id) = Id::parse(anchor) else {
                return Some(format!(
                    "instance '{}': override anchor '{anchor}' is not a valid id",
                    id.as_str()
                ));
            };
            if containing_definition(store, &anchor_id).as_ref() != Some(&def) {
                return Some(format!(
                    "instance '{}': override anchor '{anchor}' names no node \
                     inside definition '{}'",
                    id.as_str(),
                    def.as_str()
                ));
            }
        }
    }
    None
}

/// Detect an expansion cycle: a `cmp:*` definition that transitively
/// instantiates itself. Returns the offending definition id. Total (visited
/// sets), store-order deterministic.
#[must_use]
pub fn find_expansion_cycle(store: &Store) -> Option<Id> {
    // def → the defs its subtree instantiates.
    let mut ids: Vec<&Id> = store.ids().collect();
    ids.sort();
    let defs: Vec<&Id> = ids.iter().copied()
        .filter(|i| i.as_str().starts_with("cmp:"))
        .collect();
    for def in defs {
        let mut stack: Vec<Id> = vec![def.clone()];
        let mut visited: Vec<Id> = Vec::new();
        while let Some(current) = stack.pop() {
            if visited.contains(&current) {
                continue;
            }
            visited.push(current.clone());
            for referenced in referenced_defs(store, &current) {
                if &referenced == def {
                    return Some(def.clone());
                }
                stack.push(referenced);
            }
        }
    }
    None
}

/// The defs directly instantiated anywhere inside `root`'s subtree.
fn referenced_defs(store: &Store, root: &Id) -> Vec<Id> {
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(current) = stack.pop() {
        for kid in store.children(&current) {
            if let Some(rec) = store.get(&kid) {
                if rec.kind == RecordKind::Component
                    && let Some(Value::Str(s)) =
                        PropKey::by_name("ref").and_then(|k| rec.props.get(k))
                    && let Ok(target) = Id::parse(s)
                {
                    out.push(target);
                }
                if rec.kind.can_parent() {
                    stack.push(kid);
                }
            }
        }
    }
    out
}

/// The cmp:* definition CONTAINING `id` (walking parents), or None when the
/// node lives in ordinary page content.
#[must_use]
pub fn containing_definition(store: &Store, id: &Id) -> Option<Id> {
    let mut current = id.clone();
    loop {
        if current.as_str().starts_with("cmp:") {
            return Some(current);
        }
        let parent = store.get(&current)?.place.as_ref()?.parent.clone();
        current = parent;
    }
}

/// Every VISIBLE instance whose expansion includes `def` — direct instances
/// in page content, plus (recursively) visible instances of definitions that
/// themselves instantiate `def`. Total via a visited set.
#[must_use]
pub fn visible_instances_of(store: &Store, def: &Id) -> Vec<Id> {
    let mut result: Vec<Id> = Vec::new();
    let mut pending: Vec<Id> = vec![def.clone()];
    let mut seen_defs: Vec<Id> = Vec::new();
    while let Some(target) = pending.pop() {
        if seen_defs.contains(&target) {
            continue;
        }
        seen_defs.push(target.clone());
        let mut ids: Vec<&Id> = store.ids().collect();
        ids.sort();
        for id in ids {
            let Some(rec) = store.get(id) else { continue };
            if rec.kind != RecordKind::Component {
                continue;
            }
            let refs_target = PropKey::by_name("ref")
                .and_then(|k| rec.props.get(k))
                .is_some_and(|v| matches!(v, Value::Str(s) if Id::parse(s).ok().as_ref() == Some(&target)));
            if !refs_target {
                continue;
            }
            match containing_definition(store, id) {
                None => {
                    if !result.contains(id) {
                        result.push(id.clone());
                    }
                }
                Some(outer_def) => pending.push(outer_def),
            }
        }
    }
    result
}

/// M5.S3 — the FRAGMENT export: one node's subtree with NO theme block and
/// every var(--cv-*) reference inlined to its literal (embeddable in an
/// existing site that has no `--cv-*` custom properties). Uses the token
/// store's forward map so dash-containing paths (base.gray-1) stay exact.
#[must_use]
pub fn render_fragment(store: &Store, tokens: &TokenStore, id: &Id) -> String {
    inline_token_vars(&lower_subtree(store, id), tokens)
}

fn inline_token_vars(html: &str, tokens: &TokenStore) -> String {
    let mut out = html.to_owned();
    // Replace whole `var(<name>)` patterns (the closing paren makes each
    // match exact, so --cv-color never eats --cv-color-fg). Small pair set.
    for (name, literal) in tokens.css_var_pairs() {
        out = out.replace(&format!("var({name})"), &literal);
    }
    out
}

/// Lower a whole page: the theme's custom-property block once at the root,
/// then the page subtree.
#[must_use]
pub fn lower_page(store: &Store, tokens: &TokenStore, page: &Id) -> String {
    let mut out = String::new();
    out.push_str("<style id=\"cv-theme\">:root{\n");
    out.push_str(&tokens.to_css_custom_props());
    out.push_str("}\n");
    // TSK-1546: apply the body font + fg color AT THE PAGE ROOT so every
    // descendant inherits them unless it overrides. Without this rule the
    // tokens exist as custom properties but nothing USES them for plain
    // text — any node without an explicit font=/color= fell back to the
    // UA default (Times New Roman in WebKit).
    out.push_str(
        "[data-cv-kind=\"page\"]{font:var(--cv-font-body);color:var(--cv-color-fg)}",
    );
    out.push_str("</style>");
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
        // TSK-1546: the page root APPLIES body font + fg color so plain text
        // inherits them — without this rule unstyled text fell back to the
        // UA serif default (Times New Roman).
        assert!(
            html.contains("[data-cv-kind=\"page\"]{font:var(--cv-font-body);color:var(--cv-color-fg)}"),
            "page-root inheritance rule missing from the theme block"
        );
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

        // The apply-time CYCLE FENCE rejects a self-instantiating definition
        // atomically (M4.S1b) — the op path can never create the loop.
        let looper = Id::parse("cmp:loop").expect("id");
        d.store.insert_root(looper.clone(), RecordKind::Frame).expect("root2");
        let rejected = d.apply(
            1,
            &[CanvasOp::Insert {
                id: Some(id("nd:selfref")),
                kind: RecordKind::Component,
                parent: looper.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:loop".into()))],
            }],
        );
        assert!(rejected.is_err(), "the fence must reject the expansion cycle");
        assert!(d.store.get(&id("nd:selfref")).is_none(), "rejected atomically");

        // The RENDER-side depth cap is the backstop for a CORRUPTED doc that
        // bypassed the ops (store surgery below — no fence in that path).
        d.store
            .insert(id("nd:selfref2"), RecordKind::Component, &looper, &Position::Last)
            .expect("store surgery");
        d.store
            .props_mut(&id("nd:selfref2"))
            .expect("props")
            .set(key("ref"), Value::Str("cmp:loop".into()));
        let rev = d.rev();
        d.apply(
            rev,
            &[CanvasOp::Insert {
                id: Some(id("nd:top")),
                kind: RecordKind::Component,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:loop".into()))],
            }],
        )
        .expect_err("the fence also catches the pre-corrupted doc");
        // Even bypassing ops for the top instance, lowering must terminate.
        d.store
            .insert(id("nd:top2"), RecordKind::Component, &pg, &Position::Last)
            .expect("store surgery 2");
        d.store
            .props_mut(&id("nd:top2"))
            .expect("props2")
            .set(key("ref"), Value::Str("cmp:loop".into()));
        let html2 = lower_page(&d.store, &tokens, &pg);
        assert!(html2.contains("expansion depth cap"), "the lowerer must not loop");
    }

    /// M4 scale check (the sans-IO stand-in for the expansion budget: the
    /// WALL-CLOCK metric belongs to the perf_floor ratchet bin per bench.rs
    /// — Instant::now is lint-walled out of core): 100 instances of a
    /// 10-node definition render EXACTLY the expected 1000 lines with fully
    /// namespaced ids, and the output scales linearly in bytes (no
    /// accidental quadratic duplication).
    #[test]
    fn expansion_scales_linearly_and_exactly() {
        let tokens = TokenStore::default_theme();
        let mut comp = DocState::new();
        let pg = Id::page(1);
        comp.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let def = Id::parse("cmp:block").expect("cmp");
        comp.store.insert_root(def.clone(), RecordKind::Frame).expect("def");
        let mut ops = Vec::new();
        for i in 0..10 {
            ops.push(CanvasOp::Insert {
                id: None,
                kind: RecordKind::Text,
                parent: def.clone(),
                pos: Position::Last,
                props: vec![(key("text"), Value::Str(format!("line {i}")))],
            });
        }
        for _ in 0..100 {
            ops.push(CanvasOp::Insert {
                id: None,
                kind: RecordKind::Component,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("ref"), Value::Str("cmp:block".into()))],
            });
        }
        comp.apply(0, &ops).expect("comp");
        let html10 = {
            // 10-instance reference for the linearity check.
            let mut small = DocState::new();
            let pg2 = Id::page(1);
            small.store.insert_root(pg2.clone(), RecordKind::Page).expect("root");
            let def2 = Id::parse("cmp:block").expect("cmp");
            small.store.insert_root(def2.clone(), RecordKind::Frame).expect("def");
            let mut ops2 = Vec::new();
            for i in 0..10 {
                ops2.push(CanvasOp::Insert {
                    id: None,
                    kind: RecordKind::Text,
                    parent: def2.clone(),
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str(format!("line {i}")))],
                });
            }
            for _ in 0..10 {
                ops2.push(CanvasOp::Insert {
                    id: None,
                    kind: RecordKind::Component,
                    parent: pg2.clone(),
                    pos: Position::Last,
                    props: vec![(key("ref"), Value::Str("cmp:block".into()))],
                });
            }
            small.apply(0, &ops2).expect("small");
            lower_page(&small.store, &tokens, &pg2)
        };
        let html100 = lower_page(&comp.store, &tokens, &pg);
        assert_eq!(html100.matches(">line 0<").count(), 100, "every instance rendered");
        assert_eq!(html100.matches("/nd:").count() % 100, 0, "namespacing uniform");
        // Linearity: 100 instances ≤ ~11× the 10-instance bytes (theme block
        // amortizes; a quadratic bug would blow far past this).
        assert!(
            html100.len() < html10.len() * 11,
            "output grew super-linearly: {} vs {}",
            html100.len(),
            html10.len()
        );
    }

    proptest::proptest! {
        /// Expansion never panics: arbitrary component/ref/text batches
        /// (some rejected by the fence — fine); lowering the surviving
        /// store is TOTAL.
        #[test]
        fn expansion_lowering_is_total(seed in proptest::collection::vec(0u8..5, 1..40)) {
            let mut d = DocState::new();
            let pg = Id::page(1);
            d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
            let def = Id::parse("cmp:a").expect("cmp");
            d.store.insert_root(def.clone(), RecordKind::Frame).expect("def");
            let def_b = Id::parse("cmp:b").expect("cmp");
            d.store.insert_root(def_b.clone(), RecordKind::Frame).expect("def b");
            let tokens = TokenStore::default_theme();
            for (i, b) in seed.iter().enumerate() {
                let rev = d.rev();
                let op = match b {
                    0 => CanvasOp::Insert {
                        id: None, kind: RecordKind::Text, parent: def.clone(),
                        pos: Position::Last,
                        props: vec![(key("text"), Value::Str(format!("d{i}")))],
                    },
                    1 => CanvasOp::Insert {
                        id: None, kind: RecordKind::Component, parent: pg.clone(),
                        pos: Position::Last,
                        props: vec![(key("ref"), Value::Str("cmp:a".into()))],
                    },
                    2 => CanvasOp::Insert {
                        id: None, kind: RecordKind::Component, parent: def_b.clone(),
                        pos: Position::Last,
                        props: vec![(key("ref"), Value::Str("cmp:a".into()))],
                    },
                    3 => CanvasOp::Insert {
                        // The CYCLE attempt: cmp:a instantiating cmp:b (which
                        // may instantiate cmp:a) — the fence may reject; both
                        // outcomes must leave a lowerable store.
                        id: None, kind: RecordKind::Component, parent: def.clone(),
                        pos: Position::Last,
                        props: vec![(key("ref"), Value::Str("cmp:b".into()))],
                    },
                    _ => CanvasOp::Insert {
                        id: None, kind: RecordKind::Component, parent: pg.clone(),
                        pos: Position::Last,
                        props: vec![(key("ref"), Value::Str("cmp:missing".into()))],
                    },
                };
                let _ = d.apply(rev, &[op]); // rejection is a legal outcome
                let html = lower_page(&d.store, &tokens, &pg);
                proptest::prop_assert!(!html.is_empty());
            }
        }
    }

    // MARK: M4.S2 — instance overrides

    #[test]
    fn instance_root_props_and_text_overrides_apply() {
        let (mut d, pg) = component_fixture();
        let tokens = TokenStore::default_theme();
        // Root-prop override + a text override on inst-a only.
        d.apply(
            1,
            &[CanvasOp::Update {
                id: id("nd:inst-a"),
                set: vec![
                    (key("fill"), Value::Token("color.accent".into())),
                    (key("overrides"),
                     Value::Str("{\"nd:card-title\": \"Overridden A\"}".into())),
                ],
                unset: vec![],
            }],
        )
        .expect("override");
        let html = lower_page(&d.store, &tokens, &pg);
        // The instance wrapper carries the root override.
        assert!(html.contains("background:var(--cv-color-accent)"));
        // inst-a shows the override; inst-b keeps the definition text.
        assert_eq!(html.matches(">Overridden A<").count(), 1, "{html}");
        assert_eq!(html.matches(">Card title<").count(), 1);
    }

    #[test]
    fn override_fence_rejects_bad_anchors_and_malformed_tables() {
        let (mut d, _pg) = component_fixture();
        // Anchor outside the definition.
        let bad_anchor = d.apply(
            1,
            &[CanvasOp::Update {
                id: id("nd:inst-a"),
                set: vec![(key("overrides"),
                           Value::Str("{\"nd:nope\": \"x\"}".into()))],
                unset: vec![],
            }],
        );
        assert!(bad_anchor.is_err(), "unknown anchor must be fenced");
        // Malformed JSON.
        let malformed = d.apply(
            1,
            &[CanvasOp::Update {
                id: id("nd:inst-a"),
                set: vec![(key("overrides"), Value::Str("not json".into()))],
                unset: vec![],
            }],
        );
        assert!(malformed.is_err(), "malformed table must be fenced");
        // Both rejected ATOMICALLY: the instance carries no overrides prop.
        let rec = d.store.get(&id("nd:inst-a")).expect("rec");
        assert!(PropKey::by_name("overrides")
            .and_then(|k| rec.props.get(k))
            .is_none());
    }

    #[test]
    fn overrides_survive_the_io_round_trip() {
        let (mut d, pg) = component_fixture();
        d.apply(
            1,
            &[CanvasOp::Update {
                id: id("nd:inst-a"),
                set: vec![(key("overrides"),
                           Value::Str("{\"nd:card-title\": \"Persisted\"}".into()))],
                unset: vec![],
            }],
        )
        .expect("override");
        let tokens = TokenStore::default_theme();
        let doc = crate::canvas::doc::CanvasDoc::from_parts(
            // Rebuild a CanvasDoc around this state for io (root = the page).
            core::mem::take(&mut d), tokens.clone(), pg.clone());
        let saved = crate::canvas::io::save(&doc);
        let loaded = crate::canvas::io::load(&saved).expect("load");
        assert!(loaded.html().contains(">Persisted<"), "override survives save/load");
    }

    // MARK: M4.S7a — table + code kinds

    #[test]
    fn table_lowers_real_rows_with_headers_and_escaping() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[CanvasOp::Insert {
            id: Some(id("nd:tbl")),
            kind: RecordKind::Table,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![
                (key("data"),
                 Value::Str("[[\"Plan\",\"Price\"],[\"Pro <b>\",\"$12\"]]".into())),
                (key("headers"), Value::Bool(true)),
            ],
        }]).expect("tbl");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("<table data-cv-id=\"nd:tbl\""));
        assert!(html.contains("<th>Plan</th><th>Price</th>"), "{html}");
        assert!(html.contains("<td>Pro &lt;b&gt;</td>"), "cells escape");
        assert!(html.contains("<td>$12</td>"));
    }

    #[test]
    fn invalid_table_data_renders_placeholder_and_lints() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[CanvasOp::Insert {
            id: Some(id("nd:bad")),
            kind: RecordKind::Table,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![(key("data"), Value::Str("{\"not\": \"rows\"}".into()))],
        }]).expect("bad");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("invalid table data"), "total lowering");
        let findings = crate::canvas::lint::run(&d, &tokens);
        assert!(findings.iter().any(|f| f.code == "table-data-invalid"));
    }

    #[test]
    fn code_lowers_escaped_pre_with_language() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[CanvasOp::Insert {
            id: Some(id("nd:snippet")),
            kind: RecordKind::Code,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![
                (key("text"), Value::Str("<script>alert(1)</script>".into())),
                (key("language"), Value::Str("html".into())),
            ],
        }]).expect("code");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("<pre data-cv-id=\"nd:snippet\""));
        assert!(html.contains("data-cv-lang=\"html\""));
        assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"),
                "code NEVER injects: {html}");
        assert!(!html.contains("<script>alert"), "no raw script");
    }

    #[test]
    fn chart_and_diagram_lower_through_the_dsl() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let dsl_src = "chart #sales spec=\"{\\\"mark\\\":\\\"bar\\\",\\\"values\\\":[{\\\"label\\\":\\\"Q1\\\",\\\"value\\\":10}]}\"\ndiagram #flow \"graph TD; A-->B\"";
        let ops = crate::canvas::dsl::parse_fragment(dsl_src, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("data-cv-kind=\"chart\""));
        assert!(html.contains("<svg"), "{html}");
        assert!(html.contains("var(--cv-color-accent)"), "charts retheme");
        assert!(html.contains("data-cv-kind=\"diagram\""));
        assert!(html.contains("graph TD; A--&gt;B"), "diagram source escapes");
        // Bad spec: placeholder + lint.
        d.apply(1, &[CanvasOp::Insert {
            id: Some(id("nd:badchart")),
            kind: RecordKind::Chart,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![(key("spec"), Value::Str("nope".into()))],
        }]).expect("bad chart");
        let html2 = lower_page(&d.store, &tokens, &pg);
        assert!(html2.contains("invalid chart spec"));
        let findings = crate::canvas::lint::run(&d, &tokens);
        assert!(findings.iter().any(|f| f.code == "chart-spec-invalid"));
    }

    // MARK: M5.S2 — artboard chrome

    // MARK: M5.S3 — fragment export

    // MARK: M5.S6 — prototype nav (linkTo)

    #[test]
    fn columns_prop_lowers_a_container_to_a_grid() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let dsl_src = "frame #grid columns=3 gap=16 {\n  text #a \"a\"\n  text #b \"b\"\n}\nframe #plain gap=8 {\n  text #c \"c\"\n}";
        let ops = crate::canvas::dsl::parse_fragment(dsl_src, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        // The grid container: display:grid + 3 equal columns; NOT flex.
        assert!(html.contains("display:grid;grid-template-columns:repeat(3,minmax(0,1fr))"), "{html}");
        // The plain frame stays flex (columns is opt-in).
        assert!(html.contains("display:flex;flex-direction:column;"), "plain frame unchanged");
        // Exactly one grid container.
        assert_eq!(html.matches("display:grid").count(), 1);
    }

    #[test]
    fn linkto_lowers_to_data_cv_link_and_dangling_lints() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let src_dsl = "frame #ab role=artboard {\n  text #inner \"x\"\n}\ntext #nav \"Go\" linkTo=#ab\ntext #broken \"Bad\" linkTo=#ghost";
        let ops = crate::canvas::dsl::parse_fragment(src_dsl, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        // The link resolves to the target dom id.
        assert!(html.contains("data-cv-link=\"nd:ab\""), "{html}");
        // Dangling link lints; the live one does not.
        let findings = crate::canvas::lint::run(&d, &tokens);
        let dangling: Vec<_> = findings.iter()
            .filter(|f| f.code == "dangling-link").collect();
        assert_eq!(dangling.len(), 1, "only the ghost link lints");
        assert_eq!(dangling[0].id.as_ref().map(|i| i.as_str()), Some("nd:broken"));
    }

    #[test]
    fn fragment_inlines_token_literals_and_omits_the_theme_block() {
        // A named dashed token so the ambiguous-reverse trap is exercised.
        let mut doc = crate::canvas::doc::CanvasDoc::new_empty();
        // Token-only batch leaves rev unmoved (M4.S4) — both applies at 0.
        doc.apply_dsl(0, "token set base.gray-1 #abcdef").expect("tok");
        doc.apply_dsl(0, "frame #board role=artboard fill=$base.gray-1 {\n  text #t \"hi\" color=$color.accent\n}").expect("apply");

        let board = Id::parse("nd:board").expect("id");
        let fragment = doc.render_fragment(&board).expect("fragment");
        // NO theme block.
        assert!(!fragment.contains("<style"), "fragment has no theme: {fragment}");
        assert!(!fragment.contains("cv-theme"));
        // var() refs are GONE — inlined to literals (dashed path resolved exactly).
        assert!(!fragment.contains("var(--cv-"), "no var refs remain: {fragment}");
        assert!(fragment.contains("#abcdef"), "the dashed token literal inlined");
        // Scoped to the artboard subtree.
        assert!(fragment.contains(">hi<"));
        assert!(fragment.contains("data-cv-id=\"nd:board\""));
        // A missing node yields None.
        assert!(doc.render_fragment(&Id::parse("nd:nope").expect("id")).is_none());
    }

    #[test]
    fn artboards_get_labeled_chrome_and_plain_frames_do_not() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let dsl_src = "frame #board role=artboard note=\"Desktop — 1280\" minW=1280 maxW=1280 {\n  text #inside \"content\"\n}\nframe #plain gap=8 {\n  text #other \"plain\"\n}";
        let ops = crate::canvas::dsl::parse_fragment(dsl_src, &pg).expect("parse");
        d.apply(0, &ops).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = lower_page(&d.store, &tokens, &pg);
        // The artboard: outline + the label strip (token-colored chrome).
        assert!(html.contains("outline:1px solid var(--cv-color-border)"), "{html}");
        assert!(html.contains(">Desktop — 1280</div>"), "label renders");
        assert!(html.contains("var(--cv-color-muted)"), "chrome rethemes");
        // The plain frame: NO chrome (count the outline exactly once).
        assert_eq!(html.matches("outline:1px solid").count(), 1);
        // The label is NOT addressable (no data-cv-id on chrome): the label
        // strip's opening tag carries only a style attribute.
        assert!(
            html.contains("margin:-2px 0 6px 0\">Desktop — 1280</div>"),
            "the label renders inside the style-only chrome div"
        );
        assert!(
            !html.contains("data-cv-id=\"nd:board\" data-cv-kind=\"frame\">Desktop"),
            "the label is not the artboard node's direct text"
        );
        // Both artboard viewport presets live on the ADDRESSABLE node.
        assert!(html.contains("min-width:1280px"));
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
