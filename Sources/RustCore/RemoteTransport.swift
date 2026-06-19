import Foundation

/// One pushed subscription event (protocol §5): per-sub monotonic `seq`,
/// a `kind` (`created`/`changed`/`deleted`/`resync` for fs.watch;
/// `events`/`resync` for transcript.follow), and the unframed MessagePack
/// body. Delivered ON A PER-TRANSPORT SERIAL QUEUE (TSK-976), in arrival
/// order — consumers hop as needed.
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
/// block on an NSCondition with a deadline), events are handed to a
/// per-transport SERIAL DELIVERY QUEUE (TSK-976) that invokes the registered
/// subscription handlers in arrival order, OFF the reader thread (so a slow
/// handler can't stall the demux). Writes serialize under their own lock, so
/// calls from multiple threads interleave correctly with pushed events.
/// Reader failure (EOF, io error) fails ALL pending calls, drops
/// subscriptions, and fires `onClose` once.
///
/// Unsubscribe contract (TSK-976): `unsubscribe` nils the handler under the
/// `state` lock and then drains the delivery queue with a `sync` barrier, so
/// NO handler invocation for that sub can run after `unsubscribe` returns.
/// The delivery block also re-checks the sub under the lock at the instant of
/// the call, so an event the reader demuxed before the nil-out is dropped
/// rather than delivered to a torn-down handler (the prior copy-out-then-call
/// raced: a handler could fire after `unsubscribe` had already returned and
/// the closure's captured state had been torn down).
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
    /// decoding the response). Bounded on THREE axes (see `OrphanStore`);
    /// flushed on registration.
    private var orphans = OrphanStore()
    private var closedError: RemoteError?
    /// Serializes socket writes (requests only — the reader never writes).
    private let writeLock = NSLock()
    /// Serial queue that invokes subscription handlers in arrival order, off
    /// the reader thread (TSK-976). `unsubscribe` issues a `sync` barrier on
    /// it so no handler runs after `unsubscribe` returns; a slow handler
    /// stalls only this queue, never the reader's demux.
    private let deliveryQueue = DispatchQueue(label: "RemoteTransport.delivery")
    /// Fired once when the reader exits (nil error = clean EOF). Set it
    /// before issuing calls/subscriptions; delivered on the reader thread.
    public var onClose: (@Sendable (RemoteError?) -> Void)?

    /// Per-call deadline: a server that stops answering must not wedge an
    /// adapter thread forever (the Swift fallback fires instead).
    public static let callDeadline: TimeInterval = 30

    /// Globally-bounded pre-registration orphan buffer (TSK-987).
    ///
    /// The orphan dict bridges ONLY the narrow race where a pushed event for
    /// a freshly-created sub arrives before `subscribe()` decodes the response
    /// and registers the handler. A buggy/compromised `mdv-serve` could stream
    /// events for monotonically-increasing, never-subscribed sub ids; capping
    /// only the per-list length (the old `orphanBufferCap`) bounds neither the
    /// NUMBER of distinct keys nor the aggregate retained bytes, so the dict
    /// (each body up to a 16 MiB frame) grows until the client OOMs.
    ///
    /// This store enforces three independent ceilings:
    ///   - `keyCap`  — max distinct pending sub ids; a new key past the cap
    ///     evicts the OLDEST key (insertion-order LRU) before inserting.
    ///   - `byteCap` — total retained body bytes; appends that would exceed it
    ///     are dropped (the bridge is best-effort — a missed pre-registration
    ///     event is far cheaper than an OOM, and the steady-state path never
    ///     touches the buffer at all).
    ///   - `listCap` — per-sub list length (the pre-existing single-key cap).
    ///
    /// Pure value type with no I/O: driven directly by host tests. All access
    /// is under `RemoteTransport.state`, so it needs no internal locking.
    struct OrphanStore {
        static let keyCap = 64
        static let byteCap = 8 * 1024 * 1024  // 8 MiB aggregate ceiling
        static let listCap = 256

        /// Insertion-ordered (oldest key first) so eviction is O(1)-ish LRU.
        private(set) var byKey: [UInt64: [RemoteEvent]] = [:]
        /// Oldest-first key order, kept in lock-step with `byKey`.
        private(set) var order: [UInt64] = []
        private(set) var totalBytes: Int = 0

        var keyCount: Int { byKey.count }

        /// Buffer one event for a not-yet-registered sub. Enforces all three
        /// ceilings; returns false if the event was dropped (cap hit).
        @discardableResult
        mutating func buffer(_ event: RemoteEvent) -> Bool {
            let sub = event.sub
            let cost = event.body.count

            if var list = byKey[sub] {
                // Existing key: per-list AND byte ceilings.
                guard list.count < Self.listCap,
                      totalBytes + cost <= Self.byteCap else { return false }
                list.append(event)
                byKey[sub] = list
                totalBytes += cost
                return true
            }

            // New key: a single event must itself fit the byte budget.
            guard cost <= Self.byteCap else { return false }
            // Evict oldest keys until the new key fits the key cap AND the
            // event fits the byte budget. Never evict to make room for an
            // event larger than the whole budget (guarded above).
            while (byKey.count >= Self.keyCap || totalBytes + cost > Self.byteCap),
                  let oldest = order.first {
                evict(oldest)
            }
            // If eviction still couldn't free enough bytes (shouldn't happen
            // once the store is empty, since cost <= byteCap), drop.
            guard totalBytes + cost <= Self.byteCap else { return false }
            byKey[sub] = [event]
            order.append(sub)
            totalBytes += cost
            return true
        }

        /// Remove + return a sub's buffered events (on handler registration).
        mutating func take(_ sub: UInt64) -> [RemoteEvent] {
            guard let list = byKey.removeValue(forKey: sub) else { return [] }
            order.removeAll { $0 == sub }
            totalBytes -= list.reduce(0) { $0 + $1.body.count }
            return list
        }

        /// Drop a sub's buffer without delivering (unsubscribe).
        mutating func drop(_ sub: UInt64) {
            _ = take(sub)
        }

        mutating func removeAll() {
            byKey.removeAll()
            order.removeAll()
            totalBytes = 0
        }

        private mutating func evict(_ sub: UInt64) {
            guard let list = byKey.removeValue(forKey: sub) else { return }
            order.removeAll { $0 == sub }
            totalBytes -= list.reduce(0) { $0 + $1.body.count }
        }
    }

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
        guard fd >= 0 else { return }   // socket-less test instance
        // shutdown() wakes a reader blocked in read(); close() alone does
        // not reliably interrupt a blocked read on macOS.
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

