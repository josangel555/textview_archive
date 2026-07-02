//! Canvas — the M1 engine (docs/canvas/02-CORE-ENGINE.md).
//!
//! Modules: `store` (flat records, fractional order) · `props`/`registry`
//! (interned keys + validation fence) · `ops` (atomic revisioned batches +
//! exact-state undo) · `tokens` (DTCG-shaped theme) · `lower` (records→HTML,
//! `var(--cv-*)` token refs) · `patch` (op→minimal DOM mutations, apply-time
//! anchors) · `wire` (the msgpack boundary; the TSK-584 fuzz seam) · `doc`
//! (the FFI-facing façade: state + tokens + root page).
//!
//! History: the M0 patch-loop spike engine (hardcoded 201-node demo doc,
//! SetText/SetStyle mirror ops) lived here through commit 5401e5b0 and was
//! retired by the S5c FFI swap — the E2E suite now builds its content through
//! the real op engine (TSK-1343 has the spike's verdict + numbers).

pub mod chart;
pub mod doc;
pub mod dsl;
pub mod io;
pub mod lint;
pub mod lower;
pub mod ops;
pub mod patch;
pub mod props;
pub mod registry;
pub mod store;
pub mod tokens;
pub mod vocab;
pub mod wire;
