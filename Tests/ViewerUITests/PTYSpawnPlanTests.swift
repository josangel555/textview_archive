import XCTest
@testable import ViewerUI

/// TSK-979 (M4): the child branch between `forkpty()` and `execve()` used to do
/// NON-async-signal-safe work — `ProcessInfo…environment`, `Dictionary.map`,
/// `strdup`→`malloc`, `String.withCString` bridging — in a heavily
/// multi-threaded process, risking the classic malloc-lock-held-at-fork
/// deadlock. The fix PRECOMPUTES everything in the parent: `resolveShell`
/// (pure Swift-String/Dictionary work) and `CStringArray.make` (the only
/// `strdup`/`malloc`) now run BEFORE the fork; the child does only `chdir` +
/// `execve`.
///
/// The signal-safety property itself isn't directly unit-assertable, so these
/// tests guard the refactor's CORRECTNESS — the env/argv/path the parent now
/// builds must be byte-for-byte what the old child built — which is the
/// regression risk of moving the construction across the fork.
final class PTYSpawnPlanTests: XCTestCase {

    // MARK: - CStringArray (the strdup'd char** built in the parent)

    func test_cStringArray_roundTripsThroughCArray() {
        let input = ["FOO=bar", "BAZ=qux", "PATH=/usr/bin:/bin"]
        let arr = PTYProcess.CStringArray.make(input)
        XCTAssertEqual(arr.toStringArray(), input,
            "char** must round-trip back to the exact input strings, in order")
    }

    func test_cStringArray_isNullTerminated() {
        let input = ["a", "b"]
        let arr = PTYProcess.CStringArray.make(input)
        // index [count] must be the NULL terminator execve relies on.
        XCTAssertNil(arr.pointer[input.count],
            "the entry past the last member must be NULL (execve terminator)")
        XCTAssertNotNil(arr.pointer[0])
        XCTAssertNotNil(arr.pointer[input.count - 1])
    }

    func test_cStringArray_empty_isJustNullTerminator() {
        let arr = PTYProcess.CStringArray.make([])
        XCTAssertEqual(arr.toStringArray(), [])
        XCTAssertNil(arr.pointer[0], "an empty argv/envp is a bare NULL terminator")
    }

    func test_cStringArray_preservesEmbeddedEqualsAndSpaces() {
        // Env values legitimately contain '=' and spaces; the C bridge must
        // not mangle them.
        let input = ["KEY=a=b c=d", "MSG=hello world", "EMPTY="]
        let arr = PTYProcess.CStringArray.make(input)
        XCTAssertEqual(arr.toStringArray(), input)
    }

    func test_cStringArray_deepCopies_independentOfSourceArray() {
        // strdup must deep-copy: mutating/dropping the source [String] after
        // make() must not corrupt the C array (the child reads it post-fork,
        // long after the Swift array is gone).
        var src = ["ONE=1", "TWO=2"]
        let arr = PTYProcess.CStringArray.make(src)
        src.removeAll()
        src = ["clobber"]
        _ = src
        XCTAssertEqual(arr.toStringArray(), ["ONE=1", "TWO=2"],
            "the C array is a deep copy — independent of the source array")
    }

    // MARK: - resolveShell (the pure precompute moved to the parent)

    func test_resolveShell_argvIsLoginMarkerOfResolvedShell() {
        // Shell PATH resolution reads the REAL parent process env's SHELL
        // (ProcessInfo.processInfo.environment["SHELL"]) — NOT the passed-in
        // `environment` dict — falling back to /bin/zsh. This faithfully
        // mirrors the pre-refactor child behaviour (the passed env only feeds
        // the env array, never shell resolution). Whatever shell resolves,
        // argv[0] is its '-<name>' login-shell marker (not the full path).
        let r = PTYProcess.resolveShell(environment: ["HOME": "/Users/x"])
        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        XCTAssertEqual(r.shellPath, expectedShell)
        let expectedName = (expectedShell as NSString).lastPathComponent
        XCTAssertEqual(r.argv, ["-" + expectedName],
            "argv[0] is the '-<name>' login-shell marker, not the full path")
    }

