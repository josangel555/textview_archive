import Testing
@testable import ViewerCore

/// Coverage for `RichTextSerializer` (TSK-706) — the restricted-IR → canonical
/// Markdown serializer. It was previously exercised only indirectly (the RichText
/// test files cover the parser + the RTF output path, not this Markdown output),
/// so this pins (a) the canonical spelling per construct and the tricky inline-
/// code fencing / escaping rules, and (b) the stated idempotence contract
/// `parse(serialize(parse(x))) == parse(x)`. Pure logic, host-testable.
struct RichTextSerializerTests {

    private func ser(_ blocks: [RichBlock]) -> String {
        RichTextSerializer.serialize(RichTextDocument(blocks))
    }

    // MARK: - Block canonical output

    @Test func headings_use_hash_runs_clamped_to_one_through_three() {
        #expect(ser([.heading(level: 1, inlines: [.text("A")])]) == "# A")
        #expect(ser([.heading(level: 3, inlines: [.text("C")])]) == "### C")
        // Out-of-range levels clamp into 1...3 (the restricted model has no H4+).
        #expect(ser([.heading(level: 9, inlines: [.text("X")])]) == "### X")
        #expect(ser([.heading(level: 0, inlines: [.text("X")])]) == "# X")
    }

    @Test func bullet_list_uses_dash_space() {
        #expect(ser([.bulletList([RichListItem([.text("a")]), RichListItem([.text("b")])])]) == "- a\n- b")
    }

    @Test func ordered_list_renumbers_sequentially_from_start() {
        #expect(ser([.orderedList(start: 3, items: [RichListItem([.text("a")]), RichListItem([.text("b")])])]) == "3. a\n4. b")
        // A zero/negative start is clamped up to 1.
        #expect(ser([.orderedList(start: 0, items: [RichListItem([.text("a")])])]) == "1. a")
    }

    @Test func blockquote_joins_paragraphs_with_an_empty_quote_line() {
        #expect(ser([.blockquote([[.text("a")], [.text("b")]])]) == "> a\n>\n> b")
        #expect(ser([.blockquote([[.text("solo")]])]) == "> solo")
    }

    @Test func blocks_are_separated_by_a_single_blank_line() {
        #expect(ser([.paragraph([.text("a")]), .paragraph([.text("b")])]) == "a\n\nb")
    }

    // MARK: - Inline canonical delimiters

    @Test func inline_marks_use_canonical_delimiters() {
        #expect(ser([.paragraph([.bold([.text("b")])])]) == "**b**")
        #expect(ser([.paragraph([.italic([.text("i")])])]) == "*i*")
        #expect(ser([.paragraph([.strike([.text("s")])])]) == "~~s~~")
        #expect(ser([.paragraph([.link(text: [.text("L")], url: "u")])]) == "[L](u)")
        // Nesting composes.
        #expect(ser([.paragraph([.bold([.italic([.text("x")])])])]) == "***x***")
    }

    // MARK: - Inline code: CommonMark backtick-run fencing

    @Test func inline_code_grows_the_fence_past_an_internal_backtick_run() {
        // No backticks inside → single-backtick fence.
        #expect(ser([.paragraph([.code("x")])]) == "`x`")
        // One backtick inside → fence grows to two; no padding (not at edges).
        #expect(ser([.paragraph([.code("a`b")])]) == "``a`b``")
        // Two adjacent → fence grows to three.
        #expect(ser([.paragraph([.code("a``b")])]) == "```a``b```")
        // Content starts/ends with a backtick → pad with spaces so it re-parses.
        #expect(ser([.paragraph([.code("`x`")])]) == "`` `x` ``")
    }

    // MARK: - Escaping of literal text

    @Test func text_escapes_inline_metacharacters_everywhere() {
        #expect(ser([.paragraph([.text("a*b_c`d~e[f]")])]) == "a\\*b\\_c\\`d\\~e\\[f\\]")
    }

    @Test func text_escapes_block_markers_only_at_the_start() {
        #expect(ser([.paragraph([.text("#h")])]) == "\\#h")
        #expect(ser([.paragraph([.text("a#b")])]) == "a#b")   // not at start → literal
        #expect(ser([.paragraph([.text("- x")])]) == "\\- x")
        #expect(ser([.paragraph([.text("> q")])]) == "\\> q")
    }

    // MARK: - Round-trip idempotence (the documented contract)

    @Test(arguments: [
        "# Heading\n\nA paragraph with **bold** and *italic* and `code`.",
        "- one\n- two\n- three",
        "1. first\n2. second",
        "> quoted line one\n>\n> quoted line two",
        "Plain text with a [link](https://example.com) inline.",
        "Text with ~~strike~~ in it.",
    ])
    func parse_serialize_parse_is_idempotent(_ md: String) {
        let once = RichTextDocument.parse(md)
        let twice = RichTextDocument.parse(RichTextSerializer.serialize(once))
        #expect(twice == once, "round-trip changed the IR for input: \(md)")
    }
}
