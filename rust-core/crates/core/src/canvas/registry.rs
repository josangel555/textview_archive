//! Canvas M1.S2 — the type registry + validation fence rules (TSK-1357).
//!
//! One `TypeSpec` per record kind: which props are legal, which value shapes
//! they take, whether the kind bears text or children. The fence rejects —
//! typed errors, never panics — BEFORE anything mutates (02-CORE-ENGINE §4).
//! Includes the M0.S3 live-discovered rule: **ops must be kind-checked
//! against their target** (`setText` on a frame wiped its DOM subtree).
//!
//! The registry is the SINGLE SOURCE OF TRUTH the DSL vocabulary artifacts
//! generate from (07-DSL-SPIKE §2) — teaching docs can never drift from the
//! validator because they are emitted from this table.

use super::props::{PropKey, Value};
use super::store::RecordKind;

/// Resource caps (02 §4 fence; DoS-shaped input fails as data).
pub const MAX_PROPS_PER_RECORD: usize = 64;
pub const MAX_TEXT_LEN: usize = 64 * 1024;
pub const MAX_STRING_LEN: usize = 4 * 1024;
pub const MAX_CHILDREN_PER_PARENT: usize = 4096;
pub const MAX_RECORDS_PER_DOC: usize = 100_000;

/// Fence faults — every rejection names itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FenceError {
    /// The key is not in the closed table at all.
    UnknownProp(String),
    /// The key exists but this kind doesn't take it (with a teaching hint).
    PropNotAllowed { kind: &'static str, prop: &'static str },
    /// Wrong value shape/range for the key.
    BadValue { prop: &'static str, why: &'static str },
    /// An op targeted a kind that can't take it (the frame-wipe rule).
    KindMismatch { kind: &'static str, why: &'static str },
    /// A resource cap fired.
    CapExceeded(&'static str),
    /// Store-dependent fence failures whose teaching message needs runtime
    /// detail (M4.S2: override anchors; anything the static variants can't
    /// carry).
    Detail(String),
}

/// Kind names for error messages.
#[must_use]
pub fn kind_name(kind: RecordKind) -> &'static str {
    match kind {
        RecordKind::Page => "page",
        RecordKind::Frame => "frame",
        RecordKind::Text => "text",
        RecordKind::Image => "image",
        RecordKind::Shape => "shape",
        RecordKind::Component => "component",
        RecordKind::Embed => "embed",
        RecordKind::Hole => "hole",
        RecordKind::Table => "table",
        RecordKind::Code => "code",
        RecordKind::Chart => "chart",
        RecordKind::Diagram => "diagram",
    }
}

/// Does this kind bear TEXT content (may take `setText`-class ops)?
#[must_use]
pub fn bears_text(kind: RecordKind) -> bool {
    matches!(kind, RecordKind::Text)
}

/// Prop names legal per kind. Shared style/layout groups spelled out so the
/// table stays greppable; the closed key table lives in `props.rs`.
pub fn allowed_names(kind: RecordKind) -> &'static [&'static str] {
    const CONTAINER: &[&str] = &[
        "gap", "padding", "align", "justify", "direction", "wrap", "fill", "stroke", "radius",
        "shadow", "opacity", "minW", "maxW", "minH", "maxH", "grow", "shrink", "span",
    ];
    const TEXT: &[&str] = &[
        "text", "role", "color", "font", "opacity", "grow", "shrink", "span", "minW", "maxW",
        "minH", "maxH",
    ];
    const IMAGE: &[&str] = &[
        "src", "fit", "radius", "opacity", "grow", "shrink", "span", "minW", "maxW", "minH",
        "maxH",
    ];
    const SHAPE: &[&str] = &[
        "shape", "fill", "stroke", "radius", "opacity", "grow", "shrink", "span", "minW", "maxW",
        "minH", "maxH",
    ];
    const COMPONENT: &[&str] = &[
        // M4.S2: instance props override the expansion ROOT (fill/spacing/
        // sizing — the wrapper IS the box); `overrides` carries the
        // text-by-anchor table (compact JSON, fence-validated).
        "ref", "overrides", "fill", "stroke", "radius", "shadow", "opacity",
        "gap", "padding", "minW", "maxW", "minH", "maxH",
        "grow", "shrink", "span",
    ];
    const EMBED: &[&str] = &["html", "minW", "maxW", "minH", "maxH", "grow", "shrink", "span"];
    const HOLE: &[&str] = &["note", "minW", "maxW", "minH", "maxH"];
    const TABLE: &[&str] = &[
        "data", "headers", "fill", "stroke", "radius", "opacity",
        "minW", "maxW", "minH", "maxH", "grow", "shrink", "span",
    ];
    const CHART: &[&str] = &[
        "spec", "fill", "radius", "opacity",
        "minW", "maxW", "minH", "maxH", "grow", "shrink", "span",
    ];
    const DIAGRAM: &[&str] = &[
        "text", "fill", "radius", "opacity",
        "minW", "maxW", "minH", "maxH", "grow", "shrink", "span",
    ];
    const CODE: &[&str] = &[
        "text", "language", "fill", "radius", "opacity",
        "minW", "maxW", "minH", "maxH", "grow", "shrink", "span",
    ];
    match kind {
        RecordKind::Page | RecordKind::Frame => CONTAINER,
        RecordKind::Text => TEXT,
        RecordKind::Image => IMAGE,
        RecordKind::Shape => SHAPE,
        RecordKind::Component => COMPONENT,
        RecordKind::Table => TABLE,
        RecordKind::Code => CODE,
        RecordKind::Chart => CHART,
        RecordKind::Diagram => DIAGRAM,
        RecordKind::Embed => EMBED,
        RecordKind::Hole => HOLE,
    }
}

