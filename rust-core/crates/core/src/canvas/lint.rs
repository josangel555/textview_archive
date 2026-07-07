//! Canvas M1.S6 — static lint (TSK-1361; 02-CORE-ENGINE §8).
//!
//! The STATIC stage of the two-stage lint: everything provable from the
//! document + token store alone, no browser. Flow content is overlap-free by
//! construction (the layout guarantee), so the static stage focuses on
//! reference health and token discipline. Results are advisory (`Warn`/`Info`)
//! and RIDE EVERY APPLY — the agent sees problems without asking (the
//! LIDA/DesignAsCode close-the-loop lesson). Measured lint (geometry,
//! contrast-in-context) is the JS shell's stage and merges at the tool layer.

use super::ops::DocState;
use super::props::{PropKey, Value};
use super::store::{Id, RecordKind};
use super::tokens::TokenStore;

/// Advisory severity (the fence REJECTS; lint only advises).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LintSeverity {
    /// Likely wrong (dangling reference, unknown token).
    Warn,
    /// Style/discipline steer (raw literal in a themeable slot, tier-1 ref).
    Info,
}

/// One finding. `code` is stable vocabulary (tests + agents key on it).
#[derive(Debug, Clone, PartialEq, Eq)]
/// One lint finding.
pub struct Lint {
    /// How strongly to surface it.
    pub severity: LintSeverity,
    /// Stable rule code (greppable).
    pub code: &'static str,
    /// The offending element, when element-scoped.
    pub id: Option<Id>,
    /// Human-readable finding.
    pub message: String,
}

/// Themeable slots — literals here defeat retheming (the tier-2 steer).
const THEMEABLE: &[&str] = &["fill", "stroke", "color", "font", "radius", "shadow"];

/// Long unclamped text — the flow model's one bounded failure mode.
const LONG_TEXT: usize = 200;

