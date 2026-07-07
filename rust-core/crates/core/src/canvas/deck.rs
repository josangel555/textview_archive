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
use super::tokens::TokenStore;

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
/// Which ids are visible at a build step (M6 presentation).
pub struct StepState {
    /// The 0-based build step.
    pub step: u16,
    /// Ids visible at this step, sorted.
    pub visible_ids: Vec<String>,
}

/// The full timeline of a slide: the step count and, for each step 0..=max,
/// the visible-id snapshot. This is the DECLARATIVE verification surface the
/// agent checks BEFORE any pixel (06 success #3).
#[must_use]
pub fn timeline_state(store: &Store, slide: &Id) -> Vec<StepState> {
    // Walk the subtree + resolve each node's step ONCE (was O(steps × nodes):
    // visible_at re-walked descendants per step, plus max_step walked again).
    // Now a single walk feeds every step's filter — same output, no repeated
    // traversal.
    let mut nodes: Vec<(Id, Option<u16>)> = descendants(store, slide)
        .into_iter()
        .map(|id| {
            let s = node_step(store, &id);
            (id, s)
        })
        .collect();
    nodes.sort_by(|a, b| a.0.cmp(&b.0)); // deterministic id order (as before)
    let steps = nodes.iter().filter_map(|(_, s)| *s).max().unwrap_or(0);
    (0..=steps)
        .map(|step| StepState {
            step,
            visible_ids: nodes
                .iter()
                .filter(|(_, s)| s.is_none_or(|v| v <= step))
                .map(|(id, _)| id.as_str().to_owned())
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

/// One identity-morph pairing between two slides (M6.S5): a morphId present
/// in BOTH slides — the paired node animates (FLIP) from its slide-A box to
/// its slide-B box.
#[derive(Debug, Clone, PartialEq, Eq)]
/// One morph correspondence between two slides.
pub struct MorphPair {
    /// The shared morphId.
    pub morph_id: String,
    /// Element id on the FROM slide.
    pub from: String,
    /// Element id on the TO slide.
    pub to: String,
}

/// The morph transition between two slides (M6.S5) — a PURE set-diff over
/// morphId. `pairs` = ids present in both (animate); `entering` = morphIds
/// only in B (fade in); `leaving` = morphIds only in A (fade out). All
/// sorted for determinism. The JS runs the FLIP; this is the authority.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MorphPlan {
    /// morphIds present on both slides (FLIP-animate).
    pub pairs: Vec<MorphPair>,
    /// morphIds only on the TO slide (fade in).
    pub entering: Vec<String>,
    /// morphIds only on the FROM slide (fade out).
    pub leaving: Vec<String>,
}

fn morph_map(store: &Store, slide: &Id) -> Vec<(String, Id)> {
    let mut out: Vec<(String, Id)> = descendants(store, slide)
        .into_iter()
        .filter_map(|id| {
            let rec = store.get(&id)?;
            let key = PropKey::by_name("morphId")?;
            match rec.props.get(key) {
                Some(Value::Str(m)) => Some((m.clone(), id)),
                _ => None,
            }
        })
        .collect();
    out.sort();
    out
}

/// Classify the morph between slide A and slide B (M6.S5).
#[must_use]
pub fn morph_pairs(store: &Store, slide_a: &Id, slide_b: &Id) -> MorphPlan {
    let a = morph_map(store, slide_a);
    let b = morph_map(store, slide_b);
    let mut plan = MorphPlan::default();
    for (mid, from) in &a {
        if let Some((_, to)) = b.iter().find(|(m, _)| m == mid) {
            plan.pairs.push(MorphPair {
                morph_id: mid.clone(),
                from: from.as_str().to_owned(),
                to: to.as_str().to_owned(),
            });
        } else {
            plan.leaving.push(mid.clone());
        }
    }
    for (mid, _) in &b {
        if !a.iter().any(|(m, _)| m == mid) {
            plan.entering.push(mid.clone());
        }
    }
    plan.pairs.sort_by(|x, y| x.morph_id.cmp(&y.morph_id));
    plan.entering.sort();
    plan.leaving.sort();
    plan
}


/// The standalone offline player (M6.S6) — inlined into the exported deck.
/// Self-contained: keyboard nav + the SAME reveal rule as timeline_state
/// (S2) and the live player (S4), plus FLIP morph. No bridge, no network.
const DECK_PLAYER_JS: &str = r####"
(function(){
  var root=document.body;
  var deck={slide:0,step:0};
  function slides(){return Array.prototype.slice.call(root.querySelectorAll('[data-cv-role="slide"]'));}
  function maxStep(s){var m=0;if(!s)return 0;var n=s.querySelectorAll('[data-cv-step]');
    for(var i=0;i<n.length;i++){var v=parseInt(n[i].getAttribute('data-cv-step'),10);if(v>m)m=v;}return m;}
  function morphRects(s){var map={};if(!s)return map;var n=s.querySelectorAll('[data-cv-morph]');
    for(var i=0;i<n.length;i++)map[n[i].getAttribute('data-cv-morph')]=n[i].getBoundingClientRect();return map;}
  function runMorph(from,to){if(!to)return;var n=to.querySelectorAll('[data-cv-morph]');
    for(var i=0;i<n.length;i++){var id=n[i].getAttribute('data-cv-morph');var f=from[id];if(!f)continue;
      var t=n[i].getBoundingClientRect();var dx=f.left-t.left,dy=f.top-t.top;
      var sx=t.width?f.width/t.width:1,sy=t.height?f.height/t.height:1;
      if(n[i].animate)n[i].animate([{transformOrigin:'top left',transform:'translate('+dx+'px,'+dy+'px) scale('+sx+','+sy+')'},{transformOrigin:'top left',transform:'none'}],{duration:300,easing:'ease'});}}
  function apply(){var s=slides();if(deck.slide<0)deck.slide=0;if(deck.slide>=s.length)deck.slide=Math.max(0,s.length-1);
    for(var i=0;i<s.length;i++)s[i].style.display=(i===deck.slide)?'':'none';
    var cur=s[deck.slide];if(cur){var n=cur.querySelectorAll('[data-cv-step]');
      for(var j=0;j<n.length;j++){var st=parseInt(n[j].getAttribute('data-cv-step'),10);n[j].style.visibility=(st<=deck.step)?'':'hidden';}}}
  function advance(d){var s=slides();var prev=deck.slide;var max=maxStep(s[deck.slide]);
    if(d>0){if(deck.step<max)deck.step+=1;else if(deck.slide<s.length-1){deck.slide+=1;deck.step=0;}}
    else{if(deck.step>0)deck.step-=1;else if(deck.slide>0){deck.slide-=1;deck.step=maxStep(s[deck.slide]);}}
    if(deck.slide!==prev){var fr=morphRects(s[prev]);apply();runMorph(fr,slides()[deck.slide]);}else apply();}
  document.addEventListener('keydown',function(e){
    if(e.key==='ArrowRight'||e.key===' '||e.key==='PageDown'){e.preventDefault();advance(1);}
    else if(e.key==='ArrowLeft'||e.key==='PageUp'){e.preventDefault();advance(-1);}});
  apply();
})();
"####;

/// Export the deck as a SELF-CONTAINED offline HTML document (M6.S6): the
/// theme block + lowered slides + the inlined player. Plays with arrow keys,
/// zero network (06 success #4).
#[must_use]
pub fn export_html(store: &Store, tokens: &TokenStore, page: &Id) -> String {
    let mut out = String::with_capacity(8192);
    out.push_str(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <title>Canvas Deck</title><style>\
         html,body{margin:0;height:100%;background:#111;overflow:hidden}\
         [data-cv-role=\"slide\"]{position:absolute;inset:0;margin:auto}\
         </style></head><body>",
    );
    out.push_str(&super::lower::lower_page(store, tokens, page));
    out.push_str("<script>");
    out.push_str(DECK_PLAYER_JS);
    out.push_str("</script></body></html>");
    out
}

/// Export the deck as a PAGINATED PRINT layout (M6.S6 tail): every slide in
/// normal flow, each forced to its own page (page-break-after), NO player JS.
/// Opening this and File▸Print → Save as PDF yields a one-slide-per-page PDF
/// through the OS print path — deck→PDF with zero new machinery (the M6-PLAN
/// PDF finding, closed via print rather than an async createPDF driver).
/// Self-contained: theme inlined, zero network.
#[must_use]
pub fn export_print_html(store: &Store, tokens: &TokenStore, page: &Id) -> String {
    let mut out = String::with_capacity(8192);
    out.push_str("<!doctype html><html><head><meta charset=\"utf-8\">");
    out.push_str("<title>Canvas Deck</title><style>");
    out.push_str("@page{margin:0}html,body{margin:0;background:#fff}");
    out.push_str("[data-cv-role=\"slide\"]{page-break-after:always;break-after:page;");
    out.push_str("width:1280px;min-height:720px;box-sizing:border-box;overflow:hidden}");
    out.push_str("[data-cv-role=\"slide\"]:last-child{page-break-after:auto;break-after:auto}");
    out.push_str("</style></head><body>");
    out.push_str(&super::lower::lower_page(store, tokens, page));
    out.push_str("</body></html>");
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

    /// Scale guard (M6-PLAN §Budgets, sans-IO structural style — wall-clock
    /// is walled in core per bench.rs): timeline_state + morph_pairs handle
    /// the plan's documented max (a ~500-node slide, many steps) correctly and
    /// without pathology. Also pins that the single-walk optimization is
    /// still correct at scale (all nodes visible at the top step; monotone).
    #[test]
    fn timeline_and_morph_scale_to_the_documented_max() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[
            CanvasOp::Insert { id: Some(id("nd:s0")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:s1")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
        ]).expect("slides");
        // 500 stepped, morph-tagged nodes across 30 steps on slide 0; 250 with
        // matching morphIds on slide 1.
        let mut batch = Vec::new();
        for i in 0..500u32 {
            batch.push(CanvasOp::Insert {
                id: Some(id(&format!("nd:a{i}"))), kind: RecordKind::Text,
                parent: id("nd:s0"), pos: Position::Last,
                props: vec![
                    (key("text"), Value::Str(format!("n{i}"))),
                    (key("step"), Value::Num(f64::from(i % 30))),
                    (key("morphId"), Value::Str(format!("m{i}"))),
                ],
            });
        }
        d.apply(d.rev(), &batch).expect("500 nodes");
        let mut batch2 = Vec::new();
        for i in 0..250u32 {
            batch2.push(CanvasOp::Insert {
                id: Some(id(&format!("nd:b{i}"))), kind: RecordKind::Text,
                parent: id("nd:s1"), pos: Position::Last,
                props: vec![(key("morphId"), Value::Str(format!("m{i}")))],
            });
        }
        d.apply(d.rev(), &batch2).expect("250 nodes");

        let tl = timeline_state(&d.store, &id("nd:s0"));
        assert_eq!(tl.len(), 30, "steps 0..=29");
        assert_eq!(tl[29].visible_ids.len(), 500, "all revealed at the top step");
        // Monotone growth across the whole timeline.
        for w in tl.windows(2) {
            assert!(w[1].visible_ids.len() >= w[0].visible_ids.len(), "monotone at scale");
        }
        // morph_pairs across the two slides: 250 shared morphIds pair, 250 leave.
        let plan = morph_pairs(&d.store, &id("nd:s0"), &id("nd:s1"));
        assert_eq!(plan.pairs.len(), 250, "shared morphIds pair");
        assert_eq!(plan.leaving.len(), 250, "slide-0-only morphIds leave");
        assert!(plan.entering.is_empty(), "no slide-1-only morphIds");
    }

    #[test]
    fn export_print_html_paginates_slides_without_the_player() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[
            CanvasOp::Insert { id: Some(id("nd:s0")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:t")), kind: RecordKind::Text, parent: id("nd:s0"),
                pos: Position::Last, props: vec![(key("text"), Value::Str("Print me".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:s1")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
        ]).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = export_print_html(&d.store, &tokens, &pg);
        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("Print me"), "slide content");
        assert!(html.contains("page-break-after:always"), "slides paginate");
        assert!(html.contains("@page{margin:0}"), "print page setup");
        // It is a STATIC artifact — no player JS (Cmd-P is the driver).
        assert!(!html.contains("addEventListener"), "no player script in print layout");
        assert!(!html.contains("<script"), "no scripts at all");
        // Self-contained: zero network.
        assert!(!html.contains("http://") && !html.contains("https://"));
    }

    #[test]
    fn export_html_is_self_contained_and_playable() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[
            CanvasOp::Insert { id: Some(id("nd:s0")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:t")), kind: RecordKind::Text, parent: id("nd:s0"),
                pos: Position::Last, props: vec![(key("text"), Value::Str("Hello deck".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:s1")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
        ]).expect("apply");
        let tokens = TokenStore::default_theme();
        let html = export_html(&d.store, &tokens, &pg);
        assert!(html.starts_with("<!doctype html>"), "full document");
        assert!(html.contains("Hello deck"), "slide content");
        assert!(html.contains("data-cv-role=\"slide\""), "slides present");
        assert!(html.contains("addEventListener('keydown'"), "the player is inlined");
        assert!(html.contains("ArrowRight"), "keyboard nav");
        // SELF-CONTAINED: zero network (success #4).
        assert!(!html.contains("http://") && !html.contains("https://"),
                "no external URLs");
        assert!(html.contains("</html>"), "well-formed close");
    }

    #[test]
    fn morph_pairs_classifies_paired_entering_leaving() {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        d.apply(0, &[
            CanvasOp::Insert { id: Some(id("nd:s0")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:s1")), kind: RecordKind::Frame, parent: pg.clone(),
                pos: Position::Last, props: vec![(key("role"), Value::Str("slide".to_owned()))] },
            // logo morphs across both; hero only on s0 (leaving); cta only on s1 (entering).
            CanvasOp::Insert { id: Some(id("nd:a-logo")), kind: RecordKind::Text, parent: id("nd:s0"),
                pos: Position::Last, props: vec![(key("morphId"), Value::Str("logo".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:a-hero")), kind: RecordKind::Text, parent: id("nd:s0"),
                pos: Position::Last, props: vec![(key("morphId"), Value::Str("hero".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:b-logo")), kind: RecordKind::Text, parent: id("nd:s1"),
                pos: Position::Last, props: vec![(key("morphId"), Value::Str("logo".to_owned()))] },
            CanvasOp::Insert { id: Some(id("nd:b-cta")), kind: RecordKind::Text, parent: id("nd:s1"),
                pos: Position::Last, props: vec![(key("morphId"), Value::Str("cta".to_owned()))] },
        ]).expect("apply");
        let plan = morph_pairs(&d.store, &id("nd:s0"), &id("nd:s1"));
        assert_eq!(plan.pairs.len(), 1);
        assert_eq!(plan.pairs[0].morph_id, "logo");
        assert_eq!(plan.pairs[0].from, "nd:a-logo");
        assert_eq!(plan.pairs[0].to, "nd:b-logo");
        assert_eq!(plan.leaving, vec!["hero".to_owned()]);
        assert_eq!(plan.entering, vec!["cta".to_owned()]);
        // The DOM carries the morph tag for the JS FLIP.
        let tokens = crate::canvas::tokens::TokenStore::default_theme();
        let html = crate::canvas::lower::lower_page(&d.store, &tokens, &pg);
        assert!(html.contains("data-cv-morph=\"logo\""));
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
