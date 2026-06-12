import XCTest
@testable import ViewerUI

/// TSK-650 — the guard the vendor tests structurally COULDN'T provide:
/// they check the SOURCE TREE files (by design, no Bundle.module), so a
/// broken `forResource:` lookup returned "" for the runtime FOREVER while
/// every vendor check stayed green and every mermaid host degraded to raw
/// source text. This pins resolution through the BUILT bundle. Headless,
/// in the merge gate.
final class MermaidBundleLoadTests: XCTestCase {

    func test_runtime_resolvesNonEmpty_fromTheBuiltBundle() {
        XCTAssertGreaterThan(
            MermaidBundle.runtime.utf8.count, 1_000_000,
            "the ~2.5 MB mermaid runtime must resolve from Bundle.module — "
            + "empty means the forResource name drifted from the shipped "
            + "file name (the TSK-650 class)")
    }

    func test_shimResources_resolveNonEmpty() {
        XCTAssertFalse(MermaidBundle.shimJS.isEmpty, "mermaid-shim.js must resolve")
        XCTAssertFalse(MermaidBundle.shimCSS.isEmpty, "mermaid-shim.css must resolve")
    }
}
