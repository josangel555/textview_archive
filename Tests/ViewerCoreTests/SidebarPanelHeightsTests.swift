import XCTest
import CoreGraphics
@testable import ViewerCore

/// Host-side pure-logic tests for the resizable sidebar sections
/// model. Drag-handle / cursor interaction is exercised by the
/// VM-only UI test bundles — see `ResizableSectionDivider.swift`.
///
/// (The window-fraction ceiling + the TSK-592 commit-suppression
/// predicate — and their tests — were DELETED 2026-08-12 in the owner's
/// special-case sweep: the one-rule stack is floors-only with overflow
/// scrolling; `SidebarStackLayoutTests` covers the live layout math.)
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
