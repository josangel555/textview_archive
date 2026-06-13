import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-311 slice 2 — archives are a first-class preview category: the
/// detector, the mode matrix, and the document-state routing all agree,
/// and the browser view is wired into the preview switch with the open
/// hook. (The rendered listing itself is the live glance.)
@MainActor
final class ArchiveRoutingTests: HeadlessUITestCase {

    func test_detector_classifiesArchiveSuffixes_includingTwoPart() {
        func cat(_ name: String) -> FileCategory {
            FileTypeDetector.category(for: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(cat("a.zip"), .archive)
        XCTAssertEqual(cat("lib.JAR"), .archive)
        XCTAssertEqual(cat("a.tar"), .archive)
        XCTAssertEqual(cat("a.tgz"), .archive)
        XCTAssertEqual(cat("a.tar.gz"), .archive,
                       "two-part extensions must classify (pathExtension is just 'gz')")
        XCTAssertEqual(cat("a.tar.bz2"), .archive)
        XCTAssertEqual(cat("a.gz"), .unknown,
                       "a bare .gz (no .tar) stays unknown — we have no lister for it")
        XCTAssertEqual(cat("a.7z"), .unknown, "7z stays icon-only in v1")
    }

    func test_modeMatrix_archive_isPreviewPlusHex() {
        let url = URL(fileURLWithPath: "/tmp/fixture.zip")
        XCTAssertEqual(ViewModeOptions.availableModes(for: url), [.preview, .hex])
        XCTAssertEqual(ViewModeOptions.defaultMode(for: url), .preview)
        XCTAssertFalse(ViewModeOptions.supportsEditor(url),
                       "an archive is never an editable text buffer")
    }

    func test_controller_opensArchive_asPreviewState() throws {
        // A real zip on disk — the controller checks readability.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRoutingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-r", dir.appendingPathComponent("f.zip").path, "a.txt"]
        p.currentDirectoryURL = dir
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        let state = DocumentController().open(url: dir.appendingPathComponent("f.zip"))
        guard case .preview(let previewURL, let category) = state else {
            return XCTFail("archive must open into .preview, got \(state)")
        }
        XCTAssertEqual(previewURL.lastPathComponent, "f.zip")
        XCTAssertEqual(category, .archive)
    }

    /// Wiring pins: the preview switch routes `.archive` to the browser
    /// view WITH the open hook (the dead-channel idiom — a listed entry
    /// nobody can open is half a feature).
    func test_previewSwitch_and_openHook_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let preview = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/MediaPreviewView.swift"),
            encoding: .utf8)
        XCTAssertTrue(preview.contains("ArchiveBrowserView(url: url"),
                      "the .archive preview arm must mount the browser")
        XCTAssertTrue(preview.contains("onOpenEntry: onOpenSibling"),
                      "entry opening must ride the existing open hook")
    }
}
