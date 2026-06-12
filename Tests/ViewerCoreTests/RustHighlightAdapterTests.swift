import XCTest
@testable import ViewerCore
import RustCore
import ViewerKit

/// RustHighlightAdapter routing (engine port TSK-660): shipped default OFF
/// → Swift; env ON → Rust with app-contract runs (UTF-16 NSRanges, app
/// TokenKind vocabulary); a language the core build lacks → Swift fallback
/// (full coverage preserved during the migration). Gate state is injected
/// via `environment` so nothing process-global is touched.
final class RustHighlightAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    func test_shippedDefault_routesSwift() {
        // The first post-stage-A port ships OFF until its soak round —
        // the empty environment IS the shipped default.
        let out = RustHighlightAdapter.outcome(
            "let x = 1", language: .swift, environment: [:])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertEqual(
            out.value,
            TreeSitterEngine.shared.tokenize("let x = 1", language: .swift))
    }

    func test_gateOn_routesRust_withAppContractRuns() {
        let src = "fn main() { let x = 7; } // note"
        let out = RustHighlightAdapter.outcome(src, language: .rust, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        let runs = out.value
        XCTAssertFalse(runs.isEmpty)
        // Representative classifications on the rust path.
        func kind(at needle: String) -> TokenKind? {
            let loc = (src as NSString).range(of: needle).location
            return runs.first { NSLocationInRange(loc, $0.range) }?.kind
        }
        XCTAssertEqual(kind(at: "fn"), .keyword)
        XCTAssertEqual(kind(at: "main"), .function)
        XCTAssertEqual(kind(at: "// note"), .comment)
        // Ordered + disjoint NSRanges — the renderer's invariant.
        for w in zip(runs, runs.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(w.0.range), w.1.range.location)
        }
    }

    func test_gateOn_utf16Offsets_onMultibyteSource() {
        // "é" (2 bytes/1 unit) + "😀" (4 bytes/2 units) ahead of the
        // comment: byte offsets would shift the comment run 3 units right.
        let src = "let s = \"héllo 😀\" // café"
        let out = RustHighlightAdapter.outcome(src, language: .rust, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        let ns = src as NSString
        let commentLoc = ns.range(of: "// café").location
        let comment = out.value.first { $0.kind == .comment }
        XCTAssertEqual(comment?.range.location, commentLoc,
                       "comment run must start at the NSString UTF-16 offset")
        XCTAssertEqual(comment?.range.length, ns.length - commentLoc)
        // Every run stays inside the document in UTF-16 space.
        for r in out.value {
            XCTAssertLessThanOrEqual(NSMaxRange(r.range), ns.length)
        }
    }

    func test_gateOn_uncoveredLanguage_fallsBackToSwift() {
        // The core build covers a SUBSET of the Swift set until stage 3 —
        // yaml is Swift-only today, and the in-band supported:false signal
        // must land on the Swift engine, not on an empty result.
        let src = "key: value\nlist:\n  - a\n"
        let out = RustHighlightAdapter.outcome(src, language: .yaml, environment: gateOn)
        XCTAssertEqual(out.source, .swiftFallback)
        XCTAssertEqual(
            out.value, TreeSitterEngine.shared.tokenize(src, language: .yaml),
            "fallback must surface the full Swift result")
    }

    /// TSK-410 class, pinned at the ADAPTER level: with the gate ON, a
    /// lowercase TS identifier must not classify as `.type` — the Swift
    /// engine's predicate-blind mis-coloring (its `#match?` constraints are
    /// never evaluated) is absent on the rust path.
    func test_gateOn_tsLowercaseIdentifier_isNotType_tsk410() {
        let src = "const myThing = otherThing;"
        let out = RustHighlightAdapter.outcome(src, language: .typescript, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        let loc = (src as NSString).range(of: "myThing").location
        let kind = out.value.first { NSLocationInRange(loc, $0.range) }?.kind
        XCTAssertNotEqual(kind, .type, "predicate-gated capture must not classify lowercase as type")
        XCTAssertNotEqual(kind, .function)
    }

    func test_explicitToggleOff_beatsEnvAbsence_andDoesNotLeak() {
        // Adapter honors the same precedence stack as every other slice.
        let suite = "rust-highlight-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: RustCoreCapability.highlight.defaultsKey)
        let out = RustHighlightAdapter.outcome(
            "fn f() {}", language: .rust, defaults: defaults, environment: [:])
        XCTAssertEqual(out.source, .rust, "explicit ON toggle beats the OFF default")
        // env 0 still pins Swift over the explicit toggle.
        let pinned = RustHighlightAdapter.outcome(
            "fn f() {}", language: .rust, defaults: defaults,
            environment: ["MDV_RUST_HIGHLIGHT": "0"])
        XCTAssertEqual(pinned.source, .swiftBecauseGateOff)
    }
}
