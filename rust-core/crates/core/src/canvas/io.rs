//! Canvas M1.S7 — persistence (TSK-1362; 02-CORE-ENGINE §6).
//!
//! CANONICAL JSON on disk (Q2: JSON serializes the IR; it is not the agent
//! interface): `{formatVersion, rev, serial, root, records[], tombstones[],
//! tokens{}}` with records sorted by id and tokens by path — byte-stable, so
//! saves diff cleanly in git and goldens can pin exact bytes. Zero new deps:
//! the reader is the in-house [`crate::json`] parser; the writer is a small
//! canonical emitter here.
//!
//! `formatVersion` gates loads: newer-than-us is a typed refusal (never a
//! silent misparse); older versions walk the MIGRATION ladder — v1 is the
//! base, each future bump adds one `migrate_vN_to_vN+1` step, and loads walk
//! them in sequence (the DTCG/Spectrum never-strand-a-document rule).

use super::doc::CanvasDoc;
use super::ops::DocState;
use super::props::{PropBag, PropKey, Value};
use super::store::{FracIndex, Id, Place, Record, RecordKind, Store};
use super::tokens::{TokenDef, TokenStore, TokenValue};
use super::registry;
use crate::json::{self, JsonValue};

/// The current on-disk format.
pub const FORMAT_VERSION: u64 = 1;

/// Load faults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IoError {
    /// Not JSON at all (what + byte offset).
    Parse(String),
    /// JSON, but not this format's shape.
    BadShape(String),
    /// Written by a NEWER app — refuse loudly, never misparse.
    TooNew(u64),
}

// MARK: - canonical writer

fn esc(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn value_json(v: &Value, out: &mut String) {
    match v {
        Value::Str(s) => {
            out.push_str("{\"t\":\"s\",\"v\":");
            esc(s, out);
            out.push('}');
        }
        Value::Num(n) => {
            out.push_str("{\"t\":\"n\",\"v\":");
            out.push_str(&format!("{n}"));
            out.push('}');
        }
        Value::Bool(b) => {
            out.push_str("{\"t\":\"b\",\"v\":");
            out.push_str(if *b { "true" } else { "false" });
            out.push('}');
        }
        Value::Token(p) => {
            out.push_str("{\"t\":\"tok\",\"v\":");
            esc(p, out);
            out.push('}');
        }
    }
}

/// Serialize a document to canonical JSON (byte-stable: same doc ⇒ same
/// bytes; records id-sorted, props key-sorted by construction, tokens
/// path-sorted).
#[must_use]
pub fn save(doc: &CanvasDoc) -> String {
    let mut out = String::with_capacity(4096);
    out.push_str("{\"formatVersion\":");
    out.push_str(&FORMAT_VERSION.to_string());
    out.push_str(",\"rev\":");
    out.push_str(&doc.state.rev().to_string());
    out.push_str(",\"serial\":");
    out.push_str(&doc.state.store.serial().to_string());
    out.push_str(",\"root\":");
    esc(doc.root.as_str(), &mut out);

    // Records, id-sorted.
    out.push_str(",\"records\":[");
    let mut ids: Vec<&Id> = doc.state.store.ids().collect();
    ids.sort();
    let mut first = true;
    for id in ids {
        let Some(rec) = doc.state.store.get(id) else { continue };
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str("{\"id\":");
        esc(id.as_str(), &mut out);
        out.push_str(",\"kind\":");
        esc(registry::kind_name(rec.kind), &mut out);
        if let Some(place) = &rec.place {
            out.push_str(",\"parent\":");
            esc(place.parent.as_str(), &mut out);
            out.push_str(",\"index\":");
            esc(place.index.as_str(), &mut out);
        }
        out.push_str(",\"props\":{");
        let mut pfirst = true;
        for (key, value) in rec.props.iter() {
            let Some(name) = key.name() else { continue };
            if !pfirst {
                out.push(',');
            }
            pfirst = false;
            esc(name, &mut out);
            out.push(':');
            value_json(value, &mut out);
        }
        out.push_str("}}");
    }
    out.push(']');

    // Tombstones, sorted.
    out.push_str(",\"tombstones\":[");
    let mut stones: Vec<&Id> = doc.state.store.tombstone_ids().collect();
    stones.sort();
    for (i, id) in stones.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        esc(id.as_str(), &mut out);
    }
    out.push(']');

    // Tokens, path-sorted.
    out.push_str(",\"tokens\":{");
    let mut paths: Vec<&str> = doc.tokens.paths().collect();
    paths.sort_unstable();
    for (i, path) in paths.iter().enumerate() {
        let Some(def) = doc.tokens.def(path) else { continue };
        if i > 0 {
            out.push(',');
        }
        esc(path, &mut out);
        out.push_str(":{");
        match &def.value {
            TokenValue::Literal(css) => {
                out.push_str("\"value\":");
                esc(css, &mut out);
            }
            TokenValue::Alias(target) => {
                out.push_str("\"alias\":");
                esc(target, &mut out);
            }
        }
        if let Some(dep) = &def.deprecated_for {
            out.push_str(",\"deprecatedFor\":");
            esc(dep, &mut out);
        }
        out.push('}');
    }
    out.push_str("}}");
    out
}

