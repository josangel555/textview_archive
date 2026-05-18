import XCTest
@testable import ViewerCore

/// Pure state-machine tests for `WalkthroughEngine`. A fake delegate
/// records every action dispatched so we can assert ordering and the
/// "right variant per step" property without standing up any UI.
@MainActor
final class WalkthroughEngineTests: XCTestCase {

    // MARK: - Fake delegate

    private final class Recorder: WalkthroughEngineDelegate {
        var applied: [(stepID: String, action: Action)] = []
        var willApplyStepIDs: [String] = []
        var didApplyStepIDs: [String] = []

        func walkthroughEngine(
            _ engine: WalkthroughEngine,
            willApplyStep step: Step
        ) {
            willApplyStepIDs.append(step.id)
        }
        func walkthroughEngine(
            _ engine: WalkthroughEngine,
            apply action: Action,
            in step: Step
        ) {
            applied.append((step.id, action))
        }
        func walkthroughEngine(
            _ engine: WalkthroughEngine,
            didApplyStep step: Step
        ) {
            didApplyStepIDs.append(step.id)
        }
    }

    // MARK: - Fixture

    private func makeScript() -> WalkthroughScript {
        WalkthroughScript(
            id: "wt-test",
            title: "Engine tests",
            steps: [
                Step(id: "s1", actions: [
                    .openFile(OpenFilePayload(path: "a.swift", target: nil))
                ]),
                Step(id: "s2", actions: [
                    .highlightRange(HighlightRangePayload(
                        path: nil, startLine: 1, endLine: 3, style: .focus
                    )),
                    .showPopover(ShowPopoverPayload(
                        body: "hi", anchor: .editor, style: nil
                    )),
                ]),
                Step(id: "s3", actions: [.narrateOnly]),
            ]
        )
    }

    private func makeEngine(
        _ script: WalkthroughScript? = nil
    ) -> (WalkthroughEngine, Recorder) {
        let r = Recorder()
        let e = WalkthroughEngine(delegate: r)
        if let script { e.load(script) }
        return (e, r)
    }

    // MARK: - load semantics

    func test_load_doesNotApplyAnyStep() {
        let (e, r) = makeEngine(makeScript())
        XCTAssertEqual(e.state, .idle)
        XCTAssertEqual(e.stepIndex, -1)
        XCTAssertTrue(r.applied.isEmpty)
    }

    // MARK: - next / previous bounds

    func test_next_appliesStep0Then1Then2() {
        let (e, r) = makeEngine(makeScript())
        e.next()
        XCTAssertEqual(e.stepIndex, 0)
        XCTAssertEqual(e.state, .playing)
        XCTAssertEqual(r.applied.count, 1)
        XCTAssertEqual(r.applied[0].stepID, "s1")

        e.next()
        XCTAssertEqual(e.stepIndex, 1)
        // Step 2 has two actions — delegate fires twice.
        XCTAssertEqual(r.applied.count, 3)
        XCTAssertEqual(r.applied[1].stepID, "s2")
        XCTAssertEqual(r.applied[2].stepID, "s2")

        e.next()
        XCTAssertEqual(e.stepIndex, 2)
        XCTAssertEqual(r.applied.count, 4)
    }

    func test_next_atLastStep_transitionsToDone() {
        let (e, _) = makeEngine(makeScript())
        e.next(); e.next(); e.next() // s1, s2, s3
        XCTAssertEqual(e.stepIndex, 2)
        XCTAssertEqual(e.state, .playing)
        e.next() // off the end
        XCTAssertEqual(e.state, .done)
        XCTAssertEqual(e.stepIndex, 2, "Index should clamp at last step")
    }

    func test_next_withNoScript_isNoop() {
        let (e, r) = makeEngine()
        e.next()
        XCTAssertEqual(e.state, .idle)
        XCTAssertTrue(r.applied.isEmpty)
    }

    func test_previous_atFirstStep_isNoop() {
        let (e, r) = makeEngine(makeScript())
        e.next() // s1
        let countBefore = r.applied.count
        e.previous()
        XCTAssertEqual(e.stepIndex, 0)
        XCTAssertEqual(r.applied.count, countBefore,
                       "Previous at step 0 must not re-apply")
    }

    func test_previous_reappliesPriorStep() {
        let (e, r) = makeEngine(makeScript())
        e.next(); e.next() // at s2
        XCTAssertEqual(r.applied.count, 3)
        e.previous() // back to s1, re-apply
        XCTAssertEqual(e.stepIndex, 0)
        XCTAssertEqual(r.applied.last?.stepID, "s1")
    }

