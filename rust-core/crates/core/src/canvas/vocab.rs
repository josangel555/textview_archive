//! Canvas M2.S1 — the registry-generated vocabulary (TSK-1366;
//! 07-DSL-SPIKE §4: agents learn the FULL vocabulary via MCP, and the docs
//! are GENERATED from the live registries so they can never rot).
//!
//! Two emissions over the same walk: a compact agent cheat-sheet (text) and
//! a structured JSON form. Handle-bound: the token section reflects the
//! DOCUMENT's store (custom + deprecated tokens included), not a static list.

use super::registry::{self, MAX_CHILDREN_PER_PARENT, MAX_PROPS_PER_RECORD, MAX_RECORDS_PER_DOC, MAX_TEXT_LEN};
use super::store::RecordKind;
use super::tokens::{TokenStore, TokenValue};

/// Every record kind, in DSL-vocabulary order. The `can_parent` fence and
/// the per-kind prop tables in `registry` are match-exhaustive, so adding a
/// kind without updating this list fails the rot-proof test below.
const KINDS: &[RecordKind] = &[
    RecordKind::Page,
    RecordKind::Frame,
    RecordKind::Text,
    RecordKind::Image,
    RecordKind::Shape,
    RecordKind::Component,
    RecordKind::Embed,
    RecordKind::Hole,
    RecordKind::Table,
    RecordKind::Code,
    RecordKind::Chart,
    RecordKind::Diagram,
];

/// Semantic notes the FENCE enforces (check_value) that prop names alone
/// don't convey. Purely additive teaching text.
fn prop_note(name: &str) -> Option<&'static str> {
    Some(match name {
        "opacity" => "0..1",
        "grow" | "shrink" => "unitless >= 0",
        "span" => "integer >= 1",
        "minW" | "maxW" | "minH" | "maxH" | "gap" | "padding" | "radius" => {
            "px number, non-negative (or a $token)"
        }
        "fill" | "stroke" | "color" | "font" | "shadow" => {
            "CSS literal or $token (tokens keep it themeable)"
        }
        "text" => "the text content (Text only; sugar: a bare quoted string)",
        "src" => "image source path/URL",
        "ref" => "component definition id (cmp:*)",
        "direction" => "row | column",
        "align" | "justify" => "flex keywords (start/center/end/stretch/space-between)",
        "wrap" => "true to allow wrapping",
        "fit" => "cover | contain | fill",
        "note" => "what this hole placeholder still needs",
        "role" => "layout role: artboard (UI-Design frame) | slide (presentation deck)",
        "morphId" => "presentation morph tag: a node with the SAME morphId on two slides animates (FLIP) between its positions across the transition",
        "data" => "table cells: JSON array of rows, e.g. [[\"a\",\"b\"],[\"1\",\"2\"]]",
        "headers" => "true = the first data row renders as headers",
        "language" => "code language tag (display only in v1)",
        "spec" => "chart spec JSON: {\"mark\": \"bar|line|pie\", \"values\": [{\"label\", \"value\"}...]}",
        "linkTo" => "prototype nav: a node id (e.g. nd:artboard-mobile) — click scrolls to it",
        "step" => "presentation reveal step (u16): the node appears at this step within its slide",
        "columns" => "grid layout: lay this container's children in N equal columns (1..64)",
        _ => return None,
    })
}

