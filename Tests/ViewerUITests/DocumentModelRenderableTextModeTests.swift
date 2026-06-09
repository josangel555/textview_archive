import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host-tier teeth for TSK-332 — "default plain text, if only renderable ASCII".
///
/// The bug: an UNKNOWN-extension file whose bytes are actually renderable ASCII
/// opened in the HEX byte-grid (and the picker offered only HEX), because view-
/// mode resolution was extension-only and never consulted the loader's verdict.
/// `ViewModeOptions.{defaultMode,availableModes}` gained an `isRenderableText`
/// hint (unit-tested in `ViewModeMediaDefaultTests`), but no DocumentModel call
/// site THREADED it. These tests pin the threading at the model boundary: open a
/// real file and assert the resolved view mode, deriving the hint from the load
/// state (`.loaded` ⇒ text).
///
/// TEETH: before the threading, an unknown-ext ASCII file resolved to `.hex`
/// with `availableViewModes == [.hex]` — both asserts below FAIL pre-fix. The
/// binary contrast case (NUL bytes ⇒ `.binary` state ⇒ no hint) stays `.hex`,
/// proving the hint is content-driven, not blanket "unknown ⇒ source".
///
/// Tier: window-free (drives DocumentModel directly) — host-safe.
@MainActor
final class DocumentModelRenderableTextModeTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocModelRenderableText-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocModelRenderableText-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func writeBytes(_ name: String, _ data: Data) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - the fix

    /// An unknown-extension file whose bytes are renderable ASCII must open in
    /// Source (the loader returns `.loaded`, so the content hint upgrades the
    /// extension-only HEX default).
    func test_unknownExtAsciiText_opensAsSource_notHex() throws {
        let url = try writeBytes(
            "notes.xyzzy", Data("hello world\nthis is plain ascii text\n".utf8))
        // Precondition: the EXTENSION alone classifies this as .unknown, so the
        // un-hinted default would be HEX — this is the case the fix must flip.
        XCTAssertEqual(FileTypeDetector.category(for: url), .unknown,
                       "fixture must be .unknown by extension for this test to bite")

        let model = makeModel()
        model.open(url: url)

        XCTAssertEqual(model.tabs.selected?.viewMode, .source,
                       "unknown-ext ASCII content must open as Source, not the HEX grid")
        XCTAssertTrue(model.availableViewModes.contains(.source),
                      "the picker must offer Source so the resolved default is reachable")
        XCTAssertTrue(model.availableViewModes.contains(.hex),
                      "HEX stays available as the raw-bytes lens")
    }

    /// Contrast: an unknown-extension file with NUL bytes loads as `.binary`
    /// (no text hint), so it correctly stays HEX-only — the hint is content-
    /// driven, not a blanket "unknown extension ⇒ Source".
    func test_unknownExtBinary_staysHexOnly() throws {
        let url = try writeBytes(
            "blob.xyzzy", Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x10]))
        XCTAssertEqual(FileTypeDetector.category(for: url), .unknown)

        let model = makeModel()
        model.open(url: url)

        XCTAssertEqual(model.tabs.selected?.viewMode, .hex,
                       "binary (NUL) content must stay HEX — the text hint must not fire")
        XCTAssertEqual(model.availableViewModes, [.hex],
                       "no text hint ⇒ HEX-only picker for binary unknown-ext content")
    }

    /// The state→hint derivation in isolation: `.loaded` is the only positive
    /// text signal; every other state yields `nil` (leave the extension default).
    func test_renderableTextHint_onlyLoadedIsPositive() throws {
        let tf = TextFile(url: URL(fileURLWithPath: "/tmp/x"),
                          contents: "t", encoding: .utf8, byteCount: 1)
        XCTAssertEqual(DocumentModel.renderableTextHint(.loaded(tf)), true)
        XCTAssertNil(DocumentModel.renderableTextHint(.empty))
        XCTAssertNil(DocumentModel.renderableTextHint(.loading(URL(fileURLWithPath: "/tmp/x"))))
        XCTAssertNil(DocumentModel.renderableTextHint(nil))
    }
}
