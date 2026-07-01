import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-1303 — pure-data persistence coverage for the per-image-tab edit state
/// `TabSnapshot.imageEditState`, the durable half of the "image edits lost on
/// session switch" fix. Host-safe (pure Codable, no UI, no FS — round-trips
/// through `Data`). Mirrors the additive-optional / downgrade-safe contract
/// already pinned for `scrollTopLine` (`TabSnapshotScrollPersistenceTests`):
///
///   - a concrete edit state survives a `TabSnapshot` round-trip;
///   - a `nil` edit state OMITS the JSON key entirely (clean wire shape) — NOT
///     a literal `null`;
///   - a legacy on-disk tab (no `imageEditState` key) decodes to nil = no
///     restore (forward-compat downgrade guard);
///   - the edit state survives a FULL `SessionSnapshot` round-trip and a
///     differing edit state is detected by `hasSamePersistedContent` (so the
///     autosave equality guard schedules a write when the user edits an image).
///
/// This is the SERIALIZATION proof — that image edits round-trip through the
/// session snapshot. The live capture/restore wiring (dict ↔ tab fold) is
/// exercised by the model + view slices; the view↔model binding is VM-validated.
final class TabSnapshotImageEditStatePersistenceTests: XCTestCase {

    /// A non-default edit state so a dropped field is caught by the round-trip.
    private func sampleState() -> ImageEditState {
        ImageEditState(brightness: 0.5, contrast: 1.2, saturation: 0.8,
                       exposureEV: 0.3, shadow: 0.1, highlight: 0.9, sharpness: 0.2)
    }

    // MARK: - TabSnapshot round-trip

    func test_imageEditState_roundTrips() throws {
        let state = sampleState()
        let snap = TabSnapshot(path: "/tmp/pic.png", viewMode: "source",
                               imageEditState: state)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.imageEditState, state)
        // TEETH: the scalar tone values must survive exactly, not reset to defaults.
        XCTAssertEqual(back.imageEditState?.brightness, 0.5)
        XCTAssertEqual(back.imageEditState?.contrast, 1.2)
    }

    func test_imageEditState_coexistsWithScrollAndUnsaved() throws {
        // All additive-optional fields present at once must round-trip independently.
        let snap = TabSnapshot(path: "/tmp/pic.png", viewMode: "source",
                               scrollTopLine: 7,
                               unsavedText: "draft",
                               imageEditState: sampleState())
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(back.scrollTopLine, 7)
        XCTAssertEqual(back.unsavedText, "draft")
        XCTAssertEqual(back.imageEditState, sampleState())
    }

    // MARK: - nil → key omitted (not `null`)

    func test_nilImageEditState_omitsKeyOnWire() throws {
        let snap = TabSnapshot(path: "/tmp/a.md", viewMode: "rendered")
        let json = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        XCTAssertFalse(json.contains("imageEditState"),
                       "nil imageEditState must omit the key, got: \(json)")
    }

    func test_explicitNullJSON_decodesToNil() throws {
        let withNull = #"{"path":"/tmp/a.png","viewMode":"source","imageEditState":null}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(withNull.utf8))
        XCTAssertNil(snap.imageEditState)
    }

    // MARK: - Legacy decode (downgrade guard)

    func test_legacyJSON_withoutImageEditStateKey_decodesToNil() throws {
        // A pre-TSK-1303 tab has no `imageEditState` key — must decode fine with
        // the synthesized optional defaulting to nil (no restore).
        let legacy = #"{"path":"/tmp/x.png","viewMode":"source"}"#
        let snap = try JSONDecoder().decode(TabSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.path, "/tmp/x.png")
        XCTAssertNil(snap.imageEditState)
    }

    // MARK: - Full SessionSnapshot round-trip + equality guard

    func test_sessionSnapshot_carriesImageEditState_andComparesEqual() throws {
        let tabs = [
            TabSnapshot(path: "/tmp/pic.png", viewMode: "source",
                        imageEditState: sampleState()),
            TabSnapshot(path: "/tmp/b.md", viewMode: "rendered"),  // nil edit state
        ]
        let session = SessionSnapshot(
            id: UUID(), displayName: "S", createdAt: Date(),
            lastActiveAt: Date(), sidebarRootPath: "/tmp",
            openTabs: tabs, selectedTabIndex: 0)
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(back.openTabs.count, 2)
        XCTAssertEqual(back.openTabs[0].imageEditState, sampleState())
        XCTAssertNil(back.openTabs[1].imageEditState)
        // imageEditState rides `openTabs`, which `hasSamePersistedContent`
        // compares — a clean round-trip is identical content.
        XCTAssertTrue(back.hasSamePersistedContent(as: session))
    }

    func test_sessionSnapshot_differingImageEditState_isNotEqualContent() {
        // Same identity + timestamps, only the image edit state differs → must be
        // detected as a real content change so the autosave fires (else the user's
        // edit is never persisted — the bug).
        let pinned = Date(timeIntervalSince1970: 0)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        func session(_ brightness: Double) -> SessionSnapshot {
            SessionSnapshot(
                id: id, displayName: "S", createdAt: pinned, lastActiveAt: pinned,
                sidebarRootPath: nil,
                openTabs: [TabSnapshot(path: "/tmp/pic.png", viewMode: "source",
                                       imageEditState: ImageEditState(brightness: brightness))],
                selectedTabIndex: 0)
        }
        XCTAssertFalse(session(0.0).hasSamePersistedContent(as: session(0.5)),
                       "an image-edit change is a persisted-content change")
    }
}
