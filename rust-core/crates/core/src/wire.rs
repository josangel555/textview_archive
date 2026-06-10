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
/// Enforces an **end-of-stream check**: `rmp_serde::from_slice` stops at the end
/// of the first MessagePack value and silently ignores any trailing bytes, so a
/// padded or malformed payload would decode as if clean. We deserialize through a
/// cursor and require it to land exactly at end-of-input, rejecting any trailing
/// garbage — the body of a frame is one value and nothing more.
///
/// # Errors
/// Returns [`WireFault::Decode`] if deserialization fails or if any bytes remain
/// after the first value.
pub fn decode<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, WireFault> {
    let mut cursor = std::io::Cursor::new(bytes);
    let value = {
        let mut de = rmp_serde::Deserializer::new(&mut cursor);
        T::deserialize(&mut de).map_err(|e| WireFault::Decode(e.to_string()))?
    };
    // `Cursor::position` is the count of bytes the deserializer consumed; rmp reads
    // exactly the value's bytes (MessagePack is self-delimiting, no read-ahead).
    let consumed = usize::try_from(cursor.position()).unwrap_or(usize::MAX);
    if consumed != bytes.len() {
        return Err(WireFault::Decode(format!(
            "trailing bytes after MessagePack value: consumed {consumed} of {} bytes",
            bytes.len()
        )));
    }
    Ok(value)
}

/// Encode a value to a single length-prefixed frame: `u32` LE length + body.
///
/// Serializes the MessagePack body **directly into one buffer** behind a 4-byte
/// length placeholder, then backfills the `u32` LE prefix in place — avoiding
/// the encode-then-copy of a separate body `Vec`. The body bytes are produced
/// by the same `Serializer` config as [`encode`] / `to_vec_named`
/// (`Serializer::new(..).with_struct_map()` is the exact equivalent of
/// `to_vec_named`'s `RuntimeConfig::new(StructMapConfig::new(..))`), so the
/// output is byte-identical to the previous encode-and-prefix path.
///
/// # Errors
/// Returns [`WireFault::Encode`] on serialization failure, or
/// [`WireFault::Framing`] if the encoded body exceeds [`MAX_FRAME_LEN`].
pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, WireFault> {
    // Reserve a 4-byte placeholder for the length prefix; the body is appended
    // after it by the serializer (`Vec<u8>: io::Write` appends).
    let mut buf: Vec<u8> = vec![0u8; 4];
    value
        .serialize(&mut rmp_serde::Serializer::new(&mut buf).with_struct_map())
        .map_err(|e| WireFault::Encode(e.to_string()))?;

    // Body length is the buffer minus the 4-byte prefix. `checked_sub` keeps the
    // no-panic policy intact even though the prefix is always present.
    let body_len = buf
        .len()
        .checked_sub(4)
        .ok_or_else(|| WireFault::Framing("frame buffer shorter than length prefix".to_string()))?;
    if body_len > MAX_FRAME_LEN {
        return Err(WireFault::Framing(format!(
            "frame body {body_len} exceeds max {MAX_FRAME_LEN}"
        )));
    }
    // u32 cast is safe: bounded by MAX_FRAME_LEN above.
    let len = u32::try_from(body_len)
        .map_err(|_| WireFault::Framing("frame length overflow".to_string()))?;

    // Backfill the prefix via a CHECKED slice write — no indexing/slicing panic.
    let prefix = buf
        .get_mut(..4)
        .ok_or_else(|| WireFault::Framing("frame buffer missing length prefix slot".to_string()))?;
    prefix.copy_from_slice(&len.to_le_bytes());
    Ok(buf)
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

    /// The OLD `encode_frame` implementation: encode body via `to_vec_named`,
    /// then build a second `Vec` of `[u32 LE len][body]`. Kept here as the
    /// byte-identity oracle for the single-allocation rewrite.
    fn legacy_encode_frame<T: Serialize>(value: &T) -> Vec<u8> {
        let body = rmp_serde::to_vec_named(value).unwrap();
        assert!(body.len() <= MAX_FRAME_LEN);
        let len = u32::try_from(body.len()).unwrap();
        let mut out = Vec::with_capacity(4 + body.len());
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&body);
        out
    }

    #[test]
    fn single_alloc_frame_is_byte_identical_to_legacy() {
        // Pin byte-for-byte equality with the old encode-then-prefix path across
        // every wire type so the perf rewrite is provably semantics-preserving.
        let table = sample_table();
        assert_eq!(
            encode_frame(&table).unwrap(),
            legacy_encode_frame(&table),
            "Table frame diverged from legacy bytes"
        );

        let snapshot = Snapshot {
            header: vec!["a".into(), "b".into()],
            indices: vec![0, 2, 5],
            rows: vec![vec!["x".into(), "y".into()], vec!["z".into(), "w".into()]],
            total_rows: 9,
            query: "q".into(),
            version: 42,
            truncated: true,
        };
        assert_eq!(
            encode_frame(&snapshot).unwrap(),
            legacy_encode_frame(&snapshot),
            "Snapshot frame diverged from legacy bytes"
        );

        let err = WireError {
            code: -7,
            message: "boom".into(),
            data: vec![("k".into(), "v".into())],
        };
        assert_eq!(
            encode_frame(&err).unwrap(),
            legacy_encode_frame(&err),
            "WireError frame diverged from legacy bytes"
        );

        // Empty + scalar shapes also exercised.
        let empty = Table {
            delimiter: ",".into(),
            header: vec![],
            rows: vec![],
            truncated: false,
        };
        assert_eq!(encode_frame(&empty).unwrap(), legacy_encode_frame(&empty));
    }

    #[test]
    fn frame_prefix_matches_body_length() {
        let frame = encode_frame(&sample_table()).unwrap();
        let mut len_bytes = [0u8; 4];
        len_bytes.copy_from_slice(&frame[..4]);
        let declared = u32::from_le_bytes(len_bytes) as usize;
        assert_eq!(declared, frame.len() - 4);
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
    fn decode_rejects_trailing_garbage() {
        // A valid value followed by a stray byte must NOT decode as clean —
        // `from_slice` used to swallow the tail; the end-of-stream check rejects it.
        let mut bytes = encode(&sample_table()).unwrap();
        bytes.push(0xc0); // a lone MessagePack `nil`
        let r: Result<Table, _> = decode(&bytes);
        assert!(
            matches!(r, Err(WireFault::Decode(_))),
            "trailing byte after value must be rejected, got {r:?}"
        );
    }

    #[test]
    fn decode_frame_rejects_trailing_garbage_in_body() {
        // Frame whose declared length includes a stray byte after a valid value:
        // the framing length check passes (declared == body len) but the body
        // decode must now reject the trailing byte.
        let mut body = encode(&sample_table()).unwrap();
        body.push(0xc0);
        let len = u32::try_from(body.len()).unwrap();
        let mut frame = len.to_le_bytes().to_vec();
        frame.extend_from_slice(&body);
        let r: Result<Table, _> = decode_frame(&frame);
        assert!(
            matches!(r, Err(WireFault::Decode(_))),
            "frame body trailing byte must be rejected, got {r:?}"
        );
    }

    #[test]
    fn decode_clean_value_still_round_trips() {
        let t = sample_table();
        let back: Table = decode(&encode(&t).unwrap()).unwrap();
        assert_eq!(t, back);
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
