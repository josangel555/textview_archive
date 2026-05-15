import XCTest
import Foundation
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 in-process tests for drag-and-drop. We don't simulate OS-level
/// drag events (that requires a UI test); instead we exercise the
/// model-side handler with NSItemProvider for file URLs and assert the
/// model's openPath was invoked.
@MainActor
final class DragDropTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragDrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DragDrop-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_drop_singleFile_opensIt() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("dropped.md")
        try "# dropped\n".write(to: url, atomically: true, encoding: .utf8)

        // The SwiftUI .onDrop receives [NSItemProvider]. Build one that
        // vends our URL via `registerObject(_:visibility:)`.
        let provider = NSItemProvider(object: url as NSURL)

        // Simulate the drop callback used in ContentView.handleDrop.
        // (We can't construct the View itself trivially; we replicate
        // the handler body here.)
        let didStart = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL else { cont.resume(returning: false); return }
                Task { @MainActor in
                    guard FileManager.default.fileExists(atPath: droppedURL.path) else {
                        cont.resume(returning: false); return
                    }
                    model.openPath(droppedURL)
                    cont.resume(returning: true)
                }
            }
        }
        XCTAssertTrue(didStart, "Drop handler should have invoked openPath")
        // Allow the openPath -> model state mutation to settle.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(model.tabs.tabs.count, 1, "Drop should have opened exactly one tab")
        guard case .loaded(let f) = model.currentState else {
            return XCTFail("Expected .loaded after drop. Got \(model.currentState)")
        }
        XCTAssertTrue(f.contents.contains("dropped"),
            "Loaded content should match the dropped file")
    }

    func test_drop_missingFile_doesNotOpen() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("not-there.md")
        let provider = NSItemProvider(object: url as NSURL)
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL else { cont.resume(); return }
                Task { @MainActor in
                    if FileManager.default.fileExists(atPath: droppedURL.path) {
                        model.openPath(droppedURL)
                    }
                    cont.resume()
                }
            }
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(model.tabs.tabs.count, 0,
            "Dropping a non-existent file path should not open a tab")
    }
}
