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

#[cfg(test)]
mod tests {
    use super::*;

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
}
