//! Canvas M1.S5c — the wire codec for the real engine (TSK-1360).
//!
//! Request: `{baseRev, ops:[…]}` MessagePack named maps (to_vec_named — the
//! rmp interop rule). Response: `{rev, patches:[…]}` or `{error:{…}}`.
//! Wire shapes are string-keyed and self-describing (the JS applier consumes
//! them as parsed JSON-equivalents); internal types stay serde-free — this
//! module is the ONLY canvas↔serde boundary, and therefore the fuzz target
//! (TSK-584: parsers of untrusted bytes).

use serde::{Deserialize, Serialize};

use super::lint::{Lint, LintSeverity};
use super::ops::{ApplyError, CanvasOp, DocState};
use super::patch::Patch;
use super::props::{PropKey, Value};
use super::registry::FenceError;
use super::store::{Id, Position, RecordKind};
use super::tokens::TokenStore;
use crate::wire as base_wire;
use crate::wire::WireFault;

/// Wire value: literal string/number/bool, or `{token: "path"}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
enum WireValue {
    Token { token: String },
    Str(String),
    Num(f64),
    Bool(bool),
}

impl WireValue {
    fn into_value(self) -> Value {
        match self {
            WireValue::Token { token } => Value::Token(token),
            WireValue::Str(s) => Value::Str(s),
            WireValue::Num(n) => Value::Num(n),
            WireValue::Bool(b) => Value::Bool(b),
        }
    }
}

/// Wire position: `{type: "first"|"last"|"before"|"after", anchor?}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WirePos {
    First,
    Last,
    Before { anchor: String },
    After { anchor: String },
}

/// One wire op.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum WireOp {
    #[serde(rename_all = "camelCase")]
    Define { id: String },
    #[serde(rename_all = "camelCase")]
    Insert {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        kind: String,
        parent: String,
        pos: WirePos,
        #[serde(default)]
        props: Vec<(String, WireValue)>,
    },
    #[serde(rename_all = "camelCase")]
    Update {
        id: String,
        #[serde(default)]
        set: Vec<(String, WireValue)>,
        #[serde(default)]
        unset: Vec<String>,
    },
    #[serde(rename_all = "camelCase")]
    Move {
        id: String,
        parent: String,
        pos: WirePos,
    },
    #[serde(rename_all = "camelCase")]
    Remove { id: String },
}

/// The apply request frame.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApplyRequest {
    base_rev: u64,
    ops: Vec<WireOp>,
}

/// One wire patch (the applier vocabulary — mirrors `patch::Patch`).
#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum WirePatch {
    #[serde(rename_all = "camelCase")]
    SetText { id: String, text: String },
    #[serde(rename_all = "camelCase")]
    SetStyle { id: String, prop: String, value: String },
    #[serde(rename_all = "camelCase")]
    RemoveStyle { id: String, prop: String },
    #[serde(rename_all = "camelCase")]
    SetAttr { id: String, attr: String, value: String },
    #[serde(rename_all = "camelCase")]
    InsertNode {
        parent: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        before: Option<String>,
        html: String,
    },
    #[serde(rename_all = "camelCase")]
    RemoveNode { id: String },
    #[serde(rename_all = "camelCase")]
    MoveNode {
        id: String,
        parent: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        before: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    ReplaceNode { id: String, html: String },
    #[serde(rename_all = "camelCase")]
    SetTheme { css: String },
}

impl WirePatch {
    fn from_patch(p: &Patch) -> WirePatch {
        match p {
            Patch::SetText { id, text } => WirePatch::SetText {
                id: id.as_str().to_owned(),
                text: text.clone(),
            },
            Patch::SetStyle { id, prop, value } => WirePatch::SetStyle {
                id: id.as_str().to_owned(),
                prop: (*prop).to_owned(),
                value: value.clone(),
            },
            Patch::RemoveStyle { id, prop } => WirePatch::RemoveStyle {
                id: id.as_str().to_owned(),
                prop: (*prop).to_owned(),
            },
            Patch::SetAttr { id, attr, value } => WirePatch::SetAttr {
                id: id.as_str().to_owned(),
                attr: (*attr).to_owned(),
                value: value.clone(),
            },
            Patch::InsertNode { parent, before, html } => WirePatch::InsertNode {
                parent: parent.as_str().to_owned(),
                before: before.as_ref().map(|b| b.as_str().to_owned()),
                html: html.clone(),
            },
            Patch::RemoveNode { id } => WirePatch::RemoveNode {
                id: id.as_str().to_owned(),
            },
            Patch::MoveNode { id, parent, before } => WirePatch::MoveNode {
                id: id.as_str().to_owned(),
                parent: parent.as_str().to_owned(),
                before: before.as_ref().map(|b| b.as_str().to_owned()),
            },
            Patch::ReplaceNode { id, html } => WirePatch::ReplaceNode {
                id: id.as_str().to_owned(),
                html: html.clone(),
            },
            Patch::SetTheme { css } => WirePatch::SetTheme { css: css.clone() },
        }
    }
}

