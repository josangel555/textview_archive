import XCTest
@testable import ViewerCore

/// TSK-1413 — command ↔ script-verb cohesion. Two guards:
///  1. The hosted-view tools (HTTP client, feed reader, folder treemap,
///     dependency graph, walkthroughs) are ⌘K-palette-discoverable — they used
///     to be reachable ONLY via the File/View menus (a discoverability gap).
///  2. REGRESSION GUARD for the whole class: every built-in command that
///     carries a `scriptVerb` must reference a REAL catalog verb — else the
///     palette advertises a command that silently no-ops (the same failure mode
///     as the orphaned FeedReader, one layer up).
final class CommandVerbCohesionTests: XCTestCase {

    func test_hostedViewTools_arePaletteDiscoverable() {
        let reg = CommandRegistry.builtIn
        let expected: [(id: String, verb: String)] = [
            ("file.newHTTPRequest", "show-http-client"),
            ("file.feedReader", "show-feed-reader"),
            ("view.folderTreemap", "show-folder-treemap"),
            ("view.dependencyGraph", "show-dependency-graph"),
            ("view.walkthroughs", "show-walkthroughs"),
        ]
        for e in expected {
            guard let cmd = reg.command(id: e.id) else {
                XCTFail("missing palette command \(e.id) — hosted-view tool not discoverable via ⌘K")
                continue
            }
            XCTAssertEqual(cmd.scriptVerb, e.verb, "\(e.id) maps to the wrong verb")
            XCTAssertTrue(cmd.isPaletteInvokable, "\(e.id) is not palette-invokable")
            XCTAssertTrue(ScriptVerbCatalog.tokens.contains(e.verb),
                          "\(e.id)'s verb \(e.verb) is not a real catalog verb")
        }
    }

    /// Every command with a verb resolves to a real catalog token (first token,
    /// since a few embed a structured arg like `convert-encoding utf-8`). This is
    /// the cohesion regression guard: a command pointing at a non-existent verb
    /// would advertise in the palette and silently do nothing.
    func test_everyCommandVerb_resolvesToACatalogToken() {
        let tokens = ScriptVerbCatalog.tokens
        for cmd in CommandRegistry.builtIn.commands {
            guard let verb = cmd.scriptVerb else { continue }
            let base = verb.split(separator: " ").first.map(String.init) ?? verb
            XCTAssertTrue(tokens.contains(base),
                          "command \(cmd.id) references verb '\(base)' absent from ScriptVerbCatalog")
        }
    }
}
