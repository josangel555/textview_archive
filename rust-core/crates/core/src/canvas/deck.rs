//! Canvas M6 — the presentation TIME model (TSK-1396; M6-PLAN §S2). PURE,
//! sans-IO, deterministic: the `step` prop is GENERAL node state (any doc may
//! carry it — the thin-mode law: presentation mode just gives it a player),
//! and `timeline_state` computes which nodes are visible at a given step.
//!
//! Reveal rule (the SINGLE source of truth — the JS player mirrors it byte
//! for byte in S4): a node is visible at `step` iff it has no `step` prop
//! (base content, always shown) OR its `step` value is ≤ the current step.

use super::props::{PropKey, Value};
use super::store::{Id, Store};

/// The reveal step of a node: `Some(n)` if it carries a `step` prop, else
/// `None` (base content). Negative / non-integer values clamp to 0.
#[must_use]
pub fn node_step(store: &Store, id: &Id) -> Option<u16> {
    let rec = store.get(id)?;
    let key = PropKey::by_name("step")?;
    match rec.props.get(key) {
        Some(Value::Num(n)) if *n >= 0.0 => {
            // Steps are small; clamp defensively to u16.
            #[allow(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "clamped non-negative, bounded below"
            )]
            Some((*n).min(f64::from(u16::MAX)) as u16)
        }
        Some(Value::Num(_)) => Some(0),
        _ => None,
    }
}

/// Every descendant id of `root` (excluding `root` itself), in a stable
/// pre-order walk.
fn descendants(store: &Store, root: &Id) -> Vec<Id> {
    let mut out = Vec::new();
    let mut stack: Vec<Id> = store.children(root);
    stack.reverse(); // pre-order, children in document order
    while let Some(id) = stack.pop() {
        let kids = store.children(&id);
        out.push(id);
        for kid in kids.into_iter().rev() {
            stack.push(kid);
        }
    }
    out
}

/// The highest step under `slide` (0 when the slide has no stepped nodes) —
/// the number of ADVANCES the slide supports (step count = max_step).
#[must_use]
pub fn max_step(store: &Store, slide: &Id) -> u16 {
    descendants(store, slide)
        .iter()
        .filter_map(|id| node_step(store, id))
        .max()
        .unwrap_or(0)
}

/// The visible descendant ids of `slide` at `step` — sorted for
/// determinism. A node is visible iff it has no `step` (base) or step ≤ the
/// current step. (Ancestry is NOT gated here: a stepped child inside a base
/// frame reveals independently; the frame stays shown. Tier-1 semantics.)
#[must_use]
pub fn visible_at(store: &Store, slide: &Id, step: u16) -> Vec<Id> {
    let mut out: Vec<Id> = descendants(store, slide)
        .into_iter()
        .filter(|id| node_step(store, id).is_none_or(|s| s <= step))
        .collect();
    out.sort();
    out
}

/// One step's declarative snapshot: the step index + the visible id set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepState {
    pub step: u16,
    pub visible_ids: Vec<String>,
}

/// The full timeline of a slide: the step count and, for each step 0..=max,
/// the visible-id snapshot. This is the DECLARATIVE verification surface the
/// agent checks BEFORE any pixel (06 success #3).
#[must_use]
pub fn timeline_state(store: &Store, slide: &Id) -> Vec<StepState> {
    let steps = max_step(store, slide);
    (0..=steps)
        .map(|step| StepState {
            step,
            visible_ids: visible_at(store, slide, step)
                .iter()
                .map(|id| id.as_str().to_owned())
                .collect(),
        })
        .collect()
}