/// One advisory lint finding on the wire.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct WireLint {
    severity: String,
    code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    message: String,
}

impl WireLint {
    fn from_lint(l: &Lint) -> WireLint {
        WireLint {
            severity: match l.severity {
                LintSeverity::Warn => "warn".to_owned(),
                LintSeverity::Info => "info".to_owned(),
            },
            code: l.code.to_owned(),
            id: l.id.as_ref().map(|i| i.as_str().to_owned()),
            message: l.message.clone(),
        }
    }
}

/// The apply response frame. `lint` rides EVERY apply (02 §8 — the agent
/// sees problems without asking).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplyResponse {
    rev: u64,
    patches: Vec<WirePatch>,
    minted: Vec<String>,
    noop: bool,
    lint: Vec<WireLint>,
}

/// Application-level rejection (a VALID frame carrying a refused batch —
/// distinct from a malformed-frame WireFault).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplyRejection {
    rejected: String,
    detail: String,
    current_rev: u64,
}

fn parse_kind(s: &str) -> Result<RecordKind, WireFault> {
    match s {
        "page" => Ok(RecordKind::Page),
        "frame" => Ok(RecordKind::Frame),
        "text" => Ok(RecordKind::Text),
        "image" => Ok(RecordKind::Image),
        "shape" => Ok(RecordKind::Shape),
        "component" => Ok(RecordKind::Component),
        "embed" => Ok(RecordKind::Embed),
        "hole" => Ok(RecordKind::Hole),
        other => Err(WireFault::Decode(format!("unknown kind '{other}'"))),
    }
}

fn parse_id(s: &str) -> Result<Id, WireFault> {
    Id::parse(s).map_err(|e| WireFault::Decode(format!("bad id '{s}': {e:?}")))
}

fn parse_pos(pos: WirePos) -> Result<Position, WireFault> {
    Ok(match pos {
        WirePos::First => Position::First,
        WirePos::Last => Position::Last,
        WirePos::Before { anchor } => Position::Before(parse_id(&anchor)?),
        WirePos::After { anchor } => Position::After(parse_id(&anchor)?),
    })
}

fn parse_props(props: Vec<(String, WireValue)>) -> Result<Vec<(PropKey, Value)>, WireFault> {
    props
        .into_iter()
        .map(|(name, wv)| {
            let key = PropKey::by_name(&name)
                .ok_or_else(|| WireFault::Decode(format!("unknown prop '{name}'")))?;
            Ok((key, wv.into_value()))
        })
        .collect()
}

fn parse_op(op: WireOp) -> Result<CanvasOp, WireFault> {
    Ok(match op {
        WireOp::Define { id } => CanvasOp::DefineComponent { id: parse_id(&id)? },
        WireOp::Insert {
            id,
            kind,
            parent,
            pos,
            props,
        } => CanvasOp::Insert {
            id: id.as_deref().map(parse_id).transpose()?,
            kind: parse_kind(&kind)?,
            parent: parse_id(&parent)?,
            pos: parse_pos(pos)?,
            props: parse_props(props)?,
        },
        WireOp::Update { id, set, unset } => CanvasOp::Update {
            id: parse_id(&id)?,
            set: parse_props(set)?,
            unset: unset
                .iter()
                .map(|name| {
                    PropKey::by_name(name)
                        .ok_or_else(|| WireFault::Decode(format!("unknown prop '{name}'")))
                })
                .collect::<Result<Vec<_>, _>>()?,
        },
        WireOp::Move { id, parent, pos } => CanvasOp::Move {
            id: parse_id(&id)?,
            parent: parse_id(&parent)?,
            pos: parse_pos(pos)?,
        },
        WireOp::Remove { id } => CanvasOp::Remove { id: parse_id(&id)? },
    })
}