#if DEBUG
    /// TSK-976 test seam: a socket-less instance (no fd, no reader thread) so
    /// the subscription state machine — `subscribe`-registered handler,
    /// `route` event delivery, `dropHandler` teardown — is exercisable in a
    /// pure-logic host test with NO `mdv-serve` and NO socket. The dialing
    /// init is the only production path; this one never touches the wire.
    init(testSocketlessCapabilities caps: UInt64 = 0) {
        self.fd = -1
        self.capabilities = caps
    }

    /// Register a handler WITHOUT the server round-trip (the part of
    /// `subscribe` after the `call`). Returns nothing the wire would have
    /// minted — the caller supplies the sub id.
    func _testRegister(_ sub: UInt64, handler: @escaping @Sendable (RemoteEvent) -> Void) {
        state.lock()
        let raced = orphans.take(sub)   // TSK-987 OrphanStore API (was orphanEvents dict)
        subs[sub] = handler
        state.unlock()
        for event in raced {
            deliveryQueue.async { [weak self] in self?.deliver(event) }
        }
    }

    /// Drive the reader-side event path directly (no socket frame to decode).
    func _testRoute(_ event: RemoteEvent) {
        route(.event(event))
    }

    /// The local half of `unsubscribe` (nil-out + barrier), WITHOUT the
    /// server `call` — this is the part that provides the no-events-after
    /// guarantee, and the part a socket-less test can exercise.
    func _testDropHandler(_ sub: UInt64) {
        dropHandler(sub)
    }

    /// Block until the delivery queue has drained everything enqueued so far
    /// — a deterministic flush point for assertions in tests.
    func _testDrainDelivery() {
        deliveryQueue.sync {}
    }
