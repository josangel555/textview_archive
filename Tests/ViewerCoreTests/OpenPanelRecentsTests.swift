import XCTest
@testable import ViewerCore

/// Host coverage for the Open-dialog recents derivation (TSK-746). The
/// panel accessory render is a VM tail; this pins the model behavior:
/// ordering (newest-first preserved), de-dup, drop-missing, cap-to-N, and
/// add-on-open head update.
final class OpenPanelRecentsTests: XCTestCase {

    /// Build a probe that reports every supplied path present, classifying
    /// directories vs files by membership in `dirs`. Anything not listed in
    /// `files`/`dirs` reads as missing.
    private func probe(
        files: Set<String> = [],
        dirs: Set<String> = []
    ) -> (String) -> OpenPanelRecents.Existence {
        return { path in
            if dirs.contains(path) { return .directory }
            if files.contains(path) { return .file }
            return .missing
        }
    }

    // MARK: - ordering

    func test_derive_preservesNewestFirstOrder() {
        let paths = ["/a.md", "/b.md", "/c.md"]
        let out = OpenPanelRecents.derive(
            from: paths, probe: probe(files: ["/a.md", "/b.md", "/c.md"])
        )
        XCTAssertEqual(out.map(\.path), ["/a.md", "/b.md", "/c.md"])
    }

    // MARK: - de-dup

    func test_derive_dedupesKeepingFirstOccurrence() {
        // The newest (first) occurrence wins its slot; later dupes drop.
        let paths = ["/a.md", "/b.md", "/a.md"]
        let out = OpenPanelRecents.derive(
            from: paths, probe: probe(files: ["/a.md", "/b.md"])
        )
        XCTAssertEqual(out.map(\.path), ["/a.md", "/b.md"])
    }

    func test_derive_dedupesAcrossPathSpellings() {
        // `/a/` standardizes to `/a` → collapses with `/a`.
        let paths = ["/dir/", "/dir"]
        let out = OpenPanelRecents.derive(
            from: paths, probe: probe(dirs: ["/dir"])
        )
        XCTAssertEqual(out.map(\.path), ["/dir"])
    }

    func test_derive_skipsEmptyPaths() {
        let out = OpenPanelRecents.derive(
            from: ["", "   ".trimmingCharacters(in: .whitespaces), "/a.md"],
            probe: probe(files: ["/a.md"])
        )
        XCTAssertEqual(out.map(\.path), ["/a.md"])
    }

    // MARK: - existence filtering

    func test_derive_dropsMissingPaths() {
        let paths = ["/gone.md", "/here.md", "/also-gone.md"]
        let out = OpenPanelRecents.derive(
            from: paths, probe: probe(files: ["/here.md"])
        )
        XCTAssertEqual(out.map(\.path), ["/here.md"])
    }

