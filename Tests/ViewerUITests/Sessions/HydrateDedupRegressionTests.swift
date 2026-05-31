import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// End-to-end host-safe regression for TRACE #188 (launch-memory ratchet),
/// reproducing the ORIGINAL trigger through the real restore path
/// (`SessionState.hydrate` → `DocumentModel.appendLazyTab`) and asserting the
/// dedup invariant now blocks recurrence.
///
/// THE TRIGGER (root cause, pre-`41e21f2`): `appendLazyTab` (restore) stored
/// the NORMALIZED url (`standardizedFileURL.resolvingSymlinksInPath`); the
/// eager open path (`open(url:)` → `openOrReveal`) deduped on RAW url equality.
/// On macOS the same physical file is reachable as both `/var/…` and
/// `/private/var/…` (the `/var → /private/var` symlink under which every
/// `/var/folders/…` scratch root and `/tmp` live). The two forms are unequal
/// under raw `==` but EQUAL under `dedupKey`. So re-opening a restored file via
/// the OTHER form spawned a SECOND tab; `makeSnapshot` re-persisted it; the
/// next launch hydrated 2 and re-touched the focused one → 3 → … a one-way
/// ratchet that grew ~35 unique files to ~1951 tabs. The fix funnels every
/// open/restore path through `TabsState.dedupKey` and made `appendLazyTab`
/// itself idempotent.
///
/// We reproduce the asymmetry with REAL temp files referenced via both their
/// natural `/var/…` path and the `/private/var/…` twin (the `/private` prefix)
/// — `resolvingSymlinksInPath` only collapses symlink components that exist on
/// disk, so a real file is required. No NSApplication / window — pure model.
/// Host-safe (same category as the existing `SessionStateTests`).
/// Filter: `swift test --filter ViewerUITests.HydrateDedupRegressionTests`
@MainActor
final class HydrateDedupRegressionTests: XCTestCase {

    private lazy var tmp: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HydrateDedup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var created = false

