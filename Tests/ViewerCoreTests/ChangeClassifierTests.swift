import XCTest
@testable import ViewerCore

/// TSK-1195(a) — the host-vs-render change classifier (false-done killer).
final class ChangeClassifierTests: XCTestCase {

    func test_hostProvable_tiers() {
        for p in ["Sources/ViewerCore/PaletteCandidateCache.swift",
                  "Sources/ViewerKit/HighlightLanguage.swift",
                  "rust-core/crates/core/src/markdown.rs"] {
            XCTAssertEqual(ChangeClassifier.classify(p), .hostProvable, p)
        }
    }

    func test_renderPath_viewerUI() {
        XCTAssertEqual(ChangeClassifier.classify("Sources/ViewerUI/CommandPaletteView.swift"),
                       .renderPath)
        XCTAssertEqual(ChangeClassifier.classify("Sources/MarkdownViewer/App.swift"), .renderPath)
    }

    func test_needsVM_webViewSurfaces() {
        for p in ["Sources/ViewerUI/Resources/codemirror/codemirror.html",
                  "Sources/ViewerUI/Resources/canvas/canvas.html",
                  "Sources/ViewerUI/Resources/codemirror/bridge.js"] {
            XCTAssertEqual(ChangeClassifier.classify(p), .needsVM, p)
        }
    }

    func test_testOnly_and_nonCode() {
        XCTAssertEqual(ChangeClassifier.classify("Tests/ViewerCoreTests/FooTests.swift"), .testOnly)
        XCTAssertEqual(ChangeClassifier.classify("docs/DESIGN.md"), .nonCode)
        XCTAssertEqual(ChangeClassifier.classify("scripts/build-app.sh"), .nonCode)
        XCTAssertEqual(ChangeClassifier.classify("schemas/html-sanitizer-policy.json"), .nonCode)
    }

    func test_unknownPath_needsReview() {
        XCTAssertEqual(ChangeClassifier.classify("weird/unmapped/thing.xyz"), .needsReview)
    }

    func test_leadingDotSlash_stripped() {
        XCTAssertEqual(ChangeClassifier.classify("./Sources/ViewerUI/Foo.swift"), .renderPath)
    }

    // MARK: aggregate

    func test_aggregate_pureHostChange_isHostCertifiable() {
        let v = ChangeClassifier.classify(paths: [
            "Sources/ViewerCore/A.swift", "Tests/ViewerCoreTests/ATests.swift", "docs/x.md",
        ])
        XCTAssertEqual(v.overall, .hostProvable)
        XCTAssertTrue(v.hostCertifiable, "pure-core + tests + docs → host-green certifies")
    }

    func test_aggregate_oneRenderFile_forcesNotHostCertifiable() {
        // Even a mostly-host change is NOT host-certifiable if one file renders.
        let v = ChangeClassifier.classify(paths: [
            "Sources/ViewerCore/A.swift", "Sources/ViewerUI/AView.swift",
        ])
        XCTAssertEqual(v.overall, .renderPath, "most-restrictive wins")
        XCTAssertFalse(v.hostCertifiable, "the false-done killer: one render file → needs VM/owner")
    }

    func test_aggregate_webViewDominates() {
        let v = ChangeClassifier.classify(paths: [
            "Sources/ViewerUI/X.swift",
            "Sources/ViewerUI/Resources/codemirror/codemirror.html",
        ])
        XCTAssertEqual(v.overall, .needsVM, "WebView is the most restrictive")
        XCTAssertFalse(v.hostCertifiable)
    }

    func test_aggregate_empty_isNonCode() {
        let v = ChangeClassifier.classify(paths: [])
        XCTAssertEqual(v.overall, .nonCode)
        XCTAssertTrue(v.hostCertifiable, "nothing to prove")
    }

    func test_aggregate_unknownFile_notHostCertifiable() {
        let v = ChangeClassifier.classify(paths: ["Sources/ViewerCore/A.swift", "mystery.bin"])
        XCTAssertEqual(v.overall, .needsReview)
        XCTAssertFalse(v.hostCertifiable, "an unrecognized file is classified conservatively")
    }
}
