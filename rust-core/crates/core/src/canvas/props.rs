//! Canvas M1.S2 — interned property keys + typed values + the per-record
//! prop bag (TSK-1357; design 02-CORE-ENGINE §2c/§3).
//!
//! Keys are `u16` symbols assigned ONCE in a closed registry table (ABI-like:
//! never renumber, add at the end) — the §2c interning commitment: a prop is
//! `(u16, CompactValue)`, no string keys and no boxed JSON values in memory.
//! Values distinguish design-token references from literals at the TYPE level
//! so the tier-2 steering lint (§3b/§5) is structural, not string-sniffing.

/// A property key symbol. Stable: the table below is append-only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PropKey(pub u16);

/// The closed v1 key table: `(symbol, canonical name)`. CSS/Figma-familiar
/// names (research R9: meet the training distribution in vocabulary).
/// APPEND-ONLY — a key's u16 is forever.
const KEY_TABLE: &[(u16, &str)] = &[
    (1, "text"),
    (2, "src"),
    (3, "fit"),
    (4, "shape"),
    (5, "gap"),
    (6, "padding"),
    (7, "align"),
    (8, "justify"),
    (9, "direction"),
    (10, "wrap"),
    (11, "grow"),
    (12, "shrink"),
    (13, "span"),
    (14, "minW"),
    (15, "maxW"),
    (16, "minH"),
    (17, "maxH"),
    (18, "fill"),
    (19, "stroke"),
    (20, "color"),
    (21, "font"),
    (22, "radius"),
    (23, "shadow"),
    (24, "opacity"),
    (25, "ref"),
    (26, "html"),
    (27, "note"),
    (28, "role"),
    // M4.S2: the instance text-override table (compact JSON, component-only).
    (29, "overrides"),
    // M4.S7a: table cell data (JSON array-of-arrays) + header-row flag.
    (30, "data"),
    (31, "headers"),
    // M4.S7a: code language tag.
    (32, "language"),
    // M4.S7b: chart spec (VL-subset JSON).
    (33, "spec"),
    // M5.S6: prototype nav — click scrolls to the referenced node.
    (34, "linkTo"),
    // M6.S2: presentation step — the node reveals at this step (u16).
    (35, "step"),
];

impl PropKey {
    /// Resolve a canonical name to its symbol.
    #[must_use]
    pub fn by_name(name: &str) -> Option<PropKey> {
        KEY_TABLE
            .iter()
            .find(|(_, n)| *n == name)
            .map(|(k, _)| PropKey(*k))
    }

    /// The canonical name for this symbol.
    #[must_use]
    pub fn name(self) -> Option<&'static str> {
        KEY_TABLE.iter().find(|(k, _)| *k == self.0).map(|(_, n)| *n)
    }
}

/// A property value. Token references are a distinct variant — the fence and
/// lint reason about literal-vs-token structurally.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Num(f64),
    Bool(bool),
    /// A design-token reference (`$color.accent` in the DSL; `{token: "..."}`
    /// on the wire).
    Token(String),
}

/// The per-record property bag: keys kept sorted for canonical serialization
/// and O(log n) lookup. Small by design (caps in the registry).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PropBag {
    entries: Vec<(PropKey, Value)>,
}

impl PropBag {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    #[must_use]
    pub fn get(&self, key: PropKey) -> Option<&Value> {
        self.entries
            .binary_search_by_key(&key, |(k, _)| *k)
            .ok()
            .and_then(|i| self.entries.get(i))
            .map(|(_, v)| v)
    }

    /// Insert or replace; keeps the bag sorted.
    pub fn set(&mut self, key: PropKey, value: Value) {
        match self.entries.binary_search_by_key(&key, |(k, _)| *k) {
            Ok(i) => {
                if let Some(slot) = self.entries.get_mut(i) {
                    slot.1 = value;
                }
            }
            Err(i) => self.entries.insert(i, (key, value)),
        }
    }

    /// Remove a key (no-op when absent). Returns whether it was present.
    pub fn unset(&mut self, key: PropKey) -> bool {
        match self.entries.binary_search_by_key(&key, |(k, _)| *k) {
            Ok(i) => {
                self.entries.remove(i);
                true
            }
            Err(_) => false,
        }
    }

    /// Iterate in canonical (key-sorted) order.
    pub fn iter(&self) -> impl Iterator<Item = (PropKey, &Value)> {
        self.entries.iter().map(|(k, v)| (*k, v))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_table_round_trips_and_is_unique() {
        let mut seen_ids = std::collections::HashSet::new();
        let mut seen_names = std::collections::HashSet::new();
        for (id, name) in KEY_TABLE {
            assert!(seen_ids.insert(*id), "duplicate key id {id}");
            assert!(seen_names.insert(*name), "duplicate key name {name}");
            let key = PropKey::by_name(name).expect("by_name");
            assert_eq!(key, PropKey(*id));
            assert_eq!(key.name(), Some(*name));
        }
        assert!(PropKey::by_name("nope").is_none());
        assert!(PropKey(9999).name().is_none());
    }

    #[test]
    fn bag_sorted_set_get_replace_unset() {
        let mut bag = PropBag::new();
        let text = PropKey::by_name("text").expect("text");
        let fill = PropKey::by_name("fill").expect("fill");
        let gap = PropKey::by_name("gap").expect("gap");
        bag.set(fill, Value::Token("color.bg".to_owned()));
        bag.set(text, Value::Str("hi".to_owned()));
        bag.set(gap, Value::Num(8.0));
        // Canonical order = key order regardless of insertion order.
        let keys: Vec<u16> = bag.iter().map(|(k, _)| k.0).collect();
        let mut sorted = keys.clone();
        sorted.sort_unstable();
        assert_eq!(keys, sorted);
        // Replace in place.
        bag.set(text, Value::Str("bye".to_owned()));
        assert_eq!(bag.get(text), Some(&Value::Str("bye".to_owned())));
        assert_eq!(bag.len(), 3);
        // Unset.
        assert!(bag.unset(gap));
        assert!(!bag.unset(gap));
        assert_eq!(bag.get(gap), None);
    }
}