    func test_resolveShell_ignoresPassedSHELL_usesProcessEnv() {
        // A SHELL key in the passed `environment` does NOT change shell
        // resolution — it only lands in the env array. This pins the exact
        // (intentional) pre-refactor contract.
        let r = PTYProcess.resolveShell(environment: ["SHELL": "/nonexistent/sh"])
        let expectedShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        XCTAssertEqual(r.shellPath, expectedShell,
            "resolution reads the parent process env, not the passed dict")
        // But the passed SHELL DOES appear in the env array handed to the child.
        XCTAssertTrue(r.envStrings.contains("SHELL=/nonexistent/sh"))
    }

    func test_resolveShell_forcesTERM_xterm256color() {
        let r = PTYProcess.resolveShell(environment: ["SHELL": "/bin/zsh"])
        XCTAssertTrue(r.envStrings.contains("TERM=xterm-256color"),
            "TERM must be forced to the capability set we model")
    }

    func test_resolveShell_overridesCallerSuppliedTERM() {
        // Even if the caller passes a TERM, we force ours.
        let r = PTYProcess.resolveShell(environment: ["SHELL": "/bin/zsh", "TERM": "dumb"])
        XCTAssertTrue(r.envStrings.contains("TERM=xterm-256color"))
        XCTAssertFalse(r.envStrings.contains("TERM=dumb"),
            "the caller's TERM must be overridden, not appended")
        // Exactly one TERM entry.
        XCTAssertEqual(r.envStrings.filter { $0.hasPrefix("TERM=") }.count, 1)
    }

    func test_resolveShell_customEnvBecomesKeyValueStrings() {
        let env = ["SHELL": "/bin/zsh", "FOO": "bar", "EMPTY": ""]
        let r = PTYProcess.resolveShell(environment: env)
        XCTAssertTrue(r.envStrings.contains("FOO=bar"))
        XCTAssertTrue(r.envStrings.contains("EMPTY="),
            "an empty value still yields KEY= (no value)")
        XCTAssertTrue(r.envStrings.contains("SHELL=/bin/zsh"))
    }

    func test_resolveShell_envStrings_roundTripBackToDict() {
        // The KEY=VALUE encoding must be a faithful, lossless view of the input
        // dict (split on the FIRST '=' so values with '=' survive).
        let env = ["SHELL": "/bin/zsh", "A": "1", "B": "x=y", "C": ""]
        let r = PTYProcess.resolveShell(environment: env)
        var decoded: [String: String] = [:]
        for s in r.envStrings {
            guard let eq = s.firstIndex(of: "=") else { continue }
            decoded[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        var expected = env
        expected["TERM"] = "xterm-256color"   // forced
        XCTAssertEqual(decoded, expected,
            "every KEY=VALUE must decode back to the (TERM-forced) source dict")
    }

    // MARK: - SpawnPlan wiring (the C arrays the child execve's)

    func test_spawnPlan_argvAndEnvpMatchResolveShell() {
        let env = ["SHELL": "/bin/bash", "FOO": "bar"]
        let resolved = PTYProcess.resolveShell(environment: env)
        let plan = PTYProcess.SpawnPlan(environment: env)

        // path C string must equal the resolved shell path.
        XCTAssertEqual(String(cString: plan.path), resolved.shellPath)

        // argv char** must round-trip to the resolved argv (+ NULL).
        var argv: [String] = []
        var i = 0
        while let s = plan.argv[i] { argv.append(String(cString: s)); i += 1 }
        XCTAssertEqual(argv, resolved.argv)
        XCTAssertNil(plan.argv[resolved.argv.count], "argv NULL-terminated")

        // envp char** must round-trip to the resolved env (order-insensitive).
        var envp: [String] = []
        var j = 0
        while let s = plan.envp[j] { envp.append(String(cString: s)); j += 1 }
        XCTAssertEqual(Set(envp), Set(resolved.envStrings))
        XCTAssertNil(plan.envp[resolved.envStrings.count], "envp NULL-terminated")
    }
}
