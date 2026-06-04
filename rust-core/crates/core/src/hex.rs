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
/// `HexLayout.renderedRowLength`). `width` must be `> 0`.
#[must_use]
pub fn rendered_row_length(width: usize) -> usize {
    // 8 offset + 2 spaces + (width*3 - 1) hex/sep + 2 spaces + width ascii + \n
    8 + 2 + (width * 3 - 1) + 2 + width + 1
}

/// Row count for a byte buffer at the given width (mirrors `HexLayout.rowCount`).
/// Zero bytes or zero width → zero rows.
#[must_use]
pub fn row_count(byte_count: usize, width: usize) -> usize {
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

/// Render the entire dump as one string (mirrors `HexDumpBuilder.buildAll`).
/// `byte_count` is `bytes.len()` (post-truncation); `total_byte_count` is the
/// pre-truncation file size used only in the `is_truncated` header.
#[must_use]
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
