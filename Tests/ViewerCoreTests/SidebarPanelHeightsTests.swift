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

    // MARK: resize-jank suppression (TSK-592)

    /// The exact stored heights the sidebar feeds in (mirrors
    /// `SidebarView.accordionStoredHeights`): a mix at/below/above the
    /// default 220, so the predicate is exercised across regimes.
    private let storedHeights: [CGFloat] = [220, 220, 220, 220, 180, 180, 180, 220]

    /// In the roomy regime — the ceiling (`available * 0.5`) sits above
    /// every stored height — a per-frame resize delta changes NO panel's
    /// resolved height, so the commit must be suppressed. This is the core
    /// jank fix: most resize frames are dropped before touching @State.
    func test_shouldCommit_roomyRegime_suppressesNoOpResizeFrame() {
        // 900 → 880: ceiling 450 → 440, both still above max stored (220).
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 900, measured: 880, storedHeights: storedHeights))
        // A large drag entirely within the roomy band is still a no-op.
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 1200, measured: 600, storedHeights: storedHeights))
    }

    /// When the ceiling is actively shrinking the panels (cramped regime), a
    /// resize delta DOES change resolved heights — the commit must go
    /// through so the panels track the window.
    func test_shouldCommit_crampedRegime_commitsRealChange() {
        // 600 → 500: ceiling 300 → 250, both below the 220-tall panels' cap?
        // 300 > 220 so at 600 the 220 panels are unbound (==220); at 500 the
        // ceiling 250 still > 220 → unbound. Use a tighter pair that bites:
        // 400 → 360: ceiling 200 → 180; the 220-tall panels resolve 200 → 180.
        XCTAssertTrue(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 400, measured: 360, storedHeights: storedHeights))
    }

    /// Crossing the boundary between roomy and cramped (the ceiling drops
    /// below a stored height) must commit — that frame is where a panel
    /// first starts shrinking.
    func test_shouldCommit_crossingIntoCeiling_commits() {
        // 220-tall panel: ceiling binds when available*0.5 < 220, i.e.
        // available < 440. 460 (ceiling 230, unbound) → 420 (ceiling 210,
        // bound → 210) changes the resolved height.
        XCTAssertTrue(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 460, measured: 420, storedHeights: storedHeights))
    }

    /// In the pinned-at-floor regime (a tiny sidebar where every panel is
    /// already at `minExpandedHeight`) a further shrink can't lower any
    /// panel below the floor, so the frame is suppressed.
    func test_shouldCommit_pinnedAtFloor_suppresses() {
        // available 200 → 180: ceiling 100 → 90, both floored to 120 → every
        // panel resolves to 120 in both cases.
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 200, measured: 180, storedHeights: storedHeights))
    }

    /// The first real measurement after the pre-measurement zero pass must
    /// always commit — that's when the ceiling switches on.
    func test_shouldCommit_firstMeasurement_commits() {
        XCTAssertTrue(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 0, measured: 800, storedHeights: storedHeights))
        XCTAssertTrue(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: -5, measured: 800, storedHeights: storedHeights))
    }

    /// A measurement collapsing back to zero (e.g. the view leaving the
    /// hierarchy) commits so the ceiling disables and the stored fallback
    /// resumes.
    func test_shouldCommit_collapseToUnmeasured_commits() {
        XCTAssertTrue(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 800, measured: 0, storedHeights: storedHeights))
    }

    /// Two unusable heights → nothing to commit.
    func test_shouldCommit_bothUnusable_suppresses() {
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 0, measured: 0, storedHeights: storedHeights))
    }

    /// A non-finite measurement is never committed (NaN/inf from a degenerate
    /// layout pass must not poison the @State).
    func test_shouldCommit_nonFiniteMeasure_suppresses() {
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 800, measured: .infinity, storedHeights: storedHeights))
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 800, measured: .nan, storedHeights: storedHeights))
    }

    /// Sub-point resolved-height noise at a clamp boundary is suppressed —
    /// the predicate compares resolved heights, not raw measures, so float
    /// jitter near the ceiling doesn't re-body the sidebar.
    func test_shouldCommit_subPointResolvedDelta_suppresses() {
        // ceiling = available*0.5; a 0.4pt available change → 0.2pt ceiling
        // change, below heightCommitEpsilon (0.5). Pick available where the
        // ceiling binds the 220 panels (available < 440) so the resolved
        // height tracks the ceiling.
        XCTAssertFalse(
            SidebarPanelHeights.shouldCommitAvailableHeight(
                current: 400.0, measured: 400.4, storedHeights: storedHeights))
    }

    /// The predicate is consistent with the function it guards: whenever it
    /// returns `false`, every panel's `clamp(_:availableHeight:)` is
    /// unchanged across the two heights. Property-style sweep over a grid of
    /// (current, measured) pairs — the safety invariant of the optimization.
    func test_shouldCommit_falseImpliesNoResolvedHeightChange() {
        let grid: [CGFloat] = [0, 100, 120, 150, 200, 240, 300, 360, 400,
                               440, 480, 600, 800, 1000, 1400]
        for current in grid {
            for measured in grid {
                let commit = SidebarPanelHeights.shouldCommitAvailableHeight(
                    current: current, measured: measured, storedHeights: storedHeights)
                if !commit {
                    for stored in storedHeights {
                        let before = SidebarPanelHeights.clamp(
                            stored, availableHeight: current)
                        let after = SidebarPanelHeights.clamp(
                            stored, availableHeight: measured)
                        XCTAssertEqual(
                            before, after, accuracy: SidebarPanelHeights.heightCommitEpsilon,
                            "suppressed (current=\(current) measured=\(measured)) but "
                            + "stored=\(stored) resolved \(before) → \(after)")
                    }
                }
            }
        }
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

    // MARK: - fillHeight (owner 2026-08-09: panels capped at persisted height
    // stranded the rest of the shoulder when FILES is hidden)

    /// A lone short panel is RAISED to the leftover band — the dead-space bug.
    func test_fillHeight_raisesALoneShortPanel_toTheBand() {
        let h = SidebarPanelHeights.fillHeight(
            stored: 220, availableHeight: 1200,
            siblingResolvedHeights: [], chromePerPanel: 34, panelCount: 1)
        XCTAssertEqual(h, 1200 - 34, "a lone panel fills available minus its chrome")
    }

    /// A user-dragged height LARGER than the leftover still wins (fill never
    /// shrinks a panel).
    func test_fillHeight_keepsALargerStoredHeight() {
        let h = SidebarPanelHeights.fillHeight(
            stored: 900, availableHeight: 600,
            siblingResolvedHeights: [], chromePerPanel: 34, panelCount: 1)
        XCTAssertEqual(h, 900)
    }

    /// With siblings above, the fill target absorbs only what is left after
    /// their resolved bodies + everyone's chrome.
    func test_fillHeight_subtractsSiblingBodies_andChrome() {
        let h = SidebarPanelHeights.fillHeight(
            stored: 220, availableHeight: 1200,
            siblingResolvedHeights: [220, 180], chromePerPanel: 34, panelCount: 3)
        XCTAssertEqual(h, 1200 - 220 - 180 - 3 * 34)
    }

    /// Pre-measurement pass (no usable available height) falls back to the
    /// clamped stored height — same contract as the ceiling clamp.
    func test_fillHeight_unmeasuredAvailable_fallsBackToStored() {
        XCTAssertEqual(
            SidebarPanelHeights.fillHeight(
                stored: 220, availableHeight: 0,
                siblingResolvedHeights: [], chromePerPanel: 34, panelCount: 1),
            220)
        XCTAssertEqual(
            SidebarPanelHeights.fillHeight(
                stored: 60, availableHeight: .nan,
                siblingResolvedHeights: [], chromePerPanel: 34, panelCount: 1),
            SidebarPanelHeights.minExpandedHeight,
            "the stored fallback still honors the expanded floor")
    }

    /// A crowded band (siblings already exceed available) never returns less
    /// than the clamped stored height — overflow stays the scroll's job.
    func test_fillHeight_crowdedBand_keepsTheStoredFloor() {
        let h = SidebarPanelHeights.fillHeight(
            stored: 220, availableHeight: 500,
            siblingResolvedHeights: [400, 300], chromePerPanel: 34, panelCount: 3)
        XCTAssertEqual(h, 220)
    }
}
