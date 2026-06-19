import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ViewerCore

/// Teeth for the HTTP client foundation (TSK-721): request-building
/// (model → URLRequest), response-parsing (HTTPURLResponse + Data → model),
/// and error/edge cases (empty/invalid URL, unsupported scheme, non-HTTP
/// response, body suppression, timeout clamp, case-insensitive headers).
final class HTTPClientCoreTests: XCTestCase {

    // MARK: - Build: happy path

    func test_build_basicGET() throws {
        let model = HTTPRequestModel(method: .get, urlString: "https://example.com/api")
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api")
        XCTAssertNil(request.httpBody)
    }

    func test_build_trimsWhitespaceAroundURL() throws {
        let model = HTTPRequestModel(urlString: "  https://example.com  ")
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com")
    }

    func test_build_httpSchemeAllowed() throws {
        let model = HTTPRequestModel(urlString: "http://localhost:8080/health")
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.url?.scheme, "http")
    }

    // MARK: - Build: headers

    func test_build_appliesEnabledHeaders() throws {
        let model = HTTPRequestModel(
            urlString: "https://example.com",
            headers: [
                HTTPHeader(name: "Authorization", value: "Bearer abc"),
                HTTPHeader(name: "Accept", value: "application/json"),
            ]
        )
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_build_skipsDisabledHeaders() throws {
        let model = HTTPRequestModel(
            urlString: "https://example.com",
            headers: [HTTPHeader(name: "X-Skip", value: "no", isEnabled: false)]
        )
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Skip"))
    }

    func test_build_skipsEmptyNamedHeaders() throws {
        let model = HTTPRequestModel(
            urlString: "https://example.com",
            headers: [HTTPHeader(name: "   ", value: "orphan")]
        )
        let request = try HTTPClientCore.buildRequest(from: model)
        // No crash, and the orphan value isn't applied under any obvious name.
        XCTAssertNil(request.allHTTPHeaderFields?["orphan"])
        XCTAssertTrue((request.allHTTPHeaderFields ?? [:]).isEmpty)
    }

    func test_build_duplicateHeaderNamesCombined() throws {
        let model = HTTPRequestModel(
            urlString: "https://example.com",
            headers: [
                HTTPHeader(name: "X-Multi", value: "a"),
                HTTPHeader(name: "X-Multi", value: "b"),
            ]
        )
        let request = try HTTPClientCore.buildRequest(from: model)
        // addValue combines same-name headers comma-joined (URLRequest semantics).
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Multi"), "a,b")
    }

    // MARK: - Build: body

    func test_build_bodyAppliedForPOST() throws {
        let model = HTTPRequestModel(
            method: .post, urlString: "https://example.com", body: #"{"k":1}"#)
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.httpBody, Data(#"{"k":1}"#.utf8))
    }

    func test_build_bodyIgnoredForGET() throws {
        let model = HTTPRequestModel(
            method: .get, urlString: "https://example.com", body: "ignored")
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertNil(request.httpBody)
    }

    func test_build_emptyBodyNotApplied() throws {
        let model = HTTPRequestModel(method: .post, urlString: "https://example.com", body: "")
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertNil(request.httpBody)
    }

    func test_method_allowsBodyMatrix() {
        XCTAssertFalse(HTTPMethod.get.allowsBody)
        XCTAssertFalse(HTTPMethod.head.allowsBody)
        XCTAssertFalse(HTTPMethod.options.allowsBody)
        XCTAssertTrue(HTTPMethod.post.allowsBody)
        XCTAssertTrue(HTTPMethod.put.allowsBody)
        XCTAssertTrue(HTTPMethod.patch.allowsBody)
        XCTAssertTrue(HTTPMethod.delete.allowsBody)
    }

    // MARK: - Build: timeout clamp

    func test_build_timeoutClampedToFloor() throws {
        let model = HTTPRequestModel(urlString: "https://example.com", timeout: 0)
        let request = try HTTPClientCore.buildRequest(from: model)
        XCTAssertEqual(request.timeoutInterval, 30) // 0 falls back to default
    }

    func test_clampTimeout_bounds() {
        XCTAssertEqual(HTTPClientCore.clampTimeout(0.1), HTTPClientCore.minTimeout)
        XCTAssertEqual(HTTPClientCore.clampTimeout(9999), HTTPClientCore.maxTimeout)
        XCTAssertEqual(HTTPClientCore.clampTimeout(15), 15)
        XCTAssertEqual(HTTPClientCore.clampTimeout(.nan), 30)
        XCTAssertEqual(HTTPClientCore.clampTimeout(-5), 30)
    }

    // MARK: - Build: errors

    func test_build_emptyURLThrows() {
        let model = HTTPRequestModel(urlString: "   ")
        XCTAssertThrowsError(try HTTPClientCore.buildRequest(from: model)) { error in
            XCTAssertEqual(error as? HTTPRequestError, .emptyURL)
        }
    }

    func test_build_invalidURLThrows() {
        // No host ⇒ invalid.
        let model = HTTPRequestModel(urlString: "not a url")
        XCTAssertThrowsError(try HTTPClientCore.buildRequest(from: model)) { error in
            guard case .invalidURL = (error as? HTTPRequestError) else {
                return XCTFail("expected .invalidURL, got \(error)")
            }
        }
    }

    func test_build_unsupportedSchemeThrows() {
        let model = HTTPRequestModel(urlString: "ftp://example.com/file")
        XCTAssertThrowsError(try HTTPClientCore.buildRequest(from: model)) { error in
            XCTAssertEqual(error as? HTTPRequestError, .unsupportedScheme("ftp"))
        }
    }

    func test_build_fileSchemeRejected() {
        let model = HTTPRequestModel(urlString: "file:///etc/passwd")
        XCTAssertThrowsError(try HTTPClientCore.buildRequest(from: model))
    }

    // MARK: - Parse: happy path

    func test_parse_status200WithHeadersAndBody() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "X-Req-Id": "42"])!
        let body = Data(#"{"ok":true}"#.utf8)
        let parsed = try HTTPClientCore.parseResponse(data: body, response: http, elapsed: 0.123)

        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertTrue(parsed.isSuccess)
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.elapsed, 0.123, accuracy: 0.0001)
        XCTAssertEqual(parsed.bodyText, #"{"ok":true}"#)
        XCTAssertEqual(parsed.contentType, "application/json")
    }

    func test_parse_headerLookupCaseInsensitive() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"])!
        let parsed = try HTTPClientCore.parseResponse(data: Data(), response: http, elapsed: 0)
        XCTAssertEqual(parsed.headerValue("CONTENT-TYPE"), "text/plain")
        XCTAssertEqual(parsed.headerValue("content-type"), "text/plain")
    }

    func test_parse_declaredContentLength() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": "1024"])!
        let parsed = try HTTPClientCore.parseResponse(data: Data(), response: http, elapsed: 0)
        XCTAssertEqual(parsed.declaredContentLength, 1024)
    }

    func test_parse_headersSortedDeterministically() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Z-Last": "1", "A-First": "2", "M-Mid": "3"])!
        let parsed = try HTTPClientCore.parseResponse(data: Data(), response: http, elapsed: 0)
        let names = parsed.headers.map { $0.name.lowercased() }
        XCTAssertEqual(names, names.sorted())
    }

    // MARK: - Parse: non-2xx is NOT an error

    func test_parse_404ParsedNotThrown() throws {
        let url = URL(string: "https://example.com/missing")!
        let http = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let parsed = try HTTPClientCore.parseResponse(
            data: Data("nope".utf8), response: http, elapsed: 0.05)
        XCTAssertEqual(parsed.statusCode, 404)
        XCTAssertFalse(parsed.isSuccess)
        XCTAssertEqual(parsed.bodyText, "nope")
    }

    func test_parse_500NotSuccess() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        let parsed = try HTTPClientCore.parseResponse(data: Data(), response: http, elapsed: 0)
        XCTAssertFalse(parsed.isSuccess)
    }

    func test_parse_299IsSuccess_300IsNot() throws {
        let url = URL(string: "https://example.com")!
        let ok = HTTPURLResponse(url: url, statusCode: 299, httpVersion: nil, headerFields: nil)!
        let redirect = HTTPURLResponse(url: url, statusCode: 300, httpVersion: nil, headerFields: nil)!
        XCTAssertTrue(try HTTPClientCore.parseResponse(data: Data(), response: ok, elapsed: 0).isSuccess)
        XCTAssertFalse(try HTTPClientCore.parseResponse(data: Data(), response: redirect, elapsed: 0).isSuccess)
    }

    // MARK: - Parse: errors

    func test_parse_nonHTTPResponseThrows() {
        let url = URL(string: "https://example.com")!
        let plain = URLResponse(
            url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(
            try HTTPClientCore.parseResponse(data: Data(), response: plain, elapsed: 0)
        ) { error in
            XCTAssertEqual(error as? HTTPRequestError, .nonHTTPResponse)
        }
    }

    func test_parse_binaryBodyHasNilText() throws {
        let url = URL(string: "https://example.com")!
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        // Invalid UTF-8 sequence.
        let body = Data([0xFF, 0xFE, 0x00, 0x80])
        let parsed = try HTTPClientCore.parseResponse(data: body, response: http, elapsed: 0)
        XCTAssertNil(parsed.bodyText)
        XCTAssertEqual(parsed.body.count, 4)
    }

    // MARK: - Error messages

    func test_errorMessages_areUserReadable() {
        XCTAssertEqual(HTTPRequestError.emptyURL.message, "Enter a URL.")
        XCTAssertTrue(HTTPRequestError.invalidURL("x").message.contains("x"))
        XCTAssertTrue(HTTPRequestError.unsupportedScheme("ftp").message.contains("ftp"))
        XCTAssertTrue(HTTPRequestError.transport(code: 5, message: "boom").message.contains("boom"))
        XCTAssertFalse(HTTPRequestError.nonHTTPResponse.message.isEmpty)
    }

    // MARK: - Codable round-trip (session persistence readiness)

    func test_requestModel_codableRoundTrip() throws {
        let model = HTTPRequestModel(
            method: .post,
            urlString: "https://example.com",
            headers: [HTTPHeader(name: "A", value: "1")],
            body: "hello",
            timeout: 12)
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(HTTPRequestModel.self, from: data)
        XCTAssertEqual(decoded, model)
    }
}
