//! HEX dump rendering — the Rust port of the Swift `HexLayout` row math +
//! `HexDumpBuilder.buildAll`/`renderRows` (migration plan slice #4). Pure,
//! sans-IO: bytes + layout scalars in, one rendered dump string out.
//!
//! Faithful to the Swift contract (the A/B test pins it byte-for-byte): the
//! per-row layout is
//!
//! ```text
//! OOOOOOOO␣␣HH␣HH␣…␣HH␣␣AAAA…\n
//! ```
//!
//! = 8 lowercase-hex offset digits (low 32 bits of the row's byte offset) + 2
//! spaces + `width` hex byte pairs single-space-separated (a `  ` placeholder
//! for bytes past EOF in a short final row) + 2 spaces + `width` ASCII glyphs
//! (printable `0x20..=0x7e` verbatim, else `.`, a space past EOF) + newline.
//! Every row is the same character length so the highlight layer can address a
//! byte by `row * row_len + col` without per-row variable widths.
//!
//! Only the rendering moves here; the chunked/streaming drive (which feeds an
//! `NSTextView` incrementally) stays in Swift `HexDumpBuilder.build`.

/// Per-row character count in the rendered dump (mirrors
/// `HexLayout.renderedRowLength`). Total: `width == 0` (no row can exist) → 0,
/// and absurd widths saturate instead of overflowing (audit TSK-540).
#[must_use]
pub(crate) fn rendered_row_length(width: usize) -> usize {
    // 8 offset + 2 spaces + (width*3 - 1) hex/sep + 2 spaces + width ascii + \n
    // = width*4 + 12; the subtraction form underflows at width == 0.
    if width == 0 {
        return 0;
    }
    width.saturating_mul(4).saturating_add(12)
}

/// Row count for a byte buffer at the given width (mirrors `HexLayout.rowCount`).
/// Zero bytes or zero width → zero rows.
#[must_use]
pub(crate) fn row_count(byte_count: usize, width: usize) -> usize {
    if width == 0 || byte_count == 0 {
        return 0;
    }
    byte_count.div_ceil(width)
}

/// Lowercase-hex digit for a nibble (`0..=15`). Arithmetic, not a table lookup,
/// to stay clear of the `clippy::indexing_slicing` no-panic deny.
fn hex_digit(nibble: u8) -> u8 {
    if nibble < 10 {
        b'0' + nibble
    } else {
        b'a' + (nibble - 10)
    }
}

/// Upper bound on a render's bytes-per-row. Out-of-range widths clamp rather
/// than error so the render stays total for any input. Mirrors the FFI ABI
/// constant `MAX_HEX_WIDTH` (the `#define MAX_HEX_WIDTH` cbindgen emits into the
/// header) — the two are pinned equal by the envelope A/B parity test, which
/// renders at an over-cap width through both entry points. The clamp is a
/// SAFETY guard, not cosmetic: an unclamped `u32::MAX` width drives a ~17 GiB
/// single-row allocation whose failure aborts past the `catch_unwind` guard
/// (audit TSK-540).
pub const MAX_HEX_WIDTH: u32 = 512;

/// Render the entire dump as one string (mirrors `HexDumpBuilder.buildAll`).
/// `byte_count` is `bytes.len()` (post-truncation); `total_byte_count` is the
/// pre-truncation file size used only in the `is_truncated` header.
#[must_use]
#[allow(clippy::cast_possible_truncation,
        reason = "TSK-575: intentional low-32-bit offset display (matches Swift's fixed \
                  8-nibble hex-offset loop) — truncation is the documented behaviour")]
