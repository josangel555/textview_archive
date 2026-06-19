import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // Linux: URLSession lives here
#endif

/// HTTP client foundation (TSK-721) — the pure, host-testable core for the
/// in-app HTTP request tool. Holds the request model, request-building
/// (model → `URLRequest`), the response model, response-parsing
/// (`HTTPURLResponse` + `Data` + timing → model), and a thin `URLSession`-based
/// send. NO AppKit / SwiftUI import, so `ViewerCoreTests` can exercise every
/// branch on the host. URLSession only — no third-party dependency.
///
/// Design notes:
/// - Building never mutates global state; it returns a `URLRequest` or throws a
///   typed `HTTPRequestError` so the UI can show a precise message.
/// - Parsing is split out from sending so a stubbed `(Data, HTTPURLResponse)`
///   pair can be parsed in a host test without touching the network.
/// - `status` carries the raw code AND its `isSuccess` (2xx) verdict; non-2xx is
///   NOT an error here (the caller decides) — a 404 with a body is a perfectly
///   valid response to display.

// MARK: - Method

/// The HTTP methods the tool offers. `rawValue` is the on-the-wire verb.
public enum HTTPMethod: String, CaseIterable, Sendable, Codable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    /// Methods that conventionally carry a request body. HEAD/GET/OPTIONS do
    /// not, so the UI can hide the body field for them.
    public var allowsBody: Bool {
        switch self {
        case .post, .put, .patch, .delete: return true
        case .get, .head, .options: return false
        }
    }
}

// MARK: - Header

/// A single request header. Kept as an ordered list (not a dictionary) so the
/// UI preserves the user's row order and can hold duplicate-name rows while
/// editing; collapsing to canonical form happens at build time.
public struct HTTPHeader: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, value: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

// MARK: - Request model

/// The editable HTTP request. Pure value type — the SwiftUI form binds to a
/// copy of this and `HTTPClientCore.buildRequest` turns it into a `URLRequest`.
public struct HTTPRequestModel: Equatable, Sendable, Codable {
    public var method: HTTPMethod
    public var urlString: String
    public var headers: [HTTPHeader]
    public var body: String
    /// Request timeout in seconds (clamped to a sane floor at build time).
    public var timeout: TimeInterval

