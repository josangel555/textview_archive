import Testing
import Foundation
@testable import ViewerCore

/// Downgrade-rule coverage for `RichTextParser` (arbitrary Markdown → the closed
/// RichText vocabulary). The existing DocxExporter/RtfExporter tests exercise only
/// happy-path inputs; these pin the DOCUMENTED downgrade rules — the shipped
/// `.docx`/`.rtf` export depends on them — by asserting on the exported document XML.
@Suite struct RichTextDowngradeTests {

    private func docx(_ md: String) -> String {
        DocxExporter.documentXML(RichTextParser.parse(md))
    }

    @Test func image_downgradesToAltText_dropsURL() {
        // ![alt](url) → keep the alt label as text, DROP the url (no image node).
        let xml = docx("![mypic](http://example.com/secret.png)")
        #expect(xml.contains("mypic"), "alt text kept")
        #expect(!xml.contains("example.com"), "image URL dropped (downgraded to alt text)")
    }

    @Test func h4ToH6_downgradeToParagraph() {
        // The vocab allows H1–H3; H4–H6 downgrade to a paragraph (no Heading style).
        let xml = docx("#### H4 only")
        #expect(xml.contains("H4 only"), "H4 text kept")
        #expect(!xml.contains("Heading"), "H4 became a paragraph — no Heading style emitted")
    }

    @Test func rawHTMLTags_areStripped() {
        let xml = docx("before <span class=\"x\">mid</span> after")
        #expect(xml.contains("before") && xml.contains("after"), "surrounding text kept")
        #expect(!xml.contains("&lt;span"), "raw HTML tag stripped, not kept as escaped text")
    }
}
