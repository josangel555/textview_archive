import ApplicationServices
import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1254 bootstrap (2026-07-31) — the FIRST out-of-process AX
/// interaction tests: prove the whole chain end-to-end on the real app.
///
///   spawn dist/TextView.app → AXUIElementCreateApplication(pid)
///   → AXDriverCore.find("mdv.*") → kAXPressAction → observe the AX
///   tree change.
///
/// TIER-JUSTIFY: the observable is the OUT-OF-PROCESS AX tree of a real
/// app process — SwiftUI only materializes AX for external clients (the
/// in-process tree is empty, proven 2026-07-04), and a real `AXPress`
/// exercises the actual event routing a assistive client / automation
/// driver would use. No lower tier can produce either.
final class AXChromeInteractionTests: AXInteractionTestCase {

    // MARK: rig ---------------------------------------------------------

    private static let appExe: String = {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return here.appendingPathComponent(
            "dist/TextView.app/Contents/MacOS/MarkdownViewer").path
    }()

    private static let windowIDFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.markdownviewer.MarkdownViewer.windowid")

    private var app: Process?

    override func tearDown() {
        if let p = app, p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        app = nil
        super.tearDown()
    }

    /// Spawn the dist app into `scene` and return its AX application root
    /// once the window is up.
    private func spawnAndAttach(scene: String) throws -> AXUIElementNode {
        guard FileManager.default.isExecutableFile(atPath: Self.appExe) else {
            throw XCTSkip("App not built at dist/ — run the VM `pixel`/`all` lane.")
        }
        try? FileManager.default.removeItem(at: Self.windowIDFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.appExe)
        var env = ProcessInfo.processInfo.environment
        env["MDV_UI_SCENE"] = scene
        env["MDV_SKIP_WORKSPACE_RESTORE"] = "1"
        env["MDV_TEST_INSTANCE"] = "1"
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-ax-sessions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        env["MDV_SESSIONS_DIR"] = sessionsDir.path
        p.environment = env
        try p.run()
        app = p

        // Window up = the app publishes its window id (same signal the T5
        // rig waits on), then give the scene apply a beat to settle.
        let deadline = Date().addingTimeInterval(12)
        var sawWindow = false
        while Date() < deadline {
            if let data = try? Data(contentsOf: Self.windowIDFile),
               let s = String(data: data, encoding: .utf8),
               Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0 {
                sawWindow = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard sawWindow else {
            throw XCTSkip("no window id published — app failed to launch a window")
        }
        // Activate like the T5 rig does: SwiftUI routes an AXPress through
        // the normal responder path, and a never-activated background app
        // can accept the action without dispatching it.
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activate.arguments = ["-e", "tell application \"MarkdownViewer\" to activate"]
        try? activate.run()
        activate.waitUntilExit()
        Thread.sleep(forTimeInterval: 2.0)   // scene apply + first paint settle
        return AXUIElementNode.application(pid: p.processIdentifier)
    }


    /// Poll `condition` until it holds or `timeout` passes.
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return condition()
    }

    // MARK: tests -------------------------------------------------------

    /// THE unlock: our `mdv.*` accessibility identifiers are visible to an
    /// external AX client, with real geometry — the fact every future AX
    /// test builds on. (System Events could never see these; the
    /// in-process tree is empty. First run of this suite also caught the
    /// tab button's `.accessibilityElement(children: .ignore)` dropping
    /// the close button from the tree entirely — a real a11y defect.)
    func test_axTree_exposesMdvIdentifiers_withRealFrames() throws {
        let root = try spawnAndAttach(scene: "tabs-3")

        let strip = AXDriverCore.find("mdv.sessionTabBar", in: root)
        XCTAssertNotNil(strip, "the session strip must be AX-addressable by id")
        XCTAssertNotNil(strip?.axFrame, "…with real on-screen geometry")

        let tabsOK = waitUntil(5) {
            AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root).count == 3
        }
        XCTAssertTrue(tabsOK, "all 3 tabs must be AX-addressable by their ids "
            + "(got \(AXDriverCore.findAll(AXQuery("mdv.tab.item.*"), in: root).count))")
        XCTAssertGreaterThanOrEqual(
            AXDriverCore.findAll(AXQuery("mdv.tab.closeButton"), in: root).count, 1,
            "at least the SELECTED tab's close button must be pressable "
            + "(unhovered ones may fade at opacity 0)")
    }

    /// THE first real-event interaction, end-to-end: HID-click the
    /// session strip's "+" at its AX-reported frame and watch the GoTo
    /// panel materialize in the AX tree — real event → SwiftUI action →
    /// coordinator → new on-screen surface, all observed out-of-process.
    ///
    /// Mechanism, settled by measurement (2026-07-31, five rounds):
    /// AXPress is ACCEPTED but never dispatched by SwiftUI's bridge (the
    /// System-Events-adjacent trap); `postToPid` delivery is not
    /// hit-tested; the GLOBAL HID-tap click is what works — AX supplies
    /// find + geometry, HID supplies the event (`AXClickExecutor`).
    func test_hidClick_newSessionButton_opensGoToPrompt() throws {
        let root = try spawnAndAttach(scene: "tabs-3")
        _ = waitUntil(5) { AXDriverCore.find("mdv.sessionTab.new", in: root) != nil }
        guard let plus = AXDriverCore.find("mdv.sessionTab.new", in: root),
              let frame = plus.axFrame else {
            return XCTFail("the + button must be AX-addressable with a frame")
        }
        XCTAssertNil(AXDriverCore.find(AXQuery("mdv.goto.*"), in: root),
                     "precondition: no GoTo panel before the click")

        AXClickExecutor.click(centerOf: frame)

        let appeared = waitUntil(5) {
            AXDriverCore.find(AXQuery("mdv.goto.*"), in: root) != nil
        }
        XCTAssertTrue(appeared,
            "a REAL click on + must open the GoTo prompt (real event → "
            + "SwiftUI action → coordinator → new AX surface)")
    }
}
