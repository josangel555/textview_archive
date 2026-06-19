import Foundation

/// One pushed subscription event (protocol §5): per-sub monotonic `seq`,
/// a `kind` (`created`/`changed`/`deleted`/`resync` for fs.watch;
/// `events`/`resync` for transcript.follow), and the unframed MessagePack
/// body. Delivered ON THE READER THREAD — consumers hop as needed.
public struct RemoteEvent: Sendable {
    public let sub: UInt64
    public let seq: UInt64
    public let kind: String
    public let body: [UInt8]
}

/// `CoreTransport` over a UNIX socket to a `mdv-serve` daemon (TSK-652
/// stage 2 + TSK-664 subscriptions, protocol per `docs/REMOTE_PROTOCOL.md`).
/// The ssh tunnel is the trust boundary — this client only ever dials a
/// filesystem socket path.
///
/// Concurrency model (TSK-664): one background READER THREAD owns every
/// socket read and demuxes frames — responses fill per-call slots (callers
/// block on an NSCondition with a deadline), events dispatch to registered
/// subscription handlers. Writes serialize under their own lock, so calls
/// from multiple threads interleave correctly with pushed events. Reader
/// failure (EOF, io error) fails ALL pending calls, drops subscriptions,
/// and fires `onClose` once.
public final class RemoteTransport: CoreTransport, @unchecked Sendable {

    private let fd: Int32
    /// Server capability mask from the hello response.
    public let capabilities: UInt64

    /// Guards ids/pending/subs/orphans/closedError.
    private let state = NSLock()
    private var nextId: UInt64 = 1
    private var pending: [UInt64: Slot] = [:]
    private var subs: [UInt64: @Sendable (RemoteEvent) -> Void] = [:]
    /// Events that arrived for a sub id whose handler isn't registered yet
    /// (the window between the server creating the sub and `subscribe`
    /// decoding the response). Bounded; flushed on registration.
    private var orphanEvents: [UInt64: [RemoteEvent]] = [:]
    private var closedError: RemoteError?
    /// Serializes socket writes (requests only — the reader never writes).
    private let writeLock = NSLock()
    /// Fired once when the reader exits (nil error = clean EOF). Set it
    /// before issuing calls/subscriptions; delivered on the reader thread.
    public var onClose: (@Sendable (RemoteError?) -> Void)?

    /// Per-call deadline: a server that stops answering must not wedge an
    /// adapter thread forever (the Swift fallback fires instead).
    public static let callDeadline: TimeInterval = 30

    private static let orphanBufferCap = 256

    public enum RemoteError: Error, Equatable {
        case connect(String)
        case handshake(String)
        case io(String)
        case protocolViolation(String)
        case server(code: String, text: String)
    }

    /// A waiting call: the reader fills `outcome` and signals.
    private final class Slot {
        let cond = NSCondition()
        var outcome: Result<[UInt8], ServerError>?
        var transportError: RemoteError?
    }

    private struct ServerError: Error {
        let code: String
        let text: String
    }

    /// Dial + hello (synchronous, before the reader starts), then spawn
    /// the reader thread. Throws on connect failure or wire-version skew.
    public init(socketPath: String) throws {
        let (sock, caps) = try Self.dialAndHello(socketPath: socketPath)
        self.fd = sock
        self.capabilities = caps
        startReader()
    }

    deinit {
        // shutdown() wakes a reader blocked in read(); close() alone does
        // not reliably interrupt a blocked read on macOS.
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    // MARK: - CoreTransport

    public func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
        do {
            let result = try callInner(method, requestBody: requestBody, aux: [])
            CoreTransportRegistry.audit(method, transport: "remote", ok: true)
            return result
        } catch {
            CoreTransportRegistry.audit(method, transport: "remote", ok: false)
            throw error
        }
    }

    public func callAux(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]? {
        do {
            // The bulk input rides the envelope `a` (aux) key (TSK-651); the
            // server routes it to `dispatch::call`'s aux argument. Same demux,
            // deadline, and error mapping as a plain call.
            let result = try callInner(method, requestBody: requestBody, aux: aux)
            CoreTransportRegistry.audit(method, transport: "remote", ok: true)
            return result
        } catch {
            CoreTransportRegistry.audit(method, transport: "remote", ok: false)
            throw error
        }
    }

