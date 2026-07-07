import XCTest
@testable import ViewerCore

/// TSK-1447 — host coverage for the HTTP client's persisted request-builder store:
/// history recording (dedup on content, cap, newest-first), named saves (update on
/// re-save, cap), deletes, and on-disk round-trips. Pure ViewerCore — no network,
/// no UI.
final class HTTPRequestStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-httpstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore(maxHistory: Int = 100, maxSaved: Int = 200,
                           clock: @escaping @Sendable () -> Date = { Date() }) -> HTTPRequestStore {
        HTTPRequestStore(
            historyURL: tmp.appendingPathComponent("history.json"),
            savedURL: tmp.appendingPathComponent("saved.json"),
            maxHistory: maxHistory, maxSaved: maxSaved, clock: clock)
    }

    private func req(_ url: String, method: HTTPMethod = .get, body: String = "") -> HTTPRequestModel {
        HTTPRequestModel(method: method, urlString: url, body: body)
    }

    // MARK: - History

    func test_recordHistory_newestFirst() {
        let store = makeStore()
        store.recordHistory(req("https://a.example"), status: 200)
        store.recordHistory(req("https://b.example"), status: 404)
        XCTAssertEqual(store.history.map { $0.request.urlString },
                       ["https://b.example", "https://a.example"], "newest-first")
        XCTAssertEqual(store.history.first?.status, 404)
    }

    func test_recordHistory_dedupesIdenticalContent_movesToFront() {
        let store = makeStore()
        store.recordHistory(req("https://a.example"), status: 200)
        store.recordHistory(req("https://b.example"), status: 200)
        // Re-send the SAME content as the older entry — dedupe, move to front.
        store.recordHistory(req("https://a.example"), status: 500)
        XCTAssertEqual(store.history.count, 2, "identical re-send does not duplicate (teeth)")
        XCTAssertEqual(store.history.first?.request.urlString, "https://a.example")
        XCTAssertEqual(store.history.first?.status, 500, "front entry carries the fresh status")
    }

    func test_recordHistory_differentBodyIsDistinct() {
        let store = makeStore()
        store.recordHistory(req("https://a.example", method: .post, body: "x=1"), status: 200)
        store.recordHistory(req("https://a.example", method: .post, body: "x=2"), status: 200)
        XCTAssertEqual(store.history.count, 2, "same URL but different body → distinct entries")
    }

    func test_recordHistory_capsAtMax_evictingOldest() {
        let store = makeStore(maxHistory: 3)
        for i in 0..<5 { store.recordHistory(req("https://h\(i).example"), status: 200) }
        XCTAssertEqual(store.history.count, 3, "capped to maxHistory")
        XCTAssertEqual(store.history.map { $0.request.urlString },
                       ["https://h4.example", "https://h3.example", "https://h2.example"],
                       "oldest evicted")
    }

    func test_clearHistory_empties() {
        let store = makeStore()
        store.recordHistory(req("https://a.example"), status: 200)
        store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
    }

    func test_deleteHistory_byID() {
        let store = makeStore()
        let e = store.recordHistory(req("https://a.example"), status: 200)
        store.recordHistory(req("https://b.example"), status: 200)
        store.deleteHistory(id: e.id)
        XCTAssertEqual(store.history.map { $0.request.urlString }, ["https://b.example"])
    }

    // MARK: - Saved

    func test_save_appendsNewestFirst_andReturnsEntry() {
        let store = makeStore()
        let a = store.save(name: "A", request: req("https://a.example"))
        let b = store.save(name: "B", request: req("https://b.example"))
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(store.saved.map(\.name), ["B", "A"], "newest-saved-first")
    }

    func test_save_sameNameUpdatesInPlace_noDuplicate() {
        let store = makeStore()
        let first = store.save(name: "Login", request: req("https://a.example"))
        let updated = store.save(name: "Login", request: req("https://a.example/v2"))
        XCTAssertEqual(store.saved.count, 1, "re-saving a name updates, not duplicates (teeth)")
        XCTAssertEqual(store.saved.first?.request.urlString, "https://a.example/v2")
        XCTAssertEqual(first?.id, updated?.id, "identity preserved across update")
    }

    func test_save_emptyNameRejected() {
        let store = makeStore()
        XCTAssertNil(store.save(name: "   ", request: req("https://a.example")),
                     "blank name is rejected")
        XCTAssertTrue(store.saved.isEmpty)
    }

    func test_save_capsAtMax() {
        let store = makeStore(maxSaved: 2)
        store.save(name: "A", request: req("https://a.example"))
        store.save(name: "B", request: req("https://b.example"))
        store.save(name: "C", request: req("https://c.example"))
        XCTAssertEqual(store.saved.map(\.name), ["C", "B"], "capped, oldest dropped")
    }

    func test_deleteSaved_byID() {
        let store = makeStore()
        let a = store.save(name: "A", request: req("https://a.example"))!
        store.save(name: "B", request: req("https://b.example"))
        store.deleteSaved(id: a.id)
        XCTAssertEqual(store.saved.map(\.name), ["B"])
    }

    // MARK: - Persistence round-trip

    func test_persistence_reloadsHistoryAndSaved() {
        let store = makeStore()
        store.recordHistory(req("https://a.example", method: .post, body: "b"), status: 201)
        store.save(name: "Saved", request: req("https://s.example"))
        store.flush()

        let reloaded = makeStore()  // reads the same files
        XCTAssertEqual(reloaded.history.first?.request.urlString, "https://a.example")
        XCTAssertEqual(reloaded.history.first?.status, 201)
        XCTAssertEqual(reloaded.history.first?.request.body, "b")
        XCTAssertEqual(reloaded.saved.map(\.name), ["Saved"])
        XCTAssertEqual(reloaded.saved.first?.request.urlString, "https://s.example")
    }

    // MARK: - Signature + displayLabel

    func test_signature_ignoresHeaderRowIDsAndTimeout() {
        // Same logical request built twice (fresh header UUIDs, different timeout)
        // must produce the same signature so history dedupes.
        let h1 = HTTPHeader(name: "Accept", value: "application/json")
        let h2 = HTTPHeader(name: "Accept", value: "application/json")
        let a = HTTPRequestModel(method: .get, urlString: "https://a.example",
                                 headers: [h1], body: "", timeout: 30)
        let b = HTTPRequestModel(method: .get, urlString: "https://a.example",
                                 headers: [h2], body: "", timeout: 99)
        XCTAssertNotEqual(h1.id, h2.id, "distinct row ids")
        XCTAssertEqual(HTTPRequestStore.signature(a), HTTPRequestStore.signature(b),
                       "signature ignores row ids + timeout")
    }

    func test_signature_headerValueChangesSignature() {
        let a = HTTPRequestModel(urlString: "https://a.example",
                                 headers: [HTTPHeader(name: "Accept", value: "text/html")])
        let b = HTTPRequestModel(urlString: "https://a.example",
                                 headers: [HTTPHeader(name: "Accept", value: "application/json")])
        XCTAssertNotEqual(HTTPRequestStore.signature(a), HTTPRequestStore.signature(b))
    }

    func test_historyEntry_displayLabel() {
        let withStatus = HTTPHistoryEntry(
            request: req("https://api.example.com/users?q=1", method: .post), status: 200)
        XCTAssertEqual(withStatus.displayLabel, "200 · POST api.example.com/users")
        let noStatus = HTTPHistoryEntry(request: req("https://api.example.com/", method: .get))
        XCTAssertEqual(noStatus.displayLabel, "GET api.example.com")
    }
}
