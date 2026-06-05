import XCTest
@testable import ViewerCore

/// Regression coverage for AUDIT S3: `URLSchemePolicy.containedPath` must
/// resolve symlinks before its home/temp containment check. Before the fix
/// it compared only the *lexically* standardized path (`..`/`.` collapsed
/// but symlinks intact), so an in-home symlink whose target lives outside
/// the home tree — e.g. a dotfile-managed `~/link -> /etc` — passed
/// `hasPrefix(home + "/")` and `model.openPath` would then read the
/// out-of-home target. That is exactly the one-click "read arbitrary file"
/// primitive the policy exists to close.
///
/// Uniquely named to avoid colliding with the shared
/// `URLSchemePolicyTests`; do not fold these into that file.
final class Audit_Sources_ViewerCore_Security_URLSchemePolicy_swift_SymlinkEscapeTests: XCTestCase {

    /// An in-home symlink pointing OUTSIDE the home tree must not launder
    /// an out-of-home path past the containment check.
    func test_inHomeSymlinkEscapingHome_rejected() throws {
        let fm = FileManager.default
        // Anchor the symlink in the *resolved* home so the link node
        // genuinely lives inside the home tree (NSHomeDirectory() may
        // itself contain symlinks, e.g. /var -> /private/var).
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL.resolvingSymlinksInPath()
        let linkName = ".mdv_audit_symlink_escape_\(UUID().uuidString)"
        let link = home.appendingPathComponent(linkName)
        // Target is unambiguously outside the home tree.
        let outside = URL(fileURLWithPath: "/etc")

        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? fm.removeItem(at: link) }

        // Sanity: the symlink really does escape home once resolved.
        let resolvedThroughLink = link.appendingPathComponent("passwd")
            .standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertFalse(
            resolvedThroughLink.hasPrefix(home.path + "/"),
            "Test fixture is invalid — the symlink did not escape home."
        )

        // The attack: a path that is lexically under home but traverses an
        // in-home symlink to /etc/passwd. Must be rejected.
        let attack = link.appendingPathComponent("passwd").path
        XCTAssertNil(
            URLSchemePolicy.containedPath(attack),
            "In-home symlink escaping the home tree must be rejected."
        )
    }

    /// An in-home symlink whose target stays INSIDE home must still be
    /// accepted — the fix tightens the boundary without breaking the
    /// legitimate symlinked-folder case.
    func test_inHomeSymlinkStayingInHome_accepted() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL.resolvingSymlinksInPath()

        let realDir = home.appendingPathComponent(
            ".mdv_audit_symlink_target_\(UUID().uuidString)"
        )
        let link = home.appendingPathComponent(
            ".mdv_audit_symlink_inhome_\(UUID().uuidString)"
        )
        try? fm.removeItem(at: link)
        try? fm.removeItem(at: realDir)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: realDir)
        defer {
            try? fm.removeItem(at: link)
            try? fm.removeItem(at: realDir)
        }

        let candidate = link.appendingPathComponent("note.md").path
        XCTAssertNotNil(
            URLSchemePolicy.containedPath(candidate),
            "An in-home symlink that resolves inside home must stay accepted."
        )
    }
}
