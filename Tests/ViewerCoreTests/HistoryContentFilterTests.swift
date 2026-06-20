import XCTest
@testable import ViewerCore

/// Teeth for `HistoryContentFilter` (TSK-1103) — the text-only + secret
/// exclusion gate for Local History capture. Asserts binary content and
/// credential-bearing content are rejected, while ordinary prose / config that
/// merely MENTIONS secret-ish words (without a real secret value) is allowed.
/// Conservative bias: false-negatives (a leaked secret) are far worse than
/// false-positives (a missed history entry), so the secret cases are the teeth.
final class HistoryContentFilterTests: XCTestCase {

    // MARK: - Binary detection

    func test_nulByte_isBinary() {
        XCTAssertTrue(HistoryContentFilter.isProbablyBinary("abc\u{0}def"))
    }

    func test_highControlCharRatio_isBinary() {
        let ctrl = String(repeating: "\u{1}\u{2}\u{3}\u{4}", count: 100)
        XCTAssertTrue(HistoryContentFilter.isProbablyBinary(ctrl))
    }

    func test_plainText_isNotBinary() {
        XCTAssertFalse(HistoryContentFilter.isProbablyBinary("hello world\nsecond line\ttabbed\r\n"))
        XCTAssertFalse(HistoryContentFilter.isProbablyBinary(""))
        XCTAssertFalse(HistoryContentFilter.isProbablyBinary("emoji 🎉 and ünïcode are fine"))
    }

    // MARK: - Secret detection (the teeth)

    func test_privateKeyHeaders_areSecret() {
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("-----BEGIN EC PRIVATE KEY-----"))
    }

    func test_vendorTokens_areSecret() {
        let tokens = [
            "ghp_1234567890abcdefghijklmnopqrstuvwx",      // GitHub PAT
            "github_pat_11ABCDEFG0abcdefghij_klmnop",       // fine-grained PAT
            "xoxb-1234567890-abcdefghij",                   // Slack
            "sk-ant-api03-abcdefghijklmnopqrstuv",          // Anthropic
            "AIzaSyA1234567890abcdefghijklmnopqrstuvw",     // Google
            "glpat-abcdefghij1234567890",                   // GitLab
        ]
        for t in tokens {
            XCTAssertTrue(HistoryContentFilter.looksLikeSecret("key: \(t)"),
                          "vendor token must be flagged: \(t)")
        }
    }

    func test_awsAccessKeyId_isSecret() {
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("aws_key = AKIAIOSFODNN7EXAMPLE"))
    }

    func test_dotenvAssignment_isSecret() {
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("DATABASE_PASSWORD=s3cr3t-Long-Value-123"))
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("export API_KEY=\"abcdef1234567890ghij\""))
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret("client_secret: 9f8e7d6c5b4a3210ZZZZ"))
    }

    func test_secretAnywhereInDocument_isSecret() {
        let doc = """
        # My notes
        Some ordinary text here.
        Another line.
        SECRET_TOKEN=abcdefghij1234567890KLMNOP
        Trailing prose.
        """
        XCTAssertTrue(HistoryContentFilter.looksLikeSecret(doc))
    }

    // MARK: - Not secrets (no over-suppression)

    func test_prose_mentioningPassword_isNotSecret() {
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret(
            "Remember to change your password regularly and keep it private."))
    }

    func test_emptyOrPlaceholderAssignment_isNotSecret() {
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("PASSWORD="))
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("API_KEY=changeme"))
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("token: your_token_here"))
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("SECRET=<your-secret>"))
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("API_KEY=${MY_API_KEY}"))   // env ref, not literal
    }

    func test_nonSensitiveAssignment_isNotSecret() {
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("title = My Great Document"))
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("count: 1234567890123"))   // number, sensible key
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret("name=just-a-plain-value"))
    }

    func test_plainMarkdown_isNotSecret() {
        let md = """
        # Title
        - bullet one
        - bullet two

        Some `inline code` and a [link](https://example.com).
        """
        XCTAssertFalse(HistoryContentFilter.looksLikeSecret(md))
    }
}