/// Is `key` legal on `kind`?
pub fn check_allowed(kind: RecordKind, key: PropKey) -> Result<(), FenceError> {
    let Some(name) = key.name() else {
        return Err(FenceError::UnknownProp(format!("key#{}", key.0)));
    };
    if allowed_names(kind).contains(&name) {
        Ok(())
    } else {
        Err(FenceError::PropNotAllowed {
            kind: kind_name(kind),
            prop: name,
        })
    }
}

/// Validate a value's SHAPE for a key (range/type rules — the closed style
/// set's lintable core). Token refs are legal wherever literals are; the
/// tier-2 steering is a LINT nag, not a fence rejection (02 §5).
pub fn check_value(key: PropKey, value: &Value) -> Result<(), FenceError> {
    let Some(name) = key.name() else {
        return Err(FenceError::UnknownProp(format!("key#{}", key.0)));
    };
    let bad = |why: &'static str| Err(FenceError::BadValue { prop: name, why });
    match (name, value) {
        // Free-text strings, capped.
        ("text", Value::Str(s)) => {
            if s.len() > MAX_TEXT_LEN {
                return Err(FenceError::CapExceeded("text length"));
            }
            Ok(())
        }
        // Table data: a JSON payload, text-cap sized (structure validated
        // at lowering + lint; the fence caps bytes).
        ("spec", Value::Str(s)) => {
            if s.len() > MAX_TEXT_LEN {
                return Err(FenceError::CapExceeded("chart spec length"));
            }
            Ok(())
        }
        ("data", Value::Str(s)) => {
            if s.len() > MAX_TEXT_LEN {
                return Err(FenceError::CapExceeded("table data length"));
            }
            Ok(())
        }
        ("headers", Value::Bool(_)) => Ok(()),
        ("html" | "src" | "ref" | "note" | "role" | "font" | "fill" | "stroke" | "color"
            | "shadow" | "shape" | "fit" | "align" | "justify" | "direction"
            | "overrides" | "language", Value::Str(s)) => {
            if s.len() > MAX_STRING_LEN {
                return Err(FenceError::CapExceeded("string length"));
            }
            Ok(())
        }
        // Numeric, non-negative.
        ("gap" | "padding" | "radius" | "minW" | "maxW" | "minH" | "maxH" | "grow" | "shrink",
            Value::Num(n)) => {
            if n.is_finite() && *n >= 0.0 { Ok(()) } else { bad("must be a finite number >= 0") }
        }
        ("span", Value::Num(n)) => {
            if n.is_finite() && *n >= 1.0 { Ok(()) } else { bad("must be a finite number >= 1") }
        }
        ("opacity", Value::Num(n)) => {
            if n.is_finite() && (0.0..=1.0).contains(n) { Ok(()) } else { bad("must be 0..=1") }
        }
        ("wrap", Value::Bool(_)) => Ok(()),
        // Token refs allowed for themeable slots.
        ("fill" | "stroke" | "color" | "font" | "radius" | "shadow" | "gap" | "padding",
            Value::Token(t)) => {
            if t.is_empty() || t.len() > MAX_STRING_LEN {
                bad("token path must be non-empty and bounded")
            } else {
                Ok(())
            }
        }
        _ => bad("wrong value type for this prop"),
    }
}

