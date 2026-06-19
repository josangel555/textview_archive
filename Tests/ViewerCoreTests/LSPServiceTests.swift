import XCTest
@testable import ViewerCore

/// Pure-logic tests for the `LSPService` facade (TSK-963 PART 2): the
/// centralized 1-based-editor → 0-based-LSP conversion, the round-trip
/// inverse, and the `registry.language(for:)` language gate. The wire path
/// (actually spawning a server + forwarding) is covered by the pool's own
/// smoke tests; here we pin the conversion math + the gate predicate that
/// every DocumentModel call site copy-pastes today.
final class LSPServiceTests: XCTestCase {

    // MARK: - 1-based editor → 0-based LSP conversion

    func test_lspPosition_subtractsOneFromLine_keepsCharacter() {
        let pos = LSPService.lspPosition(fromEditorLine: 10, character: 4)
        XCTAssertEqual(pos.line, 9, "editor line is 1-based; LSP is 0-based")
        XCTAssertEqual(pos.character, 4, "editor character is already 0-based")
    }

    func test_lspPosition_firstLine_mapsToZero() {
        let pos = LSPService.lspPosition(fromEditorLine: 1, character: 0)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 0)
    }

    func test_lspPosition_floorsMalformedZeroLineAtZero() {
        // A malformed editor line of 0 must NOT produce a negative LSP line.
        let pos = LSPService.lspPosition(fromEditorLine: 0, character: 3)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 3)
    }

    func test_lspPosition_floorsNegativeLineAndCharacterAtZero() {
        let pos = LSPService.lspPosition(fromEditorLine: -5, character: -2)
        XCTAssertEqual(pos.line, 0)
        XCTAssertEqual(pos.character, 0)
    }

    func test_editorLine_addsOne_inverseOfLspPosition() {
        // Round-trip: editor → LSP → editor must be the identity for any
        // valid (≥1) editor line.
        for editorLine in [1, 2, 42, 1000] {
            let lsp = LSPService.lspPosition(fromEditorLine: editorLine, character: 0)
            let back = LSPService.editorLine(fromLSPLine: lsp.line)
            XCTAssertEqual(back, editorLine,
                "editor→LSP→editor must round-trip for line \(editorLine)")
        }
    }

    // MARK: - Language gate

    /// A pool whose registry maps `.py` → a (binary-less) python entry. Lets
    /// us exercise the gate predicate without any server binary on disk —
    /// `serverLauncher` returning nil is irrelevant to `canServe`, which only
    /// consults the registry's extension map.
    private func makeService(extensions: Set<String>) -> LSPService {
        let entry = LSPLanguageEntry(
            language: .python,
            fileExtensions: extensions,
            rootFinder: { _ in URL(fileURLWithPath: "/tmp/root") },
            serverLauncher: { _ in nil }
        )
        let pool = LSPPool(registry: LSPLanguageRegistry(entries: [entry]))
        return LSPService(pool: pool)
    }

    func test_canServe_trueForRegisteredExtension() {
        let svc = makeService(extensions: ["py", "pyi"])
        XCTAssertTrue(svc.canServe(URL(fileURLWithPath: "/x/a.py")))
        XCTAssertTrue(svc.canServe(URL(fileURLWithPath: "/x/a.pyi")))
    }

    func test_canServe_falseForUnregisteredExtension() {
        let svc = makeService(extensions: ["py"])
        XCTAssertFalse(svc.canServe(URL(fileURLWithPath: "/x/a.swift")))
        XCTAssertFalse(svc.canServe(URL(fileURLWithPath: "/x/README.md")))
    }

    func test_canServe_falseForNoExtension() {
        let svc = makeService(extensions: ["py"])
        XCTAssertFalse(svc.canServe(URL(fileURLWithPath: "/x/Makefile")))
    }

    func test_canServe_caseInsensitive() {
        let svc = makeService(extensions: ["py"])
        XCTAssertTrue(svc.canServe(URL(fileURLWithPath: "/x/A.PY")))
    }

    // MARK: - Gate short-circuits the request (no spawn for non-LSP files)

    /// When the file has no LSP language, every request method must return
    /// the honest empty result WITHOUT touching the pool (no spawn attempt,
    /// no throw). This is the contract DocumentModel's call sites rely on.
    func test_requests_returnEmpty_forUnservedFile() async throws {
        let svc = makeService(extensions: ["py"])
        let url = URL(fileURLWithPath: "/x/a.swift")  // not registered

        let def = try await svc.definition(url: url, editorLine: 1, character: 0)
        XCTAssertTrue(def.isEmpty)
        let decl = try await svc.declaration(url: url, editorLine: 1, character: 0)
        XCTAssertTrue(decl.isEmpty)
        let typ = try await svc.typeDefinition(url: url, editorLine: 1, character: 0)
        XCTAssertTrue(typ.isEmpty)
        let impl = try await svc.implementation(url: url, editorLine: 1, character: 0)
        XCTAssertTrue(impl.isEmpty)
        let refs = try await svc.references(url: url, editorLine: 1, character: 0)
        XCTAssertTrue(refs.isEmpty)
        let hov = try await svc.hover(url: url, editorLine: 1, character: 0)
        XCTAssertNil(hov)
        let fmt = try await svc.format(url: url)
        XCTAssertTrue(fmt.isEmpty)
        let ren = try await svc.rename(url: url, editorLine: 1, character: 0, newName: "x")
        XCTAssertTrue(ren.isEmpty)
    }
}
