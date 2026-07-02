import XCTest

@testable import ViewerCore

/// Canvas M2.S2 (TSK-1367): the lifecycle registry — create/open/save/close,
/// stable ids, double-open dedupe, canonical-byte saves through the editor's
/// atomic writer. Host-safe (temp dir, real engine).
@MainActor
final class CanvasDocumentStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func test_create_build_save_reopen_round_trip_with_rekey() throws {
        let store = CanvasDocumentStore()
        let doc = try store.create()
        XCTAssertEqual(doc.id, "untitled-1")
        _ = try doc.adapter.applyDSL(baseRev: 0, "text #t \"persist me\"")

        // Untitled save without a path is a typed error.
        XCTAssertThrowsError(try store.save(doc.id)) { error in
            guard case CanvasStoreError.untitledNeedsPath = error else {
                return XCTFail("expected untitledNeedsPath, got \(error)")
            }
        }

        // Save to a path: id RE-KEYS to the file path.
        let target = dir.appendingPathComponent("a.canvas")
        let saved = try store.save(doc.id, to: target)
        XCTAssertEqual(saved, target)
        XCTAssertThrowsError(try store.doc("untitled-1"), "old id retired")
        let rekeyed = try store.doc(CanvasDocumentStore.docID(for: target))
        XCTAssertEqual(rekeyed.url, target)

        // The bytes on disk are the engine's CANONICAL form.
        let onDisk = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(onDisk, try rekeyed.adapter.save(), "canonical bytes")

        // Close, reopen from disk — content identical.
        store.close(rekeyed.id)
        let reopened = try store.open(url: target)
        XCTAssertTrue(try reopened.adapter.html().contains(">persist me<"))
    }

    func test_double_open_dedupes_to_one_revision_stream() throws {
        let store = CanvasDocumentStore()
        let target = dir.appendingPathComponent("shared.canvas")
        let d = try store.create()
        _ = try store.save(d.id, to: target)

        let first = try store.open(url: target)
        let second = try store.open(url: target)
        XCTAssertTrue(first === second, "one engine doc per file")
        // A mutation through one handle is visible through the other.
        _ = try first.adapter.applyDSL(baseRev: 0, "text #x \"via first\"")
        XCTAssertTrue(try second.adapter.html().contains(">via first<"))
    }

    func test_typed_faults_for_bad_paths_and_unknown_docs() throws {
        let store = CanvasDocumentStore()
        XCTAssertThrowsError(try store.open(url: dir.appendingPathComponent("x.txt"))) {
            guard case CanvasStoreError.notCanvasFile = $0 else {
                return XCTFail("expected notCanvasFile, got \($0)")
            }
        }
        XCTAssertThrowsError(try store.open(url: dir.appendingPathComponent("missing.canvas"))) {
            guard case CanvasStoreError.loadFailed = $0 else {
                return XCTFail("expected loadFailed, got \($0)")
            }
        }
        // Corrupt JSON = typed loadFailed (never a crash).
        let bad = dir.appendingPathComponent("bad.canvas")
        try "not canvas json".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.open(url: bad)) {
            guard case CanvasStoreError.loadFailed = $0 else {
                return XCTFail("expected loadFailed, got \($0)")
            }
        }
        XCTAssertThrowsError(try store.doc("nope")) {
            guard case CanvasStoreError.unknownDoc(let msg) = $0 else {
                return XCTFail("expected unknownDoc, got \($0)")
            }
            XCTAssertTrue(msg.contains("open docs:"), "teaches what IS open")
        }
    }
}
