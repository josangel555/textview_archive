import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// L3 integration test for the file-watcher path: open a file, change
/// it externally, verify the model's `currentState` reflects the new
/// contents. Tests the wiring between `FileWatcher` and `DocumentModel`,
/// not just FileWatcher in isolation (that has unit tests in
/// `FileWatcherTests.swift`).
@MainActor
final class FileWatcherIntegrationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherInt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FileWatcherInt-\(UUID().uuidString)"
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

    private func write(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitFor(timeout: TimeInterval, until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return predicate()
    }

    func test_writeToOpenFile_reloadsContents() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("watched.md")
        try write(url, "# original\n")
        model.open(url: url)
        guard case .loaded(let original) = model.currentState else {
            return XCTFail("Initial open should be .loaded")
        }
        XCTAssertTrue(original.contents.contains("original"))

        // Wait a beat so the watcher has installed.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Overwrite the file via a fresh atomic write (mimics editor save).
        try write(url, "# updated\nbody\n")

        let didReload = await waitFor(timeout: 3.0) {
            if case .loaded(let f) = model.currentState,
               f.contents.contains("updated") { return true }
            return false
        }
        XCTAssertTrue(didReload,
            "DocumentModel should reload its contents within 3s of external write")
    }

    func test_appendToOpenFile_reloadsAndContentGrows() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("growing.md")
        try write(url, "# initial\n")
        model.open(url: url)
        guard case .loaded(let initial) = model.currentState else {
            return XCTFail("Initial state must be .loaded")
        }
        let initialLen = initial.contents.count
        try await Task.sleep(nanoseconds: 200_000_000)

        // Append additional content (this is a separate atomic write).
        try write(url, """
            # initial

            Appended paragraph.

            - bullet
            - bullet 2
            """)

        let grew = await waitFor(timeout: 3.0) {
            if case .loaded(let f) = model.currentState,
               f.contents.count > initialLen { return true }
            return false
        }
        XCTAssertTrue(grew,
            "DocumentModel should re-read the file and content should grow")
    }
}
