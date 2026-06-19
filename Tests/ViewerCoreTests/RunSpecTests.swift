import XCTest
@testable import ViewerCore

/// Teeth for the run-spec builder (TSK-722): a `RunnableTask` → exact argv,
/// shell-safe command line, cwd, env. Quoting edge cases are the load-bearing
/// part (a mis-quoted token would mis-spawn or shell-inject).
final class RunSpecTests: XCTestCase {

    private func task(
        command: String,
        args: [String],
        cwd: String = "/tmp/proj",
        source: RunnableTask.Source = .packageJson
    ) -> RunnableTask {
        RunnableTask(
            name: "t",
            command: command,
            arguments: args,
            workingDirectory: URL(fileURLWithPath: cwd),
            source: source
        )
    }

    func test_build_simpleArgvAndCommandLine() {
        let spec = RunSpec.build(for: task(command: "npm", args: ["run", "test"]))
        XCTAssertEqual(spec.argv, ["npm", "run", "test"])
        XCTAssertEqual(spec.shellCommandLine, "'npm' 'run' 'test'")
        XCTAssertEqual(spec.workingDirectory, URL(fileURLWithPath: "/tmp/proj"))
        XCTAssertTrue(spec.environment.isEmpty)
    }

    func test_build_quotesSpacesAndMetacharacters() {
        let spec = RunSpec.build(for: task(command: "make", args: ["build with space", "a&b;c|d"]))
        // Each token single-quoted → spaces & metacharacters are inert to /bin/sh.
        XCTAssertEqual(spec.shellCommandLine, "'make' 'build with space' 'a&b;c|d'")
    }

    func test_build_escapesEmbeddedApostrophe() {
        // The classic `'\''` splice — a token with a literal single quote.
        let spec = RunSpec.build(for: task(command: "echo", args: ["it's fine"]))
        XCTAssertEqual(spec.shellCommandLine, "'echo' 'it'\\''s fine'")
    }

    func test_build_appendsExtraArguments() {
        let spec = RunSpec.build(
            for: task(command: "npm", args: ["run", "test"]),
            extraArguments: ["--", "--watch"]
        )
        XCTAssertEqual(spec.argv, ["npm", "run", "test", "--", "--watch"])
        XCTAssertEqual(spec.shellCommandLine, "'npm' 'run' 'test' '--' '--watch'")
    }

    func test_build_carriesEnvironmentOverrides() {
        let spec = RunSpec.build(
            for: task(command: "cargo", args: ["test"]),
            extraEnvironment: ["CARGO_TERM_COLOR": "always"]
        )
        XCTAssertEqual(spec.environment, ["CARGO_TERM_COLOR": "always"])
    }

    func test_build_preservesWorkingDirectoryFromTask() {
        let spec = RunSpec.build(for: task(command: "go", args: ["test"], cwd: "/Users/x/My Proj"))
        XCTAssertEqual(spec.workingDirectory.path, "/Users/x/My Proj")
    }

    func test_build_emptyArgumentToken_isQuotedNotDropped() {
        let spec = RunSpec.build(for: task(command: "tool", args: ["", "x"]))
        XCTAssertEqual(spec.shellCommandLine, "'tool' '' 'x'", "empty token preserved as ''")
        XCTAssertEqual(spec.argv, ["tool", "", "x"])
    }
}
