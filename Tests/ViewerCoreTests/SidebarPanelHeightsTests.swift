import XCTest
import CoreGraphics
@testable import ViewerCore

/// Host-side pure-logic tests for the resizable sidebar sections
/// model. Drag-handle / cursor interaction is exercised by the
/// VM-only UI test bundles — see `ResizableSectionDivider.swift`.
final class SidebarPanelHeightsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SidebarPanelHeightsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: clamp

    func test_clamp_returnsFloor_whenInputBelowMinimum() {
        XCTAssertEqual(SidebarPanelHeights.clamp(0),
                       SidebarPanelHeights.minExpandedHeight)
        XCTAssertEqual(SidebarPanelHeights.clamp(40),
                       SidebarPanelHeights.minExpandedHeight)
        XCTAssertEqual(SidebarPanelHeights.clamp(-50),
                       SidebarPanelHeights.minExpandedHeight)
    }

    func test_clamp_passesThrough_whenInputAboveMinimum() {
        XCTAssertEqual(SidebarPanelHeights.clamp(120), 120)
        XCTAssertEqual(SidebarPanelHeights.clamp(400), 400)
    }

    func test_clamp_atFloor_isIdentity() {
        let floor = SidebarPanelHeights.minExpandedHeight
        XCTAssertEqual(SidebarPanelHeights.clamp(floor), floor)
    }

    // MARK: window-derived ceiling (P1 — tool-window bounding)

    /// With no measured height (the first pre-measurement body pass), the
    /// ceiling is disabled and the clamp falls back to the floored stored
    /// height — identical to the plain `clamp`.
    func test_clampWithCeiling_unmeasured_fallsBackToStored() {
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: 0), 220)
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: -10), 220)
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: .infinity), 220)
        // Still floors a too-small stored value.
        XCTAssertEqual(
            SidebarPanelHeights.clamp(40, availableHeight: 0),
            SidebarPanelHeights.minExpandedHeight)
    }

    /// A roomy sidebar (the ceiling exceeds the stored height) leaves the
    /// stored height untouched — appearance preserved when panels fit.
    func test_clampWithCeiling_roomy_keepsStoredHeight() {
        // 1000pt sidebar, fraction 0.5 → ceiling 500 > 220 stored.
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: 1000, fraction: 0.5),
            220)
    }

    /// A cramped sidebar (the ceiling is below the stored height) shrinks
    /// the panel down to the ceiling — the dynamic bounding the owner asked
    /// for ("derived from window size").
    func test_clampWithCeiling_cramped_shrinksToCeiling() {
        // 300pt sidebar, fraction 0.5 → ceiling 150 < 220 stored.
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: 300, fraction: 0.5),
            150)
    }

    /// The ceiling itself never drops a single panel below the floor — even
    /// a tiny sidebar keeps each panel at `minExpandedHeight` (multi-panel
    /// overflow is absorbed by the accordion scroll, not by squeezing a
    /// panel to nothing).
    func test_clampWithCeiling_neverBelowFloor() {
        // 100pt sidebar, fraction 0.5 → raw ceiling 50, floored to 120.
        XCTAssertEqual(
            SidebarPanelHeights.clamp(220, availableHeight: 100, fraction: 0.5),
            SidebarPanelHeights.minExpandedHeight)
        // Even with a stored value below the floor + a tiny sidebar.
        XCTAssertEqual(
            SidebarPanelHeights.clamp(40, availableHeight: 100, fraction: 0.5),
            SidebarPanelHeights.minExpandedHeight)
    }

    /// Monotonic: a taller sidebar never yields a shorter panel ceiling.
    func test_clampWithCeiling_monotonicInAvailableHeight() {
        let small = SidebarPanelHeights.clamp(220, availableHeight: 300, fraction: 0.5)
        let mid = SidebarPanelHeights.clamp(220, availableHeight: 500, fraction: 0.5)
        let big = SidebarPanelHeights.clamp(220, availableHeight: 1000, fraction: 0.5)
        XCTAssertLessThanOrEqual(small, mid)
        XCTAssertLessThanOrEqual(mid, big)
    }

    // MARK: read-back

    func test_readClamped_returnsDefault_whenKeyMissing() {
        let value = SidebarPanelHeights.readClamped(.bookmarks, from: defaults)
        XCTAssertEqual(value, SidebarPanel.bookmarks.defaultHeight)
    }

    /// The whole point of the clamp-on-read: a hand-edited defaults
    /// plist (or a stale value from an older build with a lower
    /// floor) shouldn't be able to push the section below the
    /// minimum.
    func test_readClamped_clampsTooSmallPersistedValue_toFloor() {
        defaults.set(20.0, forKey: SidebarPanel.bookmarks.appStorageKey)
        let value = SidebarPanelHeights.readClamped(.bookmarks, from: defaults)
        XCTAssertEqual(value, SidebarPanelHeights.minExpandedHeight)
    }

    func test_readClamped_passesThroughLegalPersistedValue() {
        defaults.set(180.0, forKey: SidebarPanel.searchAnywhere.appStorageKey)
        let value = SidebarPanelHeights.readClamped(.searchAnywhere, from: defaults)
        XCTAssertEqual(value, 180.0)
    }

    // MARK: section identity

    /// Persistence keys are a public contract — renaming any of them
    /// invalidates per-user layout state. Pin them with a test so the
    /// rename can't slip through.
    func test_appStorageKeys_are_stable() {
        XCTAssertEqual(SidebarPanel.bookmarks.appStorageKey,
                       "MarkdownViewer.sidebar.bookmarks.height")
        XCTAssertEqual(SidebarPanel.searchAnywhere.appStorageKey,
                       "MarkdownViewer.sidebar.searchAnywhere.height")
        XCTAssertEqual(SidebarPanel.gitPanel.appStorageKey,
                       "MarkdownViewer.sidebar.gitPanel.height")
        XCTAssertEqual(SidebarPanel.claudeTimeline.appStorageKey,
                       "MarkdownViewer.sidebar.claudeTimeline.height")
        XCTAssertEqual(SidebarPanel.lspOutline.appStorageKey,
                       "MarkdownViewer.sidebar.lspOutline.height")
        XCTAssertEqual(SidebarPanel.recentlyOpened.appStorageKey,
                       "MarkdownViewer.sidebar.recentlyOpened.height")
        XCTAssertEqual(SidebarPanel.pluginSections.appStorageKey,
                       "MarkdownViewer.sidebar.pluginSections.height")
    }

    func test_minExpandedHeight_isAround120() {
        // Sanity: should comfortably fit a section header + a couple
        // of rows + the "(empty)" placeholder so empty panels still
        // feel substantial. Bumped from 80 → 120 in 2026-05 alongside
        // the fixed-envelope change. Pinned with a window rather than
        // an exact match so future tuning has wiggle room without a
        // separate test edit.
        XCTAssertGreaterThanOrEqual(SidebarPanelHeights.minExpandedHeight, 100)
        XCTAssertLessThanOrEqual(SidebarPanelHeights.minExpandedHeight, 160)
    }

    /// Verify a sub-floor persisted value clamps to the new 120 floor
    /// (not the legacy 80). Catches accidental floor reverts.
    func test_readClamped_usesNewFloor_notLegacyFloor() {
        defaults.set(80.0, forKey: SidebarPanel.bookmarks.appStorageKey)
        let value = SidebarPanelHeights.readClamped(.bookmarks, from: defaults)
        XCTAssertEqual(value, SidebarPanelHeights.minExpandedHeight)
        XCTAssertGreaterThanOrEqual(value, 120)
    }
}