// MARK: - loader + migration ladder

fn bad(what: &str) -> IoError {
    IoError::BadShape(what.to_owned())
}

fn need_str(v: &JsonValue, what: &str) -> Result<String, IoError> {
    v.as_str().map(str::to_owned).ok_or_else(|| bad(what))
}

fn need_u64(v: Option<&JsonValue>, what: &str) -> Result<u64, IoError> {
    match v {
        Some(JsonValue::Int(i)) if *i >= 0 => u64::try_from(*i).map_err(|_| bad(what)),
        _ => Err(bad(what)),
    }
}

fn parse_value(v: &JsonValue) -> Result<Value, IoError> {
    let t = v.get("t").and_then(JsonValue::as_str).ok_or_else(|| bad("value.t"))?;
    let payload = v.get("v").ok_or_else(|| bad("value.v"))?;
    Ok(match t {
        "s" => Value::Str(need_str(payload, "value.v str")?),
        "tok" => Value::Token(need_str(payload, "value.v token")?),
        "b" => match payload {
            JsonValue::Bool(b) => Value::Bool(*b),
            _ => return Err(bad("value.v bool")),
        },
        "n" => match payload {
            JsonValue::Int(i) => {
                // f64 holds integral values up to 2^53 exactly; canvas
                // numerics (px, spans, opacities) are far below that.
                #[allow(clippy::cast_precision_loss)]
                Value::Num(*i as f64)
            }
            JsonValue::Float(f) => Value::Num(*f),
            _ => return Err(bad("value.v num")),
        },
        other => return Err(bad(&format!("value.t '{other}'"))),
    })
}

fn parse_kind(s: &str) -> Result<RecordKind, IoError> {
    Ok(match s {
        "page" => RecordKind::Page,
        "frame" => RecordKind::Frame,
        "text" => RecordKind::Text,
        "image" => RecordKind::Image,
        "shape" => RecordKind::Shape,
        "component" => RecordKind::Component,
        "embed" => RecordKind::Embed,
        "hole" => RecordKind::Hole,
        "table" => RecordKind::Table,
        "code" => RecordKind::Code,
        other => return Err(bad(&format!("kind '{other}'"))),
    })
}

/// The migration ladder: raise `value` from `from_version` to
/// [`FORMAT_VERSION`], one step at a time. v1 is the base — the ladder is
/// empty today; each future format bump adds one arm here and ONLY here.
fn migrate(from_version: u64, value: JsonValue) -> Result<JsonValue, IoError> {
    // v1 is the base format, so no ladder steps exist yet. Each future bump
    // adds one step here and loops until FORMAT_VERSION, e.g.:
    //   let v = migrate_v1_to_v2(value)?; then v2→v3, ...
    let _ = value;
    Err(bad(&format!("no migration from v{from_version}")))
}

