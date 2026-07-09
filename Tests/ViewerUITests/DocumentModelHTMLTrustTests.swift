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
        m.htmlNetworkConsent = HTMLNetworkConsentStore(defaults: UserDefaults(
            suiteName: "HTMLNetStore-\(UUID().uuidString)")!)
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

    // MARK: TSK-1203 — network consent accessor (fail-closed for untrusted)

    func test_networkConsent_returnsHosts_onlyWhenTrusted() {
        let m = makeModel()
        let id = openHTML(m)
        // Untrusted: granting is rejected AND the read is empty.
        XCTAssertFalse(m.allowHTMLNetwork(host: "api.example.com", forTabID: id),
                       "an untrusted tab can't be granted network")
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: id), [],
                       "untrusted tab exposes NO connect hosts (fail-closed)")
        // Trust, then grant.
        m.setHTMLTrusted(true, forTabID: id)
        XCTAssertTrue(m.allowHTMLNetwork(host: "api.example.com", forTabID: id))
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: id), ["api.example.com"])
    }

    func test_networkConsent_revokedByUntrusting() {
        let m = makeModel()
        let id = openHTML(m)
        m.setHTMLTrusted(true, forTabID: id)
        m.allowHTMLNetwork(host: "api.example.com", forTabID: id)
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: id), ["api.example.com"])
        // Revoking TRUST alone re-closes the network fence (accessor is trust-gated),
        // even though the stored consent for the path survives.
        m.setHTMLTrusted(false, forTabID: id)
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: id), [],
                       "untrusting a doc closes its network fence")
    }

    func test_revokeHTMLNetwork_clearsStoredConsent() {
        let m = makeModel()
        let id = openHTML(m)
        m.setHTMLTrusted(true, forTabID: id)
        m.allowHTMLNetwork(host: "api.example.com", forTabID: id)
        m.revokeHTMLNetwork(forTabID: id)
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: id), [],
                       "explicit revoke clears the stored consent")
    }

    func test_unknownTab_networkFailsClosed() {
        let m = makeModel()
        XCTAssertEqual(m.htmlAllowedConnectHosts(forTabID: UUID()), [])
        XCTAssertFalse(m.allowHTMLNetwork(host: "api.example.com", forTabID: UUID()))
    }
}
