import XCTest
@testable import ViewerCore
import RustCore
import ViewerKit

/// RustHighlightAdapter routing (engine port TSK-660; twin deletion TSK-854):
/// the shipped default is RUST with app-contract runs (UTF-16 NSRanges, app
/// TokenKind vocabulary). TSK-854 deleted the Swift highlight twin, so the
/// adapter is now rust-only: the `.highlight` gate's only remaining role is an
/// off-switch — gate OFF (or a bridge fault) yields EMPTY runs (plain text),
/// NOT Swift-engine tokens. Gate state is injected via `environment` so
/// nothing process-global is touched.
final class RustHighlightAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_HIGHLIGHT": "1"]

    func test_shippedDefault_routesRust() {
        // TSK-660 flip round: the empty environment IS the shipped default,
        // and it routes RUST now.
        let out = RustHighlightAdapter.outcome(
            "let x = 1", language: .swift, environment: [:])
        XCTAssertEqual(out.source, .rust)
        XCTAssertFalse(out.value.isEmpty)
    }

    func test_envZero_disablesHighlighting() {
        // TSK-854: the off-switch now yields NO highlighting (empty runs),
        // not Swift-engine tokens — the Swift highlight twin is gone. The
        // provenance tag stays `.swiftBecauseGateOff` (the gate did short the
        // rust path), but the value is empty (plain text).
        let out = RustHighlightAdapter.outcome(
            "let x = 1", language: .swift,
            environment: ["MDV_RUST_HIGHLIGHT": "0"])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertTrue(out.value.isEmpty,
            "gate-off must render plain (no highlighting), not fall back to the deleted Swift engine")
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

    func test_gateOn_uncoveredLanguage_rendersPlain() {
        // The forever-uncovered case is .plainText — the rust in-band
        // supported:false signal makes the rust closure throw, and TSK-854's
        // rust-only fallback degrades to EMPTY runs (plain text), tagged
        // `.swiftFallback` (a bridge "fault" was caught). No Swift engine.
        let src = "just words\n"
        let out = RustHighlightAdapter.outcome(src, language: .plainText, environment: gateOn)
        XCTAssertEqual(out.source, .swiftFallback)
        XCTAssertTrue(out.value.isEmpty, "an uncovered language renders plain (no runs)")
    }

    func test_gateOn_stage3Languages_routeRust() {
        // The parity set added in stage 3 must actually route rust now.
        for (lang, src): (HighlightLanguage, String) in [
            (.yaml, "key: value\n# note\n"),
            (.python, "def f():\n    return 1\n"),
            (.go, "func main() {}\n"),
            (.html, "<div class=\"a\">x</div>\n"),
        ] {
            let out = RustHighlightAdapter.outcome(src, language: lang, environment: gateOn)
            XCTAssertEqual(out.source, .rust, "\(lang) must route rust post-stage-3")
            XCTAssertFalse(out.value.isEmpty, "\(lang) must produce runs")
        }
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

    // TSK-853 — the launch warm routes through the adapter so it heats the
    // gate-SELECTED engine (Rust by default), not just the Swift fallback.
    // These pin the WIRING + concurrency safety of the warm path. The actual
    // config-cache population is a pure latency property — behaviorally
    // invisible on the host (a no-op warm yields identical tokenize output) —
    // so its teeth lives in the rust `config_cache` test
    // (`configured_grammar_is_cached_not_recompiled`) + VM/manual timing.

    func test_warm_gateOn_concurrentAllLanguages_isSafe_andStillRoutesRust() {
        // phase-2 concurrentPerform fires concurrent Rust-FFI + Swift-engine
        // calls across every language — must not crash/deadlock (the real
        // concurrency teeth: a non-thread-safe warm reddens here).
        RustHighlightAdapter.warm(
            HighlightLanguage.allCases, prioritizing: [.markdown], environment: gateOn)
        for (lang, src): (HighlightLanguage, String) in [
            (.swift, "let x = 1"), (.rust, "fn f() {}"), (.python, "def f():\n    return 1\n"),
        ] {
            let out = RustHighlightAdapter.outcome(src, language: lang, environment: gateOn)
            XCTAssertEqual(out.source, .rust, "\(lang) still routes rust after warm")
            XCTAssertFalse(out.value.isEmpty)
        }
    }

    func test_warm_gateOff_isNoOp_andDoesNotCrash() {
        // TSK-854: the warm routes through the rust-only adapter, so under the
        // off-switch it does NOT touch the (deleted-for-highlighting) Swift
        // engine — it's a safe no-op (the gate-off closure produces no runs).
        // The teeth: it must not crash, and it must not leave a highlightable
        // result on the off path.
        RustHighlightAdapter.warm(
            [.json], prioritizing: [.swift], environment: ["MDV_RUST_HIGHLIGHT": "0"])
        let out = RustHighlightAdapter.outcome(
            "let x = 1", language: .swift, environment: ["MDV_RUST_HIGHLIGHT": "0"])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertTrue(out.value.isEmpty, "gate-off highlighting stays empty after a warm")
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
