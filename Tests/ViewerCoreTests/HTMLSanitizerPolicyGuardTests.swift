import XCTest
@testable import ViewerCore

/// TSK-1507 s4 — the HTML-sanitizer security policy is single-sourced in
/// `HTMLSanitizerPolicy` and mirrored to `schemas/html-sanitizer-policy.json`
/// (the contract the rust WebUI sanitizer single-sources). These pins make a
/// divergence RED: (1) the Swift policy must equal the JSON contract byte-for-
/// byte; (2) the live `HTMLSanitizer` must actually consume the policy (a
/// behavioral spot-check so the refactor didn't silently drop a rule).
final class HTMLSanitizerPolicyGuardTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func loadContract() throws -> [String: [String]] {
        let url = repoRoot().appendingPathComponent("schemas/html-sanitizer-policy.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var out: [String: [String]] = [:]
        for key in ["droppedElements", "trustedKeepsElements",
                    "urlBearingAttributes", "dangerousSchemes"] {
            out[key] = (obj?[key] as? [String]) ?? []
        }
        return out
    }

    func test_swiftPolicy_equalsTheWireContract() throws {
        let contract = try loadContract()
        let policy = HTMLSanitizerPolicy.contract()
        XCTAssertEqual(policy, contract,
            "HTMLSanitizerPolicy diverged from schemas/html-sanitizer-policy.json — "
            + "update BOTH the Swift policy AND the contract (the rust WebUI sanitizer reads it)")
    }

    func test_trustedDropSet_isDerived_notIndependentlyDrifting() {
        // The derived set must exactly be dropped − keeps (no separate list to drift).
        XCTAssertEqual(
            HTMLSanitizerPolicy.trustedDroppedElements,
            HTMLSanitizerPolicy.droppedElements
                .subtracting(HTMLSanitizerPolicy.trustedKeepsElements))
        // And it must still drop the dangerous non-script/style tags.
        for tag in ["iframe", "object", "embed", "form", "base", "meta"] {
            XCTAssertTrue(HTMLSanitizerPolicy.trustedDroppedElements.contains(tag),
                          "trusted mode must STILL drop \(tag)")
        }
    }

    func test_liveSanitizer_consumesThePolicy() {
        // Every dropped element is actually stripped; a policy-driven behavior
        // spot-check so the single-sourcing refactor is load-bearing.
        for tag in HTMLSanitizerPolicy.droppedElements {
            let html = "<p>keep</p><\(tag)>evil</\(tag)>"
            let clean = HTMLSanitizer.sanitize(html)
            XCTAssertFalse(clean.lowercased().contains("<\(tag)"),
                           "<\(tag)> must be dropped by the sanitizer")
            XCTAssertTrue(clean.contains("keep"), "non-dropped content survives")
        }
        // A dangerous scheme in a url-bearing attr is neutralized.
        let js = HTMLSanitizer.sanitize(#"<a href="javascript:alert(1)">x</a>"#)
        XCTAssertFalse(js.lowercased().contains("javascript:"), "javascript: neutralized")
        // Trusted mode keeps <script> but still drops <iframe>.
        let trusted = HTMLSanitizer.sanitize("<script>1</script><iframe></iframe>", trusted: true)
        XCTAssertTrue(trusted.contains("<script"), "trusted keeps its own script")
        XCTAssertFalse(trusted.lowercased().contains("<iframe"), "trusted still drops iframe")
    }
}
