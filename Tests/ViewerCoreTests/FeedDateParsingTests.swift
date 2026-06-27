import Testing
import Foundation
@testable import ViewerCore

/// Edge-case coverage for `FeedDate.parse` (the RSS/Atom date normalizer).
/// FeedParserTests covers only the happy path (2-digit-day RFC822 + `+0000`);
/// these pin the dialects a real feed actually throws that the happy path does
/// NOT exercise — single-digit day, no weekday, 2-digit year, no seconds, and
/// Atom ISO8601 (plain / fractional / numeric-offset) — plus junk rejection and
/// correct instant normalization. (A bug here = a feed item's date silently
/// lost → wrong sort / "unknown date".)
@Suite struct FeedDateParsingTests {

    @Test(arguments: [
        "Mon, 16 Jun 2025 09:30:00 GMT",   // RFC1123, full (happy path)
        "Mon, 5 Jun 2025 09:30:00 GMT",    // SINGLE-DIGIT day (RFC822 allows it)
        "16 Jun 2025 09:30:00 GMT",        // no weekday
        "Mon, 16 Jun 2025 09:30 GMT",      // no seconds
        "Mon, 16 Jun 25 09:30:00 GMT",     // 2-digit year (classic RFC822)
        "Tue, 17 Jun 2025 12:00:00 +0000", // numeric-offset zone
        "2025-06-16T09:30:00Z",            // Atom ISO8601
        "2025-06-16T09:30:00.500Z",        // ISO8601 with fractional seconds
        "2025-06-16T09:30:00+05:30",       // ISO8601 numeric offset
    ])
    func parsesSupportedDialects(_ s: String) {
        #expect(FeedDate.parse(s) != nil, "should parse: \(s)")
    }

    @Test(arguments: ["", "   ", "not a date", "Jun 2025", "16/06/2025", "2025"])
    func rejectsUnparseable(_ s: String) {
        #expect(FeedDate.parse(s) == nil, "should reject: \(s)")
    }

    /// A zone offset must normalize to the SAME instant as its UTC equivalent
    /// (09:30+05:30 == 04:00Z), not just parse to some date.
    @Test func offsetNormalizesToCorrectInstant() {
        let offset = FeedDate.parse("2025-06-16T09:30:00+05:30")
        let utc = FeedDate.parse("2025-06-16T04:00:00Z")
        #expect(offset != nil)
        #expect(offset == utc, "offset date must be the same instant as its UTC equivalent")
    }

    /// Surrounding whitespace/newlines (common in XML text nodes) is trimmed.
    @Test func trimsSurroundingWhitespace() {
        #expect(FeedDate.parse("  2025-06-16T09:30:00Z\n") != nil)
    }
}
