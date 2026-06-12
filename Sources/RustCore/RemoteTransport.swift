import Foundation

/// `CoreTransport` over a UNIX socket to a `mdv-serve` daemon (TSK-652
/// stage 2, protocol per `docs/REMOTE_PROTOCOL.md`). The ssh tunnel is the
/// trust boundary — this client only ever dials a filesystem socket path.
///
/// V1 concurrency model: calls are SERIALIZED under a lock (the adapters
/// are synchronous; one in-flight request per connection is correct and
/// simple). Event frames arriving between a request and its response are
/// skipped in v1 — the subscription surface lands with the fs family.
public final class RemoteTransport: CoreTransport, @unchecked Sendable {

    private let lock = NSLock()
    private let fd: Int32
    private var nextId: UInt64 = 1
    /// Server capability mask from the hello response.
    public let capabilities: UInt64

    public enum RemoteError: Error, Equatable {
        case connect(String)
        case handshake(String)
        case io(String)
        case protocolViolation(String)
        case server(code: String, text: String)
    }

    /// Dial + hello. Throws on connect failure or wire-version skew.
    public init(socketPath: String) throws {
        let (sock, caps) = try Self.dialAndHello(socketPath: socketPath)
        self.fd = sock
        self.capabilities = caps
    }

    private static func dialAndHello(socketPath: String) throws -> (Int32, UInt64) {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw RemoteError.connect("socket(): errno \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            throw RemoteError.connect("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, len)
            }
        }
        guard rc == 0 else {
            close(sock)
            throw RemoteError.connect("connect(\(socketPath)): errno \(errno)")
        }

        // --- hello ---
        let helloBody = MsgPackValue.map([
            (.string("wire_version"), .uint(UInt64(CoreABI.compiled))),
            (.string("client"), .string("mdv-swift/RemoteTransport")),
        ]).encode()
        do {
            try writeEnvelope(sock, request(id: 0, method: "hello", body: helloBody))
            switch try readResponse(sock, id: 0) {
            case .success(let body):
                var reader = MsgPackReader(body)
                let map = try reader.decode().mapValue()
                return (sock, try map.require("capabilities").u64Value())
            case .failure(let e):
                close(sock)
                throw RemoteError.handshake("\(e.code): \(e.text)")
            }
        } catch let e as RemoteError {
            close(sock)
            throw e
        } catch {
            close(sock)
            throw RemoteError.handshake("\(error)")
        }
    }

    deinit { close(fd) }

    // MARK: CoreTransport

    public func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
        do {
            let result = try callInner(method, requestBody: requestBody)
            CoreTransportRegistry.audit(method, transport: "remote", ok: true)
            return result
        } catch {
            CoreTransportRegistry.audit(method, transport: "remote", ok: false)
            throw error
        }
    }

    private func callInner(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        nextId &+= 1
        let id = nextId
        try Self.writeEnvelope(fd, Self.request(id: id, method: method, body: requestBody))
        switch try Self.readResponse(fd, id: id) {
        case .success(let body):
            return body.isEmpty ? nil : body
        case .failure(let e):
            // Map the in-band error family onto CoreError so the adapters'
            // fallback semantics hold identically for remote faults.
            switch e.code {
            case "wire_error": throw CoreError.wireError
            case "too_large": throw CoreError.tooLarge
            case "panic": throw CoreError.panic
            case "invalid_pattern": throw CoreError.invalidPattern(e.text)
            default: throw CoreError.decode("remote: \(e.code): \(e.text)")
            }
        }
    }

    // MARK: envelope plumbing

    private struct ServerError: Error {
        let code: String
        let text: String
    }

    private static func request(id: UInt64, method: String, body: [UInt8]) -> [UInt8] {
        MsgPackValue.map([
            (.string("t"), .string("q")),
            (.string("i"), .uint(id)),
            (.string("m"), .string(method)),
            (.string("b"), .binary(body)),
        ]).encode()
    }

    private static func writeEnvelope(_ fd: Int32, _ envelope: [UInt8]) throws {
        var frame = [UInt8]()
        let n = UInt32(truncatingIfNeeded: envelope.count)
        frame.reserveCapacity(envelope.count + 4)
        frame.append(UInt8(n & 0xff))
        frame.append(UInt8((n >> 8) & 0xff))
        frame.append(UInt8((n >> 16) & 0xff))
        frame.append(UInt8((n >> 24) & 0xff))
        frame.append(contentsOf: envelope)
        var off = 0
        while off < frame.count {
            let wrote = frame[off...].withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            guard wrote > 0 else { throw RemoteError.io("write: errno \(errno)") }
            off += wrote
        }
    }

    private static func readExact(_ fd: Int32, _ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let got = out[off...].withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if got == 0 { throw RemoteError.io("connection closed") }
            guard got > 0 else { throw RemoteError.io("read: errno \(errno)") }
            off += got
        }
        return out
    }

    /// Read frames until the response with `id` arrives. Events are skipped
    /// (v1 has no subscriptions); a response with a DIFFERENT id is a
    /// protocol violation under the serialized-call model.
    private static func readResponse(
        _ fd: Int32, id: UInt64
    ) throws -> Result<[UInt8], ServerError> {
        while true {
            let lenBytes = try readExact(fd, 4)
            let len = Int(UInt32(lenBytes[0])
                | UInt32(lenBytes[1]) << 8
                | UInt32(lenBytes[2]) << 16
                | UInt32(lenBytes[3]) << 24)
            guard len <= 16 * 1024 * 1024 else {
                throw RemoteError.protocolViolation("oversized frame (\(len))")
            }
            let envelope = try readExact(fd, len)
            var reader = MsgPackReader(envelope)
            let map = try reader.decode().mapValue()
            guard case .string(let t)? = map["t"] else {
                throw RemoteError.protocolViolation("envelope missing t")
            }
            if t == "e" { continue } // v1: no subscriptions — skip events
            guard t == "r" else {
                throw RemoteError.protocolViolation("unexpected frame type '\(t)'")
            }
            let gotId = try map.require("i").u64Value()
            guard gotId == id else {
                throw RemoteError.protocolViolation("response id \(gotId), expected \(id)")
            }
            if let e = map["e"] {
                let em = try e.mapValue()
                return .failure(ServerError(
                    code: (try? em.require("c").stringValue()) ?? "unknown",
                    text: (try? em.require("x").stringValue()) ?? ""))
            }
            if case .binary(let body)? = map["b"] {
                return .success(body)
            }
            return .success([])
        }
    }
}
