//! Wire types + framing for the cross-language (Swift/JS) boundary.
//!
//! Codec: MessagePack via `rmp-serde`. **Always encode with `to_vec_named`**
//! (see [`encode`]) so structs serialize as MessagePack *maps* (field-name
//! keyed), which Swift `Codable` / JS decoders expect — the default
//! `rmp_serde::to_vec` emits positional *arrays* and silently mismatches the
//! decoders (playbook "rmp-serde interop trap").
//!
//! Framing: DIY length-prefix. Each frame is `u32` little-endian byte length
//! followed by that many MessagePack bytes. A single FFI read may otherwise
//! return a partial or coalesced payload; the length prefix makes frame
//! boundaries explicit and lets the Swift side validate the buffer it got.

use serde::{Deserialize, Serialize};

/// The parsed CSV table returned over the wire (Stage 1 result, and the
/// payload inside a session snapshot for Stage 2).
///
/// Field semantics match the existing Swift `CSVParser.Result` so the A/B is
/// apples-to-apples: `delimiter` is the (single-char) detected delimiter,
/// `header` is row 0, `rows` is the body with column count normalized to
/// `header.len()`, and `truncated` flips when any resource cap fired.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Table {
    /// The detected (or supplied) delimiter, as a string (one grapheme).
    pub delimiter: String,
    /// Header row (CSV row 0).
    pub header: Vec<String>,
    /// Body rows, each normalized to `header.len()` columns.
    pub rows: Vec<Vec<String>>,
    /// `true` if any [`crate::csv::Limits`] cap truncated the parse.
    pub truncated: bool,
}

/// A level-triggered snapshot of a [`crate::session::CsvSession`]: the current
/// visible (filtered) rows plus the original row indices, the header, and the
/// active query echoed back so the projection can reconcile.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    /// Header row (never filtered).
    pub header: Vec<String>,
    /// Original body-row indices that survived the filter (parallel to
    /// `rows`). Lets the projection preserve original line numbers.
    pub indices: Vec<u32>,
    /// The surviving rows themselves.
    pub rows: Vec<Vec<String>>,
    /// Total body row count before filtering (denominator for "showing N of
    /// M").
    pub total_rows: u32,
    /// The query that produced this snapshot, echoed for reconciliation.
    pub query: String,
    /// Monotonic version stamp; increments on every state mutation. The
    /// projection can drop stale snapshots / detect that a re-filter happened.
    pub version: u64,
    /// Whether the underlying parse was truncated by a cap.
    pub truncated: bool,
}

/// A structured error carried over the wire (the rich detail that does NOT fit
/// in the C status enum). Mirrors the JSON-RPC `{code, message, data}` model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WireError {
    /// Stable numeric code (matches the C status enum discriminant).
    pub code: i32,
    /// Human-readable message.
    pub message: String,
    /// Optional structured context (free-form key/value).
    pub data: Vec<(String, String)>,
}

/// Maximum frame body length we will encode/decode (16 MiB). Guards the
/// decoder against a hostile / corrupt length prefix demanding a huge alloc.
pub const MAX_FRAME_LEN: usize = 16 * 1024 * 1024;

/// Wire-layer errors (encode/decode/framing). Distinct from domain errors.
#[derive(Debug)]
pub enum WireFault {
    /// `rmp-serde` failed to encode.
    Encode(String),
    /// `rmp-serde` failed to decode.
    Decode(String),
    /// The frame's declared length exceeds [`MAX_FRAME_LEN`] or the buffer is
    /// shorter than the prefix claims.
    Framing(String),
}

impl core::fmt::Display for WireFault {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            WireFault::Encode(m) => write!(f, "wire encode error: {m}"),
            WireFault::Decode(m) => write!(f, "wire decode error: {m}"),
            WireFault::Framing(m) => write!(f, "wire framing error: {m}"),
        }
    }
}

impl std::error::Error for WireFault {}

/// Encode a value to MessagePack **as a named-field map** (`to_vec_named`).
///
/// # Errors
/// Returns [`WireFault::Encode`] if serialization fails.
pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, WireFault> {
    rmp_serde::to_vec_named(value).map_err(|e| WireFault::Encode(e.to_string()))
}

