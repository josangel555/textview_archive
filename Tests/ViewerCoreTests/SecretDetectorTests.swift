import XCTest
@testable import ViewerCore

/// TSK-1496 — the detector corpus: true positives per credential shape and
/// the false-positive pins that keep the entropy guard honest. NOTE: every
/// "secret" below is a synthetic test fixture.
final class SecretDetectorTests: XCTestCase {

    private func kinds(_ line: String) -> [SecretDetector.Kind] {
        SecretDetector.scan(line: line, lineNumber: 1).map(\.kind)
    }

    // MARK: True positives

    func test_wellKnownShapes_detect() {
        XCTAssertEqual(kinds("aws_key = AKIAIOSFODNN7EXAMPLE"), [.awsAccessKeyID])
        XCTAssertEqual(kinds("-----BEGIN RSA PRIVATE KEY-----"), [.privateKeyPEM])
        XCTAssertEqual(kinds("-----BEGIN OPENSSH PRIVATE KEY-----"), [.privateKeyPEM])
        XCTAssertEqual(kinds("token: ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                       [.githubToken])
        XCTAssertEqual(kinds("SLACK=xoxb-12345678901-abcdefABCDEF"), [.slackToken])
        XCTAssertEqual(kinds("key=AIzaSyA1234567890abcdefghijklmnopqrstuv"), [.gcpAPIKey])
        XCTAssertEqual(
            kinds("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4fwpM"),
            [.jwt])
    }

    func test_genericAssignment_highEntropyValue_detects() {
        XCTAssertEqual(kinds(#"password = "q9Zx7!bK2mNp4Rt8""#), [.genericAssignment])
        XCTAssertEqual(kinds("API_KEY: sk-Ab3dEf6hIj9kLm2nOp5q"), [.genericAssignment])
        XCTAssertEqual(kinds("export SECRET_TOKEN=8fK3nZq7Wp2xVb9y"), [.genericAssignment])
    }

    // MARK: False-positive pins (the guard's contract)

    func test_falsePositives_stayQuiet() {
        // Digest shapes assigned to credential-ish keys: hex SHA-1/256.
        XCTAssertEqual(kinds("token = da39a3ee5e6b4b0d3255bfef95601890afd80709"), [])
        XCTAssertEqual(kinds(
            "secret: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), [])
        // Placeholders and words.
        XCTAssertEqual(kinds("password = changeme"), [])
        XCTAssertEqual(kinds("password = placeholder"), [])
        XCTAssertEqual(kinds("secret: yourpassword"), [])
        // Low-entropy / single-class values.
        XCTAssertEqual(kinds("token = aaaaaaaaaaaaaaaa"), [])
        XCTAssertEqual(kinds("password = 111111111111"), [])
        // Prose containing the words but no assignment shape.
        XCTAssertEqual(kinds("The password field accepts any token of text."), [])
        // A git SHA in a lockfile-ish line (no credential key at all).
        XCTAssertEqual(kinds("resolved-ref: 9fceb02aa1d6a7dc4b23a6e3a4f2c9de8f7a6b5c"), [])
    }

    // MARK: Whole-text scan mechanics

    func test_scanText_lineNumbers_andCap() {
        let text = """
        line one is fine
        aws = AKIAIOSFODNN7EXAMPLE
        also fine
        -----BEGIN EC PRIVATE KEY-----
        """
        let f = SecretDetector.scan(text: text)
        XCTAssertEqual(f.map(\.line), [2, 4])
        XCTAssertEqual(f.map(\.kind), [.awsAccessKeyID, .privateKeyPEM])
        // The cap bounds a pathological file.
        let flood = Array(repeating: "k = AKIAIOSFODNN7EXAMPLE", count: 500)
            .joined(separator: "\n")
        XCTAssertEqual(SecretDetector.scan(text: flood).count,
                       SecretDetector.maxFindings)
    }

    func test_previews_neverLeakTheValue() {
        let f = SecretDetector.scan(
            line: "password = q9Zx7bK2mNp4Rt8v", lineNumber: 1)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].preview, "q9Zx…")
        XCTAssertLessThan(f[0].preview.count, 8,
                          "a finding must never carry the full credential")
    }

    func test_entropyGuard_units() {
        XCTAssertEqual(SecretDetector.shannonEntropy(""), 0)
        XCTAssertEqual(SecretDetector.shannonEntropy("aaaa"), 0)
        XCTAssertGreaterThan(SecretDetector.shannonEntropy("q9Zx7!bK2mNp4Rt8"), 3.0)
        XCTAssertTrue(SecretDetector.isLikelySecretValue("q9Zx7bK2mNp4Rt8v"))
        XCTAssertFalse(SecretDetector.isLikelySecretValue("aaaaaaaaaaaaaaaa"))
    }
}
