//! Indentation detection — the Rust port of Swift `IndentDetector` (migration
//! plan slice #7). Pure, sans-IO. Samples the first `sample_lines` indented
//! lines, so it is O(window) regardless of file size.
//!
//! Output strings are pinned by the A/B test to match Swift byte-for-byte:
//! `"Tabs"`, `"Spaces (N)"`, `"Spaces"`, `"Mixed"`, or `"—"` (em dash) when no
//! indented line appears in the sample.

use std::collections::BTreeMap;

/// Detect the indentation style of `text`, sampling up to `sample_lines`
/// indented lines. Mirrors `IndentDetector.detect`.
#[must_use]
pub fn detect(text: &str, sample_lines: usize) -> String {
    let mut seen_tabs = 0usize;
    let mut space_widths: BTreeMap<usize, usize> = BTreeMap::new();
    let mut checked = 0usize;

    for line in text.split('\n') {
        if checked >= sample_lines {
            break;
        }
        // Strip a trailing CR so CRLF-authored files match `IndentDetector.swift`
        // (which treats a trailing CR as terminator noise). Without this, a
        // whitespace-only CRLF line like "  \r" fails the all-whitespace skip
        // below (the CR isn't space/tab) and is miscounted as a 2-space indent —
        // polluting the width histogram and breaking A/B parity on Windows files.
        let line = line.strip_suffix('\r').unwrap_or(line);
        // A blank or all-whitespace line (incl. empty) carries no indent signal.
        if line.chars().all(|c| c == ' ' || c == '\t') {
            continue;
        }
        match line.chars().next() {
            Some('\t') => {
                seen_tabs += 1;
                checked += 1;
            }
            Some(' ') => {
                let n = line.chars().take_while(|&c| c == ' ').count();
                *space_widths.entry(n).or_insert(0) += 1;
                checked += 1;
            }
            _ => {}
        }
    }

    let total_space_lines: usize = space_widths.values().sum();
    if seen_tabs == 0 && total_space_lines == 0 {
        return "—".to_string();
    }
    if seen_tabs > 0 && total_space_lines > 0 {
        return "Mixed".to_string();
    }
    if seen_tabs > 0 {
        return "Tabs".to_string();
    }

    // Largest-wins on tie: prefer "4" over "2" when both divide equally (the
    // file likely uses 4-space, the 2-divisibility being incidental).
    let mut best_width = 0usize;
    let mut best_score = 0usize;
    for c in [8usize, 4, 3, 2] {
        let mut score = 0usize;
        for (&k, &v) in &space_widths {
            if k > 0 && k % c == 0 {
                score += v;
            }
        }
        if score > best_score {
            best_score = score;
            best_width = c;
        }
    }
    if best_width == 0 {
        "Spaces".to_string()
    } else {
        format!("Spaces ({best_width})")
    }
}

/// Request for [`detect_wire_aux`] (TSK-580 slice 3): just the sample bound. The
/// source text is NOT in this frame — it rides the dispatch `aux` bulk side-
/// channel (a large file needn't be wrapped in a request frame). `pub` so
/// front-ends/tests build it.
#[derive(serde::Serialize, serde::Deserialize)]
pub struct DetectAuxRequest {
    /// How many indented lines to sample (mirrors `mdvcore_indent_detect`).
    pub sample_lines: u32,
}

