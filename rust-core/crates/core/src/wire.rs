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
    /// The ENCODED result legitimately exceeds [`MAX_FRAME_LEN`] (audit
    /// TSK-548 stopgap). Distinct from [`WireFault::Framing`], which is the
    /// decode-side hostile/corrupt-prefix guard: this one means "your data is
    /// real but too big for one frame" — the caller can react (window the
    /// request, fall back) instead of treating it as a codec bug. The real fix
    /// is windowed snapshots (TSK-559).
    TooLarge(String),
}

impl core::fmt::Display for WireFault {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            WireFault::Encode(m) => write!(f, "wire encode error: {m}"),
            WireFault::Decode(m) => write!(f, "wire decode error: {m}"),
            WireFault::Framing(m) => write!(f, "wire framing error: {m}"),
            WireFault::TooLarge(m) => write!(f, "wire result too large: {m}"),
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

/// Decode a MessagePack payload **borrowing from the input slice** (TSK-561).
///
/// The owned [`decode`] copies every string field out of the buffer; for the
/// request seams that carry a whole document (`diff_parse`, `cm_apply`,
/// `find_search`, `markdown_render`, `transcript_parse`, `highlight_runs`)
/// that copy is pure overhead — the FFI/serve layer hands us a `&[u8]` that
/// outlives the call, so `#[serde(borrow)] Cow<'a, str>` fields can point
/// straight into the frame bytes.
///
/// Same strictness as [`decode`]: trailing bytes after the single MessagePack
/// value are rejected. rmp-serde's borrowing reader exposes no consumed-byte
/// count, so end-of-input is verified by probing for a second value: a clean
/// end fails that probe with `UnexpectedEof` on the very first marker byte;
/// anything else means the body carried trailing bytes (a well-formed extra
/// value or garbage — both rejected).
///
/// # Errors
/// Returns [`WireFault::Decode`] if deserialization fails or if any bytes
/// remain after the first value.
pub fn decode_borrowed<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, WireFault> {
    let mut de = rmp_serde::Deserializer::from_read_ref(bytes);
    let value = T::deserialize(&mut de).map_err(|e| WireFault::Decode(e.to_string()))?;
    match serde::de::IgnoredAny::deserialize(&mut de) {
        Err(rmp_serde::decode::Error::InvalidMarkerRead(ref io))
            if io.kind() == std::io::ErrorKind::UnexpectedEof =>
        {
            Ok(value)
        }
        Ok(serde::de::IgnoredAny) => Err(WireFault::Decode(
            "trailing bytes after MessagePack value".to_string(),
        )),
        Err(e) => Err(WireFault::Decode(format!(
            "trailing garbage after MessagePack value: {e}"
        ))),
    }
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
/// [`WireFault::TooLarge`] if the encoded body exceeds [`MAX_FRAME_LEN`].
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
        return Err(WireFault::TooLarge(format!(
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
    decode(frame_body(frame)?)
}

/// Borrowed-decode variant of [`decode_frame`] (TSK-561): same prefix/length
/// validation, body decoded via [`decode_borrowed`] so `#[serde(borrow)]`
/// fields point into `frame` instead of copying out of it.
///
/// # Errors
/// Same as [`decode_frame`].
pub fn decode_frame_borrowed<'a, T: Deserialize<'a>>(frame: &'a [u8]) -> Result<T, WireFault> {
    decode_borrowed(frame_body(frame)?)
}

/// Validate a frame's `u32` LE length prefix and return the body slice.
/// Shared by the owned and borrowed frame decoders.
fn frame_body(frame: &[u8]) -> Result<&[u8], WireFault> {
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
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        /// Wire law (TSK-585): `decode_frame` over ARBITRARY bytes never panics —
        /// the length-prefix parser (`frame_body`) must reject malformed/truncated
        /// input as a `WireFault`, never via an index/slice panic. (Fixed buffers
        /// are example-tested below; this fuzzes the framing.)
        #[test]
        fn decode_frame_never_panics_on_arbitrary_bytes(
            bytes in prop::collection::vec(any::<u8>(), 0..512)
        ) {
            let _: Result<Table, _> = decode_frame(&bytes);
            let _: Result<Snapshot, _> = decode_frame(&bytes);
            let _: Result<String, _> = decode_frame(&bytes);
        }

        /// Wire law (TSK-585): `encode_frame` → `decode_frame` round-trips any
        /// `Table` — our 4-byte LE length framing is value-preserving for any body.
        #[test]
        fn table_frame_round_trips(
            delimiter in "[,;|]",
            header in prop::collection::vec("[a-z ]{0,8}", 0..5),
            rows in prop::collection::vec(prop::collection::vec("[a-z0-9 ]{0,8}", 0..5), 0..6),
            truncated in any::<bool>(),
        ) {
            let t = Table { delimiter, header, rows, truncated };
            let frame = encode_frame(&t).expect("encode_frame");
            let back: Table = decode_frame(&frame).expect("decode_frame");
            prop_assert_eq!(t, back);
        }
    }

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
    fn encode_frame_oversize_is_too_large_not_framing() {
        // TSK-548 stopgap: a REAL result exceeding the cap must carry its own
        // identity (TooLarge) so the host can window/fall back; Framing stays
        // the decode-side hostile-prefix verdict.
        #[derive(Serialize)]
        struct Big {
            s: String,
        }
        let big = Big { s: "x".repeat(MAX_FRAME_LEN + 1) };
        let r = encode_frame(&big);
        assert!(
            matches!(r, Err(WireFault::TooLarge(_))),
            "expected TooLarge, got {:?}",
            r.map(|v| v.len())
        );
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

    // --- Borrowed (zero-copy) decode, TSK-561 ---------------------------------

    /// The request shape the engine seams use: one big text payload.
    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct BorrowReq<'a> {
        #[serde(borrow)]
        text: std::borrow::Cow<'a, str>,
        flag: bool,
    }

    #[test]
    fn decode_frame_borrowed_actually_borrows() {
        // THE point of the variant: the text field must be Cow::Borrowed —
        // a pointer into the frame, not a copy. If a refactor reroutes this
        // through the owned cursor path, Borrowed becomes Owned and this
        // test is the tripwire.
        let frame =
            encode_frame(&BorrowReq { text: "payload".into(), flag: true }).unwrap();
        let req: BorrowReq<'_> = decode_frame_borrowed(&frame).unwrap();
        assert!(
            matches!(req.text, std::borrow::Cow::Borrowed(_)),
            "text must borrow from the frame, got an owned copy"
        );
        assert_eq!(req.text, "payload");
        assert!(req.flag);
    }

    #[test]
    fn decode_borrowed_rejects_trailing_garbage() {
        // Strictness parity with `decode`: a stray byte after the value fails.
        let mut bytes = encode(&BorrowReq { text: "x".into(), flag: false }).unwrap();
        bytes.push(0xc0);
        let r: Result<BorrowReq<'_>, _> = decode_borrowed(&bytes);
        assert!(
            matches!(r, Err(WireFault::Decode(_))),
            "trailing byte after value must be rejected, got {r:?}"
        );
    }

    #[test]
    fn decode_borrowed_rejects_trailing_second_value() {
        // A well-formed SECOND value is just as much trailing garbage as a
        // stray byte (the probe must reject Ok, not only marker errors).
        let mut bytes = encode(&BorrowReq { text: "x".into(), flag: false }).unwrap();
        bytes.extend_from_slice(&encode(&7u32).unwrap());
        let r: Result<BorrowReq<'_>, _> = decode_borrowed(&bytes);
        assert!(
            matches!(r, Err(WireFault::Decode(_))),
            "second value after the first must be rejected, got {r:?}"
        );
    }

    #[test]
    fn decode_frame_borrowed_validates_framing_like_the_owned_path() {
        let frame = encode_frame(&BorrowReq { text: "x".into(), flag: false }).unwrap();
        // Truncated body.
        let err = decode_frame_borrowed::<BorrowReq<'_>>(&frame[..frame.len() - 1]).unwrap_err();
        assert!(matches!(err, WireFault::Framing(_)));
        // Short buffer.
        let err = decode_frame_borrowed::<BorrowReq<'_>>(&[0x00, 0x01]).unwrap_err();
        assert!(matches!(err, WireFault::Framing(_)));
        // Clean frame round-trips.
        let req: BorrowReq<'_> = decode_frame_borrowed(&frame).unwrap();
        assert_eq!(req.text, "x");
    }

    /// Audit fuzz #3: the FFI/RPC boundary decodes UNTRUSTED frames. Random bytes
    /// and mutated-valid frames must NEVER panic through decode_frame — only Ok or
    /// a WireFault. Allocations stay bounded (the 16 MB MAX_FRAME_LEN framing cap +
    /// serde's cautious capacity), so a malformed length marker can't allocate-bomb.
    /// Decodes into string/array/tuple/map shapes. Merge gate fixed seed; nightly
    /// varies MDV_FUZZ_SEED_BASE.
    #[test]
    #[allow(clippy::cast_possible_truncation)] // RNG bytes/indices are intentionally truncated
    fn decode_frame_fuzz_never_panics_on_arbitrary_bytes() {
        use std::collections::HashMap;
        let seed_base: u64 = std::env::var("MDV_FUZZ_SEED_BASE")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let valids: Vec<Vec<u8>> = vec![
            encode_frame(&"hello world".to_string()).unwrap(),
            encode_frame(&vec![1i64, -2, 3, 1_000_000]).unwrap(),
            encode_frame(&(7u64, "x".to_string(), true)).unwrap(),
            encode_frame(&{
                let mut m = HashMap::new();
                m.insert("k".to_string(), 9i64);
                m
            })
            .unwrap(),
        ];
        let mut s: u64 = seed_base.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        for _ in 0..1000 {
            let buf: Vec<u8> = if next() % 3 == 0 {
                // Mutate a valid frame (flip / insert / delete one byte) — stresses
                // the framing length-prefix AND the rmp-serde body decoder.
                let mut v = valids[(next() % valids.len() as u64) as usize].clone();
                if !v.is_empty() {
                    let idx = (next() % v.len() as u64) as usize;
                    match next() % 3 {
                        0 => v[idx] = next() as u8,
                        1 => v.insert(idx, next() as u8),
                        _ => {
                            v.remove(idx);
                        }
                    }
                }
                v
            } else {
                // Pure random bytes (mostly trip the framing cap/short-buffer check).
                let len = (next() % 256) as usize;
                (0..len).map(|_| next() as u8).collect()
            };
            let _ = decode_frame::<String>(&buf);
            let _ = decode_frame::<Vec<i64>>(&buf);
            let _ = decode_frame::<(u64, String, bool)>(&buf);
            let _ = decode_frame::<HashMap<String, i64>>(&buf);
        }
    }
}