pub fn render_all(
    bytes: &[u8],
    width: usize,
    total_byte_count: usize,
    is_truncated: bool,
) -> String {
    if width == 0 {
        return String::new();
    }
    let byte_count = bytes.len();
    let rows = row_count(byte_count, width);
    let per_row = rendered_row_length(width);
    let header = if is_truncated {
        format!("Showing first {byte_count} of {total_byte_count} bytes\n\n")
    } else {
        String::new()
    };

    let mut buf: Vec<u8> = Vec::with_capacity(header.len() + rows * per_row);
    buf.extend_from_slice(header.as_bytes());

    let mut row_start = 0usize;
    while row_start < byte_count {
        // 8-char offset, low 32 bits (matches Swift's fixed 8-nibble loop).
        let off = row_start as u32;
        for i in 0..8u32 {
            let nibble = ((off >> (28 - 4 * i)) & 0xF) as u8;
            buf.push(hex_digit(nibble));
        }
        buf.extend_from_slice(b"  ");

        // Hex columns: `HH` per byte, single-space separated; `  ` past EOF.
        for i in 0..width {
            match bytes.get(row_start + i) {
                Some(&b) => {
                    buf.push(hex_digit(b >> 4));
                    buf.push(hex_digit(b & 0xF));
                }
                None => buf.extend_from_slice(b"  "),
            }
            if i != width - 1 {
                buf.push(b' ');
            }
        }
        buf.extend_from_slice(b"  ");

        // ASCII column: printable verbatim, else `.`; a space past EOF.
        for i in 0..width {
            match bytes.get(row_start + i) {
                Some(&b) if (0x20..=0x7e).contains(&b) => buf.push(b),
                Some(_) => buf.push(b'.'),
                None => buf.push(b' '),
            }
        }
        buf.push(b'\n');
        row_start += width;
    }

    // Every pushed byte is ASCII (`< 0x80`), so this is always valid UTF-8;
    // `unwrap_or_default` keeps the function panic-free regardless.
    String::from_utf8(buf).unwrap_or_default()
}

// MARK: - HEX search (migration plan slice #5 — port of HexSearchEngine)

/// Query interpretation for [`hex_search`] (mirrors Swift `HexSearchMode`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HexSearchMode {
    /// Whitespace-separated hex byte pairs (`"de ad be ef"` / `"DEADBEEF"`).
    Hex,
    /// A plain string; its UTF-8 bytes are the pattern.
    Ascii,
}

/// Parse a user query into a byte pattern (mirrors `HexSearchEngine.parse`).
/// `None` = invalid for the mode (caller shows a disabled/error state); an
/// empty `Vec` = the user hasn't typed a usable pattern yet.
#[must_use]
pub fn hex_search_parse(query: &str, mode: HexSearchMode) -> Option<Vec<u8>> {
    match mode {
        HexSearchMode::Ascii => Some(query.as_bytes().to_vec()),
        HexSearchMode::Hex => {
            let mut bytes = Vec::new();
            for token in query.split_whitespace() {
                // Each token must be an even number of hex digits.
                if token.len() % 2 != 0 {
                    return None;
                }
                let raw = token.as_bytes();
                let mut i = 0;
                while i < raw.len() {
                    // i+1 < len guaranteed by the even-length check above.
                    let (hi, lo) = (raw.get(i)?, raw.get(i + 1)?);
                    let byte = (hex_nibble(*hi)? << 4) | hex_nibble(*lo)?;
                    bytes.push(byte);
                    i += 2;
                }
            }
            Some(bytes)
        }
    }
}

/// Value of a single hex digit (`0-9a-fA-F`), or `None` if not a hex char.
fn hex_nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Non-overlapping byte-sequence search (mirrors `HexSearchEngine.find`). An
/// empty pattern, or one longer than `data`, yields `[]`. On a match the cursor
/// advances by the full pattern length (Sublime/VSCode convention).
#[must_use]
pub(crate) fn hex_search_find(pattern: &[u8], data: &[u8]) -> Vec<usize> {
    if pattern.is_empty() || pattern.len() > data.len() {
        return Vec::new();
    }
    let mut hits = Vec::new();
    let m = pattern.len();
    let limit = data.len() - m;
    // TSK-562: first-byte skip replaces the per-position subslice compare.
    // `Iterator::position` over a u8 slice compiles to a vectorized scan
    // (LLVM memchr-recognition), so the common path skips in SIMD-width
    // strides and the full compare runs only at candidate positions —
    // O(n) skip + rare compares instead of O(n·m).
    let Some(&first) = pattern.first() else {
        return Vec::new();
    };
    let mut i = 0;
    while i <= limit {
        let Some(rel) = data.get(i..=limit).and_then(|w| w.iter().position(|&b| b == first))
        else {
            break;
        };
        let at = i + rel;
        if data.get(at..at + m) == Some(pattern) {
            hits.push(at);
            i = at + m; // non-overlapping (cursor advances the full pattern)
        } else {
            i = at + 1;
        }
    }
    hits
}

