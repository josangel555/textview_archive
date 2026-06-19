import XCTest
@testable import ViewerCore

/// Coverage for the package-manifest model core (TSK-319; pairs with the
/// shipped module/import graph `DotGraph`). Exercises the normalized
/// `DependencyPackage` model, dependency kinds, the root→dependency edge set,
/// version-pin capture, and graceful degradation on malformed input. The
/// explorer VIEW is a separate VM-validated phase, so these pin only the model.
final class PackageManifestTests: XCTestCase {

    // MARK: - package.json (npm)

    func test_packageJSON_rootNameVersion_andDirectDeps() {
        let m = PackageManifestParser.parsePackageJSON("""
        {
          "name": "my-app",
          "version": "1.2.3",
          "dependencies": {
            "react": "^18.2.0",
            "lodash": "4.17.21"
          }
        }
        """)
        XCTAssertEqual(m.rootName, "my-app")
        XCTAssertEqual(m.rootVersion, "1.2.3")
        XCTAssertEqual(m.source, .npm)
        // Deterministic (name-sorted) order.
        XCTAssertEqual(m.packages, [
            DependencyPackage(name: "lodash", version: "4.17.21", kind: .direct, source: .npm),
            DependencyPackage(name: "react", version: "^18.2.0", kind: .direct, source: .npm),
        ])
    }

    func test_packageJSON_devAndPeer_mapToDevKind() {
        let m = PackageManifestParser.parsePackageJSON("""
        {
          "name": "p",
          "dependencies": { "a": "1.0.0" },
          "devDependencies": { "jest": "^29.0.0" },
          "peerDependencies": { "react": ">=17" },
          "optionalDependencies": { "fsevents": "~2.3.0" }
        }
        """)
        XCTAssertEqual(m.packages.first(where: { $0.name == "a" })?.kind, .direct)
        XCTAssertEqual(m.packages.first(where: { $0.name == "jest" })?.kind, .dev)
        XCTAssertEqual(m.packages.first(where: { $0.name == "react" })?.kind, .dev)
        XCTAssertEqual(m.packages.first(where: { $0.name == "fsevents" })?.kind, .dev)
        // peer/optional version pins are still captured.
        XCTAssertEqual(m.packages.first(where: { $0.name == "react" })?.version, ">=17")
        XCTAssertEqual(m.packages.first(where: { $0.name == "fsevents" })?.version, "~2.3.0")
    }

    func test_packageJSON_edges_rootToEachDependency() {
        let m = PackageManifestParser.parsePackageJSON("""
        { "name": "root", "dependencies": { "x": "1", "y": "2" } }
        """)
        XCTAssertEqual(Set(m.edges), Set([
            DependencyEdge(from: "root", to: "x"),
            DependencyEdge(from: "root", to: "y"),
        ]))
        // Edge order mirrors package order.
        XCTAssertEqual(m.edges.map(\.from), ["root", "root"])
    }

    func test_packageJSON_noName_noEdges_butPackagesStillParsed() {
        let m = PackageManifestParser.parsePackageJSON("""
        { "dependencies": { "x": "1.0.0" } }
        """)
        XCTAssertNil(m.rootName)
        XCTAssertEqual(m.packages.map(\.name), ["x"])
        XCTAssertTrue(m.edges.isEmpty, "no root node ⇒ no anchored edges")
    }

    func test_packageJSON_nonStringVersion_toleratedAsNoPin() {
        // A version value that's an object (workspace protocol, etc.) shouldn't
        // throw or drop the package — it records no pin.
        let m = PackageManifestParser.parsePackageJSON("""
        { "name": "p", "dependencies": { "weird": { "git": "..." }, "ok": "1.0.0" } }
        """)
        XCTAssertEqual(m.packages.first(where: { $0.name == "weird" })?.version, nil)
        XCTAssertEqual(m.packages.first(where: { $0.name == "ok" })?.version, "1.0.0")
    }

    // MARK: - package.json graceful degradation

    func test_packageJSON_malformed_doesNotThrow_returnsEmpty() {
        // Truncated / invalid JSON degrades to an empty manifest.
        let m = PackageManifestParser.parsePackageJSON("{ \"name\": \"x\", \"dependencies\": {")
        XCTAssertNil(m.rootName)
        XCTAssertTrue(m.packages.isEmpty)
        XCTAssertTrue(m.edges.isEmpty)
        XCTAssertEqual(m.source, .npm)
    }

    func test_packageJSON_rootArray_notObject_degradesEmpty() {
        let m = PackageManifestParser.parsePackageJSON("[1, 2, 3]")
        XCTAssertTrue(m.packages.isEmpty)
    }

    func test_packageJSON_empty_degradesEmpty() {
        let m = PackageManifestParser.parsePackageJSON("")
        XCTAssertNil(m.rootName)
        XCTAssertTrue(m.packages.isEmpty)
    }

    func test_packageJSON_dependenciesNotObject_skipped() {
        // `dependencies` as an array is malformed — skip it, keep the rest.
        let m = PackageManifestParser.parsePackageJSON("""
        { "name": "p", "version": "1", "dependencies": ["a", "b"] }
        """)
        XCTAssertEqual(m.rootName, "p")
        XCTAssertTrue(m.packages.isEmpty)
    }

