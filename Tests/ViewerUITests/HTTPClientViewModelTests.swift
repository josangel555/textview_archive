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
}
