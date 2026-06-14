import XCTest
@testable import ViewerCore

/// TSK-696 — the `textview` command-line launcher install logic. Pure file/IO
/// over a temp dir; host-safe.
final class CLILauncherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLILauncher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Script generation

    func test_wrapperScript_shape() {
        let s = CLILauncher.wrapperScript(appPath: "/Applications/TextView.app")
        XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"), "must be a /bin/sh script")
        XCTAssertTrue(s.contains("APP='/Applications/TextView.app'"),
                      "the app path is single-quoted into APP")
        XCTAssertTrue(s.contains(#"exec /usr/bin/open -a "$APP" "$@""#),
                      "passes file args through to open(1)")
        XCTAssertTrue(s.contains(#"if [ "$#" -eq 0 ]"#),
                      "no-args branch launches the app bare")
    }

    func test_wrapperScript_shellQuotesSpacesAndApostrophes() {
        let s = CLILauncher.wrapperScript(appPath: "/Users/x/My Apps/Joe's TextView.app")
        // Spaces survive intact inside single quotes; an embedded ' is escaped.
        XCTAssertTrue(s.contains("APP='/Users/x/My Apps/Joe'\\''s TextView.app'"),
                      "a path with spaces + apostrophe is safely sh-quoted")
    }

    // MARK: Install

    func test_install_writesExecutableScript() throws {
        let dest = try CLILauncher.install(appPath: "/Applications/TextView.app", into: dir)
        XCTAssertEqual(dest.lastPathComponent, "textview")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path),
                      "installed command must be executable")
        let perms = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o755)
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertEqual(written, CLILauncher.wrapperScript(appPath: "/Applications/TextView.app"))
    }

    func test_isInstalled_falseThenTrue() throws {
        XCTAssertFalse(CLILauncher.isInstalled(in: dir))
        try CLILauncher.install(appPath: "/Applications/TextView.app", into: dir)
        XCTAssertTrue(CLILauncher.isInstalled(in: dir))
    }

    func test_reinstall_isIdempotent_overwrites() throws {
        try CLILauncher.install(appPath: "/Applications/Old.app", into: dir)
        let dest = try CLILauncher.install(appPath: "/Applications/New.app", into: dir)
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(written.contains("APP='/Applications/New.app'"),
                      "reinstall overwrites with the new app path")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path),
                      "still executable after overwrite")
    }

    func test_installCreatingDir_makesMissingDir() throws {
        let nested = dir.appendingPathComponent("does/not/exist/yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        let dest = try CLILauncher.installCreatingDir(appPath: "/Applications/TextView.app", into: nested)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
    }

    func test_install_intoMissingDir_throws() {
        // Plain `install` does NOT create the dir — it must surface the error so
        // the menu action can fall back.
        let missing = dir.appendingPathComponent("nope")
        XCTAssertThrowsError(try CLILauncher.install(appPath: "/Applications/TextView.app", into: missing))
    }

    func test_fallbackBinDir_underAppSupport() {
        let fb = CLILauncher.fallbackBinDir()
        XCTAssertEqual(fb.lastPathComponent, "bin")
        XCTAssertTrue(fb.deletingLastPathComponent().lastPathComponent == "MarkdownViewer")
    }
}