    private func callInner(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]? {
        state.lock()
        if let dead = closedError {
            state.unlock()
            throw dead
        }
        nextId &+= 1
        let id = nextId
        let slot = Slot()
        pending[id] = slot
        state.unlock()
        defer {
            state.lock()
            pending[id] = nil
            state.unlock()
        }

        do {
            writeLock.lock()
            defer { writeLock.unlock() }
            try Self.writeEnvelope(fd, Self.request(id: id, method: method, body: requestBody, aux: aux))
        }

        slot.cond.lock()
        let deadline = Date().addingTimeInterval(Self.callDeadline)
        while slot.outcome == nil && slot.transportError == nil {
            if !slot.cond.wait(until: deadline) { break }
        }
        let outcome = slot.outcome
        let transportError = slot.transportError
        slot.cond.unlock()

        if let transportError { throw transportError }
        guard let outcome else {
            throw RemoteError.io("call '\(method)' timed out after \(Self.callDeadline)s")
        }
        switch outcome {
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

    // MARK: - Subscriptions (TSK-664)

    /// Issue a subscription request (`fs.watch`, `transcript.follow`) and
    /// register `handler` for its events. Events that raced the response
    /// are flushed to the handler in order before this returns.
    public func subscribe(
        _ method: String,
        requestBody: [UInt8],
        handler: @escaping @Sendable (RemoteEvent) -> Void
    ) throws -> UInt64 {
        guard let body = try call(method, requestBody: requestBody) else {
            throw CoreError.decode("empty \(method) response")
        }
        var reader = MsgPackReader(body)
        let map = try reader.decode().mapValue()
        let sub = try map.require("sub").u64Value()
        state.lock()
        let raced = orphanEvents.removeValue(forKey: sub) ?? []
        subs[sub] = handler
        state.unlock()
        raced.forEach(handler)
        return sub
    }

    /// Drop the handler and tell the server (`fs.unwatch` serves every
    /// subscription kind; `transcript.unfollow` is an accepted alias).
    public func unsubscribe(_ sub: UInt64, method: String = "fs.unwatch") throws {
        state.lock()
        subs[sub] = nil
        orphanEvents[sub] = nil
        state.unlock()
        let body = MsgPackValue.map([(.string("sub"), .uint(sub))]).encode()
        _ = try call(method, requestBody: body)
    }

    // MARK: - Reader thread

    private func startReader() {
        let sock = fd
        let thread = Thread { [weak self] in
            let failure = Self.readLoop(sock) { [weak self] frame in
                self?.route(frame)
            }
            self?.readerDidExit(failure)
        }
        thread.name = "RemoteTransport.reader"
        thread.start()
    }

    private enum InboundFrame {
        case response(id: UInt64, outcome: Result<[UInt8], ServerError>)
        case event(RemoteEvent)
    }

    /// Read + decode frames until the socket dies; `deliver` runs for each.
    /// Returns the terminal error (nil = clean EOF).
    private static func readLoop(
        _ fd: Int32, deliver: (InboundFrame) -> Void
    ) -> RemoteError? {
        while true {
            let envelope: [UInt8]
            do {
                let lenBytes = try readExact(fd, 4)
                let len = Int(UInt32(lenBytes[0])
                    | UInt32(lenBytes[1]) << 8
                    | UInt32(lenBytes[2]) << 16
                    | UInt32(lenBytes[3]) << 24)
                guard len <= 16 * 1024 * 1024 else {
                    return .protocolViolation("oversized frame (\(len))")
                }
                envelope = try readExact(fd, len)
            } catch let e as RemoteError {
                return e.isCleanEOF ? nil : e
            } catch {
                return .io("\(error)")
            }
            do {
                var reader = MsgPackReader(envelope)
                let map = try reader.decode().mapValue()
                guard case .string(let t)? = map["t"] else {
                    return .protocolViolation("envelope missing t")
                }
                switch t {
                case "r":
                    let id = try map.require("i").u64Value()
                    if let e = map["e"] {
                        let em = try e.mapValue()
                        deliver(.response(id: id, outcome: .failure(ServerError(
                            code: (try? em.require("c").stringValue()) ?? "unknown",
                            text: (try? em.require("x").stringValue()) ?? ""))))
                    } else if case .binary(let body)? = map["b"] {
                        deliver(.response(id: id, outcome: .success(body)))
                    } else {
                        deliver(.response(id: id, outcome: .success([])))
                    }
                case "e":
                    let event = RemoteEvent(
                        sub: try map.require("s").u64Value(),
                        seq: try map.require("n").u64Value(),
                        kind: try map.require("k").stringValue(),
                        body: {
                            if case .binary(let b)? = map["b"] { return b }
                            return []
                        }())
                    deliver(.event(event))
                default:
                    return .protocolViolation("unexpected frame type '\(t)'")
                }
            } catch {
                return .protocolViolation("undecodable envelope: \(error)")
            }
        }
    }

    private func route(_ frame: InboundFrame) {
        switch frame {
        case .response(let id, let outcome):
            state.lock()
            let slot = pending[id]
            state.unlock()
            // Unknown id = a response landing after its caller's deadline —
            // tolerated, never a connection-killer.
            guard let slot else { return }
            slot.cond.lock()
            slot.outcome = outcome
            slot.cond.signal()
            slot.cond.unlock()
        case .event(let event):
            state.lock()
            if let handler = subs[event.sub] {
                state.unlock()
                handler(event)
                return
            }
            // Pre-registration race: buffer (bounded) until subscribe()
            // registers the handler.
            var buffered = orphanEvents[event.sub] ?? []
            if buffered.count < Self.orphanBufferCap {
                buffered.append(event)
                orphanEvents[event.sub] = buffered
            }
            state.unlock()
        }
    }

    /// Reader teardown: fail every waiting call, drop subscriptions, fire
    /// `onClose` exactly once.
    private func readerDidExit(_ failure: RemoteError?) {
        let terminal = failure ?? .io("connection closed")
        state.lock()
        guard closedError == nil else {
            state.unlock()
            return
        }
        closedError = terminal
        let waiting = Array(pending.values)
        pending.removeAll()
        subs.removeAll()
        orphanEvents.removeAll()
        let closeHandler = onClose
        state.unlock()
        for slot in waiting {
            slot.cond.lock()
            slot.transportError = terminal
            slot.cond.signal()
            slot.cond.unlock()
        }
        closeHandler?(failure)
    }

    // MARK: - Dial + hello

    private static func dialAndHello(socketPath: String) throws -> (Int32, UInt64) {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw RemoteError.connect("socket(): errno \(errno)") }
        // A write to a dead server must come back as errno EPIPE, not a
        // process-killing SIGPIPE (caught live: the server-death test
        // SIGPIPEd the whole xctest runner before this line existed).
        var noSigpipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))
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

