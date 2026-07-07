import XCTest
import ViewerCore
@testable import ViewerUI

/// Headless teeth for the HTTP client tool's view-model layer (TSK-721). The
/// SwiftUI rendering of `HTTPClientView` is VM-only (host can't prove pixels),
/// but the model-state transitions the form drives — add/remove header rows and
/// applying a send result (success → response set, failure → error set) — are
/// pure and pinned here so a logic regression fails the host gate.
///
/// Tier: window-free pure assertions — host-safe.
@MainActor
final class HTTPClientViewModelTests: XCTestCase {

    func test_addHeader_appendsBlankRow() {
        let vm = HTTPClientViewModel()
        XCTAssertTrue(vm.request.headers.isEmpty)
        vm.addHeader()
        XCTAssertEqual(vm.request.headers.count, 1)
        XCTAssertEqual(vm.request.headers[0].name, "")
        XCTAssertTrue(vm.request.headers[0].isEnabled)
    }

    func test_removeHeader_byID() {
        let vm = HTTPClientViewModel()
        vm.addHeader()
        vm.addHeader()
        let removeID = vm.request.headers[0].id
        let keepID = vm.request.headers[1].id
        vm.removeHeader(id: removeID)
        XCTAssertEqual(vm.request.headers.map { $0.id }, [keepID])
    }

    func test_removeHeader_unknownIDIsNoOp() {
        let vm = HTTPClientViewModel()
        vm.addHeader()
        vm.removeHeader(id: UUID())
        XCTAssertEqual(vm.request.headers.count, 1)
    }

    func test_applyResult_successSetsResponseClearsError() {
        let vm = HTTPClientViewModel()
        let response = HTTPResponseModel(
            statusCode: 200,
            headers: [HTTPResponseHeader(name: "Content-Type", value: "text/plain")],
            body: Data("hi".utf8),
            elapsed: 0.01)
        vm.applyResult(.success(response))
        XCTAssertEqual(vm.response?.statusCode, 200)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isSending)
    }

    func test_applyResult_failureSetsErrorClearsResponse() {
        let vm = HTTPClientViewModel()
        // Seed a prior response so we prove failure clears it.
        vm.applyResult(.success(HTTPResponseModel(
            statusCode: 200, headers: [], body: Data(), elapsed: 0)))
        vm.applyResult(.failure(.invalidURL("bad")))
        XCTAssertNil(vm.response)
        XCTAssertEqual(vm.errorMessage, HTTPRequestError.invalidURL("bad").message)
        XCTAssertFalse(vm.isSending)
    }

    func test_openHTTPClient_addsHostedTab() {
        let model = DocumentModel()
        let before = model.tabs.tabs.count
        let id = model.openHTTPClient()
        XCTAssertEqual(model.tabs.tabs.count, before + 1)
        // The hosted-view registry knows about the new tab's view.
        XCTAssertNotNil(model.hostedView(forID: id))
    }

    // MARK: - TSK-1447: history + save wiring

    private func makeTempStore() -> HTTPRequestStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-httpvm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HTTPRequestStore(
            historyURL: dir.appendingPathComponent("history.json"),
            savedURL: dir.appendingPathComponent("saved.json"))
    }

    func test_recordHistory_mirrorsStoreIntoPublished() {
        let vm = HTTPClientViewModel(store: makeTempStore())
        XCTAssertTrue(vm.history.isEmpty)
        vm.recordHistory(HTTPRequestModel(urlString: "https://a.example"), status: 200)
        XCTAssertEqual(vm.history.count, 1, "history mirror updated (teeth)")
        XCTAssertEqual(vm.history.first?.request.urlString, "https://a.example")
        XCTAssertEqual(vm.history.first?.status, 200)
    }

    func test_saveCurrent_savesEditorRequest_andLoadRestoresIt() {
        let vm = HTTPClientViewModel(store: makeTempStore())
        vm.request = HTTPRequestModel(method: .post, urlString: "https://save.example", body: "hi")
        vm.saveCurrent(name: "MySave")
        XCTAssertEqual(vm.saved.map(\.name), ["MySave"], "saved mirror updated")

        // Change the editor, then load the saved one back.
        vm.request = HTTPRequestModel(urlString: "https://other.example")
        vm.load(vm.saved[0].request)
        XCTAssertEqual(vm.request.urlString, "https://save.example")
        XCTAssertEqual(vm.request.method, .post)
        XCTAssertEqual(vm.request.body, "hi")
    }

    func test_saveCurrent_blankNameIsNoOp() {
        let vm = HTTPClientViewModel(store: makeTempStore())
        vm.request = HTTPRequestModel(urlString: "https://a.example")
        vm.saveCurrent(name: "   ")
        XCTAssertTrue(vm.saved.isEmpty, "blank save name does not create an entry")
    }

    func test_deleteSaved_updatesMirror() {
        let store = makeTempStore()
        let vm = HTTPClientViewModel(store: store)
        vm.request = HTTPRequestModel(urlString: "https://a.example")
        vm.saveCurrent(name: "A")
        let id = vm.saved[0].id
        vm.deleteSaved(id: id)
        XCTAssertTrue(vm.saved.isEmpty)
    }

    func test_clearHistory_updatesMirror() {
        let vm = HTTPClientViewModel(store: makeTempStore())
        vm.recordHistory(HTTPRequestModel(urlString: "https://a.example"), status: 200)
        XCTAssertFalse(vm.history.isEmpty)
        vm.clearHistory()
        XCTAssertTrue(vm.history.isEmpty)
    }

    func test_init_loadsExistingStoreState() {
        let store = makeTempStore()
        store.recordHistory(HTTPRequestModel(urlString: "https://seed.example"), status: 200)
        store.save(name: "Seed", request: HTTPRequestModel(urlString: "https://seed.example"))
        // A fresh VM over the same store surfaces the pre-existing state.
        let vm = HTTPClientViewModel(store: store)
        XCTAssertEqual(vm.history.first?.request.urlString, "https://seed.example")
        XCTAssertEqual(vm.saved.map(\.name), ["Seed"])
    }
}
