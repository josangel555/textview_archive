import XCTest
@testable import ViewerCore

/// Pins that the `initialize` capability advert offers
/// `textDocument/completion` (TSK-463). Many servers (sourcekit-lsp,
/// pyright, gopls) gate completion responses on the client advertising the
/// capability — drop the advert and they reply empty, so this is a real
/// regression guard, not a cosmetic check. Pure: no server is spawned.
final class LSPCompletionCapabilityTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/ws-fixture")

    private func textDocumentCaps() throws -> [String: Any] {
        let p = LSPClient.makeInitializeParams(
            workspaceRoot: root, processId: 1, initializationOptions: nil)
        let caps = try XCTUnwrap(p["capabilities"] as? [String: Any])
        return try XCTUnwrap(caps["textDocument"] as? [String: Any])
    }

    func test_completionCapability_isAdvertised() throws {
        let td = try textDocumentCaps()
        let completion = try XCTUnwrap(
            td["completion"] as? [String: Any],
            "completion capability must be advertised or servers reply empty")
        XCTAssertEqual(completion["dynamicRegistration"] as? Bool, false)
    }

    func test_completionItem_doesNotClaimSnippetSupport() throws {
        // We surface `isSnippet` per-item but don't expand placeholders, so
        // we must NOT advertise snippetSupport (else servers send snippets
        // we'd commit as literal `${1:…}` text).
        let td = try textDocumentCaps()
        let completion = try XCTUnwrap(td["completion"] as? [String: Any])
        let item = try XCTUnwrap(completion["completionItem"] as? [String: Any])
        XCTAssertEqual(item["snippetSupport"] as? Bool, false)
    }

    func test_existingCapabilities_stillPresent() throws {
        // Guard against the advert edit accidentally dropping a sibling.
        let td = try textDocumentCaps()
        XCTAssertNotNil(td["hover"])
        XCTAssertNotNil(td["definition"])
        XCTAssertNotNil(td["synchronization"])
    }
}