    public init(
        method: HTTPMethod = .get,
        urlString: String = "",
        headers: [HTTPHeader] = [],
        body: String = "",
        timeout: TimeInterval = 30
    ) {
        self.method = method
        self.urlString = urlString
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

// MARK: - Errors

/// Build / send failures, surfaced to the UI with a user-readable message.
public enum HTTPRequestError: Error, Equatable, Sendable {
    /// URL string is empty after trimming.
    case emptyURL
    /// URL string isn't a valid absolute URL (or lacks an http/https scheme).
    case invalidURL(String)
    /// Scheme isn't http or https (e.g. `ftp://`, `file://`).
    case unsupportedScheme(String)
    /// The transport (URLSession) reported an error — code + localized message.
    case transport(code: Int, message: String)
    /// The response wasn't an `HTTPURLResponse` (shouldn't happen for http/s).
    case nonHTTPResponse

    public var message: String {
        switch self {
        case .emptyURL:
            return "Enter a URL."
        case .invalidURL(let s):
            return "Not a valid URL: \(s)"
        case .unsupportedScheme(let s):
            return "Unsupported scheme \"\(s)\" — use http or https."
        case .transport(let code, let message):
            return "Request failed (\(code)): \(message)"
        case .nonHTTPResponse:
            return "Server returned a non-HTTP response."
        }
    }
}

// MARK: - Response model

/// The parsed response the UI displays.
public struct HTTPResponseModel: Equatable, Sendable {
    public let statusCode: Int
    /// Header fields in lowercased-name canonical form (HTTP names are
    /// case-insensitive); the original-case display name is kept too.
    public let headers: [HTTPResponseHeader]
    public let body: Data
    /// Wall-clock seconds from send to completion.
    public let elapsed: TimeInterval

    public init(statusCode: Int, headers: [HTTPResponseHeader], body: Data, elapsed: TimeInterval) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.elapsed = elapsed
    }

    /// True for 2xx.
    public var isSuccess: Bool { (200...299).contains(statusCode) }

    /// `Content-Type` value (case-insensitive lookup), or nil.
    public var contentType: String? { headerValue("content-type") }

    /// `Content-Length` reported by the server (the declared length; the actual
    /// downloaded length is `body.count`), or nil if absent/unparseable.
    public var declaredContentLength: Int? {
        headerValue("content-length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Best-effort UTF-8 decode of the body for text display. Nil for binary.
    public var bodyText: String? { String(data: body, encoding: .utf8) }

    /// Case-insensitive header lookup; returns the first match's value.
    public func headerValue(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name.lowercased() == lower }?.value
    }

    /// A human "200 OK"-style status line.
    public var statusLine: String {
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        return "\(statusCode) \(reason.capitalized)"
    }
}

/// One response header (preserves server-sent name casing).
public struct HTTPResponseHeader: Equatable, Sendable, Identifiable {
    public var id: UUID
    public let name: String
    public let value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

// MARK: - Core

public enum HTTPClientCore {

    /// Minimum allowed timeout (seconds). A user can't accidentally set 0
    /// (which URLSession treats as "no body data expected", a footgun).
    public static let minTimeout: TimeInterval = 1
    /// Maximum allowed timeout (seconds).
    public static let maxTimeout: TimeInterval = 300

    // MARK: Build

    /// Build a `URLRequest` from the model, or throw `HTTPRequestError`.
    ///
    /// Validation:
    /// - URL is trimmed; empty ⇒ `.emptyURL`.
    /// - Must parse as an absolute URL with a host ⇒ else `.invalidURL`.
    /// - Scheme must be http/https ⇒ else `.unsupportedScheme`.
    ///
    /// Headers: only `isEnabled` rows with a non-empty trimmed name are applied,
    /// in order, via `addValue(_:forHTTPHeaderField:)` so duplicate-name rows
    /// (e.g. multiple `Set-Cookie`-style values) are preserved rather than
    /// last-wins-clobbered.
    ///
    /// Body: applied only for methods where `allowsBody` is true and the body is
    /// non-empty, as UTF-8. We do NOT auto-set Content-Type — the user owns that
    /// header (so they can send form-encoded, JSON, etc.).
    public static func buildRequest(from model: HTTPRequestModel) throws -> URLRequest {
        let trimmed = model.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HTTPRequestError.emptyURL }

        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host != nil else {
            throw HTTPRequestError.invalidURL(trimmed)
        }
        let lowerScheme = scheme.lowercased()
        guard lowerScheme == "http" || lowerScheme == "https" else {
            throw HTTPRequestError.unsupportedScheme(scheme)
        }

        var request = URLRequest(url: url)
        request.httpMethod = model.method.rawValue
        request.timeoutInterval = clampTimeout(model.timeout)

        for header in model.headers where header.isEnabled {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            request.addValue(header.value, forHTTPHeaderField: name)
        }

        if model.method.allowsBody, !model.body.isEmpty {
            request.httpBody = Data(model.body.utf8)
        }

        return request
    }

    /// Clamp a requested timeout into `[minTimeout, maxTimeout]`. A non-finite or
    /// non-positive value falls back to a 30s default.
    public static func clampTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 30 }
        return min(max(value, minTimeout), maxTimeout)
    }

    // MARK: Parse

    /// Parse a transport result `(Data, HTTPURLResponse)` plus measured timing
    /// into a `HTTPResponseModel`. Split out from `send` so it's host-testable
    /// without the network. Throws `.nonHTTPResponse` if `response` isn't an
    /// `HTTPURLResponse`.
    public static func parseResponse(
        data: Data,
        response: URLResponse,
        elapsed: TimeInterval
    ) throws -> HTTPResponseModel {
        guard let http = response as? HTTPURLResponse else {
            throw HTTPRequestError.nonHTTPResponse
        }
        let headers: [HTTPResponseHeader] = http.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return HTTPResponseHeader(name: name, value: String(describing: value))
        }
        // Deterministic order for display + tests (headers come back as an
        // unordered NSDictionary).
        .sorted { $0.name.lowercased() < $1.name.lowercased() }

        return HTTPResponseModel(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            elapsed: elapsed
        )
    }

    // MARK: Send

    /// Build + send the request and return the parsed response. Measures
    /// wall-clock elapsed time around the transport call. Transport failures
    /// (no network, DNS, TLS, timeout) surface as `HTTPRequestError.transport`;
    /// a non-2xx HTTP status is NOT an error — it's returned as a normal
    /// `HTTPResponseModel` for the UI to display.
    public static func send(
        _ model: HTTPRequestModel,
        session: URLSession = .shared
    ) async throws -> HTTPResponseModel {
        let request = try buildRequest(from: model)
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            return try parseResponse(data: data, response: response, elapsed: elapsed)
        } catch let error as HTTPRequestError {
            throw error
        } catch let urlError as URLError {
            throw HTTPRequestError.transport(
                code: urlError.errorCode,
                message: urlError.localizedDescription
            )
        } catch {
            let ns = error as NSError
            throw HTTPRequestError.transport(code: ns.code, message: ns.localizedDescription)
        }
    }
}
