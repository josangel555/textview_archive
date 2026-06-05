import XCTest
@testable import ViewerCore

/// Regression coverage for the S3 finding: the untrusted file-drop
/// boundary must validate step paths against a caller-injected
/// `trustedRoot`, NOT the script's self-declared `rootHint` (which is
/// attacker-controlled, travelling inside the same untrusted JSON).
///
/// Pins:
///   - A script declaring an over-broad `rootHint` ("/") cannot reach
///     paths outside the trusted root.
///   - A `rootHint` resolving outside the trusted root is rejected.
///   - A `rootHint` that narrows to a subdir of the trusted root is OK.
///   - The trusted fence still rejects `..` escapes regardless of what
///     `rootHint` claims.
///   - Legacy behaviour (no `trustedRoot`) is unchanged.
final class Audit_Sources_ViewerCore_Walkthrough_WalkthroughLoader_swift_TrustedRootTests: XCTestCase {

    private func script(rootHint: String?, openPath: String) -> Data {
        let hintLine = rootHint.map { "\"rootHint\": \"\($0)\"," } ?? ""
        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "t",
          "title": "T",
          \(hintLine)
          "steps": [
            { "id": "s1", "actions": [
                { "kind": "openFile", "path": "\(openPath)" }
            ]}
          ]
        }
        """
        return Data(json.utf8)
    }

    // MARK: - The core exploit the finding describes

    func test_attackerRootHintSlash_doesNotEscapeTrustedRoot() {
        // The classic exploit: script declares rootHint "/" so its own
        // fence accepts everything, then targets an absolute path far
        // outside the caller's trusted root.
        let data = script(rootHint: "/", openPath: "/etc/passwd")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        // The over-broad rootHint itself is the first thing rejected.
        guard case .failure(.rootHintOutsideTrustedRoot(let hint, let trusted)) = r else {
            return XCTFail("Expected rootHintOutsideTrustedRoot, got \(r)")
        }
        XCTAssertEqual(hint, "/")
        XCTAssertEqual(trusted, "/tmp/repo")
    }

    func test_rootHintOutsideTrustedRoot_rejected() {
        let data = script(rootHint: "/Users", openPath: "x.txt")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .failure(.rootHintOutsideTrustedRoot) = r else {
            return XCTFail("Expected rootHintOutsideTrustedRoot, got \(r)")
        }
    }

    // MARK: - Legitimate narrowing is allowed

    func test_rootHintNarrowsToSubdir_ofTrustedRoot_loads() {
        // A script may legitimately scope itself to a subdir of the
        // trusted root. Paths inside that subdir must load.
        let data = script(rootHint: "/tmp/repo/src", openPath: "A.swift")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .success = r else {
            return XCTFail("Expected success, got \(r)")
        }
    }

    func test_rootHintEqualsTrustedRoot_loads() {
        let data = script(rootHint: "/tmp/repo", openPath: "src/A.swift")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .success = r else {
            return XCTFail("Expected success, got \(r)")
        }
    }

    // MARK: - The trusted fence still catches `..` escapes

    func test_dotDotEscape_fromTrustedRoot_rejected_evenWithMatchingRootHint() {
        // rootHint matches the trusted root, but the step path climbs
        // out via `..`. The escape must be caught against the trusted
        // fence.
        let data = script(rootHint: "/tmp/repo", openPath: "../../etc/passwd")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .failure(.pathEscape(let stepID, _)) = r else {
            return XCTFail("Expected pathEscape, got \(r)")
        }
        XCTAssertEqual(stepID, "s1")
    }

    func test_absolutePathOutsideTrustedRoot_rejected_evenWithMatchingRootHint() {
        let data = script(rootHint: "/tmp/repo", openPath: "/etc/passwd")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .failure(.pathEscape) = r else {
            return XCTFail("Expected pathEscape, got \(r)")
        }
    }

    // MARK: - missingRootHint still fires before the trusted-root check

    func test_missingRootHint_stillRejected_atUntrustedBoundary() {
        let data = script(rootHint: nil, openPath: "src/A.swift")
        let r = WalkthroughLoader.load(
            data: data, requireRootHint: true, trustedRoot: "/tmp/repo"
        )
        guard case .failure(.missingRootHint) = r else {
            return XCTFail("Expected missingRootHint, got \(r)")
        }
    }

    // MARK: - Legacy callers (no trustedRoot) are unchanged

    func test_noTrustedRoot_validatesAgainstRootHint_asBefore() {
        // Internal/legacy callers that omit trustedRoot keep the old
        // behaviour: validate against the script's own rootHint.
        let inFence = script(rootHint: "/tmp/repo", openPath: "src/A.swift")
        guard case .success = WalkthroughLoader.load(data: inFence) else {
            return XCTFail("Expected success for in-fence legacy script")
        }

        let escaping = script(rootHint: "/tmp/repo", openPath: "../etc/x")
        guard case .failure(.pathEscape) = WalkthroughLoader.load(data: escaping) else {
            return XCTFail("Expected pathEscape for escaping legacy script")
        }
    }
}
