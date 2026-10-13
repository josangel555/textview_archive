import XCTest

/// TSK-626 regression guard for the SwiftPM header-staleness trap. Drives the
/// EXACT shell function the build wires (`scripts/lib/restage-header.sh`'s
/// `restage_core_header`, called by `build-rust-core.sh`) over hermetic fixture
/// dirs — no cargo, no window — and pins the two-way contract:
///
///   * header CHANGED → the TEST targets (Tests/RustCoreTests) AND every Swift
///     file naming the header surface (MDV_CAP_/MDV_WIRE_VERSION/import CMdvCore)
///     get touched, so stale test objects against a re-laid-out ABI can't
///     SIGSEGV-as-FFI-bug (the documented trap, bit twice).
///   * header UNCHANGED → only the RustCore bridge sources relink (the .a isn't
///     a tracked build input); test targets stay untouched (cheap restage).
///
/// Closes the test-gap the fix (fc5153b) deliberately left open ("a hermetic
/// test would need cargo stubbing seams") — the extracted function needs none.
final class RustCoreHeaderRestageTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ViewerCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    private static var lib: URL { repoRoot.appendingPathComponent("scripts/lib/restage-header.sh") }

    /// 2001-01-01 — a "stale" mtime far enough before now that a touch is
    /// unambiguous regardless of filesystem timestamp granularity.
    private let stalePast = Date(timeIntervalSince1970: 978_307_200)

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RustCoreHeaderRestage-\(UUID().uuidString)")
        for sub in ["Sources/RustCore", "Tests/RustCoreTests", "Sources/Other"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "import CMdvCore\n".write(to: f("Sources/RustCore/Bridge.swift"), atomically: true, encoding: .utf8)
        try "let x = MDV_CAP_FOO\n".write(to: f("Tests/RustCoreTests/BridgeTests.swift"), atomically: true, encoding: .utf8)
        try "let y = MDV_WIRE_VERSION\n".write(to: f("Sources/Other/Referent.swift"), atomically: true, encoding: .utf8)
        // A test file that does NOT name the header surface — it can only be
        // reached by the broad `find Tests/RustCoreTests` touch, not the
        // grep-for-referents. This is the actual 2026-06-12 SIGSEGV case: a test
        // object that links the re-laid-out module without naming a const.
        try "func helper() {}\n".write(to: f("Tests/RustCoreTests/Helper.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func f(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    private func markStale(_ rels: [String]) throws {
        for r in rels {
            try FileManager.default.setAttributes([.modificationDate: stalePast], ofItemAtPath: f(r).path)
        }
    }

    /// `true` iff `rel` was touched during the run (mtime is recent, not the
    /// stale 2001 marker). Tolerant of fs timestamp granularity.
    private func wasTouched(_ rel: String) throws -> Bool {
        let m = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: f(rel).path)[.modificationDate] as? Date)
        return m.timeIntervalSinceNow > -3600   // within the last hour ⇒ touched this run
    }

    @discardableResult
    private func runRestage(new: String, staged: String, staticlibChanged: Int = 1) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c",
            "source '\(Self.lib.path)'; restage_core_header '\(f(new).path)' '\(f(staged).path)' '\(root.path)' \(staticlibChanged)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, "restage_core_header exited non-zero:\n\(out)")
        return out
    }

    func test_headerChanged_touchesTestTargetsAndReferents() throws {
        try "v1\n".write(to: f("staged.h"), atomically: true, encoding: .utf8)
        try "v2-changed\n".write(to: f("new.h"), atomically: true, encoding: .utf8)
        try markStale(["Sources/RustCore/Bridge.swift",
                       "Tests/RustCoreTests/BridgeTests.swift",
                       "Tests/RustCoreTests/Helper.swift",
                       "Sources/Other/Referent.swift"])

        let out = try runRestage(new: "new.h", staged: "staged.h")

        XCTAssertTrue(out.contains("header CHANGED"), "must announce the change:\n\(out)")
        XCTAssertTrue(try wasTouched("Tests/RustCoreTests/BridgeTests.swift"),
                      "a header change MUST touch the test targets — the SIGSEGV-as-FFI-bug guard")
        XCTAssertTrue(try wasTouched("Tests/RustCoreTests/Helper.swift"),
                      "ALL test files must be touched, even ones not naming the header surface "
                      + "(the 2026-06-12 stale-test-object SIGSEGV case the grep alone would miss)")
        XCTAssertTrue(try wasTouched("Sources/Other/Referent.swift"),
                      "a header change MUST touch MDV_CAP_/MDV_WIRE_VERSION referents")
        XCTAssertTrue(try wasTouched("Sources/RustCore/Bridge.swift"),
                      "bridge sources always relink")
        XCTAssertEqual(try String(contentsOf: f("staged.h"), encoding: .utf8), "v2-changed\n",
                       "the new header must be staged")
    }

    func test_headerUnchanged_touchesOnlyBridgeSources() throws {
        try "identical\n".write(to: f("staged.h"), atomically: true, encoding: .utf8)
        try "identical\n".write(to: f("new.h"), atomically: true, encoding: .utf8)
        try markStale(["Sources/RustCore/Bridge.swift",
                       "Tests/RustCoreTests/BridgeTests.swift",
                       "Tests/RustCoreTests/Helper.swift",
                       "Sources/Other/Referent.swift"])

        let out = try runRestage(new: "new.h", staged: "staged.h")

        XCTAssertFalse(out.contains("header CHANGED"), "no change ⇒ no widened-touch announcement")
        XCTAssertFalse(try wasTouched("Tests/RustCoreTests/BridgeTests.swift"),
                       "an unchanged header must NOT touch test targets (keeps routine restages cheap)")
        XCTAssertFalse(try wasTouched("Tests/RustCoreTests/Helper.swift"),
                       "an unchanged header must NOT touch test targets")
        XCTAssertFalse(try wasTouched("Sources/Other/Referent.swift"),
                       "an unchanged header must NOT touch referents")
        XCTAssertTrue(try wasTouched("Sources/RustCore/Bridge.swift"),
                      "bridge sources relink because the .a changed (staticlibChanged defaults to 1 here)")
    }

    // TSK-848 — the bridge-source touch (which propagates an untracked-`.a`
    // change into the relink) is now gated on the `.a` actually changing, so a
    // no-Rust-change gate run no longer relinks RustCore + all downstream (~63s).

    func test_headerUnchanged_staticlibUnchanged_skipsBridgeTouch() throws {
        // The no-op build: nothing changed (no header, no .a) ⇒ NOTHING is
        // touched. This is the saved ~63s — without it every gate run that ran
        // build-rust-core.sh relinked the world.
        try "identical\n".write(to: f("staged.h"), atomically: true, encoding: .utf8)
        try "identical\n".write(to: f("new.h"), atomically: true, encoding: .utf8)
        try markStale(["Sources/RustCore/Bridge.swift",
                       "Tests/RustCoreTests/BridgeTests.swift"])

        let out = try runRestage(new: "new.h", staged: "staged.h", staticlibChanged: 0)

        XCTAssertFalse(out.contains("header CHANGED"))
        XCTAssertFalse(try wasTouched("Sources/RustCore/Bridge.swift"),
                       "no .a change + no header change ⇒ bridge NOT touched (the no-op win)")
        XCTAssertFalse(try wasTouched("Tests/RustCoreTests/BridgeTests.swift"),
                       "still no widened touch")
    }

    func test_staticlibChanged_headerUnchanged_relinksBridge() throws {
        // The CORRECTNESS guard (the 2026-06-10 stale-link bug): an impl-only
        // Rust change rebuilds the .a but not the header, so the bridge MUST
        // still relink or SwiftPM links stale Rust against new Swift.
        try "identical\n".write(to: f("staged.h"), atomically: true, encoding: .utf8)
        try "identical\n".write(to: f("new.h"), atomically: true, encoding: .utf8)
        try markStale(["Sources/RustCore/Bridge.swift",
                       "Tests/RustCoreTests/BridgeTests.swift"])

        let out = try runRestage(new: "new.h", staged: "staged.h", staticlibChanged: 1)

        XCTAssertFalse(out.contains("header CHANGED"))
        XCTAssertTrue(try wasTouched("Sources/RustCore/Bridge.swift"),
                      "a .a change MUST relink the bridge even when the header is unchanged")
        XCTAssertFalse(try wasTouched("Tests/RustCoreTests/BridgeTests.swift"),
                       "an unchanged header still doesn't widen to the test targets")
    }
}
