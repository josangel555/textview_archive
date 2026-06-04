//! `mdvcore-core` — the pure, sans-IO functional core for the Rust-Core PoC.
//!
//! `#![forbid(unsafe_code)]`: this crate contains zero unsafe. All FFI / raw
//! pointers / symbol exports live in the sibling `mdvcore-ffi` crate (you cannot
//! punch a hole in `forbid` within one crate — that's the point of the split).
//!
//! Modules:
//!   - [`cm_edit`] — CodeMirror incremental-edit reducer (UTF-16, sans-IO).
//!   - [`csv`]     — hand-rolled CSV parser (no `csv` crate).
//!   - [`filter`]  — pure row-filtering.
//!   - [`session`] — the stateful, level-triggered [`session::CsvSession`].
//!   - [`wire`]    — MessagePack wire types + length-prefixed framing.
//!   - [`trace`]   — dependency-free instrumentation facade (the Swift
//!     `ObservabilitySink` analog).
//!
//! The core is synchronous and does no I/O: bytes come in, values go out. Time
//! and randomness are not read (enforced by the clippy `disallowed_methods`
//! lint). This is what makes it trivially deterministic to test and free to
//! run either in-process (FFI) or, eventually, over a wire (remote).

#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod cm_edit;
pub mod csv;
pub mod diff;
pub mod filter;
pub mod hex;
pub mod indent;
pub mod session;
pub mod trace;
pub mod wire;