/// All `role=slide` frame ids in the document, in document (frac-index)
/// order — the deck's slide sequence.
#[must_use]
pub fn slide_ids(store: &Store) -> Vec<Id> {
    // Slides are role=slide frames; collect from a full walk, ordered by the
    // stable child order under each parent. A page-child walk suffices for
    // v1 decks (slides are page children), but we scan all ids to be robust
    // and then sort by the same frac-index the store exposes via children().
    let mut ids: Vec<Id> = store
        .ids()
        .filter(|id| {
            store.get(id).is_some_and(|rec| {
                PropKey::by_name("role")
                    .and_then(|k| rec.props.get(k))
                    .is_some_and(|v| matches!(v, Value::Str(s) if s == "slide"))
            })
        })
        .cloned()
        .collect();
    // Order by document position: a slide's ancestry+index. Sorting by id is
    // NOT document order, so order by each slide's place index string within
    // its parent (page-level slides share a parent → the frac index sorts).
    ids.sort_by(|a, b| {
        let ka = store.get(a).and_then(|r| r.place.as_ref()).map(|p| p.index.as_str().to_owned());
        let kb = store.get(b).and_then(|r| r.place.as_ref()).map(|p| p.index.as_str().to_owned());
        ka.cmp(&kb).then_with(|| a.as_str().cmp(b.as_str()))
    });
    ids
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

/// The whole deck's timeline as canonical JSON (M6.S3): the declarative
/// verification surface the agent reads before any pixel.
/// `{"slides":[{"id","stepCount","steps":[{"step","visibleIds":[...]}]}]}`
#[must_use]
pub fn timeline_json(store: &Store) -> String {
    let mut out = String::from("{\"slides\":[");
    for (si, slide) in slide_ids(store).iter().enumerate() {
        if si > 0 {
            out.push(',');
        }
        let states = timeline_state(store, slide);
        out.push_str("{\"id\":");
        esc_json(slide.as_str(), &mut out);
        out.push_str(",\"stepCount\":");
        out.push_str(&max_step(store, slide).to_string());
        out.push_str(",\"steps\":[");
        for (i, st) in states.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"step\":");
            out.push_str(&st.step.to_string());
            out.push_str(",\"visibleIds\":[");
            for (j, v) in st.visible_ids.iter().enumerate() {
                if j > 0 {
                    out.push(',');
                }
                esc_json(v, &mut out);
            }
            out.push_str("]}");
        }
        out.push_str("]}");
    }
    out.push_str("]}");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::ops::{CanvasOp, DocState};
    use crate::canvas::store::{Position, RecordKind};

    fn id(s: &str) -> Id {
        Id::parse(s).expect("id")
    }
    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    /// A slide with base content + two stepped reveals.
    fn deck() -> (DocState, Id) {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:slide")),
                    kind: RecordKind::Frame,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("role"), Value::Str("slide".to_owned()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:title")),
                    kind: RecordKind::Text,
                    parent: id("nd:slide"),
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str("Base".to_owned()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:b1")),
                    kind: RecordKind::Text,
                    parent: id("nd:slide"),
                    pos: Position::Last,
                    props: vec![
                        (key("text"), Value::Str("First".to_owned())),
                        (key("step"), Value::Num(1.0)),
                    ],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:b2")),
                    kind: RecordKind::Text,
                    parent: id("nd:slide"),
                    pos: Position::Last,
                    props: vec![
                        (key("text"), Value::Str("Second".to_owned())),
                        (key("step"), Value::Num(2.0)),
                    ],
                },
            ],
        )
        .expect("apply");
        (d, id("nd:slide"))
    }

    #[test]
    fn max_step_counts_the_advances() {
        let (d, slide) = deck();
        assert_eq!(max_step(&d.store, &slide), 2);
    }

    #[test]
    fn visibility_is_monotonic_and_base_always_shows() {
        let (d, slide) = deck();
        // Step 0: base title only.
        let v0 = visible_at(&d.store, &slide, 0);
        assert!(v0.contains(&id("nd:title")), "base always visible");
        assert!(!v0.contains(&id("nd:b1")), "step-1 hidden at 0");
        // Step 1: title + b1.
        let v1 = visible_at(&d.store, &slide, 1);
        assert!(v1.contains(&id("nd:b1")) && !v1.contains(&id("nd:b2")));
        // Step 2: all.
        let v2 = visible_at(&d.store, &slide, 2);
        assert!(v2.contains(&id("nd:b1")) && v2.contains(&id("nd:b2")));
        // Monotonic: each step's set is a superset of the previous.
        assert!(v0.iter().all(|x| v1.contains(x)));
        assert!(v1.iter().all(|x| v2.contains(x)));
    }

    #[test]
    fn step_outside_a_slide_lints_orphan() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[CanvasOp::Insert {
            id: Some(id("nd:loose")),
            kind: RecordKind::Text,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![
                (key("text"), Value::Str("loose".to_owned())),
                (key("step"), Value::Num(1.0)),
            ],
        }]).expect("apply");
        let tokens = crate::canvas::tokens::TokenStore::default_theme();
        let findings = crate::canvas::lint::run(&d, &tokens);
        assert!(findings.iter().any(|f| f.code == "orphan-step"
            && f.id.as_ref().map(|i| i.as_str()) == Some("nd:loose")));
    }

    #[test]
    fn timeline_json_lists_slides_in_document_order() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        // Two slides, a stepped node in the first.
        d.apply(0, &[
            CanvasOp::Insert { id: Some(id("nd:s0")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:s1")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:x")), kind: RecordKind::Text, parent: id("nd:s0"),
                pos: Position::Last, props: vec![
                    (key("text"), Value::Str("x".to_owned())),
                    (key("step"), Value::Num(1.0))] },
        ]).expect("apply");
        let ids = slide_ids(&d.store);
        assert_eq!(ids, vec![id("nd:s0"), id("nd:s1")], "document order");
        let json = timeline_json(&d.store);
        assert!(json.contains("\"id\":\"nd:s0\""));
        assert!(json.contains("\"stepCount\":1"), "{json}");
        assert!(json.contains("\"visibleIds\":[\"nd:x\"]") || json.contains("nd:x"));
        // Valid JSON round-trips through the in-house parser.
        assert!(crate::json::parse(&json).is_ok(), "well-formed JSON");
    }

    #[test]
    fn timeline_state_snapshots_every_step() {
        let (d, slide) = deck();
        let tl = timeline_state(&d.store, &slide);
        assert_eq!(tl.len(), 3, "steps 0,1,2");
        assert_eq!(tl[0].step, 0);
        assert!(tl[0].visible_ids.contains(&"nd:title".to_owned()));
        assert!(!tl[0].visible_ids.contains(&"nd:b1".to_owned()));
        assert!(tl[2].visible_ids.contains(&"nd:b2".to_owned()));
        // Deterministic: ids are sorted.
        assert_eq!(tl[2].visible_ids, {
            let mut s = tl[2].visible_ids.clone();
            s.sort();
            s
        });
    }

    use proptest::prelude::*;

    proptest! {
        /// The visible set only GROWS with step, and base (unstepped) nodes
        /// are visible at every step — the reveal invariant the player relies
        /// on (S4 mirrors the exact rule).
        #[test]
        fn visibility_grows_monotonically(steps in prop::collection::vec(0u16..6, 0..12)) {
            let mut d = DocState::new();
            let pg = id("pg:1");
            d.store.insert_root(pg.clone(), RecordKind::Page).unwrap();
            d.apply(0, &[CanvasOp::Insert {
                id: Some(id("nd:s")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))],
            }]).unwrap();
            // A base node (no step) + one node per requested step value.
            d.apply(d.rev(), &[CanvasOp::Insert {
                id: Some(id("nd:base")), kind: RecordKind::Text, parent: id("nd:s"),
                pos: Position::Last, props: vec![(key("text"), Value::Str("b".to_owned()))],
            }]).unwrap();
            for (i, s) in steps.iter().enumerate() {
                let nid = format!("nd:n{i}");
                d.apply(d.rev(), &[CanvasOp::Insert {
                    id: Some(id(&nid)), kind: RecordKind::Text, parent: id("nd:s"),
                    pos: Position::Last,
                    props: vec![
                        (key("text"), Value::Str("x".to_owned())),
                        (key("step"), Value::Num(f64::from(*s))),
                    ],
                }]).unwrap();
            }
            let slide = id("nd:s");
            let top = max_step(&d.store, &slide);
            let mut prev: Vec<Id> = Vec::new();
            for step in 0..=top {
                let cur = visible_at(&d.store, &slide, step);
                prop_assert!(cur.contains(&id("nd:base")), "base always visible");
                prop_assert!(prev.iter().all(|x| cur.contains(x)), "monotone growth");
                prev = cur;
            }
        }
    }
}
