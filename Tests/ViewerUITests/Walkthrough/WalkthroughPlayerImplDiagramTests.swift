import XCTest
@testable import ViewerUI
import ViewerCore

/// Behaviour tests for the `diagram` (illustration) verb's delegate
/// dispatch in `WalkthroughPlayerImpl`. The render path (Mermaid
/// WebView / ASCII callout / image view) is VM-validated, but the
/// MODEL-state outcome of applying the verb — what lands on the
/// `WalkthroughBridge` diagram channel — is host-testable and pinned
/// here so a routing regression fails the host gate (per the
/// change→tests mandate: pin each verb's interaction behaviour).
@MainActor
final class WalkthroughPlayerImplDiagramTests: XCTestCase {

    /// Build a model + engine + impl wired together, with the impl
    /// prepared for `script` (caches the rootHint). Mirrors the host
    /// wiring the player view does before `engine.load`.
    private func makeStack(
        for script: WalkthroughScript
    ) -> (DocumentModel, WalkthroughEngine, WalkthroughPlayerImpl) {
        let model = DocumentModel()
        let engine = WalkthroughEngine()
        let impl = WalkthroughPlayerImpl(model: model, engine: engine)
        impl.prepare(for: script)
        engine.delegate = impl
        engine.load(script)
        return (model, engine, impl)
    }

    private func script(actions: [Action], rootHint: String? = nil)
        -> WalkthroughScript
    {
        WalkthroughScript(
            schema: .v2, id: "diag", title: "Diag",
            rootHint: rootHint,
            steps: [Step(id: "s1", actions: actions)]
        )
    }

    func test_diagramMermaid_publishesToBridge() {
        let s = script(actions: [.diagram(DiagramPayload(
            diagramKind: .mermaid, data: "graph TD; A-->B;",
            caption: "the flow"
        ))])
        // `impl` must be retained: WalkthroughEngine.delegate is weak, so
        // dropping the impl deallocates the delegate and `next()` no-ops.
        let (model, engine, impl) = makeStack(for: s)
        defer { _ = impl }
        engine.next()  // apply step s1

        let d = model.walkthroughBridge.diagram
        XCTAssertEqual(d?.kind, .mermaid)
        XCTAssertEqual(d?.data, "graph TD; A-->B;")
        XCTAssertEqual(d?.caption, "the flow")
        // Mermaid carries inline source, no image URL to resolve.
        XCTAssertNil(d?.imageURL)
    }

    func test_diagramAscii_publishesToBridge() {
        let s = script(actions: [.diagram(DiagramPayload(
            diagramKind: .ascii, data: "+---+\n| A |\n+---+"
        ))])
        let (model, engine, impl) = makeStack(for: s)
        defer { _ = impl }
        engine.next()

        let d = model.walkthroughBridge.diagram
        XCTAssertEqual(d?.kind, .ascii)
        XCTAssertEqual(d?.data, "+---+\n| A |\n+---+")
        XCTAssertNil(d?.imageURL)
    }

    func test_diagramImage_resolvesPathAgainstRootHint() {
        // The `image` kind's `data` is a relative path; the delegate
        // resolves it against the cached rootHint into an absolute URL
        // the overlay can load directly. Use a real (non-symlinked)
        // temp dir as the root so `resolvingSymlinksInPath()` (which
        // collapses /tmp → /private/tmp) doesn't make the suffix
        // comparison brittle.
        let root = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        let s = script(
            actions: [.diagram(DiagramPayload(
                diagramKind: .image, data: "assets/arch.png"
            ))],
            rootHint: root.path
        )
        let (model, engine, impl) = makeStack(for: s)
        defer { _ = impl }
        engine.next()

        let d = model.walkthroughBridge.diagram
        XCTAssertEqual(d?.kind, .image)
        let expected = root.appendingPathComponent("assets/arch.png").path
        XCTAssertEqual(d?.imageURL?.path, expected,
                       "image path must resolve under rootHint")
    }

    func test_diagramImage_absolutePath_passesThrough() {
        let root = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        let abs = root.appendingPathComponent("x.png").path
        let s = script(actions: [.diagram(DiagramPayload(
            diagramKind: .image, data: abs
        ))], rootHint: root.path)
        let (model, engine, impl) = makeStack(for: s)
        defer { _ = impl }
        engine.next()

        let d = model.walkthroughBridge.diagram
        XCTAssertEqual(d?.imageURL?.path, abs)
    }

    func test_diagram_clearedOnStepTransition() {
        // A step with a diagram followed by a step without one must
        // clear the diagram channel (willApplyStep wipes transients).
        let s = WalkthroughScript(
            schema: .v2, id: "two", title: "Two",
            steps: [
                Step(id: "s1", actions: [.diagram(DiagramPayload(
                    diagramKind: .ascii, data: "x"
                ))]),
                Step(id: "s2", actions: [.narrateOnly]),
            ]
        )
        let model = DocumentModel()
        let engine = WalkthroughEngine()
        let impl = WalkthroughPlayerImpl(model: model, engine: engine)
        impl.prepare(for: s)
        engine.delegate = impl
        engine.load(s)

        engine.next()  // s1 — diagram set
        XCTAssertNotNil(model.walkthroughBridge.diagram)
        engine.next()  // s2 — narrateOnly, must clear
        XCTAssertNil(model.walkthroughBridge.diagram)
    }
}
