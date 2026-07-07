import XCTest
@testable import ViewerCore

/// TSK-1489 — the new-tab omnibox resolution table: input shape → action.
final class OmniResolverTests: XCTestCase {

    /// An existence probe over a fixed set (dirs vs files).
    private func probe(dirs: Set<String> = [], files: Set<String> = [])
        -> (String) -> Bool? {
        { path in
            if dirs.contains(path) { return true }
            if files.contains(path) { return false }
            return nil
        }
    }

    func test_empty_isEmpty() {
        XCTAssertEqual(OmniResolver.classify("", pathExists: probe()), .empty)
        XCTAssertEqual(OmniResolver.classify("   ", pathExists: probe()), .empty)
    }

    func test_existingPaths_openWithDirFlag() {
        XCTAssertEqual(
            OmniResolver.classify("/tmp/proj", pathExists: probe(dirs: ["/tmp/proj"])),
            .openPath("/tmp/proj", isDirectory: true))
        XCTAssertEqual(
            OmniResolver.classify("/tmp/a.md", pathExists: probe(files: ["/tmp/a.md"])),
            .openPath("/tmp/a.md", isDirectory: false))
    }

    func test_tildeExpands_andFileURLStrips() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            OmniResolver.classify("~/notes.md", pathExists: probe(files: [home + "/notes.md"])),
            .openPath(home + "/notes.md", isDirectory: false))
        XCTAssertEqual(
            OmniResolver.classify("file:///etc/hosts", pathExists: probe(files: ["/etc/hosts"])),
            .openPath("/etc/hosts", isDirectory: false))
    }

    func test_missingPathShape_staysAPathOpen_notSearch() {
        // A path-shaped miss routes as an open (caller surfaces "no such file"),
        // never a silent search for "/x/y".
        XCTAssertEqual(
            OmniResolver.classify("/does/not/exist", pathExists: probe()),
            .openPath("/does/not/exist", isDirectory: false))
    }

    func test_webURLs() {
        XCTAssertEqual(OmniResolver.classify("https://example.com", pathExists: probe()),
                       .openURL("https://example.com"))
        XCTAssertEqual(OmniResolver.classify("HTTP://EXAMPLE.com/x", pathExists: probe()),
                       .openURL("HTTP://EXAMPLE.com/x"), "scheme match is case-insensitive")
        // Not a web scheme → not openURL.
        if case .openURL = OmniResolver.classify("mailto://x", pathExists: probe()) {
            XCTFail("mailto is not a browsable URL")
        }
    }

    func test_gitRemotes() {
        XCTAssertEqual(OmniResolver.classify("git@github.com:o/r.git", pathExists: probe()),
                       .gitRemote("git@github.com:o/r.git"))
        XCTAssertEqual(OmniResolver.classify("https://github.com/o/r.git", pathExists: probe()),
                       .gitRemote("https://github.com/o/r.git"),
                       "a .git https URL is a remote, not a page")
        XCTAssertEqual(OmniResolver.classify("github.com/o/r", pathExists: probe()),
                       .gitRemote("github.com/o/r"))
    }

    func test_bareText_isSearch() {
        XCTAssertEqual(OmniResolver.classify("todo refactor", pathExists: probe()),
                       .search("todo refactor"))
        XCTAssertEqual(OmniResolver.classify("relative/path.md", pathExists: probe()),
                       .search("relative/path.md"),
                       "a non-anchored relative path is ambiguous → search")
    }

    func test_windowsDriveLetter_isNotAURL() {
        // C:\ must not parse as scheme "c" — it's search fodder on macOS.
        XCTAssertEqual(OmniResolver.classify(#"C:\Users\x"#, pathExists: probe()),
                       .search(#"C:\Users\x"#))
    }
}
