//! HTML block-patch foundation (TSK-838 — the DOM-patch perf lever).
//!
//! The rendered-markdown WebView currently re-`loadHTMLString`s the WHOLE page on
//! every update (the measured 2-9s reload storm; TSK-598/839 attribution). The fix
//! keeps the page mounted (`WarmHTMLWebViewCache`, already built) and applies a
//! MINIMAL DOM patch. This module is the pure, host-testable, sans-IO core: it
//! splits rendered HTML into top-level BLOCKS so two renders can be diffed
//! block-by-block. The block DIFF and the JS DOM applier are the next slices.
//!
//! Scope: robust for the HTML WE emit (pulldown-cmark — escaped content, simple
//! attributes, no `<`/`>` inside attribute strings). NOT a general HTML parser.

/// Void (self-closing-by-spec) HTML elements — they never have a separate close
/// tag, so they do not open a nesting level.
const VOID_ELEMENTS: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TagKind {
    Open,
    Close,
    /// A void element or an explicitly self-closed `<tag/>` — no nesting change.
    Selfish,
}

/// Split well-formed rendered-markdown HTML into its top-level pieces: each
/// top-level element (`<h1>…</h1>`, `<p>…</p>`, `<ul>…</ul>`, `<hr>`, a
/// `<!--…-->` chunk sentinel, …) is one block, and the text/whitespace BETWEEN
/// elements (pulldown-cmark's separating newlines) is preserved as its own block.
///
/// INVARIANT (exact): the blocks concatenate back to the input verbatim
/// (`split_top_level_blocks(h).concat() == h`) — no byte is dropped or added, so a
/// later rejoin/patch cannot corrupt the document. This is the property the
/// proptest pins against real rendered HTML.
#[must_use]
pub fn split_top_level_blocks(html: &str) -> Vec<String> {
    let bytes = html.as_bytes();
    let n = bytes.len();
    let mut blocks: Vec<String> = Vec::new();
    let mut i = 0usize;
    while i < n {
        if bytes.get(i) == Some(&b'<') {
            let end = top_level_node_end(bytes, i);
            if let Some(slice) = html.get(i..end) {
                blocks.push(slice.to_owned());
            }
            // `end` always advances past `i` (a tag is at least `<>`); guard anyway.
            i = end.max(i + 1);
        } else {
            let start = i;
            while i < n && bytes.get(i) != Some(&b'<') {
                i += 1;
            }
            if let Some(slice) = html.get(start..i) {
                blocks.push(slice.to_owned());
            }
        }
    }
    blocks
}

