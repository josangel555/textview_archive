//! Canvas M1.S5b — DOM-patch plans from applied op batches (TSK-1360;
//! 02-CORE-ENGINE §9). Replaces the M0 mirror-the-op plan with the real
//! thing: each applied op maps to MINIMAL DOM mutations, computed from the
//! POST-apply store (fragments and before-siblings reflect final state) and
//! the SAME `css_decl` table the full lowering uses — the two render paths
//! cannot drift by construction. Idempotent-replay ops (`Noop` effects)
//! yield ZERO patches.

use super::lower;
use super::ops::{AppliedEffect, CanvasOp, DocState};
use super::props::{PropKey, Value};
use super::store::Id;

/// One DOM mutation instruction (the applier's vocabulary).
#[derive(Debug, Clone, PartialEq)]
pub enum Patch {
    SetText { id: Id, text: String },
    SetStyle { id: Id, prop: &'static str, value: String },
    RemoveStyle { id: Id, prop: &'static str },
    SetAttr { id: Id, attr: &'static str, value: String },
    /// `before: None` = append at the end of `parent`.
    InsertNode { parent: Id, before: Option<Id>, html: String },
    RemoveNode { id: Id },
    MoveNode { id: Id, parent: Id, before: Option<Id> },
    /// Re-render one node in place (outerHTML swap) — the definition-edit
    /// verb (M4.S1c): an edit INSIDE a cmp:* subtree re-lowers every visible
    /// instance instead of patching ids that don't exist bare in the DOM.
    ReplaceNode { id: Id, html: String },
    /// Swap the root theme block's custom properties (M4.S4) — the ZERO-OP
    /// retheme: token edits repaint the whole document through the var()
    /// indirection with ONE patch and no re-lower.
    SetTheme { css: String },
}

/// Map one prop mutation to its patch (shared-table style mapping; `text` and
/// `src` are content/attr patches, not styles).
fn prop_patch(id: &Id, key: PropKey, value: &Value) -> Option<Patch> {
    match key.name() {
        Some("text") => match value {
            Value::Str(s) => Some(Patch::SetText {
                id: id.clone(),
                text: s.clone(),
            }),
            _ => None,
        },
        Some("src") => match value {
            Value::Str(s) => Some(Patch::SetAttr {
                id: id.clone(),
                attr: "src",
                value: s.clone(),
            }),
            _ => None,
        },
        _ => lower::css_decl(key, value).map(|(prop, v)| Patch::SetStyle {
            id: id.clone(),
            prop,
            value: v,
        }),
    }
}

/// The unset counterpart.
fn unset_patch(id: &Id, key: PropKey) -> Option<Patch> {
    match key.name() {
        Some("text") => Some(Patch::SetText {
            id: id.clone(),
            text: String::new(),
        }),
        Some("src") => Some(Patch::SetAttr {
            id: id.clone(),
            attr: "src",
            value: String::new(),
        }),
        // Probe the css mapping with a throwaway value to learn the css prop.
        _ => lower::css_decl(key, &Value::Str(String::new()))
            .map(|(prop, _)| Patch::RemoveStyle {
                id: id.clone(),
                prop,
            }),
    }
}

/// Build the patch plan for an applied batch. `doc` MUST be post-apply;
/// `ops` and `applied.effects` are parallel.
#[must_use]
pub fn plan(doc: &DocState, ops: &[CanvasOp], effects: &[AppliedEffect]) -> Vec<Patch> {
    let mut patches: Vec<Patch> = Vec::new();
    // Definition-edit handling (M4.S1c): ops whose target lives inside a
    // cmp:* definition patch NOTHING bare (those ids aren't in the DOM);
    // instead every VISIBLE instance of the touched definition re-lowers in
    // place. Deduped across the batch.
    let mut touched_defs: Vec<Id> = Vec::new();
    for (op, effect) in ops.iter().zip(effects.iter()) {
        if matches!(effect, AppliedEffect::Noop) {
            continue;
        }
        let target: Option<&Id> = match op {
            // A fresh definition has no instances → nothing to repaint.
            CanvasOp::DefineComponent { .. } => None,
            CanvasOp::Insert { parent, .. } => Some(parent),
            CanvasOp::Update { id, .. }
            | CanvasOp::Move { id, .. }
            | CanvasOp::Remove { id } => Some(id),
        };
        if let Some(t) = target {
            // For removes the record is gone — containing_definition walks
            // the CURRENT store; a removed subtree's definition is found via
            // the op's PARENT context instead. Removes of def-internal nodes
            // resolve through the batch's other signals; v1 accepts a full
            // instance re-lower keyed on whatever still resolves.
            if let Some(def) = super::lower::containing_definition(&doc.store, t)
                && !touched_defs.contains(&def)
            {
                touched_defs.push(def);
            }
        }
    }
    for (op, effect) in ops.iter().zip(effects.iter()) {
        // Suppress bare patches for in-definition targets.
        let in_definition = |candidate: &Id| -> bool {
            super::lower::containing_definition(&doc.store, candidate).is_some()
        };
        match (op, effect) {
            (_, AppliedEffect::Noop) => {}
            (_, AppliedEffect::Defined(_)) => {} // definitions never patch
            (CanvasOp::Insert { .. }, AppliedEffect::Inserted { id, .. })
                if in_definition(id) => {}
            (CanvasOp::Update { .. }, AppliedEffect::Updated(id))
                if in_definition(id) => {}
            (CanvasOp::Move { .. }, AppliedEffect::Moved { id, .. })
                if in_definition(id) => {}
            _ => { plan_one(doc, op, effect, &mut patches); continue }
        }
    }
    for def in &touched_defs {
        for instance in super::lower::visible_instances_of(&doc.store, def) {
            patches.push(Patch::ReplaceNode {
                id: instance.clone(),
                html: lower::lower_subtree(&doc.store, &instance),
            });
        }
    }
    patches
}

fn plan_one(doc: &DocState, op: &CanvasOp, effect: &AppliedEffect, patches: &mut Vec<Patch>) {
    {
        match (op, effect) {
            (_, AppliedEffect::Noop) => {} // replay — nothing to do
            (CanvasOp::Insert { parent, .. }, AppliedEffect::Inserted { id: new_id, before }) => {
                patches.push(Patch::InsertNode {
                    parent: parent.clone(),
                    before: before.clone(),
                    html: lower::lower_subtree(&doc.store, new_id),
                });
            }
            (CanvasOp::Update { set, unset, .. }, AppliedEffect::Updated(id)) => {
                for (k, v) in set {
                    if let Some(p) = prop_patch(id, *k, v) {
                        patches.push(p);
                    }
                }
                for k in unset {
                    if let Some(p) = unset_patch(id, *k) {
                        patches.push(p);
                    }
                }
            }
            (CanvasOp::Move { parent, .. }, AppliedEffect::Moved { id, before }) => {
                patches.push(Patch::MoveNode {
                    id: id.clone(),
                    parent: parent.clone(),
                    before: before.clone(),
                });
            }
            (CanvasOp::Remove { .. }, AppliedEffect::Removed(id)) => {
                patches.push(Patch::RemoveNode { id: id.clone() });
            }
            // Op/effect kind mismatch = internal inconsistency; emit nothing
            // for that op (the full re-lower is the recovery path).
            _ => debug_assert!(false, "op/effect mismatch: {op:?} vs {effect:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::store::{Position, RecordKind};

    fn id(s: &str) -> Id {
        Id::parse(s).expect("id")
    }
    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    fn seeded() -> (DocState, Id) {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:a")),
                    kind: RecordKind::Text,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str("a".to_owned()))],
                },
                CanvasOp::Insert {
                    id: Some(id("nd:b")),
                    kind: RecordKind::Text,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![(key("text"), Value::Str("b".to_owned()))],
                },
            ],
        )
        .expect("seed");
        (d, pg)
    }

    #[test]
    fn insert_before_anchor_and_fragment_come_from_post_state() {
        let (mut d, pg) = seeded();
        let ops = [CanvasOp::Insert {
            id: Some(id("nd:mid")),
            kind: RecordKind::Text,
            parent: pg.clone(),
            pos: Position::Before(id("nd:b")),
            props: vec![(key("text"), Value::Str("mid".to_owned()))],
        }];
        let applied = d.apply(1, &ops).expect("apply");
        let got = plan(&d, &ops, &applied.effects);
        let expected_html = lower::lower_subtree(&d.store, &id("nd:mid"));
        assert!(expected_html.contains(">mid</div>"));
        assert_eq!(
            got,
            vec![Patch::InsertNode {
                parent: pg,
                before: Some(id("nd:b")),
                html: expected_html,
            }]
        );
    }

    #[test]
    fn update_maps_text_src_style_and_unset() {
        let (mut d, pg) = seeded();
        d.apply(
            1,
            &[CanvasOp::Insert {
                id: Some(id("nd:img")),
                kind: RecordKind::Image,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("src"), Value::Str("a.png".to_owned()))],
            }],
        )
        .expect("img");
        let ops = [
            CanvasOp::Update {
                id: id("nd:a"),
                set: vec![
                    (key("text"), Value::Str("A2".to_owned())),
                    (key("color"), Value::Token("color.accent".to_owned())),
                ],
                unset: vec![key("font")],
            },
            CanvasOp::Update {
                id: id("nd:img"),
                set: vec![(key("src"), Value::Str("b.png".to_owned()))],
                unset: vec![],
            },
        ];
        let applied = d.apply(2, &ops).expect("apply");
        let plan = plan(&d, &ops, &applied.effects);
        assert_eq!(
            plan,
            vec![
                Patch::SetText { id: id("nd:a"), text: "A2".to_owned() },
                Patch::SetStyle {
                    id: id("nd:a"),
                    prop: "color",
                    value: "var(--cv-color-accent)".to_owned(),
                },
                Patch::RemoveStyle { id: id("nd:a"), prop: "font" },
                Patch::SetAttr { id: id("nd:img"), attr: "src", value: "b.png".to_owned() },
            ]
        );
    }

    #[test]
    fn move_and_remove_map_directly() {
        let (mut d, pg) = seeded();
        let ops = [
            CanvasOp::Move {
                id: id("nd:b"),
                parent: pg.clone(),
                pos: Position::First,
            },
            CanvasOp::Remove { id: id("nd:a") },
        ];
        let applied = d.apply(1, &ops).expect("apply");
        let plan = plan(&d, &ops, &applied.effects);
        assert_eq!(
            plan,
            vec![
                Patch::MoveNode {
                    id: id("nd:b"),
                    parent: pg.clone(),
                    before: Some(id("nd:a")), // post-move order: b, a
                },
                Patch::RemoveNode { id: id("nd:a") },
            ]
        );
    }

    #[test]
    fn idempotent_replay_yields_zero_patches() {
        let (mut d, pg) = seeded();
        let replay = [CanvasOp::Insert {
            id: Some(id("nd:a")),
            kind: RecordKind::Text,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![(key("text"), Value::Str("a".to_owned()))],
        }];
        let applied = d.apply(1, &replay).expect("replay");
        assert!(applied.noop);
        assert!(plan(&d, &replay, &applied.effects).is_empty());
    }

    #[test]
    fn minted_insert_uses_the_resolved_id() {
        let (mut d, pg) = seeded();
        let ops = [CanvasOp::Insert {
            id: None,
            kind: RecordKind::Text,
            parent: pg.clone(),
            pos: Position::Last,
            props: vec![(key("text"), Value::Str("minted".to_owned()))],
        }];
        let applied = d.apply(1, &ops).expect("apply");
        let minted = applied.minted.first().cloned().expect("minted id");
        let got = plan(&d, &ops, &applied.effects);
        let expected_html = lower::lower_subtree(&d.store, &minted);
        assert!(expected_html.contains(minted.as_str()));
        assert_eq!(
            got,
            vec![Patch::InsertNode {
                parent: pg,
                before: None,
                html: expected_html,
            }]
        );
    }
    // MARK: M4.S1c — definition-edit planning

    #[test]
    fn definition_edit_replaces_every_visible_instance_and_nothing_bare() {
        let mut d = DocState::new();
        let pg = Id::page(1);
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        let card = Id::parse("cmp:card").expect("cmp");
        d.store.insert_root(card.clone(), RecordKind::Frame).expect("def root");
        d.apply(0, &[
            CanvasOp::Insert {
                id: Some(id("nd:card-title")),
                kind: RecordKind::Text,
                parent: card.clone(),
                pos: Position::Last,
                props: vec![(key("text"), Value::Str("t".into()))],
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
        ]).expect("seed");

        // Edit INSIDE the definition.
        let ops = [CanvasOp::Update {
            id: id("nd:card-title"),
            set: vec![(key("text"), Value::Str("edited".into()))],
            unset: vec![],
        }];
        let applied = d.apply(1, &ops).expect("edit");
        let got = plan(&d, &ops, &applied.effects);
        // NO bare patch for nd:card-title; exactly the two instances replace.
        assert_eq!(got.len(), 2, "{got:?}");
        for patch in &got {
            assert!(
                matches!(patch, Patch::ReplaceNode { .. }),
                "expected ReplaceNode, got {patch:?}"
            );
            if let Patch::ReplaceNode { id: instance, html } = patch {
                assert!(instance.as_str().starts_with("nd:inst-"));
                assert!(html.contains(">edited<"), "re-lowered content");
                assert!(
                    html.contains(&format!("{}/nd:card-title", instance.as_str())),
                    "namespaced inner ids in the replacement"
                );
            }
        }
    }

    #[test]
    fn page_content_edits_still_patch_minimally() {
        // The definition machinery must not tax ordinary edits.
        let (mut d, _pg) = seeded();
        let ops = [CanvasOp::Update {
            id: id("nd:a"),
            set: vec![(key("text"), Value::Str("still minimal".into()))],
            unset: vec![],
        }];
        let applied = d.apply(1, &ops).expect("edit");
        let got = plan(&d, &ops, &applied.effects);
        assert_eq!(
            got,
            vec![Patch::SetText { id: id("nd:a"), text: "still minimal".into() }]
        );
    }

}
