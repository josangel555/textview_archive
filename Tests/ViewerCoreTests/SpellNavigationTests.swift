import Testing
@testable import ViewerCore

/// TSK-1505 — pure coverage for the spelling-verb core (`SpellNavigation`):
/// the wrapping nav cursor, the UTF-16 range replace (fix), and word extraction.
struct SpellNavigationTests {

    // MARK: - step (wrapping nav cursor)

    @Test func step_fromNil_forwardLandsOnFirst_backwardOnLast() {
        #expect(SpellNavigation.step(from: nil, count: 3, by: +1) == 0)
        #expect(SpellNavigation.step(from: nil, count: 3, by: -1) == 2)
    }

    @Test func step_advancesAndWrapsForward() {
        #expect(SpellNavigation.step(from: 0, count: 3, by: +1) == 1)
        #expect(SpellNavigation.step(from: 1, count: 3, by: +1) == 2)
        #expect(SpellNavigation.step(from: 2, count: 3, by: +1) == 0)   // wrap
    }

    @Test func step_retreatsAndWrapsBackward() {
        #expect(SpellNavigation.step(from: 2, count: 3, by: -1) == 1)
        #expect(SpellNavigation.step(from: 0, count: 3, by: -1) == 2)   // wrap (non-negative modulo)
    }

    @Test func step_emptyIsNil_singleStaysPut() {
        #expect(SpellNavigation.step(from: nil, count: 0, by: +1) == nil)
        #expect(SpellNavigation.step(from: 0, count: 1, by: +1) == 0)
        #expect(SpellNavigation.step(from: 0, count: 1, by: -1) == 0)
    }

    @Test func step_treatsAnyMagnitudeAsSingleStep() {
        // A caller passing +5 must not skip issues — only the sign matters.
        #expect(SpellNavigation.step(from: 0, count: 3, by: +5) == 1)
        #expect(SpellNavigation.step(from: 0, count: 3, by: -5) == 2)
    }

    // MARK: - correctedText (fix = UTF-16 range replace)

    @Test func correctedText_replacesTheRange() {
        // "I recieve it" → replace [2,9] ("recieve") with "receive".
        let out = SpellNavigation.correctedText(
            replacingUTF16: 2, 9, with: "receive", in: "I recieve it")
        #expect(out == "I receive it")
    }

    @Test func correctedText_outOfRangeIsNoOp() {
        #expect(SpellNavigation.correctedText(
            replacingUTF16: 0, 99, with: "x", in: "abc") == "abc")
        #expect(SpellNavigation.correctedText(
            replacingUTF16: 5, 2, with: "x", in: "abcdef") == "abcdef")   // inverted
        #expect(SpellNavigation.correctedText(
            replacingUTF16: -1, 2, with: "x", in: "abc") == "abc")
    }

    @Test func correctedText_handlesUTF16Astral() {
        // "a😀bad" — the emoji is 2 UTF-16 units, so "bad" starts at offset 3.
        let text = "a😀bad"
        #expect(SpellNavigation.correctedText(
            replacingUTF16: 3, 6, with: "good", in: text) == "a😀good")
    }

    // MARK: - word (extraction for learn/ignore)

    @Test func word_extractsTheSpan() {
        #expect(SpellNavigation.word(atUTF16: 2, 9, in: "I recieve it") == "recieve")
    }

    @Test func word_emptyOnBadRange() {
        #expect(SpellNavigation.word(atUTF16: 2, 2, in: "abc") == "")   // zero-length
        #expect(SpellNavigation.word(atUTF16: 0, 99, in: "abc") == "")  // out of range
    }
}