/// Index just past the top-level node that STARTS with `<` at `start`. Tracks
/// nesting depth across all tags so a nested element is contained; returns when
/// depth returns to 0 (or immediately for a void/self-close/comment node).
fn top_level_node_end(bytes: &[u8], start: usize) -> usize {
    let n = bytes.len();
    // Comment / chunk sentinel: `<!-- … -->`.
    if bytes.get(start..start.saturating_add(4)) == Some(b"<!--".as_slice()) {
        let mut j = start.saturating_add(4);
        while j.saturating_add(3) <= n {
            if bytes.get(j..j.saturating_add(3)) == Some(b"-->".as_slice()) {
                return j.saturating_add(3);
            }
            j += 1;
        }
        return n; // unterminated comment → to EOF (preserves the bytes)
    }
    let mut i = start;
    let mut depth: i32 = 0;
    while i < n {
        if bytes.get(i) == Some(&b'<') {
            let (tag_end, kind) = parse_tag(bytes, i);
            match kind {
                TagKind::Open => depth += 1,
                TagKind::Close => depth -= 1,
                TagKind::Selfish => {}
            }
            i = tag_end;
            if depth <= 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    n
}

/// Parse the tag starting at `start` (where `bytes[start] == b'<'`). Returns the
/// index just past the closing `>` and the tag's kind.
fn parse_tag(bytes: &[u8], start: usize) -> (usize, TagKind) {
    let n = bytes.len();
    let is_close = bytes.get(start.saturating_add(1)) == Some(&b'/');
    let mut j = start.saturating_add(1);
    while j < n && bytes.get(j) != Some(&b'>') {
        j += 1;
    }
    let end = j.saturating_add(1).min(n); // just past '>'
    if is_close {
        return (end, TagKind::Close);
    }
    // Self-closing: the byte immediately before '>' is '/'.
    let self_closed = j.checked_sub(1).and_then(|k| bytes.get(k)) == Some(&b'/');
    if self_closed {
        return (end, TagKind::Selfish);
    }
    if VOID_ELEMENTS.contains(&tag_name(bytes, start.saturating_add(1)).as_str()) {
        return (end, TagKind::Selfish);
    }
    (end, TagKind::Open)
}

/// Lowercased tag name starting at `from` (just past the `<`).
fn tag_name(bytes: &[u8], from: usize) -> String {
    let mut name: Vec<u8> = Vec::new();
    let mut j = from;
    while let Some(&c) = bytes.get(j) {
        if c.is_ascii_alphanumeric() || c == b'-' {
            name.push(c.to_ascii_lowercase());
            j += 1;
        } else {
            break;
        }
    }
    String::from_utf8_lossy(&name).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn rejoins(html: &str) -> bool {
        split_top_level_blocks(html).concat() == html
    }

    #[test]
    fn splits_sibling_blocks_and_preserves_separators() {
        let html = "<h1>A</h1>\n<p>B</p>\n";
        assert_eq!(
            split_top_level_blocks(html),
            vec!["<h1>A</h1>", "\n", "<p>B</p>", "\n"]
        );
        assert!(rejoins(html));
    }

    #[test]
    fn nested_element_is_one_block() {
        // The <ul> (with its nested <li>s and inner newlines) is ONE top-level block.
        let html = "<ul>\n<li>x</li>\n<li>y</li>\n</ul>\n<p>after</p>";
        assert_eq!(
            split_top_level_blocks(html),
            vec!["<ul>\n<li>x</li>\n<li>y</li>\n</ul>", "\n", "<p>after</p>"]
        );
        assert!(rejoins(html));
    }

    #[test]
    fn void_and_selfclose_and_comment_blocks() {
        assert!(rejoins("<hr>\n<p>x</p>"));
        assert!(rejoins("<hr />\n<img src=\"a.png\">\n<p>y</p>"));
        // A chunk sentinel comment is its own top-level block.
        assert_eq!(
            split_top_level_blocks("<!--mdv-chunk-0-->\n<p>z</p>"),
            vec!["<!--mdv-chunk-0-->", "\n", "<p>z</p>"]
        );
        assert!(rejoins("<!--mdv-chunk-0-->\n<p>z</p>"));
    }

    #[test]
    fn empty_and_textonly() {
        assert_eq!(split_top_level_blocks(""), Vec::<String>::new());
        assert_eq!(split_top_level_blocks("just text"), vec!["just text"]);
    }

    proptest! {
        /// TSK-838: the splitter is EXACT (split→concat == input) on real rendered
        /// markdown HTML — drives the pulldown-cmark renderer over generated block
        /// mixes (headings/paras/lists/quotes/rules/code/links, incl. the chunk
        /// sentinels render emits) and asserts no byte is lost. A mis-split (dropped
        /// char, bad UTF-8 boundary, mishandled void/comment) fails here.
        #[test]
        fn split_rejoins_rendered_markdown_exactly(
            parts in prop::collection::vec(
                prop::sample::select(vec![
                    "# Heading one",
                    "Some **bold** and _em_ paragraph text.",
                    "- item a\n- item b\n- item c",
                    "1. one\n2. two",
                    "> a block quote",
                    "---",
                    "```\nlet x = 1;\n```",
                    "A [link](http://example.com) and `code` inline.",
                    "| a | b |\n| - | - |\n| 1 | 2 |",
                ]),
                0..8,
            ),
        ) {
            let md = parts.join("\n\n");
            let html = crate::markdown::render(&md).html;
            prop_assert_eq!(split_top_level_blocks(&html).concat(), html);
        }
    }
}
