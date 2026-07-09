import XCTest
@testable import ViewerCore

/// TSK-1496 — host tests for the secret warn-badge render slice: the pure
/// gating/labelling logic (SecretBannerState) + the exact fixture the 'secrets'
/// UI scene uses (so the on-screen count is pinned by a host test, not just a
/// pixel). The detector's corpus is covered by SecretDetectorTests; this pins
/// the BANNER's contract.
final class SecretBannerStateTests: XCTestCase {

    // MARK: - gating

    func test_shouldShow_requiresFindings_notOff_notDismissed() {
        // Happy path: warn treatment (0), a finding, not dismissed → show.
        XCTAssertTrue(SecretBannerState.shouldShow(findingCount: 1, treatmentRaw: 0, dismissed: false))
        // No findings → hidden even when enabled.
        XCTAssertFalse(SecretBannerState.shouldShow(findingCount: 0, treatmentRaw: 0, dismissed: false))
        // Off (2) → hidden even with findings.
        XCTAssertFalse(SecretBannerState.shouldShow(findingCount: 3, treatmentRaw: 2, dismissed: false))
        // Dismissed → hidden.
        XCTAssertFalse(SecretBannerState.shouldShow(findingCount: 3, treatmentRaw: 0, dismissed: true))
        // Mask treatment (1) still shows the badge for now (mask is a later slice).
        XCTAssertTrue(SecretBannerState.shouldShow(findingCount: 1, treatmentRaw: 1, dismissed: false))
    }

    func test_scanEnabled_skipsOnlyWhenOff() {
        XCTAssertTrue(SecretBannerState.scanEnabled(treatmentRaw: 0))
        XCTAssertTrue(SecretBannerState.scanEnabled(treatmentRaw: 1))
        XCTAssertFalse(SecretBannerState.scanEnabled(treatmentRaw: 2))
    }

    func test_countLabel_pluralises_andNeverLeaksAValue() {
        XCTAssertEqual(SecretBannerState.countLabel(1), "1 potential secret detected — values are hidden")
        XCTAssertEqual(SecretBannerState.countLabel(2), "2 potential secrets detected — values are hidden")
    }

    // MARK: - the 'secrets' scene fixture (pinned so the on-screen count is exact)

    func test_secretsSceneFixture_flagsTwoSecrets_uuidStaysQuiet() {
        // MUST match the fixture written by UISceneApplier's 'secrets' scene.
        let fixture = """
        # Example config (fixture — not real credentials)
        AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
        GH_PAT=ghp_1234567890abcdefghijklmnopqrstuvwxyz12
        NORMAL_UUID=550e8400-e29b-41d4-a716-446655440000
        """
        let findings = SecretDetector.scan(text: fixture)
        let kinds = Set(findings.map(\.kind))
        XCTAssertEqual(findings.count, 2, "exactly the AWS key + GitHub token; got \(findings.map(\.kind))")
        XCTAssertTrue(kinds.contains(.awsAccessKeyID), "AWS key flagged")
        XCTAssertTrue(kinds.contains(.githubToken), "GitHub token flagged")
        // The benign UUID line must NOT be flagged (false-positive guard, U4).
        XCTAssertFalse(findings.contains { $0.line == 4 }, "the UUID line stays quiet")
        // Previews are redacted — the raw AWS key must never appear.
        XCTAssertFalse(findings.contains { $0.preview.contains("AKIAIOSFODNN7EXAMPLE") },
                       "previews are redacted, never the full value")
    }
}
