import XCTest
import UniformTypeIdentifiers
@testable import ViewerUI

/// TSK-284 (owner choice (a)) — drag files OUT of the app. The physical
/// drag session is the live glance; these pin the data layer (what the
/// provider REGISTERS — the part that decides whether Finder copies a
/// file or drops a dead link) and the wiring (source pins).
@MainActor
final class FileDragProviderTests: HeadlessUITestCase {

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDragProviderTests-\(UUID().uuidString).txt")
        try Data("drag me".utf8).write(to: url)
        return url
    }

    func test_make_registersTheFileURLRepresentation() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = FileDragProvider.make(for: url)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "Finder needs public.file-url to COPY a file — got: "
            + "\(provider.registeredTypeIdentifiers)")
    }

    func test_make_missingFile_stillCarriesTheURL_neverCrashes() {
        let gone = URL(fileURLWithPath: "/tmp/FileDragProviderTests-no-such-\(UUID()).txt")
        let provider = FileDragProvider.make(for: gone)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "the fallback registration must still carry the file reference")
    }

    /// The tab-strip compose contract: attaching the file URL must PRESERVE
    /// the reorder payload's .plainText representation — breaking it breaks
    /// in-app tab drag-reorder (TabDropDelegate reads .plainText).
    func test_attachFileURL_preservesThePlainTextReorderPayload() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = NSItemProvider(object: NSString(string: "tab-payload"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(
            UTType.plainText.identifier))
        FileDragProvider.attachFileURL(url, to: provider)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
            "the reorder payload must survive the file-URL attachment")
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "and the file reference must be added alongside it")
    }

    /// Wiring pins (the TSK-561 dead-channel idiom): the three drag-out
    /// sources actually attach the provider.
    func test_dragSources_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        }
        let sidebar = try source("Sources/ViewerUI/SidebarView.swift")
        XCTAssertEqual(
            sidebar.components(separatedBy: "FileDragProvider.make(for:").count - 1, 2,
            "both the tree row and the filter row must be drag-out sources")
        let tabBar = try source("Sources/ViewerUI/TabBar.swift")
        XCTAssertTrue(tabBar.contains("FileDragProvider.attachFileURL"),
                      "the tab strip must compose the file reference onto "
                      + "its reorder payload (TSK-284)")
    }
}