    // MARK: - jumpTo

    func test_jumpTo_validID_appliesThatStep() throws {
        let (e, r) = makeEngine(makeScript())
        try e.jumpTo(stepID: "s3")
        XCTAssertEqual(e.stepIndex, 2)
        XCTAssertEqual(e.state, .playing)
        XCTAssertEqual(r.applied.last?.stepID, "s3")
    }

    func test_jumpTo_unknownID_throws() {
        let (e, _) = makeEngine(makeScript())
        XCTAssertThrowsError(try e.jumpTo(stepID: "nope")) { err in
            XCTAssertEqual(err as? EngineError, .unknownStepID("nope"))
        }
    }

    func test_jumpTo_withoutScript_throws() {
        let (e, _) = makeEngine()
        XCTAssertThrowsError(try e.jumpTo(stepID: "s1")) { err in
            XCTAssertEqual(err as? EngineError, .noScriptLoaded)
        }
    }

    // MARK: - restart

    func test_restart_returnsToStep0AndReapplies() {
        let (e, r) = makeEngine(makeScript())
        e.next(); e.next(); e.next()
        let priorCount = r.applied.count
        e.restart()
        XCTAssertEqual(e.stepIndex, 0)
        XCTAssertEqual(e.state, .playing)
        XCTAssertGreaterThan(r.applied.count, priorCount)
        XCTAssertEqual(r.applied.last?.stepID, "s1")
    }

    // MARK: - pause / resume

    func test_pause_onlyTransitionsFromPlaying() {
        let (e, _) = makeEngine(makeScript())
        e.pause()
        XCTAssertEqual(e.state, .idle, "Pause from idle is a no-op")
        e.next()
        e.pause()
        XCTAssertEqual(e.state, .paused)
    }

    func test_resume_returnsToPlaying() {
        let (e, r) = makeEngine(makeScript())
        e.next()
        e.pause()
        let before = r.applied.count
        e.resume()
        XCTAssertEqual(e.state, .playing)
        XCTAssertEqual(r.applied.count, before,
                       "Resume must NOT re-apply the current step")
    }

    func test_resume_fromNonPaused_isNoop() {
        let (e, _) = makeEngine(makeScript())
        e.resume()
        XCTAssertEqual(e.state, .idle)
    }

    // MARK: - delegate sees the right variant per step

    func test_delegateReceivesActionVariantsMatchingStepDefinitions() {
        let (e, r) = makeEngine(makeScript())
        e.next(); e.next(); e.next()
        // 4 total actions: openFile, highlightRange, showPopover, narrateOnly.
        XCTAssertEqual(r.applied.count, 4)
        guard case .openFile = r.applied[0].action else {
            return XCTFail("Expected openFile, got \(r.applied[0].action)")
        }
        guard case .highlightRange = r.applied[1].action else {
            return XCTFail("Expected highlightRange, got \(r.applied[1].action)")
        }
        guard case .showPopover = r.applied[2].action else {
            return XCTFail("Expected showPopover, got \(r.applied[2].action)")
        }
        guard case .narrateOnly = r.applied[3].action else {
            return XCTFail("Expected narrateOnly, got \(r.applied[3].action)")
        }
    }

    func test_willAndDidApplyStep_bracketActions() {
        let (e, r) = makeEngine(makeScript())
        e.next()
        XCTAssertEqual(r.willApplyStepIDs, ["s1"])
        XCTAssertEqual(r.didApplyStepIDs, ["s1"])
        e.next()
        XCTAssertEqual(r.willApplyStepIDs, ["s1", "s2"])
        XCTAssertEqual(r.didApplyStepIDs, ["s1", "s2"])
    }

    // MARK: - empty script

    func test_emptyScript_nextImmediatelyTransitionsToDone() {
        let s = WalkthroughScript(id: "empty", title: "e", steps: [])
        let (e, r) = makeEngine(s)
        e.next()
        XCTAssertEqual(e.state, .done)
        XCTAssertTrue(r.applied.isEmpty)
    }

    func test_emptyScript_restartIsNoop() {
        let s = WalkthroughScript(id: "empty", title: "e", steps: [])
        let (e, r) = makeEngine(s)
        e.restart()
        XCTAssertEqual(e.state, .idle)
        XCTAssertTrue(r.applied.isEmpty)
    }
}