#endif

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
    /// register `handler` for its events. Events that raced the response are
    /// flushed to the handler IN ORDER on the delivery queue (ahead of any
    /// later-arriving live events, since the queue is FIFO and the reader has
    /// not yet routed any post-registration event).
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
        let raced = orphans.take(sub)
        subs[sub] = handler
        state.unlock()
        // Flush raced events through the SAME serial queue used for live
        // delivery, so a concurrent unsubscribe's barrier drains them too and
        // they never overtake / fall behind live events for this sub.
        for event in raced {
            deliveryQueue.async { [weak self] in self?.deliver(event) }
        }
        return sub
    }

    /// Drop the handler and tell the server (`fs.unwatch` serves every
    /// subscription kind; `transcript.unfollow` is an accepted alias).
    ///
    /// The local teardown (nil-out + delivery-queue drain) happens BEFORE the
    /// server round-trip so the no-events-after-unsubscribe guarantee holds
    /// even if the `call` itself throws (e.g. the server died) — see
    /// `dropHandler`.
    public func unsubscribe(_ sub: UInt64, method: String = "fs.unwatch") throws {
        dropHandler(sub)
        let body = MsgPackValue.map([(.string("sub"), .uint(sub))]).encode()
        _ = try call(method, requestBody: body)
    }

    /// Local half of unsubscribe (TSK-976): forget the handler under the lock,
    /// then drain the delivery queue with a `sync` barrier so any event the
    /// reader already enqueued runs (and is dropped by the live re-check) or
    /// completes BEFORE this returns. After this, no `deliver(_:)` for `sub`
    /// can invoke its handler — `deliver` re-checks `subs[sub]` under the lock.
    private func dropHandler(_ sub: UInt64) {
        state.lock()
        subs[sub] = nil
        orphans.drop(sub)
        state.unlock()
        // Barrier: wait out anything already on the queue. We never call this
        // FROM the delivery queue, so this cannot deadlock.
        deliveryQueue.sync {}
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
                        // Allocation-free 2-field error read: no throwaway dict.
                        deliver(.response(id: id, outcome: .failure(ServerError(
                            code: (try? e.requireField("c").stringValue()) ?? "unknown",
                            text: (try? e.requireField("x").stringValue()) ?? ""))))
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
            if subs[event.sub] != nil {
                state.unlock()
                // Hand off to the serial delivery queue rather than calling
                // the handler on the reader thread. `deliver` re-checks the
                // sub under the lock at call time, so an unsubscribe that
                // lands between here and the dequeue drops this event — and
                // its `sync` barrier guarantees no handler runs after
                // `unsubscribe` returns (TSK-976).
                deliveryQueue.async { [weak self] in self?.deliver(event) }
                return
            }
            // Pre-registration race: buffer (globally bounded — key cap,
            // byte budget, per-list cap) until subscribe() registers the
            // handler. A new sub id past the key cap evicts the oldest;
            // events past the byte budget are dropped (TSK-987).
            orphans.buffer(event)
            state.unlock()
        }
    }

    /// Runs on the serial delivery queue. Re-reads the live handler UNDER the
    /// `state` lock — if `unsubscribe`/`readerDidExit` nilled it after the
    /// reader enqueued this event, the event is dropped, never delivered to a
    /// torn-down handler (TSK-976).
    private func deliver(_ event: RemoteEvent) {
        state.lock()
        let handler = subs[event.sub]
        state.unlock()
        handler?(event)
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
        orphans.removeAll()
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
            // Allocation-free 2-field error read: no throwaway dict.
            return .failure(ServerError(
                code: (try? e.requireField("c").stringValue()) ?? "unknown",
                text: (try? e.requireField("x").stringValue()) ?? ""))
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