/// Decode a MessagePack payload (named-field map) back to a value.
///
/// # Errors
/// Returns [`WireFault::Decode`] if deserialization fails.
pub fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, WireFault> {
    rmp_serde::from_slice(bytes).map_err(|e| WireFault::Decode(e.to_string()))
}

/// Encode a value to a single length-prefixed frame: `u32` LE length + body.
///
/// # Errors
/// Returns [`WireFault::Encode`] on serialization failure, or
/// [`WireFault::Framing`] if the encoded body exceeds [`MAX_FRAME_LEN`].
pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, WireFault> {
    let body = encode(value)?;
    if body.len() > MAX_FRAME_LEN {
        return Err(WireFault::Framing(format!(
            "frame body {} exceeds max {MAX_FRAME_LEN}",
            body.len()
        )));
    }
    // u32 cast is safe: bounded by MAX_FRAME_LEN above.
    let len = u32::try_from(body.len())
        .map_err(|_| WireFault::Framing("frame length overflow".to_string()))?;
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// Decode a single length-prefixed frame produced by [`encode_frame`].
/// Validates the prefix against the actual buffer and [`MAX_FRAME_LEN`].
///
/// # Errors
/// Returns [`WireFault::Framing`] if the buffer is too short or the declared
/// length is invalid/oversized, or [`WireFault::Decode`] on a body decode
/// failure.
pub fn decode_frame<T: for<'de> Deserialize<'de>>(frame: &[u8]) -> Result<T, WireFault> {
    if frame.len() < 4 {
        return Err(WireFault::Framing(format!(
            "frame too short for length prefix: {} bytes",
            frame.len()
        )));
    }
    let (prefix, body) = frame.split_at(4);
    let mut len_bytes = [0u8; 4];
    len_bytes.copy_from_slice(prefix);
    let declared = u32::from_le_bytes(len_bytes) as usize;
    if declared > MAX_FRAME_LEN {
        return Err(WireFault::Framing(format!(
            "declared frame length {declared} exceeds max {MAX_FRAME_LEN}"
        )));
    }
    if declared != body.len() {
        return Err(WireFault::Framing(format!(
            "declared frame length {declared} != actual body {}",
            body.len()
        )));
    }
    decode(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_table() -> Table {
        Table {
            delimiter: ",".to_string(),
            header: vec!["a".into(), "b".into()],
            rows: vec![vec!["1".into(), "2".into()], vec!["3".into(), "4".into()]],
            truncated: false,
        }
    }

    #[test]
    fn table_round_trips_through_frame() {
        let t = sample_table();
        let frame = encode_frame(&t).unwrap();
        // 4-byte prefix present and matches body length.
        assert!(frame.len() > 4);
        let decoded: Table = decode_frame(&frame).unwrap();
        assert_eq!(t, decoded);
    }

    #[test]
    fn named_encoding_uses_map_not_array() {
        // to_vec_named must produce a map (so Swift Codable decodes by key).
        // First MessagePack byte for a small map is 0x8N (fixmap); a small
        // array would be 0x9N (fixarray). Table has 4 fields → 0x84.
        let bytes = encode(&sample_table()).unwrap();
        assert_eq!(
            bytes[0] & 0xF0,
            0x80,
            "expected fixmap marker, got {:#x}",
            bytes[0]
        );
    }

    #[test]
    fn truncated_frame_is_rejected() {
        let frame = encode_frame(&sample_table()).unwrap();
        let err = decode_frame::<Table>(&frame[..frame.len() - 1]).unwrap_err();
        assert!(matches!(err, WireFault::Framing(_)));
    }

    #[test]
    fn oversized_declared_length_is_rejected() {
        let mut frame = vec![0xFF, 0xFF, 0xFF, 0xFF]; // declares ~4 GiB
        frame.push(0x80);
        let err = decode_frame::<Table>(&frame).unwrap_err();
        assert!(matches!(err, WireFault::Framing(_)));
    }

    #[test]
    fn short_buffer_is_rejected() {
        let err = decode_frame::<Table>(&[0x00, 0x01]).unwrap_err();
        assert!(matches!(err, WireFault::Framing(_)));
    }
}