/// Convenience: parse + find. Returns `[]` on an invalid or empty query
/// (mirrors `HexSearchEngine.search`).
#[must_use]
pub fn hex_search(query: &str, mode: HexSearchMode, data: &[u8]) -> Vec<usize> {
    match hex_search_parse(query, mode) {
        Some(pattern) if !pattern.is_empty() => hex_search_find(&pattern, data),
        _ => Vec::new(),
    }
}

/// Response payload for the FFI search shim: the match offsets.
#[derive(serde::Serialize, serde::Deserialize)]
struct SearchResponse {
    offsets: Vec<u32>,
}

/// Search `data` for `query` and encode the match offsets as a length-prefixed
/// MessagePack `{offsets:[u32]}` frame. Pure + sans-IO (cargo-testable); the FFI
/// shim adds only the pointer/`MdvBuf`/guard plumbing. Offsets are byte
/// positions in a buffer capped well under `u32::MAX`.
///
/// # Errors
/// [`crate::wire::WireFault`] on an encode failure.
pub fn hex_search_frame(
    data: &[u8],
    query: &str,
    mode: HexSearchMode,
) -> Result<Vec<u8>, crate::wire::WireFault> {
    let offsets: Vec<u32> = hex_search(query, mode, data)
        .into_iter()
        .map(|o| u32::try_from(o).unwrap_or(u32::MAX))
        .collect();
    crate::wire::encode_frame(&SearchResponse { offsets })
}

/// Request for [`search_wire_aux`] (TSK-580 slice 3): `{query, mode}` only. The
/// buffer to search is NOT in this frame — it rides the dispatch `aux` bulk
/// side-channel, so a multi-MiB file needn't be wrapped in a request frame
/// (frame-cap-exempt). `pub` so front-ends/tests build it. Borrowed query to
/// match the zero-copy spirit (the query itself is tiny either way).
#[derive(serde::Serialize, serde::Deserialize)]
pub struct SearchAuxRequest<'a> {
    pub query: &'a str,
    /// `1` = ASCII/raw bytes, else hex-byte-pair (mirrors `mdvcore_hex_search`).
    pub mode: u32,
}

/// Hex search routed through the dispatch envelope (TSK-580 slice 3) — the FIRST
/// consumer of the `aux` bulk side-channel. The buffer to search arrives as
/// `aux` (zero-copy borrowed, frame-cap-exempt); `req` carries only the small
/// `{query, mode}` frame. The `{offsets:[u32]}` response is byte-identical to
/// [`hex_search_frame`] called directly (the dedicated `mdvcore_hex_search`
/// symbol keeps using that during the coexistence window).
///
/// # Errors
/// [`crate::wire::WireFault`] on a request-decode or response-encode fault.
pub fn search_wire_aux(req: &[u8], aux: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let r: SearchAuxRequest<'_> = crate::wire::decode_frame_borrowed(req)?;
    let mode = if r.mode == 1 { HexSearchMode::Ascii } else { HexSearchMode::Hex };
    hex_search_frame(aux, r.query, mode)
}

/// Request for [`render_wire_aux`] (TSK-580 slice 3, output half): just the
/// small layout scalars. The bytes to render are NOT in this frame — they ride
/// the dispatch `aux` bulk side-channel (a 4 MB file → ~18 MB dump; frame-cap-
/// exempt on the input AND the raw output). `pub` so front-ends/tests build it.
#[derive(serde::Serialize, serde::Deserialize)]
pub struct RenderAuxRequest {
    /// Bytes-per-row, clamped to [`MAX_HEX_WIDTH`] (mirrors `mdvcore_hex_render`).
    pub width: u32,
    /// Pre-truncation file size — shown only in the `is_truncated` header.
    pub total_byte_count: u64,
    /// Whether the buffer was truncated for display (drives the header line).
    pub is_truncated: bool,
}