/// Decode + apply + plan + encode: the FFI entry for the REAL engine.
/// Malformed frames → `Err(WireFault)`; refused batches → an Ok frame carrying
/// `{rejected, detail, currentRev}` so the caller gets structure either way.
pub fn apply_wire(
    doc: &mut DocState,
    tokens: &TokenStore,
    req_frame: &[u8],
) -> Result<Vec<u8>, WireFault> {
    let req: ApplyRequest = base_wire::decode_frame(req_frame)?;
    let mut ops: Vec<CanvasOp> = Vec::with_capacity(req.ops.len());
    for wire_op in req.ops {
        ops.push(parse_op(wire_op)?);
    }
    respond(doc, tokens, req.base_rev, &ops)
}

/// Apply parsed ops and encode the standard response/rejection frame — the
/// shared back half of BOTH entries (op frames and DSL text). The undo unit
/// for the batch is pushed onto `doc`'s caller-managed stack by the caller.
pub fn respond(
    doc: &mut DocState,
    tokens: &TokenStore,
    base_rev: u64,
    ops: &[CanvasOp],
) -> Result<Vec<u8>, WireFault> {
    respond_with_theme(doc, tokens, base_rev, ops, false)
}

/// The theme-aware responder (M4.S4): when `theme_changed`, a SetTheme
/// patch (the zero-op retheme) is APPENDED to the plan.
pub fn respond_with_theme(
    doc: &mut DocState,
    tokens: &TokenStore,
    base_rev: u64,
    ops: &[CanvasOp],
    theme_changed: bool,
) -> Result<Vec<u8>, WireFault> {
    match doc.apply(base_rev, ops) {
        Ok(applied) => {
            let mut patches = super::patch::plan(doc, ops, &applied.effects);
            if theme_changed {
                patches.push(super::patch::Patch::SetTheme {
                    css: tokens.to_css_custom_props(),
                });
            }
            let findings = super::lint::run(doc, tokens);
            base_wire::encode_frame(&ApplyResponse {
                rev: applied.rev,
                patches: patches.iter().map(WirePatch::from_patch).collect(),
                minted: applied.minted.iter().map(|m| m.as_str().to_owned()).collect(),
                noop: applied.noop,
                lint: findings.iter().map(WireLint::from_lint).collect(),
            })
        }
        Err(e) => {
            let (rejected, detail) = describe_apply_error(&e);
            base_wire::encode_frame(&ApplyRejection {
                rejected,
                detail,
                current_rev: doc.rev(),
            })
        }
    }
}

/// Encode the full-document lint findings as a standalone `{lint: […]}`
/// frame (the `canvas_lint` tool's payload — same WireLint shape that rides
/// applies).
pub fn lint_frame(doc: &DocState, tokens: &TokenStore) -> Result<Vec<u8>, WireFault> {
    #[derive(Serialize)]
    struct LintFrame {
        lint: Vec<WireLint>,
    }
    let findings = super::lint::run(doc, tokens);
    base_wire::encode_frame(&LintFrame {
        lint: findings.iter().map(WireLint::from_lint).collect(),
    })
}

/// Encode a DSL parse failure as a structured rejection frame
/// (`{rejected: "dsl", detail: "line N: …", currentRev}`).
pub fn dsl_rejection(doc: &DocState, e: &super::dsl::DslError) -> Result<Vec<u8>, WireFault> {
    base_wire::encode_frame(&ApplyRejection {
        rejected: "dsl".to_owned(),
        detail: format!("line {}: {}", e.line, e.message),
        current_rev: doc.rev(),
    })
}

fn describe_apply_error(e: &ApplyError) -> (String, String) {
    match e {
        ApplyError::Conflict { current } => {
            ("conflict".to_owned(), format!("stale baseRev; current is {current}"))
        }
        ApplyError::Fence(f) => ("fence".to_owned(), describe_fence(f)),
        ApplyError::Store(s) => ("store".to_owned(), format!("{s:?}")),
        ApplyError::IdInUse(id) => ("idInUse".to_owned(), format!("id '{id}' holds different content")),
    }
}