    override func setUp() async throws { _ = tmp; created = true }
    override func tearDown() async throws {
        if created { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Create a real file at `name` under `tmp`; return its natural `/var/…`
    /// URL and the `/private/var/…` twin pointing at the same bytes.
    private func makeTwinned(_ name: String, _ body: String = "x") throws
        -> (varForm: URL, privateForm: URL) {
        let varForm = tmp.appendingPathComponent(name)
        try body.write(to: varForm, atomically: true, encoding: .utf8)
        let privateForm = URL(fileURLWithPath: "/private" + varForm.path)
        return (varForm, privateForm)
    }

    /// Skip on hosts where the `/var↔/private/var` shape (and its `dedupKey`
    /// collapse) isn't present — the trigger can't be reproduced there.
    private func requireVarSymlink(_ v: URL, _ p: URL) throws {
        try XCTSkipUnless(
            v.path.hasPrefix("/var/")
                && FileManager.default.fileExists(atPath: p.path)
                && TabsState.dedupKey(v) == TabsState.dedupKey(p),
            "host temp dir is not /var↔/private/var symlinked; trigger can't be reproduced")
    }

    private func makeModelAndSession() -> (DocumentModel, SessionState) {
        let model = DocumentModel()
        let state = SessionState(rootURL: tmp, displayName: "S", model: model)
        return (model, state)
    }

    // MARK: the trigger — hydrate then re-open via the OTHER form

    /// Hydrate restores a tab for `/var/…/doc.md`; the user then re-opens the
    /// SAME file via its `/private/var/…` twin. Post-fix: exactly one tab.
    /// Pre-`41e21f2`: two.
    func test_trigger_hydrateThenOtherFormReopen_staysOneTab() throws {
        let (varForm, privateForm) = try makeTwinned("doc.md", "# hi\n")
        try requireVarSymlink(varForm, privateForm)

        let (model, state) = makeModelAndSession()
        state.hydrate(from: SessionSnapshot(
            id: state.id, displayName: "S",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmp.path,
            openTabs: [TabSnapshot(path: varForm.path, viewMode: "source")],
            selectedTabIndex: 0))
        XCTAssertEqual(model.tabs.tabs.count, 1, "restore appends exactly one tab")

        // Re-open via the /private/var twin (an NSOpenPanel/realpath flow form).
        model.open(url: privateForm)
        XCTAssertEqual(model.tabs.tabs.count, 1,
            "#188 trigger: other-form re-open of a restored tab must NOT duplicate")
    }

    /// The multi-launch ratchet, simulated as repeated other-form re-opens
    /// after a single restore. Each iteration is one "launch step"; the count
    /// must never climb past 1.
    func test_ratchet_repeatedOtherFormReopens_neverGrow() throws {
        let (varForm, privateForm) = try makeTwinned("ratchet.md")
        try requireVarSymlink(varForm, privateForm)

        let (model, state) = makeModelAndSession()
        state.hydrate(from: SessionSnapshot(
            id: state.id, displayName: "S",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmp.path,
            openTabs: [TabSnapshot(path: varForm.path, viewMode: "source")],
            selectedTabIndex: 0))

        for step in 0..<25 {
            // Alternate the form on each "launch" — the exact compounding motion.
            model.open(url: step.isMultiple(of: 2) ? privateForm : varForm)
            XCTAssertEqual(model.tabs.tabs.count, 1,
                "launch step \(step): the ratchet must not advance")
        }
    }

    /// A snapshot that ALREADY accumulated duplicate entries (both forms of the
    /// same file, plus an exact dup) — the on-disk state of an already-bloated
    /// session — heals to a single tab on hydrate, never re-materializing it.
    func test_hydrate_alreadyBloatedSnapshot_healsToUnique() throws {
        let (varForm, privateForm) = try makeTwinned("bloat.md")
        try requireVarSymlink(varForm, privateForm)
        let normalizedPath = TabsState.dedupKey(varForm).path

        let (model, state) = makeModelAndSession()
        let snap = SessionSnapshot(
            id: state.id, displayName: "S",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmp.path,
            openTabs: [
                TabSnapshot(path: varForm.path, viewMode: "source"),
                TabSnapshot(path: privateForm.path, viewMode: "rendered"),
                TabSnapshot(path: varForm.path, viewMode: "rendered"),
            ],
            selectedTabIndex: 2)

        state.hydrate(from: snap)
        XCTAssertEqual(model.tabs.tabs.count, 1,
            "a bloated snapshot of one file must hydrate to a single tab")
        XCTAssertEqual(model.tabs.selected?.url?.path, normalizedPath,
            "the survivor carries the normalized path appendLazyTab stores")
    }

    /// Round-trip self-heal: hydrate a bloated snapshot, then re-serialize.
    /// The freshly written snapshot must be the deduped form — the mechanism
    /// that shrinks the owner's 1951-tab file back to its unique set on the
    /// next clean write.
    func test_roundTrip_bloatedSnapshotHealsOnReserialize() throws {
        let (aVar, aPriv) = try makeTwinned("a.md", "a")
        let (_, bPriv) = try makeTwinned("b.md", "b")   // reference b via its /private twin
        try requireVarSymlink(aVar, aPriv)

        let (_, state) = makeModelAndSession()
        // Two unique files, each persisted 4× across both forms → 8 entries.
        var bloated: [TabSnapshot] = []
        for _ in 0..<4 {
            bloated.append(TabSnapshot(path: aVar.path, viewMode: "source"))
            bloated.append(TabSnapshot(path: bPriv.path, viewMode: "source"))
        }
        state.hydrate(from: SessionSnapshot(
            id: state.id, displayName: "S",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmp.path,
            openTabs: bloated, selectedTabIndex: 0))

        let healed = state.makeSnapshot()
        XCTAssertEqual(healed.openTabs.count, 2,
            "re-serialized snapshot heals 8 bloated entries to the 2 unique files")
        XCTAssertEqual(Set(healed.openTabs.map { $0.path }).count, 2)
    }
}
