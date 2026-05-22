import XCTest
import Foundation

/// One named scenario that the multi-scenario harness can execute.
///
/// A scenario is a self-contained slice of a test method: it owns its
/// `--script` body, knows which file to pass as argv, and knows how to
/// assert on the resulting per-step JSON dumps. Bundling these together
/// lets a single `XCTestCase` method run N scenarios sequentially while
/// reporting failures by scenario `name` instead of by line offset.
///
/// The scenario does NOT launch the app itself; the harness does. This
/// keeps the harness in charge of timeouts, fixture lifetime, and the
/// pre-flight skip check.
struct Scenario {
    /// Human-readable name surfaced in `XCTContext.runActivity` and in
    /// failure prefixes (`[scenario: <name>] ...`).
    let name: String

    /// Optional override for the per-script timeout. Defaults to the
    /// harness's own `defaultTimeout` when nil.
    let timeout: TimeInterval?

    /// File passed as argv to the .app (the "open this file on launch"
    /// path). Most tests reuse one fixture across scenarios.
    let argFile: URL

    /// The `--script` body. Each non-blank, non-comment line is one
    /// step; see `AppLauncher` for the supported step commands.
    let script: String

    /// Assertion closure invoked with the array of per-step JSON dumps.
    /// `file`/`line` come from where the scenario was constructed so
    /// XCTest reports the call site.
    let assert: ([[String: Any]], _ file: StaticString, _ line: UInt) -> Void

    init(
        name: String,
        timeout: TimeInterval? = nil,
        argFile: URL,
        script: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        assert: @escaping ([[String: Any]], StaticString, UInt) -> Void
    ) {
        self.name = name
        self.timeout = timeout
        self.argFile = argFile
        self.script = script
        // Bind the construction-site file/line into the closure so the
        // caller doesn't have to thread them through every assertion.
        self.assert = { dumps, _, _ in
            assert(dumps, file, line)
        }
    }
}