/// The full per-prop fence: allowed on the kind AND a legal value shape.
pub fn check_prop(kind: RecordKind, key: PropKey, value: &Value) -> Result<(), FenceError> {
    check_allowed(kind, key)?;
    check_value(key, value)
}

/// The M0.S3 rule: a text-mutating op must target a text-bearing kind
/// (`setText` on a container wiped its subtree via textContent).
pub fn check_text_target(kind: RecordKind) -> Result<(), FenceError> {
    if bears_text(kind) {
        Ok(())
    } else {
        Err(FenceError::KindMismatch {
            kind: kind_name(kind),
            why: "setText targets must bear text (the M0 frame-wipe rule)",
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    #[test]
    fn frame_rejects_text_prop_and_settext_targets() {
        assert!(matches!(
            check_allowed(RecordKind::Frame, key("text")),
            Err(FenceError::PropNotAllowed { kind: "frame", prop: "text" })
        ));
        assert!(matches!(
            check_text_target(RecordKind::Frame),
            Err(FenceError::KindMismatch { .. })
        ));
        assert!(check_text_target(RecordKind::Text).is_ok());
    }

    #[test]
    fn value_shapes_are_enforced() {
        assert!(check_value(key("opacity"), &Value::Num(0.5)).is_ok());
        assert!(matches!(
            check_value(key("opacity"), &Value::Num(1.5)),
            Err(FenceError::BadValue { prop: "opacity", .. })
        ));
        assert!(matches!(
            check_value(key("gap"), &Value::Num(-1.0)),
            Err(FenceError::BadValue { .. })
        ));
        assert!(matches!(
            check_value(key("gap"), &Value::Num(f64::NAN)),
            Err(FenceError::BadValue { .. })
        ));
        assert!(matches!(
            check_value(key("text"), &Value::Num(3.0)),
            Err(FenceError::BadValue { .. })
        ));
        assert!(check_value(key("wrap"), &Value::Bool(true)).is_ok());
    }

    #[test]
    fn token_refs_legal_on_themeable_slots_only() {
        assert!(check_value(key("fill"), &Value::Token("color.bg".into())).is_ok());
        assert!(check_value(key("gap"), &Value::Token("space.md".into())).is_ok());
        assert!(matches!(
            check_value(key("text"), &Value::Token("nope".into())),
            Err(FenceError::BadValue { .. })
        ));
        assert!(matches!(
            check_value(key("fill"), &Value::Token(String::new())),
            Err(FenceError::BadValue { .. })
        ));
    }

    #[test]
    fn caps_fire_as_typed_errors() {
        let big = "x".repeat(MAX_TEXT_LEN + 1);
        assert!(matches!(
            check_value(key("text"), &Value::Str(big)),
            Err(FenceError::CapExceeded("text length"))
        ));
        let bigs = "y".repeat(MAX_STRING_LEN + 1);
        assert!(matches!(
            check_value(key("src"), &Value::Str(bigs)),
            Err(FenceError::CapExceeded("string length"))
        ));
    }

    #[test]
    fn every_kind_has_a_valid_allowed_table() {
        for kind in [
            RecordKind::Page,
            RecordKind::Frame,
            RecordKind::Text,
            RecordKind::Image,
            RecordKind::Shape,
            RecordKind::Component,
            RecordKind::Embed,
            RecordKind::Hole,
        ] {
            for name in allowed_names(kind) {
                assert!(
                    PropKey::by_name(name).is_some(),
                    "{} allows unknown key '{name}'",
                    kind_name(kind)
                );
            }
        }
    }

    #[test]
    fn full_prop_fence_combines_both_checks() {
        assert!(check_prop(RecordKind::Text, key("text"), &Value::Str("hi".into())).is_ok());
        assert!(check_prop(RecordKind::Frame, key("text"), &Value::Str("hi".into())).is_err());
        assert!(check_prop(RecordKind::Text, key("opacity"), &Value::Num(2.0)).is_err());
    }
}
