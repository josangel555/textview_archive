import XCTest
@testable import ViewerCore

/// Headless (Tier 1) coverage for the pure OSC-7 cwd-report decoder (TSK-341).
/// This is the value transformer the `ANSIParser` feeds the OSC payload into to
/// recover the live working directory the user `cd`'d to, so a restored terminal
/// tab re-spawns where they left off rather than in the original spawn dir.
final class TerminalOSC7Tests: XCTestCase {

    // MARK: - Happy path

    func test_basicLocalhostPayload_decodesToDirectory() {
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file://localhost/Users/me/proj")
        XCTAssertEqual(dir?.path, "/Users/me/proj")
    }

    func test_emptyHost_isTreatedAsLocal() {
        // Many shells emit `file:///abs/path` (empty authority).
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file:///Users/me")
        XCTAssertEqual(dir?.path, "/Users/me")
    }

    func test_percentEncodedSpaces_decode() {
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file://localhost/Users/me/My%20Docs")
        XCTAssertEqual(dir?.path, "/Users/me/My Docs")
    }

    func test_percentEncodedUnicode_decodes() {
        // "café" → c a f %C3%A9
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file:///tmp/caf%C3%A9")
        XCTAssertEqual(dir?.lastPathComponent, "café")
    }

    func test_returnedURL_isMarkedDirectory() {
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file:///Users/me/proj")
        XCTAssertTrue(dir?.hasDirectoryPath ?? false,
            "an OSC-7 cwd is always a directory; the URL should carry the marker")
    }

    func test_loopbackIPHost_isLocal() {
        let dir = TerminalOSC7.directory(fromOSCPayload: "7;file://127.0.0.1/var/log")
        XCTAssertEqual(dir?.path, "/var/log")
    }

    // MARK: - Local-host matching

    func test_matchingLocalHost_isAccepted() {
        let dir = TerminalOSC7.directory(
            fromOSCPayload: "7;file://mymac.local/Users/me",
            localHost: "mymac.local")
        XCTAssertEqual(dir?.path, "/Users/me")
    }

    func test_shortHostMatchesFullLocalHost() {
        // Emitter reports the bare short name; our localHost is the full ".local".
        let dir = TerminalOSC7.directory(
            fromOSCPayload: "7;file://mymac/Users/me",
            localHost: "mymac.local")
        XCTAssertEqual(dir?.path, "/Users/me")
    }

    func test_hostMatchIsCaseInsensitive() {
        let dir = TerminalOSC7.directory(
            fromOSCPayload: "7;file://MyMac.Local/Users/me",
            localHost: "mymac.local")
        XCTAssertEqual(dir?.path, "/Users/me")
    }

    // MARK: - Rejections (return nil)

    func test_remoteHost_isRejected() {
        let dir = TerminalOSC7.directory(
            fromOSCPayload: "7;file://other-machine/Users/me",
            localHost: "mymac.local")
        XCTAssertNil(dir, "a path on another machine can't seed the local shell's cwd")
    }

    func test_wrongSelector_isRejected() {
        // OSC 0/2 (window title), OSC 8 (hyperlink) must NOT be read as cwd.
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "0;some window title"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "2;another title"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "8;;https://example.com"))
    }

    func test_nonFileScheme_isRejected() {
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7;http://localhost/path"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7;ssh://host/path"))
    }

    func test_noSelectorSeparator_isRejected() {
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: ""))
    }

    func test_relativePath_isRejected() {
        // A non-absolute decoded path (no leading '/') is garbage for a cwd.
        // `file:relative/path` — schemeless-authority form where the remainder
        // doesn't begin with '/', so there's no absolute path component.
        XCTAssertNil(TerminalOSC7.directory(fromFileURI: "file:relative/path"))
    }

    func test_dotSegmentsAreStandardized() {
        // A '/'-prefixed path with dot-segments is absolute — accepted and
        // standardized (../oops/.. → /oops-parent resolution).
        let dir = TerminalOSC7.directory(fromFileURI: "file:///Users/me/proj/../proj2")
        XCTAssertEqual(dir?.path, "/Users/me/proj2")
    }

    func test_garbledPayload_isRejected() {
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7;notauri"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7;file://"))
        XCTAssertNil(TerminalOSC7.directory(fromOSCPayload: "7;"))
    }

    func test_trailingWhitespaceIsTolerated() {
        let dir = TerminalOSC7.directory(fromFileURI: "file:///Users/me/proj\n")
        XCTAssertEqual(dir?.path, "/Users/me/proj")
    }
}
