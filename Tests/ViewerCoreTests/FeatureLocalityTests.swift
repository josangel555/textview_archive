import XCTest
@testable import ViewerCore

/// Pins the TSK-805 core/Swift split classification. These tests are the teeth
/// behind `CORE_SWIFT_SPLIT_DESIGN_2026-06-19.md`: the design doc states the
/// boundary in prose, this proves the encoded classification obeys it.
///
/// The load-bearing guarantee: a future change that gives a `remoteableCore`
/// engine a host dependency (or otherwise mis-tiers a surface) FAILS here,
/// rather than silently breaking the remote-core story.
final class FeatureLocalityTests: XCTestCase {

    // MARK: - Tier lattice

    func test_tierOrderingIsPortabilityLattice() {
        XCTAssertLessThan(FeatureTier.remoteableCore, FeatureTier.hostOrchestrated)
        XCTAssertLessThan(FeatureTier.hostOrchestrated, FeatureTier.localOnlySwift)
        // Most-portable is the floor.
        XCTAssertEqual(FeatureTier.allCases.min(), .remoteableCore)
        XCTAssertEqual(FeatureTier.allCases.max(), .localOnlySwift)
    }

    func test_capabilityMinimumTierEncodesBoundary() {
        XCTAssertEqual(HostCapability.pureCompute.minimumTier, .remoteableCore)
        // IO/process capabilities are symmetric local/remote → host-orchestrated.
        for cap in [HostCapability.filesystemIO, .subprocess, .pushStream] {
            XCTAssertEqual(cap.minimumTier, .hostOrchestrated, "\(cap) should be host-orchestrated")
        }
        // OS-pinned capabilities force local-only.
        for cap in [HostCapability.appKitUI, .macSystemFramework, .localHardware, .interactivePointer] {
            XCTAssertEqual(cap.minimumTier, .localOnlySwift, "\(cap) should be local-only")
        }
    }

    // MARK: - Minimum-tier derivation (work flows downhill)

    func test_minimumTakesHighestDependency() {
        // One local-only dependency pins the whole surface local, even mixed
        // with a pure-compute one.
        XCTAssertEqual(
            FeatureTier.minimum(for: [.pureCompute, .appKitUI]),
            .localOnlySwift
        )
        // filesystem + subprocess stays host-orchestrated.
        XCTAssertEqual(
            FeatureTier.minimum(for: [.filesystemIO, .subprocess]),
            .hostOrchestrated
        )
        // No dependencies → the portable floor.
        XCTAssertEqual(FeatureTier.minimum(for: []), .remoteableCore)
    }

    // MARK: - The teeth: catalog consistency

    /// EVERY classified surface must declare exactly the tier its dependencies
    /// force. This is the regression guard for the whole split.
    func test_catalogIsInternallyConsistent() {
        let bad = FeatureLocalityCatalog.inconsistencies
        XCTAssertTrue(
            bad.isEmpty,
            "Mis-tiered surfaces (declared tier ≠ derived from dependencies): " +
            bad.map { "\($0.id): declared=\($0.tier.id) derived=\($0.derivedMinimumTier.id)" }
                .joined(separator: ", ")
        )
    }

    /// Demonstrates the teeth bite: a surface declared MORE portable than its
    /// dependencies permit is caught as inconsistent. (Builds an off-catalog
    /// instance so the shipped catalog stays clean.)
    func test_overPortableSurfaceIsInconsistent() {
        let violation = FeatureSurface(
            id: "bogus.audio.in.core",
            name: "Audio editor mistakenly tiered as core",
            tier: .remoteableCore,                       // claims portable…
            dependencies: [.macSystemFramework, .localHardware], // …but needs the Mac
            locus: "n/a"
        )
        XCTAssertFalse(violation.isConsistent)
        XCTAssertEqual(violation.derivedMinimumTier, .localOnlySwift)
    }

    func test_underPortableSurfaceIsInconsistent() {
        // Declared local-only but only needs pure compute → also flagged
        // (a missed-portability smell — keeps the classification honest).
        let smell = FeatureSurface(
            id: "bogus.parser.pinned.local",
            name: "Pure parser needlessly pinned local",
            tier: .localOnlySwift,
            dependencies: [.pureCompute],
            locus: "n/a"
        )
        XCTAssertFalse(smell.isConsistent)
        XCTAssertEqual(smell.derivedMinimumTier, .remoteableCore)
    }

    // MARK: - Catalog invariants

    func test_remoteableCoreSurfacesHaveNoHostDependency() {
        for s in FeatureLocalityCatalog.surfaces(in: .remoteableCore) {
            XCTAssertEqual(s.dependencies, [.pureCompute],
                           "\(s.id) is remoteable-core but depends on host capabilities")
        }
    }

    func test_localOnlySurfacesNeverDependedUponByLowerTiers() {
        // The lattice is one-way: nothing in the catalog should sit in a lower
        // tier yet require a local-only capability. (Equivalent to the
        // consistency check, asserted from the dependency direction.)
        for s in FeatureLocalityCatalog.surfaces where s.tier < .localOnlySwift {
            let pinsLocal = s.dependencies.contains { $0.minimumTier == .localOnlySwift }
            XCTAssertFalse(pinsLocal,
                           "\(s.id) is below local-only yet depends on a Mac-pinned capability")
        }
    }

    func test_everyTierIsPopulated() {
        for tier in FeatureTier.allCases {
            XCTAssertFalse(FeatureLocalityCatalog.surfaces(in: tier).isEmpty,
                           "tier \(tier.id) has no classified surface")
        }
    }

    func test_surfaceIdsAreUnique() {
        let ids = FeatureLocalityCatalog.surfaces.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate surface id in catalog")
    }

    func test_lookupRoundTrips() {
        XCTAssertEqual(FeatureLocalityCatalog.surface("git.client")?.tier, .hostOrchestrated)
        XCTAssertEqual(FeatureLocalityCatalog.surface("au.midi")?.tier, .localOnlySwift)
        XCTAssertEqual(FeatureLocalityCatalog.surface("markdown.render")?.tier, .remoteableCore)
        XCTAssertNil(FeatureLocalityCatalog.surface("does.not.exist"))
    }

    // MARK: - Codable round-trip (so the catalog can feed diagnostics/docs)

    func test_surfaceCodableRoundTrip() throws {
        let original = FeatureLocalityCatalog.surface("fs.watch")!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeatureSurface.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
