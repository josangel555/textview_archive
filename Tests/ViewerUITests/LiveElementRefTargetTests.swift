import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1256 slice 4 — host coverage for the LIVE ElementRefTarget. The
/// host-routable resolutions (.tab select, .file open) drive a real
/// DocumentModel and are asserted on its state; the render-only ones (.web/.ax)
/// are asserted to delegate to the injected render-bridge closures (the actual
/// CM6 cmDispatch / AXDriverCore wiring + its pixels are the VM slice).
@MainActor
final class LiveElementRefTargetTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "LiveElementRefTargetTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func makeTarget() -> LiveElementRefTarget {
        LiveElementRefTarget(
            model: harness.model,
            gotoWebLine: { _, _ in true },
            selectWebNode: { _, _ in true },
            activateAX: { _ in true })
    }

    func test_selectTab_resolvesRefByTabID() throws {
        let a = try harness.writeFile("ref-a.txt", "A\n"); harness.model.open(url: a)
        let b = try harness.writeFile("ref-b.txt", "B\n"); harness.model.open(url: b)
        let aTab = try XCTUnwrap(harness.model.tabs.tabs.first { $0.url == a })
        XCTAssertNotEqual(harness.model.tabs.selected?.id, aTab.id, "precondition: last-opened (b) is selected")

        let ok = ElementRefExecutor.execute(.tab(id: aTab.id.uuidString), on: makeTarget())

        XCTAssertTrue(ok)
        XCTAssertEqual(harness.model.tabs.selected?.id, aTab.id, "the ref activated a's tab")
    }

    func test_selectTab_unknownID_returnsFalse() {
        XCTAssertFalse(ElementRefExecutor.execute(.tab(id: "not-a-real-uuid"), on: makeTarget()))
    }

    func test_openFile_opensViaModel() throws {
        let f = try harness.writeFile("ref-open.txt", "hi\n")
        let ok = ElementRefExecutor.execute(.file(path: f.path, line: nil), on: makeTarget())
        XCTAssertTrue(ok)
        XCTAssertTrue(harness.model.tabs.tabs.contains { $0.url?.path == f.path }, "file opened as a tab")
    }

    func test_webAndAX_delegateToRenderBridges() {
        var gotoCalls: [(String, Int)] = []
        var axCalls: [String] = []
        let target = LiveElementRefTarget(
            model: harness.model,
            gotoWebLine: { d, l in gotoCalls.append((d, l)); return true },
            selectWebNode: { _, _ in true },
            activateAX: { q in axCalls.append(q.stem); return true })

        ElementRefExecutor.execute(.webLine(docId: "d1", line: 7), on: target)
        ElementRefExecutor.execute(.ax(identifier: "mdv.hexView"), on: target)

        XCTAssertEqual(gotoCalls.map(\.1), [7], ".web delegated to the goto-line render bridge")
        XCTAssertEqual(axCalls, ["mdv.hexView"], ".ax delegated to the AX render bridge")
    }
}