/// Load a document from its canonical JSON.
pub fn load(text: &str) -> Result<CanvasDoc, IoError> {
    let parsed = json::parse(text)
        .map_err(|e| IoError::Parse(format!("{e:?}")))?;
    let version = need_u64(parsed.get("formatVersion"), "formatVersion")?;
    if version > FORMAT_VERSION {
        return Err(IoError::TooNew(version));
    }
    let parsed = if version < FORMAT_VERSION {
        migrate(version, parsed)?
    } else {
        parsed
    };

    let rev = need_u64(parsed.get("rev"), "rev")?;
    let serial = need_u64(parsed.get("serial"), "serial")?;
    let root = Id::parse(&need_str(
        parsed.get("root").ok_or_else(|| bad("root"))?,
        "root",
    )?)
    .map_err(|e| bad(&format!("root id: {e:?}")))?;

    let mut store = Store::new();
    let records = parsed
        .get("records")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| bad("records"))?;
    let mut rebuilt: Vec<Record> = Vec::with_capacity(records.len());
    for entry in records {
        let id = Id::parse(&need_str(
            entry.get("id").ok_or_else(|| bad("record.id"))?,
            "record.id",
        )?)
        .map_err(|e| bad(&format!("record id: {e:?}")))?;
        let kind = parse_kind(
            entry.get("kind").and_then(JsonValue::as_str).ok_or_else(|| bad("record.kind"))?,
        )?;
        let place = match (entry.get("parent"), entry.get("index")) {
            (Some(p), Some(ix)) => Some(Place {
                parent: Id::parse(&need_str(p, "record.parent")?)
                    .map_err(|e| bad(&format!("parent id: {e:?}")))?,
                index: FracIndex::parse(&need_str(ix, "record.index")?)
                    .map_err(|e| bad(&format!("index: {e:?}")))?,
            }),
            (None, None) => None,
            _ => return Err(bad("record place: parent/index must come together")),
        };
        let mut props = PropBag::new();
        if let Some(JsonValue::Object(pairs)) = entry.get("props") {
            for (name, value) in pairs {
                let key = PropKey::by_name(name)
                    .ok_or_else(|| bad(&format!("unknown prop '{name}'")))?;
                props.set(key, parse_value(value)?);
            }
        }
        rebuilt.push(Record { id, kind, place, props });
    }
    store
        .restore_records(rebuilt)
        .map_err(|e| bad(&format!("records restore: {e:?}")))?;

    let stones = parsed
        .get("tombstones")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| bad("tombstones"))?;
    let mut stone_ids: Vec<Id> = Vec::with_capacity(stones.len());
    for s in stones {
        stone_ids.push(
            Id::parse(&need_str(s, "tombstone")?)
                .map_err(|e| bad(&format!("tombstone id: {e:?}")))?,
        );
    }
    store.restore_tombstones(stone_ids);
    store.restore_serial(serial);

    let mut tokens = TokenStore::new();
    if let Some(JsonValue::Object(pairs)) = parsed.get("tokens") {
        for (path, def) in pairs {
            let value = if let Some(v) = def.get("value") {
                TokenValue::Literal(need_str(v, "token.value")?)
            } else if let Some(a) = def.get("alias") {
                TokenValue::Alias(need_str(a, "token.alias")?)
            } else {
                return Err(bad(&format!("token '{path}' has neither value nor alias")));
            };
            let deprecated_for = match def.get("deprecatedFor") {
                Some(d) => Some(need_str(d, "token.deprecatedFor")?),
                None => None,
            };
            tokens
                .set_def(path, TokenDef { value, deprecated_for })
                .map_err(|e| bad(&format!("token '{path}': {e:?}")))?;
        }
    } else {
        return Err(bad("tokens"));
    }

    if store.get(&root).is_none() {
        return Err(bad("root record missing"));
    }
    Ok(CanvasDoc::from_parts(DocState::restore(store, rev), tokens, root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::ops::CanvasOp;
    use crate::canvas::store::Position;

    fn built_doc() -> CanvasDoc {
        let mut doc = CanvasDoc::new_empty();
        let ops = [
            CanvasOp::Insert {
                id: Some(Id::parse("nd:hero").expect("id")),
                kind: RecordKind::Frame,
                parent: doc.root.clone(),
                pos: Position::Last,
                props: vec![
                    (PropKey::by_name("fill").expect("k"), Value::Token("color.surface".into())),
                    (PropKey::by_name("gap").expect("k"), Value::Num(8.0)),
                ],
            },
            CanvasOp::Insert {
                id: None,
                kind: RecordKind::Text,
                parent: Id::parse("nd:hero").expect("id"),
                pos: Position::Last,
                props: vec![(
                    PropKey::by_name("text").expect("k"),
                    Value::Str("quote \"x\" and\nnewline".into()),
                )],
            },
        ];
        doc.state.apply(0, &ops).expect("seed");
        // A removal so tombstones are non-empty.
        let rm = [CanvasOp::Insert {
            id: Some(Id::parse("nd:gone").expect("id")),
            kind: RecordKind::Shape,
            parent: doc.root.clone(),
            pos: Position::Last,
            props: vec![],
        }];
        doc.state.apply(1, &rm).expect("rm-seed");
        doc.state
            .apply(2, &[CanvasOp::Remove { id: Id::parse("nd:gone").expect("id") }])
            .expect("rm");
        doc
    }

    #[test]
    fn save_load_round_trips_exactly() {
        let doc = built_doc();
        let saved = save(&doc);
        let loaded = load(&saved).expect("load");
        assert_eq!(loaded.state.rev(), doc.state.rev());
        assert_eq!(loaded.root, doc.root);
        assert_eq!(
            loaded.state.store.fingerprint(),
            doc.state.store.fingerprint(),
            "content identical"
        );
        assert_eq!(save(&loaded), saved, "save∘load∘save is byte-identical");
    }

    #[test]
    fn saves_are_byte_stable_and_id_sorted() {
        let doc = built_doc();
        assert_eq!(save(&doc), save(&doc));
        let s = save(&doc);
        let hero = s.find("{\"id\":\"nd:hero\"").expect("hero record");
        let page = s.find("{\"id\":\"pg:1\"").expect("page record");
        assert!(hero < page, "records are id-sorted (nd:* before pg:*)");
    }

    #[test]
    fn loaded_docs_keep_minting_fresh_ids_and_reject_tombstones() {
        let doc = built_doc();
        let mut loaded = load(&save(&doc)).expect("load");
        let rev = loaded.state.rev();
        // Fresh mints must not collide with anything loaded.
        let applied = loaded
            .state
            .apply(
                rev,
                &[CanvasOp::Insert {
                    id: None,
                    kind: RecordKind::Text,
                    parent: loaded.root.clone(),
                    pos: Position::Last,
                    props: vec![],
                }],
            )
            .expect("mint");
        assert_eq!(applied.minted.len(), 1);
        // The tombstoned id stays dead across the round trip.
        let rev2 = loaded.state.rev();
        let err = loaded
            .state
            .apply(
                rev2,
                &[CanvasOp::Insert {
                    id: Some(Id::parse("nd:gone").expect("id")),
                    kind: RecordKind::Shape,
                    parent: loaded.root.clone(),
                    pos: Position::Last,
                    props: vec![],
                }],
            )
            .expect_err("tombstone");
        let _ = err;
    }

    #[test]
    fn version_gate_refuses_newer_and_unknown_migrations() {
        let doc = built_doc();
        let newer = save(&doc).replace("\"formatVersion\":1", "\"formatVersion\":99");
        assert!(matches!(load(&newer), Err(IoError::TooNew(99))));
        let older = save(&doc).replace("\"formatVersion\":1", "\"formatVersion\":0");
        assert!(matches!(load(&older), Err(IoError::BadShape(_))));
    }

    #[test]
    fn malformed_documents_fail_typed_not_panicky() {
        assert!(matches!(load("not json at all"), Err(IoError::Parse(_))));
        assert!(matches!(load("{}"), Err(IoError::BadShape(_))));
        let doc = built_doc();
        let broken = save(&doc).replace("\"kind\":\"frame\"", "\"kind\":\"portal\"");
        assert!(matches!(load(&broken), Err(IoError::BadShape(_))));
    }

    /// GOLDEN: the exact v1 bytes for a tiny document. If this test breaks,
    /// the on-disk format changed — that REQUIRES a formatVersion bump + a
    /// migration arm, not a fixture update.
    #[test]
    fn golden_v1_fixture_parses_and_reserializes() {
        let golden = "{\"formatVersion\":1,\"rev\":1,\"serial\":0,\"root\":\"pg:1\",\
\"records\":[{\"id\":\"nd:t\",\"kind\":\"text\",\"parent\":\"pg:1\",\"index\":\"V\",\
\"props\":{\"text\":{\"t\":\"s\",\"v\":\"hello\"}}},{\"id\":\"pg:1\",\"kind\":\"page\",\
\"props\":{}}],\"tombstones\":[],\"tokens\":{\"color.fg\":{\"alias\":\"base.black\",\
\"deprecatedFor\":\"color.ink\"},\"space.md\":{\"value\":\"16px\"}}}";
        let loaded = load(golden).expect("golden must load");
        assert_eq!(save(&loaded), golden, "golden bytes are the canonical form");
        assert_eq!(loaded.tokens.deprecated_replacement("color.fg"), Some("color.ink"));
    }
}
