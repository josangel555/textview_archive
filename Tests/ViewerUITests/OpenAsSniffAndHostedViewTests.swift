import XCTest
import SwiftUI
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// WAVE 2b — the UI-layer (DocumentModel) pieces of Open-As + the
/// view-hosting tab + File-History gating that have no home in
/// ViewerCore/ViewerKit (they touch `DocumentModel`, which owns the
/// hosted-view registry and the magic-byte sniff). HOST-SAFE: these are
/// pure model tests — no NSApplication, no window, no `.app` launch —
/// the same shape as the existing `DocumentModelGitPanelTests`. Scratch
/// files live under the per-user tmpdir.
///
/// Coverage:
///   - `sniffCategory(url:)` magic-byte auto-hint (SQLite / PNG / JPEG /
///     GIF / PDF, and the no-match / empty / short-header cases);
///   - `openAsCategories(for:)` offers the FULL viewer list for ANY file
///     — including binaries (not just HEX) — with the sniffed category
///     floated to the front as a hint;
///   - `openHostedView(title:rootView:)` appends a `.hostedView` tab and
///     registers the AnyView, and the registry is SWEPT when the tab
///     closes (`closeTab` → `purgeCaches`);
///   - `canShowFileHistory(for:)` gates on repo-membership + tracked.
@MainActor
final class OpenAsSniffAndHostedViewTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAsSniffTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func write(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - sniffCategory (magic bytes)

    func test_sniff_sqlite() throws {
        // "SQLite format 3\0" header.
        let header = Array("SQLite format 3".utf8) + [0x00]
        let url = try write("data.db.bak", bytes: header + [0x01, 0x02, 0x03])
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .sqlite)
    }

    func test_sniff_png() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD]
        let url = try write("img.dat", bytes: png)
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .image)
    }

    func test_sniff_jpeg() throws {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        let url = try write("photo.raw", bytes: jpeg)
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .image)
    }

    func test_sniff_gif() throws {
        let gif: [UInt8] = Array("GIF89a".utf8) + [0x01, 0x00]
        let url = try write("anim.bin", bytes: gif)
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .image)
    }

    func test_sniff_pdf() throws {
        let pdf: [UInt8] = Array("%PDF-1.7".utf8)
        let url = try write("doc.blob", bytes: pdf)
        XCTAssertEqual(DocumentModel.sniffCategory(url: url), .pdf)
    }

    func test_sniff_returnsNil_forPlainText() throws {
        let url = try write("notes.unknownext", bytes: Array("hello world\n".utf8))
        XCTAssertNil(DocumentModel.sniffCategory(url: url),
                     "no recognizable magic ⇒ nil (no hint)")
    }

    func test_sniff_returnsNil_forEmptyFile() throws {
        let url = try write("empty.bin", bytes: [])
        XCTAssertNil(DocumentModel.sniffCategory(url: url))
    }

    func test_sniff_returnsNil_forMissingFile() {
        let url = tmp.appendingPathComponent("does-not-exist.bin")
        XCTAssertNil(DocumentModel.sniffCategory(url: url))
    }

    func test_sniff_truncatedHeader_doesNotFalsePositive() throws {
        // A 2-byte file can't satisfy any of the >=N-byte magics; the
        // length guards must prevent an out-of-bounds read.
        let url = try write("short.bin", bytes: [0xFF, 0xD8])  // JPEG needs 3 bytes
        XCTAssertNil(DocumentModel.sniffCategory(url: url))
    }

    // MARK: - openAsCategories (full list, including binaries)

    /// The full universal viewer set offered by Open-As (2026-06-01: widened
    /// to every real viewer when the context-menu Open-As was folded into the
    /// one chip). `.unknown` is excluded — it's the not-a-viewer sentinel.
    private static let universalViewers: Set<FileCategory> = [
        .code, .plainText, .markdown, .mermaid, .html,
        .image, .audio, .video, .pdf, .sqlite, .binary,
    ]

    func test_openAsCategories_offersFullViewerList() throws {
        // A plain text file with no recognizable magic: the menu order is
        // the full universal viewer list — no category dropped, including
        // .binary (HEX), the media lenses, and .sqlite even though this
        // isn't a DB.
        let url = try write("plain.txt", bytes: Array("just text\n".utf8))
        let cats = DocumentModel().openAsCategories(for: url)
        XCTAssertEqual(Set(cats), Self.universalViewers,
                       "every viewer offered for any file")
        XCTAssertTrue(cats.contains(.binary), "binary (HEX) is always an option")
        // No .unknown sentinel leaks into the user-facing list.
        XCTAssertFalse(cats.contains(.unknown))
    }

    func test_openAsCategories_floatsSniffedHintToFront() throws {
        // A `.txt` whose bytes are actually a SQLite DB: the sniff floats
        // .sqlite to the front as the obvious first pick (a hint, not a
        // restriction — the rest of the list is still present).
        let header = Array("SQLite format 3".utf8) + [0x00]
        let url = try write("mislabeled.txt", bytes: header)
        let cats = DocumentModel().openAsCategories(for: url)
        XCTAssertEqual(cats.first, .sqlite, "sniffed category floats to front")
        // No category lost or duplicated in the reorder.
        XCTAssertEqual(Set(cats), Self.universalViewers)
        XCTAssertEqual(cats.count, Self.universalViewers.count,
                       "float must not duplicate the hint")
    }

    func test_openAsCategories_onBinary_stillFullList() throws {
        // A NUL-heavy binary blob: the menu still offers every viewer,
        // not just HEX — the whole point of universal Open-As.
        let url = try write("blob.bin", bytes: [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00])
        let cats = DocumentModel().openAsCategories(for: url)
        XCTAssertEqual(Set(cats), Self.universalViewers)
        XCTAssertTrue(cats.contains(.plainText))
        XCTAssertTrue(cats.contains(.markdown))
        XCTAssertTrue(cats.contains(.code))
        XCTAssertTrue(cats.contains(.binary))
    }

    // MARK: - openHostedView + registry sweep on close

    func test_openHostedView_appendsTab_andRegistersView() {
        let m = DocumentModel()
        let id = m.openHostedView(title: "History: a.txt", rootView: Text("hi"))
        XCTAssertEqual(m.tabs.tabs.count, 1)
        guard case .hostedView(let hid, let title) = m.tabs.tabs[0].state else {
            return XCTFail("expected a .hostedView tab")
        }
        XCTAssertEqual(hid, id)
        XCTAssertEqual(title, "History: a.txt")
        XCTAssertNotNil(m.hostedView(forID: id), "AnyView registered under id")
    }

    func test_closingHostedTab_sweepsRegistry() {
        let m = DocumentModel()
        let id = m.openHostedView(title: "X", rootView: Text("hi"))
        XCTAssertNotNil(m.hostedView(forID: id))
        m.closeTab(at: 0)
        XCTAssertTrue(m.tabs.isEmpty)
        XCTAssertNil(m.hostedView(forID: id),
                     "closing the tab must release its hosted view (no leak)")
    }

    func test_closingOneHostedTab_keepsOthersAlive() {
        let m = DocumentModel()
        let id1 = m.openHostedView(title: "one", rootView: Text("1"))
        let id2 = m.openHostedView(title: "two", rootView: Text("2"))
        XCTAssertEqual(m.tabs.tabs.count, 2)
        // Close the first; the second's view must survive the sweep.
        m.closeTab(at: 0)
        XCTAssertNil(m.hostedView(forID: id1), "closed tab swept")
        XCTAssertNotNil(m.hostedView(forID: id2), "surviving tab kept")
    }

    func test_multipleHostedTabs_haveDistinctIDs() {
        let m = DocumentModel()
        let id1 = m.openHostedView(title: "a", rootView: Text("a"))
        let id2 = m.openHostedView(title: "b", rootView: Text("b"))
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - canShowFileHistory gating

    func test_canShowFileHistory_falseOutsideRepo() throws {
        let url = tmp.appendingPathComponent("loose.txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(DocumentModel().canShowFileHistory(for: url),
                       "a file not under any git repo has no history")
    }

    func test_canShowFileHistory_trueForTracked_falseForUntracked() throws {
        let repo = try makeRepo()
        try gitWrite("tracked.txt", "x\n", in: repo)
        try git(["add", "tracked.txt"], in: repo)
        try git(["commit", "-q", "-m", "add tracked"], in: repo)
        // An untracked file present on disk but never committed.
        try gitWrite("untracked.txt", "y\n", in: repo)

        let m = DocumentModel()
        XCTAssertTrue(m.canShowFileHistory(for: repo.appendingPathComponent("tracked.txt")),
                      "tracked file ⇒ history available")
        XCTAssertFalse(m.canShowFileHistory(for: repo.appendingPathComponent("untracked.txt")),
                       "untracked file ⇒ no history")
        XCTAssertFalse(m.canShowFileHistory(for: repo.appendingPathComponent("ghost.txt")),
                       "nonexistent file ⇒ no history")
    }

    // MARK: - git scratch helpers

    private func makeRepo() throws -> URL {
        let dir = tmp.appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "t@example.com"], in: dir)
        try git(["config", "user.name", "Tester"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
        return dir
    }

    private func gitWrite(_ name: String, _ contents: String, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