/// Indent detection routed through the dispatch envelope (TSK-580 slice 3). The
/// source text arrives as `aux` (frame-cap-exempt); `req` carries only
/// `{sample_lines}`. Like [`crate::hex::render_wire_aux`], the response is the
/// **raw UTF-8 result string** (`"Tabs"`, `"Spaces (4)"`, `"—"`, …) — NOT a
/// MessagePack frame — which `mdvcore_call` writes to `out_buf` verbatim.
/// Byte-identical to the dedicated `mdvcore_indent_detect` symbol (the A/B
/// parity test pins it).
///
/// # Errors
/// [`crate::wire::WireFault::Decode`] on a request-decode fault, or when `aux`
/// is not valid UTF-8 (the dedicated symbol returns `MdvStatus::BadUtf8`; the
/// Swift caller always sends a valid-UTF-8 `String`, so the error is defensive).
pub fn detect_wire_aux(req: &[u8], aux: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let r: DetectAuxRequest = crate::wire::decode_frame(req)?;
    let text = core::str::from_utf8(aux)
        .map_err(|_| crate::wire::WireFault::Decode("indent text is not valid UTF-8".to_string()))?;
    let sample = usize::try_from(r.sample_lines).unwrap_or(usize::MAX);
    Ok(detect(text, sample).into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Robustness audit (un-fuzzed shipped engine): arbitrary text — mixed
    /// tabs/spaces, varying widths, blank/comment lines, unicode, raw noise —
    /// must NEVER panic in detect(), which always returns a non-empty label
    /// (— / Tabs / "N spaces"). Deterministic LCG, no dep. Teeth: an empty label
    /// fails the assert.
    #[test]
    #[allow(clippy::cast_possible_truncation, reason = "LCG values are modulo-bounded before use")]
    fn detect_fuzz_never_panics_and_returns_a_label() {
        const LINES: &[&str] = &[
            "abc", "  two", "    four", "\ttab", "        eight", " one", "   three",
            "\t  mixed", "中文", "", "   ", "\t\t", "// c", "def foo():", "      six",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0x12DE_27AA_0001_0001;
        for _ in 0..3000u32 {
            let n = (lcg(&mut state) % 20) as usize;
            let mut s = String::new();
            for _ in 0..n {
                s.push_str(LINES[(lcg(&mut state) as usize) % LINES.len()]);
                s.push('\n');
            }
            let sample = (lcg(&mut state) % 100) as usize;
            assert!(
                !detect(&s, sample).is_empty(),
                "detect returned an empty label for {s:?}"
            );
        }
    }

    #[test]
    fn no_indent_is_dash() {
        assert_eq!(detect("abc\ndef\n", 50), "—");
        assert_eq!(detect("", 50), "—");
    }

    #[test]
    fn tabs() {
        assert_eq!(detect("\tfoo\n\tbar\n", 50), "Tabs");
    }

    #[test]
    fn spaces_widths() {
        assert_eq!(detect("  a\n  b\n", 50), "Spaces (2)");
        assert_eq!(detect("    a\n    b\n", 50), "Spaces (4)");
        assert_eq!(detect("        a\n", 50), "Spaces (8)");
    }

    #[test]
    fn mixed() {
        assert_eq!(detect("\tfoo\n  bar\n", 50), "Mixed");
    }

    #[test]
    fn largest_divisor_wins() {
        // All 4-space; 2 also divides but 4 should win.
        assert_eq!(detect("    a\n    b\n    c\n", 50), "Spaces (4)");
    }

    #[test]
    fn blank_lines_ignored() {
        assert_eq!(detect("\n\n    a\n\n", 50), "Spaces (4)");
    }

    #[test]
    fn sample_window_bounds_work() {
        // Only the first indented line is sampled; it's tabs → "Tabs".
        assert_eq!(detect("\tx\n    y\n", 1), "Tabs");
    }

    #[test]
    fn crlf_whitespace_only_line_is_blank_not_indent() {
        // "  \r" is a blank line in a CRLF file (trailing spaces). It must NOT
        // count as a 2-space indent — a tab file with such a line stays "Tabs",
        // not "Mixed". Without the trailing-CR strip this returns "Mixed".
        assert_eq!(detect("\tfoo\r\n  \r\n\tbar\r\n", 50), "Tabs");
    }

    #[test]
    fn crlf_indented_lines_detected() {
        // Trailing CR on content lines is ignored; 4-space CRLF → "Spaces (4)".
        assert_eq!(detect("    a\r\n    b\r\n", 50), "Spaces (4)");
    }

    #[test]
    fn crlf_blank_space_lines_do_not_pollute_width() {
        // 4-space indents interleaved with blank "  \r" lines must still detect
        // 4, not 2. Without the fix the spurious width-2 lines outscore width-4
        // (2 divides 4) and this returns "Spaces (2)" — the teeth on the bug.
        assert_eq!(detect("    a\r\n  \r\n    b\r\n  \r\n    c\r\n", 50), "Spaces (4)");
    }

    #[test]
    fn detect_wire_aux_matches_detect() {
        // Text rides `aux`; {sample_lines} rides the `req` frame. The raw result
        // bytes must equal detect() called directly (no framing).
        let text = "    a\n    b\n";
        let req = crate::wire::encode_frame(&DetectAuxRequest { sample_lines: 50 }).unwrap();
        let via = detect_wire_aux(&req, text.as_bytes()).unwrap();
        assert_eq!(via, detect(text, 50).into_bytes());
        assert_eq!(String::from_utf8(via).unwrap(), "Spaces (4)");

        // The sample bound is honored through the wire path (only the first
        // indented line — a tab — is sampled → "Tabs", not "Mixed").
        let req1 = crate::wire::encode_frame(&DetectAuxRequest { sample_lines: 1 }).unwrap();
        let one = detect_wire_aux(&req1, "\tx\n    y\n".as_bytes()).unwrap();
        assert_eq!(String::from_utf8(one).unwrap(), "Tabs");

        // Invalid UTF-8 in `aux` is a typed decode fault, never a panic.
        assert!(matches!(
            detect_wire_aux(&req, &[0xff, 0xfe]),
            Err(crate::wire::WireFault::Decode(_))
        ));
    }

    // --- Property tests (TSK-585 lane): detect oracle correctness -------------
    // (The fuzz test above pins no-panic + a label; these pin the CLASSIFICATION.)
    use proptest::prelude::*;

    proptest! {
        /// A file whose indented lines are ALL tab-led (no space-led line)
        /// classifies as "Tabs".
        #[test]
        fn detect_consistent_tabs_is_tabs(
            lines in proptest::collection::vec((1usize..4, "[a-z]{1,5}"), 1..6),
        ) {
            let text = lines.into_iter()
                .map(|(t, c)| format!("{}{}", "\t".repeat(t), c))
                .collect::<Vec<_>>()
                .join("\n");
            prop_assert_eq!(detect(&text, 100), "Tabs");
        }

        /// A file whose indented lines are ALL multiples of 4 spaces (no tab)
        /// classifies as "Spaces (4)" — 4 wins the divisor vote over 2/8.
        #[test]
        fn detect_consistent_4_spaces_is_spaces_4(
            contents in proptest::collection::vec("[a-z]{1,5}", 1..6),
        ) {
            // Exactly 4 spaces per indented line — unambiguous: an all-8-space
            // file would (correctly) detect as "Spaces (8)", so don't vary the width.
            let text = contents.into_iter()
                .map(|c| format!("    {}", c))
                .collect::<Vec<_>>()
                .join("\n");
            prop_assert_eq!(detect(&text, 100), "Spaces (4)");
        }

        /// A file mixing tab-led AND space-led indented lines classifies "Mixed".
        #[test]
        fn detect_tabs_and_spaces_is_mixed(
            tabc in "[a-z]{1,5}",
            spc in "[a-z]{1,5}",
        ) {
            let text = format!("\t{}\n    {}", tabc, spc);
            prop_assert_eq!(detect(&text, 100), "Mixed");
        }
    }
}