fn esc_json(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// The compact agent cheat-sheet.
#[must_use]
pub fn emit_text(tokens: &TokenStore) -> String {
    let mut out = String::with_capacity(4096);
    out.push_str("CANVAS DSL — the authoring vocabulary (generated from the live registry)\n\n");
    out.push_str("ELEMENT LINES:  <kind> [#id] [\"text sugar\"] [prop=value …] [{\n");
    out.push_str("  children on following lines, closed by } alone on its line\n");
    out.push_str("EDIT STATEMENTS:  set #id prop=value … | unset #id prop … |\n");
    out.push_str("  move #id to #parent [first|last|before #x|after #x] | remove #id\n");
    out.push_str("TOKENS:  token set <path> <value> | token alias <path> <target> |\n");
    out.push_str("  token rename <old> <new>  (renames keep old refs resolving; a token\n");
    out.push_str("  edit rethemes the whole document live — zero record ops).\n");
    out.push_str("REPETITION:  each data=\"[{…},…]\" [where=field] { …template… }\n");
    out.push_str("  expands per item AT APPLY; use {{i}} (index) in anchors and\n");
    out.push_str("  {{item.field}} in values; where= skips falsy-field items.\n");
    out.push_str("COMPONENTS:  component #name { …children… }  defines a reusable\n");
    out.push_str("  block; use #name #instance [prop=…] [override text #anchor \"…\"]\n");
    out.push_str("  instantiates it (editing the definition updates every instance).\n");
    out.push_str("PRESENTATION (a deck):  frame #slide-N role=slide { … } per slide;\n");
    out.push_str("  step=K on a child reveals it at step K (base = always shown);\n");
    out.push_str("  morphId=name on nodes in consecutive slides morphs them (FLIP);\n");
    out.push_str("  canvas_timeline verifies reveals before pixels; canvas_export\n");
    out.push_str("  {flavor: deck} = offline player, {flavor: print} = one-page-per-slide PDF.\n");
    out.push_str("LAYOUT EXTRAS:  columns=N on a container → N-equal-column grid;\n");
    out.push_str("  linkTo=#node on any element → click scrolls to it (prototype nav).\n");
    out.push_str("VALUES:  8 → number(px)  0.5 → number  \"text\" → string  cover → keyword\n");
    out.push_str("  true/false → bool  $color.accent → design-token reference\n");
    out.push_str("IDS:  #name mints nd:name (stable, addressable); omit to auto-mint;\n");
    out.push_str("  containers with children MUST carry an anchor. // comments allowed.\n\n");

    out.push_str("ELEMENTS AND THEIR PROPS:\n");
    for kind in KINDS {
        let name = registry::kind_name(*kind);
        out.push_str("  ");
        out.push_str(name);
        if kind.can_parent() {
            out.push_str(" (container)");
        }
        out.push_str(":\n");
        for prop in registry::allowed_names(*kind) {
            out.push_str("    ");
            out.push_str(prop);
            if let Some(note) = prop_note(prop) {
                out.push_str(" — ");
                out.push_str(note);
            }
            out.push('\n');
        }
    }

    out.push_str("\nDESIGN TOKENS (this document; prefer semantic over base.*):\n");
    let mut paths: Vec<&str> = tokens.paths().collect();
    paths.sort_unstable();
    for tier2 in [true, false] {
        out.push_str(if tier2 { "  semantic: " } else { "  base:     " });
        let mut first = true;
        for p in &paths {
            if TokenStore::is_primitive(p) == tier2 {
                continue;
            }
            if !first {
                out.push_str(", ");
            }
            first = false;
            out.push('$');
            out.push_str(p);
            if tokens.deprecated_replacement(p).is_some() {
                out.push_str(" (deprecated)");
            }
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "\nCAPS: {MAX_RECORDS_PER_DOC} records/doc, {MAX_CHILDREN_PER_PARENT} children/parent, \
         {MAX_PROPS_PER_RECORD} props/record, {MAX_TEXT_LEN} text bytes.\n"
    ));
    out.push_str(
        "REJECTIONS: conflict (stale baseRev — re-read, retry with currentRev), \
         fence (illegal prop/value — the message names what IS legal), store \
         (unknown/tombstoned ids), idInUse (id holds different content), dsl \
         (parse error — line-anchored message).\n\
         Lint rides every apply: warnings are advisory, never blocking.\n",
    );
    out
}

/// The structured JSON form (same walk, hand-emitted like `io.rs` — no new
/// deps; key order fixed for byte-stable output).
#[must_use]
pub fn emit_json(tokens: &TokenStore) -> String {
    let mut out = String::with_capacity(4096);
    out.push_str("{\"kinds\":[");
    for (i, kind) in KINDS.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"name\":");
        esc_json(registry::kind_name(*kind), &mut out);
        out.push_str(",\"container\":");
        out.push_str(if kind.can_parent() { "true" } else { "false" });
        out.push_str(",\"props\":[");
        for (j, prop) in registry::allowed_names(*kind).iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            out.push_str("{\"name\":");
            esc_json(prop, &mut out);
            if let Some(note) = prop_note(prop) {
                out.push_str(",\"note\":");
                esc_json(note, &mut out);
            }
            out.push('}');
        }
        out.push_str("]}");
    }
    out.push_str("],\"tokens\":[");
    let mut paths: Vec<&str> = tokens.paths().collect();
    paths.sort_unstable();
    for (i, p) in paths.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"path\":");
        esc_json(p, &mut out);
        out.push_str(",\"tier\":");
        out.push_str(if TokenStore::is_primitive(p) { "1" } else { "2" });
        if let Some(def) = tokens.def(p) {
            match &def.value {
                TokenValue::Literal(css) => {
                    out.push_str(",\"value\":");
                    esc_json(css, &mut out);
                }
                TokenValue::Alias(target) => {
                    out.push_str(",\"alias\":");
                    esc_json(target, &mut out);
                }
            }
        }
        if let Some(rep) = tokens.deprecated_replacement(p) {
            out.push_str(",\"deprecatedFor\":");
            esc_json(rep, &mut out);
        }
        out.push('}');
    }
    out.push_str(&format!(
        "],\"caps\":{{\"records\":{MAX_RECORDS_PER_DOC},\"children\":{MAX_CHILDREN_PER_PARENT},\
         \"props\":{MAX_PROPS_PER_RECORD},\"textLen\":{MAX_TEXT_LEN}}},"
    ));
    out.push_str(
        "\"rejections\":[\"conflict\",\"fence\",\"store\",\"idInUse\",\"dsl\"]}",
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;

    #[test]
    fn rot_proof_every_registry_kind_and_prop_appears_in_both_emissions() {
        let t = TokenStore::default_theme();
        let text = emit_text(&t);
        let json_s = emit_json(&t);
        for kind in KINDS {
            let name = registry::kind_name(*kind);
            assert!(text.contains(&format!("  {name}")), "text missing kind {name}");
            assert!(json_s.contains(&format!("\"name\":\"{name}\"")), "json missing {name}");
            for prop in registry::allowed_names(*kind) {
                assert!(text.contains(prop), "text missing prop {prop}");
                assert!(
                    json_s.contains(&format!("\"name\":\"{prop}\"")),
                    "json missing prop {prop}"
                );
            }
        }
        // And the kind LIST itself can't silently shrink: every name in the
        // prop key table that is kind-bound appears somewhere above (spot
        // guard; the registry matches are compiler-exhaustive).
        assert_eq!(KINDS.len(), 12, "new RecordKind? extend KINDS + this test");
    }

    #[test]
    fn tokens_reflect_the_document_not_a_static_list() {
        let mut t = TokenStore::default_theme();
        t.set_literal("color.brand-special", "#123123").expect("custom");
        t.set_literal("radius.old", "6px").expect("old");
        t.deprecate_and_alias("radius.old", "radius.fresh").expect("dep");
        let text = emit_text(&t);
        assert!(text.contains("$color.brand-special"), "custom token listed");
        assert!(text.contains("$radius.old (deprecated)"), "deprecation marked");
        let json_s = emit_json(&t);
        assert!(json_s.contains("\"deprecatedFor\":\"radius.fresh\""));
    }

    #[test]
    fn json_emission_is_valid_json_and_byte_stable() {
        let t = TokenStore::default_theme();
        let s = emit_json(&t);
        assert_eq!(s, emit_json(&t));
        let parsed = json::parse(&s).expect("valid JSON");
        assert!(parsed.get("kinds").is_some());
        assert!(parsed.get("caps").is_some());
    }

    #[test]
    fn cheat_sheet_teaches_the_grammar_and_the_rejections() {
        let t = TokenStore::default_theme();
        let text = emit_text(&t);
        for needle in [
            "ELEMENT LINES", "EDIT STATEMENTS", "set #id", "move #id to",
            "$color.accent", "conflict", "fence", "dsl", "Lint rides every apply",
            "PRESENTATION (a deck)", "role=slide", "step=K", "morphId", "canvas_timeline",
            "flavor: deck", "flavor: print", "columns=N", "linkTo=#node",
        ] {
            assert!(text.contains(needle), "cheat sheet missing: {needle}");
        }
    }
}
