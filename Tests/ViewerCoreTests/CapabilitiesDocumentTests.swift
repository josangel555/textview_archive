import Testing
import Foundation
@testable import ViewerCore

/// TSK-1575 — the Help ▸ Capabilities content source: prefer the bundled
/// `CAPABILITIES.md` (single source), fall back to an embedded pointer when the
/// resource isn't staged (dev / tests).
struct CapabilitiesDocumentTests {

    @Test func fallback_isNonEmpty_withTitle() {
        #expect(CapabilitiesDocument.fallbackMarkdown.contains("# TextView — Capabilities"))
        #expect(!CapabilitiesDocument.fallbackMarkdown.isEmpty)
    }

    @Test func markdown_fallsBack_whenBundleLacksResource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyCaps-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try #require(Bundle(url: dir))
        #expect(CapabilitiesDocument.markdown(in: bundle) == CapabilitiesDocument.fallbackMarkdown)
    }

    @Test func markdown_prefersBundledResource_whenPresent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caps-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let planted = "# Bundled Capabilities\n\nreal guide content\n"
        try planted.write(to: dir.appendingPathComponent("CAPABILITIES.md"),
                          atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: dir))
        #expect(CapabilitiesDocument.markdown(in: bundle) == planted)
    }
}