/// HEX dump render routed through the dispatch envelope (TSK-580 slice 3, the
/// bulk-OUTPUT half — the genuinely new mechanism the `aux` channel was built
/// for). The bytes to render arrive as `aux` (frame-cap-exempt); `req` carries
/// only the `{width, total_byte_count, is_truncated}` frame. Unlike the
/// frame-returning methods, the response is the **raw UTF-8 dump bytes** (NOT a
/// MessagePack frame): a ~18 MB dump would blow the 16 MiB frame cap, and
/// double-encoding it is pure waste. `mdvcore_call` writes these bytes to
/// `out_buf` verbatim; the `MdvStatus` (Ok vs a wire status) disambiguates raw
/// output from an error frame. Byte-identical to `render_all` / the dedicated
/// `mdvcore_hex_render` symbol (the A/B parity test pins it; the symbol keeps
/// serving during the coexistence window).
///
/// # Errors
/// [`crate::wire::WireFault`] on a request-decode fault. Rendering itself is
/// total — it never faults — so a successful decode always yields `Ok`.
pub fn render_wire_aux(req: &[u8], aux: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let r: RenderAuxRequest = crate::wire::decode_frame(req)?;
    // Same clamp as the FFI symbol (the safety guard, NOT cosmetic — see
    // MAX_HEX_WIDTH); width == 0 → empty dump per render_all's contract.
    let width = usize::try_from(r.width.min(MAX_HEX_WIDTH)).unwrap_or(0);
    let total = usize::try_from(r.total_byte_count).unwrap_or(usize::MAX);
    Ok(render_all(aux, width, total, r.is_truncated).into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TSK-562 coverage hole found by the teeth run: no prior test had a
    /// first-byte-matches-but-rest-doesn't case, so a search that reported
    /// bare first-byte hits passed the whole suite. Pins the candidate
    /// REJECTION path of the skip-loop.
    #[test]
    fn find_rejects_partial_prefix_matches() {
        // 0xAB appears three times; only ONE full [0xAB, 0xCD] match exists.
        let data = [0xABu8, 0x00, 0xAB, 0xCD, 0xAB];
        assert_eq!(hex_search_find(&[0xAB, 0xCD], &data), vec![2]);
        // And a needle whose first byte is frequent but never completes.
        assert_eq!(hex_search_find(&[0xAB, 0xEE], &data), Vec::<usize>::new());
    }

    /// Robustness audit (un-fuzzed shipped engine): arbitrary bytes × widths
    /// (incl. 0) through render_all, and arbitrary query/mode × data through
    /// hex_search / hex_search_find — must NEVER panic (width=0 divide guard plus
    /// offset/row math are the risk surface). Every search hit must FIT the
    /// data (offset + pattern.len() <= data.len()) and be non-overlapping.
    /// Deterministic LCG, no dep. Teeth: an out-of-bounds/overlapping hit or a
    /// render panic fails outright.
    #[test]
    #[allow(clippy::cast_possible_truncation)] // LCG modulo-bounded; tiny fuzz inputs
    fn hex_fuzz_never_panics_render_and_search() {
        const BYTES: &[u8] = &[0x00, 0xff, 0x41, 0x0a, 0x09, 0x80, 0x7f, 0xc3, 0x28, 0x41];
        const QUERIES: &[&str] = &[
            "", "41", "ff 00", "4", "zz", "deadbeef", "G", "0x41", " 41 41 ", "ффф", "41 4",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0x4EC0_DEBA_BE00_0001;
        for _ in 0..3000u32 {
            let dlen = (lcg(&mut state) % 64) as usize;
            let mut data = Vec::new();
            for _ in 0..dlen {
                data.push(BYTES[(lcg(&mut state) as usize) % BYTES.len()]);
            }

            // render_all at a random width INCLUDING 0 (the divide-by-zero guard).
            let width = (lcg(&mut state) % 40) as usize;
            let total = data.len() + (lcg(&mut state) % 100) as usize;
            let _ = render_all(&data, width, total, lcg(&mut state) & 1 == 0);

            // hex_search (parse + find): hits fit + are non-overlapping.
            let q = QUERIES[(lcg(&mut state) as usize) % QUERIES.len()];
            let mode = if lcg(&mut state) & 1 == 0 {
                HexSearchMode::Hex
            } else {
                HexSearchMode::Ascii
            };
            let pat_len = hex_search_parse(q, mode).map_or(0, |p| p.len());
            let mut prev_end = 0usize;
            for &off in &hex_search(q, mode, &data) {
                assert!(
                    off.checked_add(pat_len).is_some_and(|e| e <= data.len()),
                    "hex_search hit {off}+{pat_len} out of data len {} q={q:?}",
                    data.len()
                );
                assert!(off >= prev_end, "hex_search hits overlap: {off} < {prev_end}");
                prev_end = off + pat_len;
            }

            // hex_search_find directly with a random raw pattern.
            let plen = (lcg(&mut state) % 5) as usize;
            let mut pat = Vec::new();
            for _ in 0..plen {
                pat.push(BYTES[(lcg(&mut state) as usize) % BYTES.len()]);
            }
            let mut prev = 0usize;
            for &off in &hex_search_find(&pat, &data) {
                assert!(
                    off.checked_add(pat.len()).is_some_and(|e| e <= data.len()),
                    "hex_search_find hit {off}+{} out of data len {}",
                    pat.len(),
                    data.len()
                );
                assert!(off >= prev, "hex_search_find hits overlap");
                prev = off + pat.len();
            }
        }
    }

    #[test]
    fn row_math_matches_swift() {
        assert_eq!(rendered_row_length(16), 8 + 2 + 47 + 2 + 16 + 1);
        assert_eq!(row_count(0, 16), 0);
        assert_eq!(row_count(1, 16), 1);
        assert_eq!(row_count(16, 16), 1);
        assert_eq!(row_count(17, 16), 2);
        assert_eq!(row_count(10, 0), 0);
    }

    #[test]
    fn rendered_row_length_is_total() {
        // TSK-540: width 0 used to underflow (width*3 - 1); absurd widths
        // used to overflow. Both must now be defined.
        assert_eq!(rendered_row_length(0), 0);
        assert_eq!(rendered_row_length(usize::MAX), usize::MAX); // saturates
    }

    #[test]
    fn empty_buffer_renders_empty() {
        assert_eq!(render_all(b"", 16, 0, false), "");
    }

    #[test]
    fn single_short_row_pads_to_full_width() {
        // 3 bytes at width 4: one row, last 1 column is padded.
        let out = render_all(&[0x41, 0x42, 0x43], 4, 3, false);
        // offset(8) + "  " + "41 42 43    " (3 bytes + 1 pad placeholder "  ")
        //   + "  " + "ABC " (1 pad space) + "\n"
        assert_eq!(out, "00000000  41 42 43     ABC \n");
        assert_eq!(out.chars().count(), rendered_row_length(4));
    }

    #[test]
    fn non_printable_becomes_dot() {
        // 0x00 and 0x7f are non-printable; 0x41 ('A') prints.
        let out = render_all(&[0x00, 0x41, 0x7f, 0xff], 4, 4, false);
        assert_eq!(out, "00000000  00 41 7f ff  .A..\n");
    }

    #[test]
    fn truncated_emits_header() {
        let out = render_all(&[0x41], 16, 999, true);
        assert!(out.starts_with("Showing first 1 of 999 bytes\n\n"));
        assert!(out.contains("\n00000000  41"));
    }

    #[test]
    fn offset_increments_per_row() {
        // 5 bytes at width 4 → 2 rows; second row offset is 00000004.
        let out = render_all(&[1, 2, 3, 4, 5], 4, 5, false);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].starts_with("00000000  "));
        assert!(lines[1].starts_with("00000004  "));
    }

    #[test]
    fn parse_hex_forms() {
        assert_eq!(hex_search_parse("de ad be ef", HexSearchMode::Hex), Some(vec![0xde, 0xad, 0xbe, 0xef]));
        assert_eq!(hex_search_parse("DEADBEEF", HexSearchMode::Hex), Some(vec![0xde, 0xad, 0xbe, 0xef]));
        assert_eq!(hex_search_parse("de adbe ef", HexSearchMode::Hex), Some(vec![0xde, 0xad, 0xbe, 0xef]));
        assert_eq!(hex_search_parse("", HexSearchMode::Hex), Some(vec![]));
    }

    #[test]
    fn parse_hex_rejects_invalid() {
        assert_eq!(hex_search_parse("de a", HexSearchMode::Hex), None); // odd-length token
        assert_eq!(hex_search_parse("zz", HexSearchMode::Hex), None);   // non-hex
        assert_eq!(hex_search_parse("dez0", HexSearchMode::Hex), None); // non-hex within
    }

    #[test]
    fn parse_ascii_is_utf8_bytes() {
        assert_eq!(hex_search_parse("AB", HexSearchMode::Ascii), Some(vec![0x41, 0x42]));
        assert_eq!(hex_search_parse("", HexSearchMode::Ascii), Some(vec![]));
    }

    #[test]
    fn find_is_non_overlapping() {
        assert_eq!(hex_search_find(&[0xAA, 0xAA], &[0xAA, 0xAA, 0xAA]), vec![0]);
        assert_eq!(hex_search_find(&[0xAA], &[0xAA, 0xAA, 0xAA]), vec![0, 1, 2]);
        assert_eq!(hex_search_find(&[0x01, 0x02], &[0x00, 0x01, 0x02, 0x01, 0x02]), vec![1, 3]);
    }

    #[test]
    fn find_edge_cases() {
        assert_eq!(hex_search_find(&[], &[1, 2, 3]), Vec::<usize>::new());
        assert_eq!(hex_search_find(&[1, 2, 3, 4], &[1, 2]), Vec::<usize>::new()); // pattern > data
        assert_eq!(hex_search_find(&[9], &[1, 2, 3]), Vec::<usize>::new());       // no match
    }

    #[test]
    fn search_invalid_query_is_empty() {
        assert_eq!(hex_search("de a", HexSearchMode::Hex, &[0xde, 0xad]), Vec::<usize>::new());
        assert_eq!(hex_search("", HexSearchMode::Hex, &[0xde, 0xad]), Vec::<usize>::new());
    }

    #[test]
    fn search_frame_round_trips() {
        let data = [0x00, 0xde, 0xad, 0xde, 0xad];
        let frame = hex_search_frame(&data, "dead", HexSearchMode::Hex).unwrap();
        let resp: SearchResponse = crate::wire::decode_frame(&frame).unwrap();
        assert_eq!(resp.offsets, vec![1, 3]);
    }

    #[test]
    fn render_wire_aux_matches_render_all_and_clamps_width() {
        // Bytes ride `aux`; the layout scalars ride the `req` frame. The raw
        // dump bytes must equal render_all called directly (no framing).
        let data = [0x00u8, 0x41, 0x7f, 0xff, 0x42];
        let req = crate::wire::encode_frame(&RenderAuxRequest {
            width: 4,
            total_byte_count: data.len() as u64,
            is_truncated: false,
        })
        .unwrap();
        let via = render_wire_aux(&req, &data).unwrap();
        assert_eq!(
            via,
            render_all(&data, 4, data.len(), false).into_bytes(),
            "render_wire_aux(req={{width,…}}, aux=bytes) is the raw dump"
        );

        // Over-cap width clamps to MAX_HEX_WIDTH — the safety guard, identical
        // to the symbol. Teeth: were the clamp dropped, render_all at
        // u32::MAX-as-usize would diverge (and on a real buffer abort).
        let req_big = crate::wire::encode_frame(&RenderAuxRequest {
            width: MAX_HEX_WIDTH + 1,
            total_byte_count: data.len() as u64,
            is_truncated: false,
        })
        .unwrap();
        assert_eq!(
            render_wire_aux(&req_big, &data).unwrap(),
            render_all(&data, MAX_HEX_WIDTH as usize, data.len(), false).into_bytes(),
            "an over-cap width clamps to MAX_HEX_WIDTH"
        );
    }
}
