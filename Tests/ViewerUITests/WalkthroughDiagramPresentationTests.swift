import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1119 — the walkthrough illustration overlay's input-mapping (DiagramRequest → medium).
/// Pure host teeth, independent of the SwiftUI view: each kind maps to its presentation, an
/// empty payload renders nothing, and a `.image` with no resolved URL falls back to its path text.
@MainActor
final class WalkthroughDiagramPresentationTests: XCTestCase {

    func test_mermaid_mapsToMermaidSource() {
        let r = WalkthroughBridge.DiagramRequest(kind: .mermaid, data: "graph TD; A-->B")
        XCTAssertEqual(WalkthroughDiagramPresentation.of(r), .mermaid(source: "graph TD; A-->B"))
    }

    func test_ascii_mapsToAsciiText() {
        let r = WalkthroughBridge.DiagramRequest(kind: .ascii, data: "+--+\n|  |\n+--+")
        XCTAssertEqual(WalkthroughDiagramPresentation.of(r), .ascii(text: "+--+\n|  |\n+--+"))
    }

    func test_image_withURL_mapsToImage() {
        let url = URL(fileURLWithPath: "/tmp/diagram.png")
        let r = WalkthroughBridge.DiagramRequest(kind: .image, data: "diagram.png", imageURL: url)
        XCTAssertEqual(WalkthroughDiagramPresentation.of(r), .image(url: url))
    }

    func test_image_withoutURL_fallsBackToPathText() {
        let r = WalkthroughBridge.DiagramRequest(kind: .image, data: "diagram.png", imageURL: nil)
        XCTAssertEqual(WalkthroughDiagramPresentation.of(r), .ascii(text: "diagram.png"))
    }

    func test_emptyPayload_mapsToEmpty() {
        XCTAssertEqual(
            WalkthroughDiagramPresentation.of(WalkthroughBridge.DiagramRequest(kind: .ascii, data: "")),
            .empty)
        XCTAssertEqual(
            WalkthroughDiagramPresentation.of(WalkthroughBridge.DiagramRequest(kind: .mermaid, data: "")),
            .empty)
    }
}
