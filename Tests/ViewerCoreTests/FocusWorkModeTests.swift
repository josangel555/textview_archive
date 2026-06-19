import XCTest
@testable import ViewerCore
import ViewerKit

/// Pure-logic tests for `FocusWorkMode` — the one-click workspace presets
/// (TSK-381). These cover the seam the future `View → Focus Mode` menu /
/// command-palette wiring will read from: the per-mode panel set, the
/// `PanelVisibilityOverrides` snapshot a mode produces, and the preferred-lens
/// resolution. Host-runnable (no UI), so they live in `ViewerCoreTests`.
final class FocusWorkModeTests: XCTestCase {

    // MARK: - Identity surfaces (menu / palette rows)

    /// Every mode needs a non-blank label + icon or its menu / palette row
    /// renders empty (same failure class as the sidebar rail buttons).
    func test_everyMode_hasNonEmptyDisplayNameAndImage() {
        for mode in FocusWorkMode.allCases {
            XCTAssertFalse(
                mode.displayName.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(mode) has an empty displayName — its menu row would be blank"
            )
            XCTAssertFalse(
                mode.systemImage.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(mode) has an empty systemImage — its menu row icon would be blank"
            )
        }
    }

    func test_displayNames_areUnique() {
        let names = FocusWorkMode.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "Two modes share a displayName — menu rows would be ambiguous: \(names)")
    }

    /// `id` is the raw value — pinned so a Codable / persistence consumer can
    /// rely on it.
    func test_id_isRawValue() {
        for mode in FocusWorkMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    /// Codable round-trip — a mode may be persisted (e.g. "remember last focus
    /// mode") so the wire form must survive encode→decode.
    func test_codable_roundTrip() throws {
        for mode in FocusWorkMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let back = try JSONDecoder().decode(FocusWorkMode.self, from: data)
            XCTAssertEqual(back, mode)
        }
    }

    // MARK: - Per-mode panel sets

    /// The file tree is the spatial anchor for every activity — pinned so a
    /// future tweak can't accidentally hide Files in a mode.
    func test_everyMode_includesFiles() {
        for mode in FocusWorkMode.allCases {
            XCTAssertTrue(mode.panels.contains(.files),
                          "\(mode) must include the Files tree")
        }
    }

    /// Each mode's panel set is a subset of the known registry — no mode may
    /// name a panel that isn't a real `SidebarPanelKind` (the type system
    /// already guarantees this, but pin the registry-coverage relationship so
    /// a future panel is consciously placed).
    func test_everyMode_panelsAreKnownRegistryKinds() {
        let known = Set(SidebarPanelRegistry.defaultOrder)
        for mode in FocusWorkMode.allCases {
            XCTAssertTrue(mode.panels.isSubset(of: known),
                          "\(mode) names a panel outside the registry")
        }
    }

    /// Pin the concrete curation per mode — this is the product contract a
    /// reviewer eyeballs, and a regression here silently changes what the user
    /// sees when they pick a mode.
    func test_panelSets_areExpected() {
        XCTAssertEqual(FocusWorkMode.coding.panels,
                       [.files, .lspOutline, .lspProblems])
        XCTAssertEqual(FocusWorkMode.codeReading.panels,
                       [.files, .lspOutline, .lspNavigation])
        XCTAssertEqual(FocusWorkMode.docReading.panels,
                       [.files, .bookmarks])
        XCTAssertEqual(FocusWorkMode.gitHistory.panels,
                       [.files, .git])
        XCTAssertEqual(FocusWorkMode.gitDiff.panels,
                       [.files, .git])
        XCTAssertEqual(FocusWorkMode.codeReview.panels,
                       [.files, .git, .lspProblems])
    }

    // MARK: - panelOverrides() snapshot

    /// The snapshot forces RELEVANT panels `.shown` and EVERY other panel
    /// `.hidden` — no panel is left `.auto`, so the layout is deterministic
    /// regardless of data-presence (the whole point of a focus mode).
    func test_panelOverrides_showsRelevant_hidesRest_explicitly() {
        for mode in FocusWorkMode.allCases {
            let ov = mode.panelOverrides()
            for kind in SidebarPanelRegistry.defaultOrder {
                let expected: PanelOverride = mode.panels.contains(kind) ? .shown : .hidden
                XCTAssertEqual(ov.state(kind), expected,
                               "\(mode): panel \(kind) should be \(expected)")
                XCTAssertNotEqual(ov.state(kind), .auto,
                                  "\(mode): panel \(kind) must be explicit, not .auto")
            }
        }
    }

    /// The overrides drive the resolver to actual on-screen visibility: a
    /// relevant panel is visible even with NO data (`.shown` wins over the
    /// heuristic), and an irrelevant panel is hidden even WITH data
    /// (`.hidden` wins). This is the behaviour a user feels.
    func test_panelOverrides_driveResolverVisibility() {
        let ov = FocusWorkMode.gitHistory.panelOverrides()
        // Git is relevant → visible even though we claim no repo data present.
        XCTAssertTrue(PanelVisibilityResolver.isVisible(
            .git, override: ov.state(.git), dataPresent: false))
        // Outline is irrelevant → hidden even though data is present.
        XCTAssertFalse(PanelVisibilityResolver.isVisible(
            .lspOutline, override: ov.state(.lspOutline), dataPresent: true))
    }

    /// The snapshot persists through the same `UserDefaults` round-trip the
    /// rail toggles use — applying a focus mode reuses the existing
    /// persistence surface, no new key.
    func test_panelOverrides_persistRoundTrip() {
        let suite = "FocusWorkModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let ov = FocusWorkMode.codeReview.panelOverrides()
        ov.save(to: defaults)
        let loaded = PanelVisibilityOverrides.load(from: defaults)
        XCTAssertEqual(loaded, ov)
        // Spot-check the contract survived the disk hop.
        XCTAssertEqual(loaded.state(.git), .shown)
        XCTAssertEqual(loaded.state(.lspProblems), .shown)
        XCTAssertEqual(loaded.state(.bookmarks), .hidden)
    }

    /// A panel registered AFTER a mode was authored (not in any mode's set)
    /// must be HIDDEN by the snapshot, never silently left visible — we iterate
    /// the full `order`, so an unknown future panel defaults to hidden.
    func test_panelOverrides_unlistedPanel_isHidden() {
        // `pluginSections` is in no mode's curated set today.
        let ov = FocusWorkMode.coding.panelOverrides()
        XCTAssertEqual(ov.state(.pluginSections), .hidden)
        XCTAssertFalse(PanelVisibilityResolver.isVisible(
            .pluginSections, override: ov.state(.pluginSections), dataPresent: true))
    }

    // MARK: - preferredMode / appliedMode lens resolution

    func test_preferredModes_areExpected() {
        XCTAssertEqual(FocusWorkMode.coding.preferredMode, .editor)
        XCTAssertEqual(FocusWorkMode.codeReading.preferredMode, .source)
        XCTAssertEqual(FocusWorkMode.docReading.preferredMode, .rendered)
        XCTAssertEqual(FocusWorkMode.gitHistory.preferredMode, .source)
        XCTAssertEqual(FocusWorkMode.gitDiff.preferredMode, .diff)
        XCTAssertEqual(FocusWorkMode.codeReview.preferredMode, .diff)
    }

    /// `appliedMode` returns the preferred lens only when the file supports it.
    func test_appliedMode_returnsPreferred_whenAvailable() {
        let avail: [ViewMode] = [.source, .editor, .hex]
        XCTAssertEqual(FocusWorkMode.coding.appliedMode(available: avail), .editor)
        XCTAssertEqual(FocusWorkMode.codeReading.appliedMode(available: avail), .source)
    }

    /// When the preferred lens isn't reachable for the file, `appliedMode`
    /// returns nil so the caller leaves the file on its own default — applying
    /// a focus mode never forces a file into a lens it can't render.
    func test_appliedMode_returnsNil_whenUnavailable() {
        // A plain text file: no diff, no rendered lens.
        let avail: [ViewMode] = [.source, .editor, .hex]
        XCTAssertNil(FocusWorkMode.gitDiff.appliedMode(available: avail))
        XCTAssertNil(FocusWorkMode.docReading.appliedMode(available: avail))
        XCTAssertNil(FocusWorkMode.codeReview.appliedMode(available: avail))
    }

    /// Concrete end-to-end: a markdown file (rendered + source + editor + hex)
    /// under Doc Reading lands on Rendered; under Coding lands on Editor.
    func test_appliedMode_concrete_markdownFile() {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let avail = ViewModeOptions.availableModes(for: url)
        XCTAssertEqual(FocusWorkMode.docReading.appliedMode(available: avail), .rendered)
        XCTAssertEqual(FocusWorkMode.coding.appliedMode(available: avail), .editor)
    }

    /// Concrete end-to-end: a `.diff` file under Code Review / Git Diff lands
    /// on the Diff lens.
    func test_appliedMode_concrete_diffFile() {
        let url = URL(fileURLWithPath: "/tmp/change.diff")
        let avail = ViewModeOptions.availableModes(for: url)
        XCTAssertEqual(FocusWorkMode.codeReview.appliedMode(available: avail), .diff)
        XCTAssertEqual(FocusWorkMode.gitDiff.appliedMode(available: avail), .diff)
    }
}