    // MARK: - Cargo.toml (Cargo)

    func test_cargo_packageAndDirectDeps_shortAndInlineForm() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "my-crate"
        version = "0.3.1"
        edition = "2021"

        [dependencies]
        serde = "1.0"
        tokio = { version = "1.35", features = ["full"] }
        """)
        XCTAssertEqual(m.rootName, "my-crate")
        XCTAssertEqual(m.rootVersion, "0.3.1")
        XCTAssertEqual(m.source, .cargo)
        XCTAssertEqual(m.packages, [
            DependencyPackage(name: "serde", version: "1.0", kind: .direct, source: .cargo),
            DependencyPackage(name: "tokio", version: "1.35", kind: .direct, source: .cargo),
        ])
    }

    func test_cargo_devAndBuildDeps_mapToDevKind() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies]
        anyhow = "1"

        [dev-dependencies]
        criterion = "0.5"

        [build-dependencies]
        cc = "1.0"
        """)
        XCTAssertEqual(m.packages.first(where: { $0.name == "anyhow" })?.kind, .direct)
        XCTAssertEqual(m.packages.first(where: { $0.name == "criterion" })?.kind, .dev)
        XCTAssertEqual(m.packages.first(where: { $0.name == "cc" })?.kind, .dev)
    }

    func test_cargo_pathOnlyDep_recordsNilVersion() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies]
        local = { path = "../local" }
        pinned = { version = "2.0", path = "../pinned" }
        """)
        XCTAssertEqual(m.packages.first(where: { $0.name == "local" })?.version, nil)
        XCTAssertEqual(m.packages.first(where: { $0.name == "pinned" })?.version, "2.0")
    }

    func test_cargo_subTableDependency_versionAttached() {
        // `[dependencies.foo]` followed by a `version = …` line.
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies.image]
        version = "0.24"
        default-features = false

        [dev-dependencies.proptest]
        version = "1.4"
        """)
        XCTAssertEqual(m.packages.first(where: { $0.name == "image" })?.version, "0.24")
        XCTAssertEqual(m.packages.first(where: { $0.name == "image" })?.kind, .direct)
        XCTAssertEqual(m.packages.first(where: { $0.name == "proptest" })?.version, "1.4")
        XCTAssertEqual(m.packages.first(where: { $0.name == "proptest" })?.kind, .dev)
    }

    func test_cargo_edges_rootToEachDependency() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "root-crate"

        [dependencies]
        a = "1"
        b = "2"
        """)
        XCTAssertEqual(m.edges, [
            DependencyEdge(from: "root-crate", to: "a"),
            DependencyEdge(from: "root-crate", to: "b"),
        ])
    }

    func test_cargo_comments_andQuotedKeys() {
        let m = PackageManifestParser.parseCargoTOML("""
        # top comment
        [package]
        name = "c"  # trailing comment after value

        [dependencies]
        serde = "1.0"  # keep this
        "weird-name" = "2.0"
        """)
        XCTAssertEqual(m.rootName, "c")
        XCTAssertEqual(m.packages.first(where: { $0.name == "serde" })?.version, "1.0")
        XCTAssertEqual(m.packages.first(where: { $0.name == "weird-name" })?.version, "2.0")
    }

    func test_cargo_hashInsideQuotedValue_notTreatedAsComment() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [dependencies]
        gitdep = { git = "https://example.com/repo#frag", version = "1.0" }
        """)
        // The `#frag` inside quotes must not truncate the line; version survives.
        XCTAssertEqual(m.packages.first(where: { $0.name == "gitdep" })?.version, "1.0")
    }

    // MARK: - Cargo graceful degradation

    func test_cargo_empty_degradesEmpty() {
        let m = PackageManifestParser.parseCargoTOML("")
        XCTAssertNil(m.rootName)
        XCTAssertTrue(m.packages.isEmpty)
        XCTAssertTrue(m.edges.isEmpty)
        XCTAssertEqual(m.source, .cargo)
    }

    func test_cargo_garbage_doesNotThrow_skipsJunk() {
        let m = PackageManifestParser.parseCargoTOML("""
        this is not toml at all
        }}}}}}
        [dependencies
        broken line without bracket close
        = no key
        """)
        // No crash, no throw; nothing usable parsed.
        XCTAssertTrue(m.packages.isEmpty)
    }

    func test_cargo_unrelatedTables_ignored() {
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"

        [features]
        default = ["std"]

        [profile.release]
        opt-level = 3

        [dependencies]
        real = "1.0"
        """)
        // Only the real dependency table contributes packages.
        XCTAssertEqual(m.packages.map(\.name), ["real"])
    }

    func test_cargo_partialResult_keepsWhatItCanBeforeBreakage() {
        // A valid package + deps, then trailing junk — the good parts survive.
        let m = PackageManifestParser.parseCargoTOML("""
        [package]
        name = "c"
        version = "1.0"

        [dependencies]
        good = "1.0"
        \u{0}\u{0}garbage\u{0}
        """)
        XCTAssertEqual(m.rootName, "c")
        XCTAssertEqual(m.packages.first?.name, "good")
    }
}
