import XCTest
@testable import ViewerCore
@testable import RustCore

/// TSK-665 — the launch-time remote attach: env-gated, fail-safe to
/// in-process on any failure, auto-revert on connection loss. Runs against
/// a REAL mdv-serve; skips when the binary isn't built.
final class RemoteCoreAttachTests: XCTestCase {

    private var server: Process?
    private var socketPath: String = ""

    override func tearDown() {
        CoreTransportRegistry.resetToInProcess()
        server?.terminate()
        if !socketPath.isEmpty {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        super.tearDown()
    }

    private func serveBinary() throws -> String {
        if let env = ProcessInfo.processInfo.environment["MDV_SERVE_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let fallback = "/private/tmp/mdv-rust-target/debug/mdv-serve"
        guard FileManager.default.isExecutableFile(atPath: fallback) else {
            throw XCTSkip("mdv-serve binary not built (cargo build -p mdvcore-serve)")
        }
        return fallback
    }

    private func spawnServer() throws {
        let bin = try serveBinary()
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-attach-\(UUID().uuidString.prefix(8)).sock").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--socket", socketPath]
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { return }
            usleep(50_000)
        }
        XCTFail("mdv-serve socket never appeared")
    }

    func test_unsetEnv_isNotConfigured_andRegistryUntouched() {
        let outcome = RemoteCoreAttach.attachIfConfigured(environment: [:])
        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertTrue(CoreTransportRegistry.current is InProcessTransport,
                      "no env = the in-process default stays")
    }

    func test_attach_swapsRegistry_andEngineCallsRouteRemote() throws {
        try spawnServer()
        let outcome = RemoteCoreAttach.attachIfConfigured(
            environment: ["MDV_REMOTE_SOCKET": socketPath])
        guard case .attached(let caps) = outcome else {
            return XCTFail("expected attach, got \(outcome)")
        }
        XCTAssertNotEqual(caps, 0, "hello capabilities must surface")
        XCTAssertTrue(CoreTransportRegistry.current is RemoteTransport)
        // A REAL engine call routes through the remote and returns sane data.
        let ranked = try mdvCoreFuzzyRank(query: "fz", candidates: ["fuzzy", "nope"])
        XCTAssertEqual(ranked.first?.index, 0,
                       "engine calls must work through the attached remote")
    }

    func test_attachFailure_keepsInProcess_failSafe() {
        let outcome = RemoteCoreAttach.attachIfConfigured(
            environment: ["MDV_REMOTE_SOCKET": "/nonexistent/mdv-\(UUID()).sock"])
        guard case .failed = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertTrue(CoreTransportRegistry.current is InProcessTransport,
                      "a failed attach must leave the in-process transport installed")
        // And engines still work locally.
        XCTAssertNoThrow(try mdvCoreFuzzyRank(query: "a", candidates: ["a"]))
    }

    func test_connectionLoss_autoRevertsToInProcess_andCallsKeepWorking() throws {
        try spawnServer()
        let outcome = RemoteCoreAttach.attachIfConfigured(
            environment: ["MDV_REMOTE_SOCKET": socketPath])
        guard case .attached = outcome else {
            return XCTFail("expected attach, got \(outcome)")
        }
        XCTAssertTrue(CoreTransportRegistry.current is RemoteTransport)

        // Drop the tunnel: the server dies; the reader's onClose must
        // revert the registry to in-process.
        server?.terminate()
        server?.waitUntilExit()
        server = nil
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !(CoreTransportRegistry.current is InProcessTransport) {
            usleep(20_000)
        }
        XCTAssertTrue(CoreTransportRegistry.current is InProcessTransport,
                      "connection loss must auto-revert to local engines")
        // The app keeps working on local engines afterwards.
        let ranked = try mdvCoreFuzzyRank(query: "fz", candidates: ["fuzzy", "nope"])
        XCTAssertEqual(ranked.first?.index, 0)
    }

    // TSK-1010: a transport that closed during the init→install window must not
    // stay installed (onClose may not have fired yet). Inject a pre-closed
    // socket-less transport — no mdv-serve needed, so this always runs.
    func test_attach_revertsIfTransportDiedDuringWindow() {
        CoreTransportRegistry.resetToInProcess()
        let dead = RemoteTransport(testSocketlessCapabilities: 0)
        dead._testSimulateReaderExit(nil)   // died during the window
        let outcome = RemoteCoreAttach.attachIfConfigured(
            environment: ["MDV_REMOTE_SOCKET": "/fake.sock"],
            _transportForTest: dead)
        guard case .failed = outcome else {
            return XCTFail("a transport closed during attach must fail, got \(outcome)")
        }
        XCTAssertTrue(CoreTransportRegistry.current is InProcessTransport,
                      "the dead transport must be reverted, not installed")
    }

    func test_attach_installsLiveInjectedTransport() {
        CoreTransportRegistry.resetToInProcess()
        let live = RemoteTransport(testSocketlessCapabilities: 0b101)
        let outcome = RemoteCoreAttach.attachIfConfigured(
            environment: ["MDV_REMOTE_SOCKET": "/fake.sock"],
            _transportForTest: live)
        guard case .attached(let caps) = outcome else {
            return XCTFail("a live transport must attach, got \(outcome)")
        }
        XCTAssertEqual(caps, 0b101)
        XCTAssertTrue(CoreTransportRegistry.current is RemoteTransport)
    }
}
