import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1189 slice 2b — teeth for the model trust WIRING that feeds the renderer's
/// relaxation. The render itself (does a trusted doc run its scripts on screen)
/// is render-path / review-ceiling; here we pin the host-testable decision:
/// a local .html is eligible but OFF by default, an explicit opt-in trusts it
/// (and revoke clears), and an unknown tab is fail-closed.
@MainActor
final class DocumentModelHTMLTrustTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLTrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeModel() -> DocumentModel {
        let m = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "HTMLTrustPrefs-\(UUID().uuidString)")!))
        // Throwaway suite so the opt-in doesn't touch .standard.
        m.htmlTrustStore = HTMLTrustStore(defaults: UserDefaults(
            suiteName: "HTMLTrustStore-\(UUID().uuidString)")!)
        return m
    }

    @discardableResult
    private func openHTML(_ model: DocumentModel, _ name: String = "app.html") -> UUID {
        let url = tmpDir.appendingPathComponent(name)
        try! "<script>render()</script><div id=app></div>".write(
            to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        return model.tabs.selected!.id
    }

    func test_localHTML_isEligible_butUntrustedByDefault() {
        let m = makeModel()
        let id = openHTML(m)
        XCTAssertTrue(m.htmlTrustEligible(forTabID: id),
                      "a local, non-quarantined .html is trust-eligible")
        XCTAssertFalse(m.htmlTrusted(forTabID: id), "trust default is OFF")
    }

    func test_optIn_makesTrusted_andRevokeClears() {
        let m = makeModel()
        let id = openHTML(m)
        m.setHTMLTrusted(true, forTabID: id)
        XCTAssertTrue(m.htmlTrusted(forTabID: id), "explicit opt-in trusts the doc")
        m.setHTMLTrusted(false, forTabID: id)
        XCTAssertFalse(m.htmlTrusted(forTabID: id), "revoke clears trust")
    }

    func test_unknownTab_failsClosed() {
        let m = makeModel()
        XCTAssertFalse(m.htmlTrusted(forTabID: UUID()))
        XCTAssertFalse(m.htmlTrustEligible(forTabID: UUID()))
    }

    // MARK: shouldOfferHTMLTrust — the banner-visibility predicate

    func test_shouldOfferTrust_forScriptDependentEligibleUntrustedDoc() {
        let m = makeModel()
        let id = openHTML(m)  // content includes <script>
        XCTAssertTrue(m.shouldOfferHTMLTrust(forTabID: id, contents: "<script>x()</script><div></div>"),
                      "offer trust for a local, script-dependent, untrusted doc")
    }

    func test_shouldOfferTrust_falseOnceTrusted() {
        let m = makeModel()
        let id = openHTML(m)
        m.setHTMLTrusted(true, forTabID: id)
        XCTAssertFalse(m.shouldOfferHTMLTrust(forTabID: id, contents: "<script>x()</script>"),
                       "no banner once the doc is already trusted")
    }

    func test_shouldOfferTrust_falseForNonScriptDoc() {
        let m = makeModel()
        let id = openHTML(m)
        XCTAssertFalse(m.shouldOfferHTMLTrust(forTabID: id, contents: "<p>just text, no scripts</p>"),
                       "no banner when nothing was suppressed")
    }
}
