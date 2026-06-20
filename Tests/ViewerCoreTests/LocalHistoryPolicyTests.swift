import XCTest
@testable import ViewerCore

/// Teeth for `LocalHistoryPolicy` (TSK-1103) — the owner's retention/privacy
/// rules: default-ON, configurable version cap, 20MB cap, text-only, exclude
/// `.env`/secret-like files. Each rule is pinned so a regression fails the host
/// gate.
final class LocalHistoryPolicyTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "mdv-localhistpolicy-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - enable

    func test_defaultOn_whenUnset() {
        XCTAssertTrue(LocalHistoryPolicy.isEnabled(defaults: freshDefaults(), environment: [:]))
    }

    func test_explicitlyDisabled_persisted() {
        let d = freshDefaults()
        d.set(false, forKey: LocalHistoryPolicy.enabledKey)
        XCTAssertFalse(LocalHistoryPolicy.isEnabled(defaults: d, environment: [:]))
    }

    func test_envOverride_forcesOff() {
        let d = freshDefaults()
        XCTAssertFalse(LocalHistoryPolicy.isEnabled(defaults: d, environment: ["MDV_LOCAL_HISTORY": "0"]))
    }

    func test_envOverride_forcesOn_overridesPersistedOff() {
        let d = freshDefaults()
        d.set(false, forKey: LocalHistoryPolicy.enabledKey)
        XCTAssertTrue(LocalHistoryPolicy.isEnabled(defaults: d, environment: ["MDV_LOCAL_HISTORY": "1"]))
    }

    // MARK: - version cap (configurable)

    func test_versionCap_defaultsTo50() {
        XCTAssertEqual(LocalHistoryPolicy.versionCap(defaults: freshDefaults()), 50)
    }

    func test_versionCap_honorsConfiguredValue() {
        let d = freshDefaults()
        d.set(10, forKey: LocalHistoryPolicy.versionCapKey)
        XCTAssertEqual(LocalHistoryPolicy.versionCap(defaults: d), 10)
    }

    func test_versionCap_clampsNonPositiveToDefault() {
        let d = freshDefaults()
        d.set(0, forKey: LocalHistoryPolicy.versionCapKey)
        XCTAssertEqual(LocalHistoryPolicy.versionCap(defaults: d), 50)
    }

    // MARK: - secret exclusion

    func test_dotenv_excluded() {
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/proj/.env"))
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/proj/.env.local"))
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/proj/.env.production.local"))
    }

    func test_keyAndCertExtensions_excluded() {
        for p in ["/k/id_rsa", "/k/server.pem", "/k/cert.crt", "/k/store.p12", "/k/private.key"] {
            XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: p), p)
        }
    }

    func test_secretFragments_excluded() {
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/x/my_secret.txt"))
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/x/db_credentials.json"))
        XCTAssertTrue(LocalHistoryPolicy.isSecretLike(path: "/x/api_key.conf"))
    }

    func test_ordinaryFiles_notSecret() {
        for p in ["/x/notes.md", "/x/main.swift", "/x/README.txt", "/x/data.csv"] {
            XCTAssertFalse(LocalHistoryPolicy.isSecretLike(path: p), p)
        }
    }

    // MARK: - text-only

    func test_textContent_isText() {
        XCTAssertTrue(LocalHistoryPolicy.isLikelyText("hello\nworld"))
        XCTAssertTrue(LocalHistoryPolicy.isLikelyText(""))   // empty file is text
    }

    func test_nulByte_isNotText() {
        XCTAssertFalse(LocalHistoryPolicy.isLikelyText("abc\u{0}def"))
    }

    // MARK: - the combined decision

    func test_decision_allowsOrdinaryTextSave() {
        let d = decision(path: "/x/notes.md", content: "edited\n")
        XCTAssertEqual(d, .allowed)
        XCTAssertTrue(d.isAllowed)
    }

    func test_decision_disabledShortCircuits() {
        let d = LocalHistoryPolicy.decideSnapshot(
            path: "/x/notes.md", content: "edited",
            defaults: freshDefaults(), environment: ["MDV_LOCAL_HISTORY": "0"])
        XCTAssertEqual(d, .disabled)
    }

    func test_decision_secretExcludedEvenWhenEnabled() {
        XCTAssertEqual(decision(path: "/x/.env", content: "SECRET=1\n"), .excludedSecret)
    }

    func test_decision_oversizeRejected() {
        // 20MB + 1 byte of 'a'.
        let big = String(repeating: "a", count: LocalHistoryPolicy.maxSnapshotBytes + 1)
        XCTAssertEqual(decision(path: "/x/huge.txt", content: big), .tooLarge)
    }

    func test_decision_atCap_allowed() {
        let atCap = String(repeating: "a", count: LocalHistoryPolicy.maxSnapshotBytes)
        XCTAssertEqual(decision(path: "/x/cap.txt", content: atCap), .allowed)
    }

    func test_decision_binaryRejected() {
        XCTAssertEqual(decision(path: "/x/blob.bin", content: "ok\u{0}bad"), .notText)
    }

    func test_decision_secretBeatsOversize() {
        // Order matters: a secret-like path is excluded before the size check.
        let big = String(repeating: "a", count: LocalHistoryPolicy.maxSnapshotBytes + 1)
        XCTAssertEqual(decision(path: "/x/.env", content: big), .excludedSecret)
    }

    // MARK: - helper

    private func decision(path: String, content: String) -> LocalHistoryPolicy.Decision {
        LocalHistoryPolicy.decideSnapshot(
            path: path, content: content,
            defaults: freshDefaults(), environment: [:])
    }
}
