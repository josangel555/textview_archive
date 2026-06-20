import XCTest
@testable import ViewerCore

/// TSK-1189 — teeth for the trust-local-HTML GATE. The relaxation of HTML
/// hardening keys solely off `HTMLTrustPolicy.isTrusted`, so an inversion or a
/// leak here is a security regression. These pin: remote/quarantined/nil are
/// NEVER eligible, trust requires an explicit per-path opt-in (default off,
/// fail-closed), and the trust store is per-document (trusting A never trusts B).
final class HTMLTrustPolicyTests: XCTestCase {

    private let localDoc = URL(fileURLWithPath: "/tmp/site/app.html")

    // MARK: eligibility — the gate's necessary condition

    func test_localFile_notQuarantined_isEligible() {
        XCTAssertTrue(HTMLTrustPolicy.isTrustEligible(url: localDoc, isQuarantined: false))
    }

    func test_quarantinedLocalFile_isNotEligible() {
        XCTAssertFalse(HTMLTrustPolicy.isTrustEligible(url: localDoc, isQuarantined: true),
                       "a downloaded/received (quarantined) file must not be trust-eligible")
    }

    func test_remoteURL_isNeverEligible() {
        XCTAssertFalse(HTMLTrustPolicy.isTrustEligible(
            url: URL(string: "https://evil.example/app.html"), isQuarantined: false),
            "remote content must NEVER be trust-eligible")
    }

    func test_nilURL_isNotEligible() {
        XCTAssertFalse(HTMLTrustPolicy.isTrustEligible(url: nil, isQuarantined: false))
    }

    func test_customScheme_isNotEligible() {
        XCTAssertFalse(HTMLTrustPolicy.isTrustEligible(
            url: URL(string: "x-custom://foo/app.html"), isQuarantined: false))
    }

    // MARK: effective trust — FAIL CLOSED (the security teeth)

    func test_isTrusted_requiresBothEligibleAndOptIn() {
        XCTAssertTrue(HTMLTrustPolicy.isTrusted(url: localDoc, isQuarantined: false, userOptedIn: true))
    }

    func test_optIn_withoutEligibility_isNotTrusted_remote() {
        // The fail-closed teeth: even an explicit opt-in cannot trust remote.
        XCTAssertFalse(HTMLTrustPolicy.isTrusted(
            url: URL(string: "https://evil.example/app.html"), isQuarantined: false, userOptedIn: true),
            "opt-in must NEVER trust remote content")
    }

    func test_optIn_withoutEligibility_isNotTrusted_quarantined() {
        XCTAssertFalse(HTMLTrustPolicy.isTrusted(url: localDoc, isQuarantined: true, userOptedIn: true),
                       "opt-in must NEVER trust a quarantined download")
    }

    func test_eligible_withoutOptIn_isNotTrusted_default() {
        XCTAssertFalse(HTMLTrustPolicy.isTrusted(url: localDoc, isQuarantined: false, userOptedIn: false),
                       "default is OFF — eligibility alone does not trust")
    }

    // MARK: trust key — per-path, standardized

    func test_trustKey_standardizesPath() {
        let messy = URL(fileURLWithPath: "/tmp/site/../site/./app.html")
        XCTAssertEqual(HTMLTrustPolicy.trustKey(for: messy), HTMLTrustPolicy.trustKey(for: localDoc))
    }

    func test_trustKey_distinctSiblings_doNotCollide() {
        XCTAssertNotEqual(
            HTMLTrustPolicy.trustKey(for: URL(fileURLWithPath: "/tmp/site/a.html")),
            HTMLTrustPolicy.trustKey(for: URL(fileURLWithPath: "/tmp/site/b.html")))
    }

    // MARK: store — per-document opt-in, default off, revocable, isolated

    private func freshStore() -> HTMLTrustStore {
        let suite = "HTMLTrust-\(UUID().uuidString)"
        return HTMLTrustStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func test_store_defaultIsNotOptedIn() {
        XCTAssertFalse(freshStore().isOptedIn(url: localDoc))
    }

    func test_store_setThenRead_roundTrips() {
        let store = freshStore()
        store.setOptedIn(true, url: localDoc)
        XCTAssertTrue(store.isOptedIn(url: localDoc))
    }

    func test_store_isPerDocument_trustingAdoesNotTrustB() {
        let store = freshStore()
        let a = URL(fileURLWithPath: "/tmp/site/a.html")
        let b = URL(fileURLWithPath: "/tmp/site/b.html")
        store.setOptedIn(true, url: a)
        XCTAssertTrue(store.isOptedIn(url: a))
        XCTAssertFalse(store.isOptedIn(url: b), "trusting A must never trust sibling B")
    }

    func test_store_revoke_clearsTrust() {
        let store = freshStore()
        store.setOptedIn(true, url: localDoc)
        store.setOptedIn(false, url: localDoc)
        XCTAssertFalse(store.isOptedIn(url: localDoc))
    }

    func test_store_persistsAcrossInstances_sameSuite() {
        let suite = "HTMLTrust-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        HTMLTrustStore(defaults: d).setOptedIn(true, url: localDoc)
        XCTAssertTrue(HTMLTrustStore(defaults: d).isOptedIn(url: localDoc),
                      "a trust opt-in must survive reopen (same store backing)")
    }
}