        // --- hello (the reader is not running yet; read inline) ---
        let helloBody = MsgPackValue.map([
            (.string("wire_version"), .uint(UInt64(CoreABI.compiled))),
            (.string("client"), .string("mdv-swift/RemoteTransport")),
        ]).encode()
        do {
            try writeEnvelope(sock, request(id: 0, method: "hello", body: helloBody))
            switch try readHelloResponse(sock) {
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

    /// Hello-only inline read (id 0, no demux — nothing else is in flight).
    private static func readHelloResponse(
        _ fd: Int32
    ) throws -> Result<[UInt8], ServerError> {
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
        guard case .string("r")? = map["t"] else {
            throw RemoteError.protocolViolation("hello answer must be a response")
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

    // MARK: - Envelope plumbing

    private static func request(id: UInt64, method: String, body: [UInt8], aux: [UInt8] = []) -> [UInt8] {
        // The `a` (aux) key is appended ONLY when non-empty so req-only calls
        // stay byte-identical to the pre-aux wire (the server's encoder does
        // the same — see envelope.rs `aux_key_is_omitted_when_empty`).
        var pairs: [(MsgPackValue, MsgPackValue)] = [
            (.string("t"), .string("q")),
            (.string("i"), .uint(id)),
            (.string("m"), .string(method)),
            (.string("b"), .binary(body)),
        ]
        if !aux.isEmpty {
            pairs.append((.string("a"), .binary(aux)))
        }
        return MsgPackValue.map(pairs).encode()
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
}

private extension RemoteTransport.RemoteError {
    /// EOF at a frame boundary is the clean-shutdown shape.
    var isCleanEOF: Bool {
        if case .io(let m) = self { return m == "connection closed" }
        return false
    }
}
