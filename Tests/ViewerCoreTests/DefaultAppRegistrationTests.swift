import XCTest
@testable import ViewerCore

/// TSK-356 — host coverage for the "make TextView the default viewer" logic.
/// The LaunchServices I/O is behind `RoleHandlerService`, so every state and
/// flip transition is exercised with a fake — no live system DB touched.
final class DefaultAppRegistrationTests: XCTestCase {

    private let ours = DefaultAppRegistration.defaultBundleID

    /// In-memory `RoleHandlerService`: a UTI→handler map for reads, a recorded
    /// set of writes, plus an optional forced error to test failure paths.
    private final class FakeService: RoleHandlerService, @unchecked Sendable {
        var handlers: [String: String]
        /// UTIs for which `setDefaultViewerHandler` should report an error.
        var failFor: Set<String> = []
        let failStatus: Int32 = -10810  // kLSUnknownErr-ish sentinel
        private(set) var setCalls: [(uti: String, bundleID: String)] = []

        init(handlers: [String: String] = [:]) { self.handlers = handlers }

        func defaultViewerHandler(forContentType contentType: String) -> String? {
            handlers[contentType]
        }

        func setDefaultViewerHandler(
            _ bundleID: String, forContentType contentType: String
        ) -> Int32 {
            setCalls.append((contentType, bundleID))
            if failFor.contains(contentType) { return failStatus }
            handlers[contentType] = bundleID
            return noErr
        }
    }

    // MARK: - Catalog

    func testGroupsMirrorInfoPlistAndHaveStableIDs() {
        let groups = DefaultAppRegistration.groups
        XCTAssertEqual(groups.map(\.name),
                       ["Markdown", "Plain Text", "Source Code"])
        // Every group claims at least one UTI; ids are unique & stable.
        XCTAssertTrue(groups.allSatisfy { !$0.utis.isEmpty })
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
        // Markdown's canonical UTIs are present (the flip target).
        let md = groups.first { $0.name == "Markdown" }!
        XCTAssertTrue(md.utis.contains("net.daringfireball.markdown"))
        XCTAssertTrue(md.utis.contains("public.markdown"))
        XCTAssertEqual(md.id, "net.daringfireball.markdown")
    }

    // MARK: - status()

    func testStatusNoneOwnedIsNotDefault() {
        let svc = FakeService(handlers: [
            "net.daringfireball.markdown": "com.apple.TextEdit",
            "public.markdown": "com.apple.TextEdit",
        ])
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        let md = st.first { $0.group.name == "Markdown" }!
        XCTAssertFalse(md.isDefault)
        XCTAssertFalse(md.isPartial)
    }

    func testStatusAllOwnedIsDefault() {
        let svc = FakeService(handlers: [
            "net.daringfireball.markdown": ours,
            "public.markdown": ours,
        ])
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        let md = st.first { $0.group.name == "Markdown" }!
        XCTAssertTrue(md.isDefault)
        XCTAssertFalse(md.isPartial)
    }

    func testStatusSomeOwnedIsPartial() {
        let svc = FakeService(handlers: [
            "net.daringfireball.markdown": ours,
            "public.markdown": "com.apple.TextEdit",
        ])
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        let md = st.first { $0.group.name == "Markdown" }!
        XCTAssertFalse(md.isDefault)
        XCTAssertTrue(md.isPartial)
    }

    func testStatusOwnershipIsCaseInsensitive() {
        // LaunchServices normalizes bundle ids to lowercase; we must match.
        let svc = FakeService(handlers: [
            "net.daringfireball.markdown": ours.lowercased(),
            "public.markdown": ours.uppercased(),
        ])
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        let md = st.first { $0.group.name == "Markdown" }!
        XCTAssertTrue(md.isDefault)
    }

    func testStatusUnregisteredUTICountsAsNotOurs() {
        let svc = FakeService(handlers: [:])  // nothing registered anywhere
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        XCTAssertTrue(st.allSatisfy { !$0.isDefault && !$0.isPartial })
        XCTAssertEqual(st.count, DefaultAppRegistration.groups.count)
    }

    // MARK: - setDefault()

    func testSetDefaultFlipsAllUTIsAndSucceeds() {
        let svc = FakeService(handlers: [
            "net.daringfireball.markdown": "com.apple.TextEdit",
            "public.markdown": "com.apple.TextEdit",
        ])
        let md = DefaultAppRegistration.groups.first { $0.name == "Markdown" }!
        let result = DefaultAppRegistration.setDefault(
            for: md, using: svc, ourBundleID: ours)
        XCTAssertEqual(result, .success)
        // Both UTIs were written, and a re-query now reads as default.
        XCTAssertEqual(svc.setCalls.count, md.utis.count)
        let st = DefaultAppRegistration.status(using: svc, ourBundleID: ours)
        XCTAssertTrue(st.first { $0.group.name == "Markdown" }!.isDefault)
    }

    func testSetDefaultReportsFirstErrorButStillAttemptsRest() {
        let svc = FakeService(handlers: [:])
        svc.failFor = ["net.daringfireball.markdown"]
        let md = DefaultAppRegistration.groups.first { $0.name == "Markdown" }!
        let result = DefaultAppRegistration.setDefault(
            for: md, using: svc, ourBundleID: ours)
        XCTAssertEqual(result, .failed(firstError: svc.failStatus))
        // It does NOT bail on first error — every UTI is attempted so a
        // partial flip still applies what it can.
        XCTAssertEqual(svc.setCalls.map(\.uti), md.utis)
        // The non-failing UTI did flip.
        XCTAssertEqual(svc.handlers["public.markdown"], ours)
    }

    func testSetDefaultIsIdempotent() {
        let svc = FakeService()
        let md = DefaultAppRegistration.groups.first { $0.name == "Markdown" }!
        XCTAssertEqual(
            DefaultAppRegistration.setDefault(for: md, using: svc, ourBundleID: ours),
            .success)
        XCTAssertEqual(
            DefaultAppRegistration.setDefault(for: md, using: svc, ourBundleID: ours),
            .success)
        XCTAssertTrue(
            DefaultAppRegistration.status(using: svc, ourBundleID: ours)
                .first { $0.group.name == "Markdown" }!.isDefault)
    }
}