fn describe_fence(f: &FenceError) -> String {
    match f {
        FenceError::UnknownProp(p) => format!("unknown prop {p}"),
        FenceError::PropNotAllowed { kind, prop } => {
            format!("prop '{prop}' is not allowed on kind '{kind}'")
        }
        FenceError::BadValue { prop, why } => format!("bad value for '{prop}': {why}"),
        FenceError::KindMismatch { kind, why } => format!("kind '{kind}': {why}"),
        FenceError::CapExceeded(what) => format!("cap exceeded: {what}"),
        FenceError::Detail(why) => why.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct RawReq {
        base_rev: u64,
        ops: Vec<super::WireOp>,
    }

    fn doc() -> (DocState, TokenStore) {
        let mut d = DocState::new();
        d.store
            .insert_root(Id::parse("pg:1").expect("pg"), RecordKind::Page)
            .expect("root");
        (d, TokenStore::default_theme())
    }

    fn frame(req: &RawReq) -> Vec<u8> {
        base_wire::encode_frame(req).expect("encode")
    }

    #[derive(Debug, serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct RespEcho {
        rev: Option<u64>,
        patches: Option<Vec<PatchEcho>>,
        noop: Option<bool>,
        rejected: Option<String>,
        current_rev: Option<u64>,
        lint: Option<Vec<LintEcho>>,
    }
    #[derive(Debug, serde::Deserialize)]
    struct LintEcho {
        severity: String,
        code: String,
    }
    #[derive(Debug, serde::Deserialize)]
    struct PatchEcho {
        op: String,
        #[serde(default)]
        html: Option<String>,
        #[serde(default)]
        text: Option<String>,
    }

    #[test]
    fn insert_and_update_round_trip_with_patches() {
        let (mut d, t) = doc();
        let req = RawReq {
            base_rev: 0,
            ops: vec![
                WireOp::Insert {
                    id: Some("nd:a".to_owned()),
                    kind: "text".to_owned(),
                    parent: "pg:1".to_owned(),
                    pos: WirePos::Last,
                    props: vec![("text".to_owned(), WireValue::Str("hi".to_owned()))],
                },
                WireOp::Update {
                    id: "nd:a".to_owned(),
                    set: vec![(
                        "color".to_owned(),
                        WireValue::Token { token: "color.accent".to_owned() },
                    )],
                    unset: vec![],
                },
            ],
        };
        let resp = apply_wire(&mut d, &t, &frame(&req)).expect("apply");
        let echo: RespEcho = base_wire::decode_frame(&resp).expect("decode");
        assert_eq!(echo.rev, Some(1));
        assert_eq!(echo.noop, Some(false));
        let patches = echo.patches.expect("patches");
        assert_eq!(patches.len(), 2);
        assert_eq!(patches[0].op, "insertNode");
        assert!(patches[0].html.as_deref().is_some_and(|h| h.contains(">hi<")));
        assert_eq!(patches[1].op, "setStyle");
    }

    #[test]
    fn lint_rides_the_apply_response() {
        let (mut d, t) = doc();
        let req = RawReq {
            base_rev: 0,
            ops: vec![WireOp::Insert {
                id: Some("nd:s".to_owned()),
                kind: "shape".to_owned(),
                parent: "pg:1".to_owned(),
                pos: WirePos::Last,
                props: vec![("fill".to_owned(), WireValue::Str("#ff0000".to_owned()))],
            }],
        };
        let resp = apply_wire(&mut d, &t, &frame(&req)).expect("apply");
        let echo: RespEcho = base_wire::decode_frame(&resp).expect("decode");
        let lint = echo.lint.expect("lint must ride the apply");
        assert!(
            lint.iter().any(|l| l.code == "raw-literal-themeable" && l.severity == "info"),
            "expected the tier-2 steer, got {lint:?}"
        );
    }

    #[test]
    fn conflict_and_fence_rejections_are_structured_frames() {
        let (mut d, t) = doc();
        // Stale rev.
        let stale = RawReq { base_rev: 9, ops: vec![] };
        let resp = apply_wire(&mut d, &t, &frame(&stale)).expect("frame ok");
        let echo: RespEcho = base_wire::decode_frame(&resp).expect("decode");
        assert_eq!(echo.rejected.as_deref(), Some("conflict"));
        assert_eq!(echo.current_rev, Some(0));
        // Fence violation (text on a frame).
        let bad = RawReq {
            base_rev: 0,
            ops: vec![WireOp::Insert {
                id: Some("nd:f".to_owned()),
                kind: "frame".to_owned(),
                parent: "pg:1".to_owned(),
                pos: WirePos::Last,
                props: vec![("text".to_owned(), WireValue::Str("x".to_owned()))],
            }],
        };
        let resp = apply_wire(&mut d, &t, &frame(&bad)).expect("frame ok");
        let echo: RespEcho = base_wire::decode_frame(&resp).expect("decode");
        assert_eq!(echo.rejected.as_deref(), Some("fence"));
    }

    /// Dep-free fuzz of the untrusted-bytes boundary (the TSK-584 lane's
    /// in-tree pattern, mirroring the highlight runs_utf16 fuzz): (a) pure
    /// byte storms and (b) structure-aware corruptions of a VALID frame —
    /// bit flips, truncations, length-prefix damage. Invariants: never a
    /// panic (the test would abort), every outcome is a typed WireFault or
    /// a decodable response frame, and the document NEVER half-applies —
    /// its fingerprint moves only when the response says a mutation
    /// happened.
    #[test]
    fn fuzz_apply_wire_byte_storms_and_frame_corruptions() {
        // Deterministic xorshift64* — no rand dep, no wall clock.
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };

        let (mut d, t) = doc();
        let valid = frame(&RawReq {
            base_rev: 0,
            ops: vec![WireOp::Insert {
                id: Some("nd:a".to_owned()),
                kind: "text".to_owned(),
                parent: "pg:1".to_owned(),
                pos: WirePos::Last,
                props: vec![("text".to_owned(), WireValue::Str("seed".to_owned()))],
            }],
        });

        for round in 0..1200usize {
            let bytes: Vec<u8> = if round % 2 == 0 {
                // Pure storm: 0..96 random bytes.
                let len = usize::try_from(next() % 96).unwrap_or(0);
                (0..len).map(|_| (next() & 0xFF) as u8).collect()
            } else {
                // Structure-aware: corrupt the valid frame.
                let mut b = valid.clone();
                match next() % 4 {
                    0 => {
                        // Bit flip somewhere.
                        let i = usize::try_from(next() % b.len() as u64).unwrap_or(0);
                        b[i] ^= 1 << (next() % 8);
                    }
                    1 => {
                        // Truncate.
                        b.truncate(usize::try_from(next() % b.len() as u64).unwrap_or(0));
                    }
                    2 => {
                        // Damage the length prefix.
                        let i = usize::try_from(next() % 4.min(b.len()) as u64).unwrap_or(0);
                        b[i] = (next() & 0xFF) as u8;
                    }
                    _ => {
                        // Append garbage.
                        let extra = usize::try_from(next() % 16).unwrap_or(0);
                        b.extend((0..extra).map(|_| (next() & 0xFF) as u8));
                    }
                }
                b
            };

            let before = d.store.fingerprint();
            let rev_before = d.rev();
            match apply_wire(&mut d, &t, &bytes) {
                Err(_) => {
                    // Typed fault: state must be untouched.
                    assert_eq!(d.store.fingerprint(), before, "fault mutated state");
                    assert_eq!(d.rev(), rev_before);
                }
                Ok(resp) => {
                    // Any Ok frame must decode; state may move only if the
                    // response is a non-noop success.
                    let echo: RespEcho =
                        base_wire::decode_frame(&resp).expect("Ok frames decode");
                    let mutated = echo.rev.is_some() && echo.noop == Some(false);
                    if !mutated {
                        assert_eq!(
                            d.store.fingerprint(),
                            before,
                            "rejection/noop mutated state"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn malformed_frames_and_unknown_vocabulary_are_wire_faults() {
        let (mut d, t) = doc();
        assert!(apply_wire(&mut d, &t, &[0xFF, 0x01]).is_err());
        let unknown_kind = RawReq {
            base_rev: 0,
            ops: vec![WireOp::Insert {
                id: None,
                kind: "wormhole".to_owned(),
                parent: "pg:1".to_owned(),
                pos: WirePos::Last,
                props: vec![],
            }],
        };
        assert!(apply_wire(&mut d, &t, &frame(&unknown_kind)).is_err());
        let unknown_prop = RawReq {
            base_rev: 0,
            ops: vec![WireOp::Update {
                id: "pg:1".to_owned(),
                set: vec![("bling".to_owned(), WireValue::Num(1.0))],
                unset: vec![],
            }],
        };
        assert!(apply_wire(&mut d, &t, &frame(&unknown_prop)).is_err());
    }
}