    func test_derive_classifiesDirectoryVsFile() {
        let out = OpenPanelRecents.derive(
            from: ["/proj", "/note.md"],
            probe: probe(files: ["/note.md"], dirs: ["/proj"])
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].isDirectory)
        XCTAssertFalse(out[1].isDirectory)
    }

    // MARK: - cap

    func test_derive_capsToLimit() {
        let paths = (0..<20).map { "/p\($0).md" }
        let out = OpenPanelRecents.derive(
            from: paths, limit: 5, probe: probe(files: Set(paths))
        )
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.map(\.path), Array(paths.prefix(5)))
    }

    func test_derive_capCountedAfterFilteringNotBefore() {
        // Two missing entries up front must NOT eat the cap: the limit
        // applies to KEPT entries, so a leading run of dead paths still
        // yields `limit` live ones when enough exist behind them.
        let live = (0..<5).map { "/live\($0).md" }
        let paths = ["/dead1.md", "/dead2.md"] + live
        let out = OpenPanelRecents.derive(
            from: paths, limit: 3, probe: probe(files: Set(live))
        )
        XCTAssertEqual(out.map(\.path), Array(live.prefix(3)))
    }

    func test_derive_zeroLimitYieldsEmpty() {
        let out = OpenPanelRecents.derive(
            from: ["/a.md"], limit: 0, probe: probe(files: ["/a.md"])
        )
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - add-on-open head update

    func test_addingOnOpen_putsOpenedAtHead() {
        let list = OpenPanelRecents.derive(
            from: ["/a.md", "/b.md"], probe: probe(files: ["/a.md", "/b.md"])
        )
        let updated = OpenPanelRecents.addingOnOpen(
            "/c.md", to: list, isDirectory: false
        )
        XCTAssertEqual(updated.map(\.path), ["/c.md", "/a.md", "/b.md"])
    }

    func test_addingOnOpen_reopeningExistingMovesItToHead() {
        let list = OpenPanelRecents.derive(
            from: ["/a.md", "/b.md", "/c.md"],
            probe: probe(files: ["/a.md", "/b.md", "/c.md"])
        )
        let updated = OpenPanelRecents.addingOnOpen(
            "/c.md", to: list, isDirectory: false
        )
        // /c.md jumps to the head; no duplicate left behind.
        XCTAssertEqual(updated.map(\.path), ["/c.md", "/a.md", "/b.md"])
    }

    func test_addingOnOpen_recapsAfterPrepend() {
        let base = (0..<5).map { "/p\($0).md" }
        let list = OpenPanelRecents.derive(
            from: base, probe: probe(files: Set(base))
        )
        let updated = OpenPanelRecents.addingOnOpen(
            "/new.md", to: list, isDirectory: false, limit: 5
        )
        XCTAssertEqual(updated.count, 5)
        XCTAssertEqual(updated.first?.path, "/new.md")
        // Oldest (the previous tail) is evicted by the re-cap.
        XCTAssertFalse(updated.map(\.path).contains("/p4.md"))
    }

    func test_addingOnOpen_standardizesOpenedPath() {
        let list = OpenPanelRecents.derive(
            from: ["/a.md"], probe: probe(files: ["/a.md"])
        )
        // "/dir/" standardizes to "/dir" for both head + dedup.
        let updated = OpenPanelRecents.addingOnOpen(
            "/dir/", to: list, isDirectory: true
        )
        XCTAssertEqual(updated.first?.path, "/dir")
        XCTAssertTrue(updated.first?.isDirectory == true)
    }

    // MARK: - entry metadata

    func test_entry_displayNameIsLastComponent() {
        let e = OpenPanelRecentEntry(path: "/Users/me/notes/todo.md", isDirectory: false)
        XCTAssertEqual(e.displayName, "todo.md")
    }

    func test_entry_parentLabelIsParentFolderName() {
        let e = OpenPanelRecentEntry(path: "/Users/me/notes/todo.md", isDirectory: false)
        XCTAssertEqual(e.parentLabel, "notes")
    }

    func test_entry_parentLabelHomeAbbreviatesToTilde() {
        let home = NSHomeDirectory()
        let e = OpenPanelRecentEntry(path: home + "/todo.md", isDirectory: false)
        XCTAssertEqual(e.parentLabel, "~")
    }

    func test_entry_parentLabelAtRootIsSlash() {
        let e = OpenPanelRecentEntry(path: "/foo.md", isDirectory: false)
        XCTAssertEqual(e.parentLabel, "/")
    }

    func test_entry_urlRoundTrips() {
        let e = OpenPanelRecentEntry(path: "/Users/me/todo.md", isDirectory: false)
        XCTAssertEqual(e.url.path, "/Users/me/todo.md")
    }

    // MARK: - integration with the live FileManager probe

    func test_derive_withRealFileSystemProbe() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPanelRecents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("real.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let subdir = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let missing = tmp.appendingPathComponent("ghost.md")

        let out = OpenPanelRecents.derive(
            from: [missing.path, file.path, subdir.path]
        )
        // ghost dropped; file + dir kept in input order, correctly classified.
        XCTAssertEqual(out.map(\.path), [file.path, subdir.path])
        XCTAssertFalse(out[0].isDirectory)
        XCTAssertTrue(out[1].isDirectory)
    }
}