/// Run the full static lint over the document.
#[must_use]
pub fn run(doc: &DocState, tokens: &TokenStore) -> Vec<Lint> {
    let mut findings: Vec<Lint> = Vec::new();
    let mut ids: Vec<&Id> = doc.store.ids().collect();
    ids.sort();
    for id in ids {
        let Some(rec) = doc.store.get(id) else { continue };
        for (key, value) in rec.props.iter() {
            lint_prop(id, key, value, tokens, &mut findings);
        }
        // M6.S2: a `step` (presentation reveal) only makes sense inside a
        // slide — an orphan step reveals nothing.
        if PropKey::by_name("step").is_some_and(|k| rec.props.get(k).is_some())
            && !under_slide(&doc.store, id)
        {
            findings.push(Lint {
                severity: LintSeverity::Warn,
                code: "orphan-step",
                id: Some(id.clone()),
                message: "step is set on a node outside any role=slide frame —                           the presentation player only reveals within slides"
                    .to_owned(),
            });
        }
        // M5.S6: a linkTo (prototype nav) must reference a live node.
        if let Some(Value::Str(target)) = PropKey::by_name("linkTo")
            .and_then(|k| rec.props.get(k))
        {
            let ok = Id::parse(target).is_ok_and(|t| doc.store.get(&t).is_some());
            if !ok {
                findings.push(Lint {
                    severity: LintSeverity::Warn,
                    code: "dangling-link",
                    id: Some(id.clone()),
                    message: format!(
                        "linkTo target '{target}' does not exist (link an existing \
                         node id, e.g. an artboard)"
                    ),
                });
            }
        }
        match rec.kind {
            RecordKind::Hole => {
                let note = PropKey::by_name("note")
                    .and_then(|k| rec.props.get(k))
                    .and_then(|v| match v {
                        Value::Str(s) => Some(s.clone()),
                        _ => None,
                    })
                    .unwrap_or_default();
                findings.push(Lint {
                    severity: LintSeverity::Info,
                    code: "hole",
                    id: Some(id.clone()),
                    message: format!("placeholder outstanding: {note}"),
                });
            }
            RecordKind::Component => {
                let dangling = !PropKey::by_name("ref")
                    .and_then(|k| rec.props.get(k))
                    .is_some_and(|v| match v {
                        Value::Str(target) => Id::parse(target)
                            .is_ok_and(|t| doc.store.get(&t).is_some()),
                        _ => false,
                    });
                if dangling {
                    findings.push(Lint {
                        severity: LintSeverity::Warn,
                        code: "dangling-ref",
                        id: Some(id.clone()),
                        message: "component instance references no known definition \
                                  (define it, or detach the instance)"
                            .to_owned(),
                    });
                }
            }
            RecordKind::Table => {
                let data_ok = PropKey::by_name("data")
                    .and_then(|k| rec.props.get(k))
                    .is_some_and(|v| matches!(v, Value::Str(s)
                        if super::lower::table_data_is_valid(s)));
                if !data_ok {
                    findings.push(Lint {
                        severity: LintSeverity::Warn,
                        code: "table-data-invalid",
                        id: Some(id.clone()),
                        message: "table needs a `data` prop holding a JSON array of \
                                  rows (e.g. [[\"a\",\"b\"],[\"1\",\"2\"]])"
                            .to_owned(),
                    });
                }
            }
            RecordKind::Chart => {
                let spec_ok = PropKey::by_name("spec")
                    .and_then(|k| rec.props.get(k))
                    .is_some_and(|v| matches!(v, Value::Str(s)
                        if super::chart::parse_spec(s).is_some()));
                if !spec_ok {
                    findings.push(Lint {
                        severity: LintSeverity::Warn,
                        code: "chart-spec-invalid",
                        id: Some(id.clone()),
                        message: "chart needs a `spec` prop: {\"mark\": \
                                  \"bar|line|pie\", \"values\": [{\"label\", \
                                  \"value\"}…]} (1..=1000 non-negative values)"
                            .to_owned(),
                    });
                }
            }
            RecordKind::Text => {
                let long = PropKey::by_name("text")
                    .and_then(|k| rec.props.get(k))
                    .is_some_and(|v| matches!(v, Value::Str(s) if s.len() > LONG_TEXT));
                let clamped = PropKey::by_name("maxW")
                    .and_then(|k| rec.props.get(k))
                    .is_some();
                if long && !clamped {
                    findings.push(Lint {
                        severity: LintSeverity::Info,
                        code: "text-unclamped",
                        id: Some(id.clone()),
                        message: format!(
                            "text over {LONG_TEXT} chars without maxW — long runs \
                             inflate hug containers (add a clamp)"
                        ),
                    });
                }
            }
            _ => {}
        }
    }
    findings
}

fn lint_prop(
    id: &Id,
    key: PropKey,
    value: &Value,
    tokens: &TokenStore,
    findings: &mut Vec<Lint>,
) {
    let Some(name) = key.name() else { return };
    match value {
        Value::Token(path) => {
            if !tokens.exists(path) {
                findings.push(Lint {
                    severity: LintSeverity::Warn,
                    code: "token-unknown",
                    id: Some(id.clone()),
                    message: format!("'{name}' references unknown token '{path}'"),
                });
            } else {
                if TokenStore::is_primitive(path) {
                    findings.push(Lint {
                        severity: LintSeverity::Info,
                        code: "token-primitive",
                        id: Some(id.clone()),
                        message: format!(
                            "'{name}' references tier-1 primitive '{path}' — prefer a \
                             semantic token so theming holds"
                        ),
                    });
                }
                if let Some(replacement) = tokens.deprecated_replacement(path) {
                    findings.push(Lint {
                        severity: LintSeverity::Info,
                        code: "token-deprecated",
                        id: Some(id.clone()),
                        message: format!(
                            "'{name}' references deprecated '{path}' — use '{replacement}'"
                        ),
                    });
                }
            }
        }
        Value::Str(_) | Value::Num(_) => {
            if THEMEABLE.contains(&name) {
                findings.push(Lint {
                    severity: LintSeverity::Info,
                    code: "raw-literal-themeable",
                    id: Some(id.clone()),
                    message: format!(
                        "'{name}' holds a raw literal — a token keeps it themeable"
                    ),
                });
            }
        }
        Value::Bool(_) => {}
    }
}

