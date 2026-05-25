import AppKit
import XCTest
@testable import ViewerCore

final class FileTreeRecencyTests: XCTestCase {

    // MARK: - Tier boundary table

    /// Boundaries are inclusive-lower / exclusive-upper. Walking the
    /// exact-second boundary in both directions catches off-by-one
    /// errors that day-aliased arithmetic would hide.
    func testTierBoundaries() {
        let day  = FileTreeRecency.dayInSeconds
        let week = FileTreeRecency.weekInSeconds
        let mon  = FileTreeRecency.monthInSeconds
        let qtr  = FileTreeRecency.quarterInSeconds

        // < 1 day
        XCTAssertEqual(FileTreeRecency.tier(forAge: 0),         .today)
        XCTAssertEqual(FileTreeRecency.tier(forAge: 1),         .today)
        XCTAssertEqual(FileTreeRecency.tier(forAge: day - 1),   .today)

        // 1d ..< 7d
        XCTAssertEqual(FileTreeRecency.tier(forAge: day),       .week)
        XCTAssertEqual(FileTreeRecency.tier(forAge: week - 1),  .week)

        // 7d ..< 30d
        XCTAssertEqual(FileTreeRecency.tier(forAge: week),      .month)
        XCTAssertEqual(FileTreeRecency.tier(forAge: mon - 1),   .month)

        // 30d ..< 90d
        XCTAssertEqual(FileTreeRecency.tier(forAge: mon),       .quarter)
        XCTAssertEqual(FileTreeRecency.tier(forAge: qtr - 1),   .quarter)

        // >= 90d
        XCTAssertEqual(FileTreeRecency.tier(forAge: qtr),       .older)
        XCTAssertEqual(FileTreeRecency.tier(forAge: qtr * 10),  .older)
    }

    /// Negative ages (clock skew / backdated files) should land in
    /// `.today`, not silently flip to `.older` via signed comparison.
    func testNegativeAgeClampsToToday() {
        XCTAssertEqual(FileTreeRecency.tier(forAge: -1),        .today)
        XCTAssertEqual(FileTreeRecency.tier(forAge: -10_000),   .today)
    }

    func testDateOverloadAgreesWithAgeOverload() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * FileTreeRecency.dayInSeconds)
        XCTAssertEqual(FileTreeRecency.tier(for: twoDaysAgo, now: now), .week)
    }

    // MARK: - Default mode

    func testDefaultModeIsModified() {
        XCTAssertEqual(FileTreeRecency.RecencyMode.default, .modified)
        XCTAssertEqual(FileTreeRecency.RecencyMode.default.rawValue, "Modified")
    }

    func testAllRecencyModeCasesCoveredByRawValueRoundTrip() {
        for mode in FileTreeRecency.RecencyMode.allCases {
            XCTAssertEqual(
                FileTreeRecency.RecencyMode(rawValue: mode.rawValue), mode
            )
        }
    }

    // MARK: - Color contract

    /// Every tier must return a non-clear, non-zero-alpha NSColor.
    /// The SwiftUI layer is free to elide drawing for `.older`, but
    /// the data contract is "always usable color".
    func testColorContractAllTiersHaveUsableColor() {
        for tier in FileTreeRecency.RecencyTier.allCases {
            let c = FileTreeRecency.color(for: tier)
            // Force a concrete resolution against aqua appearance so
            // NSDynamicColor evaluates its provider.
            let resolved = c.usingColorSpace(.sRGB) ?? c
            XCTAssertGreaterThan(
                resolved.alphaComponent, 0,
                "tier \(tier) returned zero-alpha color"
            )
        }
    }

    /// Color objects are dynamic — equality is by name, not by RGBA.
    /// We at least want distinct color instances per tier (no
    /// accidental fall-through in the switch).
    func testColorPerTierIsDistinct() {
        let colors = FileTreeRecency.RecencyTier.allCases.map {
            FileTreeRecency.color(for: $0)
        }
        // Resolved RGBA in the default appearance must differ across
        // the four "active" tiers. `.older` may share a hue with the
        // light-mode background but its alpha is unique enough.
        let resolved = colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        let descriptors = resolved.map {
            "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)"
        }
        XCTAssertEqual(Set(descriptors).count, descriptors.count,
                       "expected one unique color per tier, got duplicates: \(descriptors)")
    }

    // MARK: - Mode -> Date selection

    func testAttributesPickerSelectsRightTimestamp() {
        let m = Date(timeIntervalSinceReferenceDate: 100)
        let c = Date(timeIntervalSinceReferenceDate: 200)
        let attrs = FileTreeRecencyAttributes(modifiedAt: m, createdAt: c)
        XCTAssertEqual(attrs.date(for: .modified), m)
        XCTAssertEqual(attrs.date(for: .added),    m)  // proxy
        XCTAssertEqual(attrs.date(for: .created),  c)
    }

    // MARK: - Cache round-trip

    func testCachePopulatesAndInvalidates() {
        // Use the test bundle's own executable as a known-extant file
        // (avoids touching temporaryDirectory in this fast test).
        let url = Bundle(for: type(of: self)).bundleURL
        FileTreeRecencyCache.invalidate(url)
        let first  = FileTreeRecencyCache.attributes(for: url)
        let second = FileTreeRecencyCache.attributes(for: url)
        // Both reads should return the same modifiedAt (cache hit).
        XCTAssertEqual(first.modifiedAt, second.modifiedAt)
        // After invalidation the lookup still succeeds (re-stats).
        FileTreeRecencyCache.invalidate(url)
        let third = FileTreeRecencyCache.attributes(for: url)
        XCTAssertEqual(first.modifiedAt, third.modifiedAt)
    }

    // MARK: - AppStorage round-trip
    //
    // `@AppStorage` is a thin wrapper over `UserDefaults`. We exercise
    // the rawValue<->String round-trip + UserDefaults persistence
    // directly so the test stays headless (no SwiftUI view tree).

    func testAppStorageKeyRoundTripPersistsMode() {
        // Use a per-test suite name so we never touch the host's
        // shared `UserDefaults.standard`. The old version of this
        // test set a key on standard defaults with a `defer`
        // cleanup; on a crashing test the key persisted to the
        // developer's machine.
        let suite = "FileTreeRecencyTests-AppStorage-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("failed to construct test UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "MarkdownViewer.sidebar.recencyMode"

        for mode in FileTreeRecency.RecencyMode.allCases {
            defaults.set(mode.rawValue, forKey: key)
            let raw = defaults.string(forKey: key) ?? ""
            XCTAssertEqual(FileTreeRecency.RecencyMode(rawValue: raw), mode,
                           "round-trip failed for \(mode)")
        }
    }
}
