import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 tests for the source-view find bar. NSTextView's `usesFindBar`
/// and `isIncrementalSearchingEnabled` flags control whether the bar
/// is available; we assert those flags propagate correctly.
///
/// Find behavior itself (next/prev, regex, case) is provided by
/// AppKit's NSTextFinder; we don't re-test that — we only verify the
/// wiring (NSTextView is configured to use the find bar).
@MainActor
final class FindBarTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FindBar-\(UUID().uuidString)"
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

    private func renderHost<V: View>(_ view: V) -> NSView {
        _ = NSApplication.shared
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(origin: .zero, size: NSSize(width: 1200, height: 800))
        h.layoutSubtreeIfNeeded()
        return h
    }

    private func descendants(of view: NSView) -> [NSView] {
        var out: [NSView] = [view]
        for s in view.subviews { out.append(contentsOf: descendants(of: s)) }
        return out
    }

    func test_sourceView_nsTextView_usesFindBar() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("find.xml")
        try "<root>\n<a/>\n<b/>\n</root>\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        guard let tv = descendants(of: host).compactMap({ $0 as? NSTextView }).first else {
            return XCTFail("No NSTextView found for source view")
        }
        XCTAssertTrue(tv.usesFindBar,
            "NSTextView must have usesFindBar=true for ⌘F to show the find bar")
        XCTAssertTrue(tv.isIncrementalSearchingEnabled,
            "Incremental searching should be enabled so the field highlights matches as you type")
    }

    func test_sourceView_nsTextView_isResponderForFindAction() throws {
        // NSTextView responds to performFindPanelAction(_:) which is what
        // the Edit > Find menu sends. Without this, ⌘F would beep.
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("find.xml")
        try "<root>\n<a>findme</a>\n</root>\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let host = renderHost(ContentView(model: model))
        guard let tv = descendants(of: host).compactMap({ $0 as? NSTextView }).first else {
            return XCTFail("No NSTextView found")
        }
        XCTAssertTrue(tv.responds(to: #selector(NSTextView.performFindPanelAction(_:))),
            "NSTextView must respond to performFindPanelAction:")
    }
}