/// True when `id` has an ancestor frame with role=slide (M6.S2).
fn under_slide(store: &super::store::Store, id: &Id) -> bool {
    let mut cursor = store.get(id).and_then(|r| r.place.as_ref()).map(|p| p.parent.clone());
    while let Some(pid) = cursor {
        if let Some(rec) = store.get(&pid) {
            let is_slide = PropKey::by_name("role")
                .and_then(|k| rec.props.get(k))
                .is_some_and(|v| matches!(v, Value::Str(s) if s == "slide"));
            if is_slide {
                return true;
            }
            cursor = rec.place.as_ref().map(|p| p.parent.clone());
        } else {
            break;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::ops::CanvasOp;
    use crate::canvas::store::Position;

    fn id(s: &str) -> Id {
        Id::parse(s).expect("id")
    }
    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    fn doc() -> (DocState, TokenStore, Id) {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        (d, TokenStore::default_theme(), pg)
    }

    fn codes(findings: &[Lint]) -> Vec<&'static str> {
        findings.iter().map(|l| l.code).collect()
    }

    #[test]
    fn clean_doc_lints_clean() {
        let (mut d, t, pg) = doc();
        d.apply(
            0,
            &[CanvasOp::Insert {
                id: Some(id("nd:a")),
                kind: RecordKind::Text,
                parent: pg,
                pos: Position::Last,
                props: vec![
                    (key("text"), Value::Str("hi".to_owned())),
                    (key("color"), Value::Token("color.fg".to_owned())),
                ],
            }],
        )
        .expect("seed");
        assert!(run(&d, &t).is_empty());
    }

    #[test]
    fn token_health_findings() {
        let (mut d, mut t, pg) = doc();
        t.set_literal("base.special", "#123456").expect("lit");
        t.set_literal("radius.old", "6px").expect("lit2");
        t.deprecate_and_alias("radius.old", "radius.fresh").expect("rename");
        d.apply(
            0,
            &[CanvasOp::Insert {
                id: Some(id("nd:a")),
                kind: RecordKind::Shape,
                parent: pg,
                pos: Position::Last,
                props: vec![
                    (key("fill"), Value::Token("color.nope".to_owned())),
                    (key("stroke"), Value::Token("base.special".to_owned())),
                    (key("radius"), Value::Token("radius.old".to_owned())),
                ],
            }],
        )
        .expect("seed");
        let findings = run(&d, &t);
        let cs = codes(&findings);
        assert!(cs.contains(&"token-unknown"));
        assert!(cs.contains(&"token-primitive"));
        assert!(cs.contains(&"token-deprecated"));
        // The deprecated finding names the replacement.
        let dep = findings.iter().find(|l| l.code == "token-deprecated").expect("dep");
        assert!(dep.message.contains("radius.fresh"));
    }

    #[test]
    fn raw_literal_nag_is_themeable_slots_only() {
        let (mut d, t, pg) = doc();
        d.apply(
            0,
            &[CanvasOp::Insert {
                id: Some(id("nd:a")),
                kind: RecordKind::Shape,
                parent: pg,
                pos: Position::Last,
                props: vec![
                    (key("fill"), Value::Str("#ff0000".to_owned())), // themeable → nag
                    (key("opacity"), Value::Num(0.5)),               // not themeable → quiet
                ],
            }],
        )
        .expect("seed");
        let findings = run(&d, &t);
        assert_eq!(codes(&findings), vec!["raw-literal-themeable"]);
    }

    #[test]
    fn holes_dangling_refs_and_long_text_surface() {
        let (mut d, t, pg) = doc();
        let long = "x".repeat(300);
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:h")),
                    kind: RecordKind::Hole,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("note"), Value::Str("finish the chart".to_owned()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:c")),
                    kind: RecordKind::Component,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("ref"), Value::Str("cmp:kpi".to_owned()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:t")),
                    kind: RecordKind::Text,
                    parent: pg,
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str(long))],
                },
            ],
        )
        .expect("seed");
        let findings = run(&d, &t);
        let cs = codes(&findings);
        assert!(cs.contains(&"hole"));
        assert!(cs.contains(&"dangling-ref"));
        assert!(cs.contains(&"text-unclamped"));
        // The hole finding carries its note.
        let hole = findings.iter().find(|l| l.code == "hole").expect("hole");
        assert!(hole.message.contains("finish the chart"));
    }
}
