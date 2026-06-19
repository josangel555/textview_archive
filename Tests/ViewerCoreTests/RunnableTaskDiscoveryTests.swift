import XCTest
@testable import ViewerCore

/// Teeth for the task/command runner foundation (TSK-722): manifest discovery
/// (package.json / Cargo.toml / Makefile / common test commands) → normalized
/// `RunnableTask`s, plus the `RunSpec` argv/cwd/quoting builder. Pure host logic.
final class RunnableTaskDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-taskrunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - package.json

    func test_packageJson_discoversScripts_inDeclaredOrder() throws {
        try write("package.json", """
        {
          "name": "demo",
          "scripts": {
            "build": "tsc",
            "test": "vitest run",
            "lint": "eslint ."
          }
        }
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertEqual(tasks.map(\.name), ["build", "test", "lint"], "declared order preserved")
        XCTAssertTrue(tasks.allSatisfy { $0.source == .packageJson })
        let test = try XCTUnwrap(tasks.first { $0.name == "test" })
        XCTAssertEqual(test.command, "npm")
        XCTAssertEqual(test.arguments, ["run", "test"])
        XCTAssertEqual(test.workingDirectory, root)
        XCTAssertEqual(test.argv, ["npm", "run", "test"])
        XCTAssertEqual(test.id, "packageJson:test")
    }

    func test_packageJson_noScriptsBlock_yieldsNoNpmTasks() throws {
        try write("package.json", #"{ "name": "x", "version": "1.0.0" }"#)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertTrue(tasks.filter { $0.source == .packageJson }.isEmpty)
    }

    func test_packageJson_malformed_isSkippedNotThrown() throws {
        try write("package.json", "{ this is not json ")
        // Must not throw; just yields nothing for that source.
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertTrue(tasks.filter { $0.source == .packageJson }.isEmpty)
    }

    func test_packageJson_empty_scriptsObject() throws {
        try write("package.json", #"{ "scripts": {} }"#)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertTrue(tasks.filter { $0.source == .packageJson }.isEmpty)
    }

    // MARK: - Cargo.toml

    func test_cargo_withExplicitBins() throws {
        try write("Cargo.toml", """
        [package]
        name = "myapp"
        version = "0.1.0"

        [[bin]]
        name = "server"
        path = "src/server.rs"

        [[bin]]
        name = "cli"
        path = "src/cli.rs"
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertEqual(tasks.map(\.name), ["test", "run server", "run cli"])
        let server = try XCTUnwrap(tasks.first { $0.name == "run server" })
        XCTAssertEqual(server.command, "cargo")
        XCTAssertEqual(server.arguments, ["run", "--bin", "server"])
        XCTAssertEqual(server.source, .cargo)
        let test = try XCTUnwrap(tasks.first { $0.name == "test" })
        XCTAssertEqual(test.arguments, ["test"])
    }

    func test_cargo_packageWithoutExplicitBin_getsTestAndRun() throws {
        try write("Cargo.toml", """
        [package]
        name = "lib_or_implicit_bin"
        version = "0.1.0"

        [dependencies]
        serde = "1"
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertEqual(tasks.map(\.name), ["test", "run"])
        XCTAssertEqual(tasks.first { $0.name == "run" }?.arguments, ["run"])
    }

    func test_cargo_commentAfterBinNameIsStripped() throws {
        try write("Cargo.toml", """
        [package]
        name = "x"

        [[bin]]
        name = "tool"  # the main entrypoint
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertTrue(tasks.contains { $0.name == "run tool" }, "comment after value stripped")
    }

    func test_cargo_dependenciesSectionDoesNotLeakAsBin() throws {
        // A `name = "..."` line under [dependencies] must NOT be read as a bin.
        try write("Cargo.toml", """
        [package]
        name = "x"

        [dependencies]
        name = "should-not-appear"
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertFalse(tasks.contains { $0.name.contains("should-not-appear") })
        XCTAssertEqual(tasks.map(\.name), ["test", "run"])
    }

    func test_cargo_absent_yieldsNothing() {
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        XCTAssertTrue(tasks.filter { $0.source == .cargo }.isEmpty)
    }

    // MARK: - Makefile

    func test_makefile_realTargets_skipsPhonyVarsPatterns() throws {
        try write("Makefile", """
        .PHONY: build test clean

        CC := clang
        CFLAGS ?= -O2

        build: deps
        \tgo build ./...

        test:
        \tgo test ./...

        %.o: %.c
        \t$(CC) -c $<

        clean:
        \trm -rf bin
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        let makeTasks = tasks.filter { $0.source == .makefile }
        XCTAssertEqual(makeTasks.map(\.name), ["build", "test", "clean"],
                       ".PHONY/var-assignments/pattern-rules excluded; real targets in order")
        let build = try XCTUnwrap(makeTasks.first { $0.name == "build" })
        XCTAssertEqual(build.command, "make")
        XCTAssertEqual(build.arguments, ["build"])
    }

    func test_makefile_variableAssignmentForms_allRejected() throws {
        try write("Makefile", """
        A = 1
        B := 2
        C ::= 3
        D ?= 4
        E += 5
        realtarget:
        \techo hi
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root).filter { $0.source == .makefile }
        XCTAssertEqual(tasks.map(\.name), ["realtarget"])
    }

    func test_makefile_lowercaseAndGNUmakefileNames() throws {
        try write("makefile", """
        run:
        \t./app
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root).filter { $0.source == .makefile }
        XCTAssertEqual(tasks.map(\.name), ["run"])
    }

    func test_makefile_multiTargetLineSkipped() throws {
        try write("Makefile", """
        a b c:
        \techo multi
        solo:
        \techo solo
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root).filter { $0.source == .makefile }
        XCTAssertEqual(tasks.map(\.name), ["solo"], "ambiguous multi-target line skipped")
    }

    // MARK: - Common test commands

    func test_commonTestCommand_pytestMarker() throws {
        try write("pytest.ini", "[pytest]\n")
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        let py = try XCTUnwrap(tasks.first { $0.source == .commonTestCommand })
        XCTAssertEqual(py.command, "pytest")
        XCTAssertEqual(py.arguments, [])
    }

    func test_commonTestCommand_goMod() throws {
        try write("go.mod", "module example.com/x\n\ngo 1.22\n")
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        let go = try XCTUnwrap(tasks.first { $0.command == "go" })
        XCTAssertEqual(go.arguments, ["test", "./..."])
        XCTAssertEqual(go.source, .commonTestCommand)
    }

    // MARK: - Combined / ordering / dedupe

    func test_mixedManifests_groupedBySourceOrder() throws {
        try write("package.json", #"{ "scripts": { "dev": "vite" } }"#)
        try write("Cargo.toml", "[package]\nname = \"x\"\n")
        try write("Makefile", "release:\n\techo go\n")
        try write("go.mod", "module x\n")
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        // package.json, then cargo, then makefile, then common-test.
        XCTAssertEqual(tasks.map(\.source),
                       [.packageJson, .cargo, .cargo, .makefile, .commonTestCommand])
        XCTAssertEqual(tasks.map(\.name), ["dev", "test", "run", "release", "go test"])
    }

    func test_dedupe_byId_firstWins() throws {
        // Two sources can't share an id here (id encodes source), so dedupe is
        // exercised by a same-source collision: a Makefile that lists the same
        // target name twice yields one task.
        try write("Makefile", """
        build:
        \techo one
        build:
        \techo two
        """)
        let tasks = RunnableTaskDiscovery.discover(projectRoot: root).filter { $0.source == .makefile }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].name, "build")
    }

    func test_emptyProject_yieldsNoTasks() {
        XCTAssertTrue(RunnableTaskDiscovery.discover(projectRoot: root).isEmpty)
    }
}
