import XCTest
@testable import ViewerCore

/// Host tests for the PM dependency graph + work_next queue + roll-up (TSK-345).
final class WorkItemGraphQueueTests: XCTestCase {

    private typealias Item = WorkItemModel.Item
    private typealias State = WorkItemModel.State

    private func item(
        _ id: String,
        state: State = .ready,
        parkReason: WorkItemModel.ParkReason? = nil,
        gate: WorkItemModel.AutonomyGate = .auto,
        dependsOn: [String] = [],
        consumes: [String] = [],
        touches: [String] = [],
        parent: String? = nil,
        hasAcceptance: Bool = true,
        budgetRemaining: Bool = true,
        contextFresh: Bool = true,
        tier: Int = 0,
        sequence: Int = 0,
        confidence: Double = 1.0,
        escalationThreshold: Double = 0.0
    ) -> Item {
        Item(
            id: id, state: state, parkReason: parkReason, gate: gate,
            confidence: confidence, escalationThreshold: escalationThreshold,
            dependsOn: dependsOn, consumes: consumes, touches: touches,
            parent: parent, hasAcceptance: hasAcceptance,
            budgetRemaining: budgetRemaining, contextFresh: contextFresh,
            tier: tier, sequence: sequence
        )
    }

    // MARK: - Cycle detection (teeth: cycles must be rejected)

    func testDependsOnCycleDetected() {
        let items = [
            item("a", dependsOn: ["b"]),
            item("b", dependsOn: ["c"]),
            item("c", dependsOn: ["a"]),
        ]
        guard case .wouldCreateCycle(let edge, let path)? = WorkItemGraph.validate(items) else {
            return XCTFail("expected a depends_on cycle")
        }
        XCTAssertEqual(edge, .dependsOn)
        XCTAssertTrue(Set(path).isSuperset(of: ["a", "b", "c"]))
    }

    func testParentCycleDetected() {
        let items = [
            item("a", parent: "b"),
            item("b", parent: "a"),
        ]
        guard case .wouldCreateCycle(let edge, _)? = WorkItemGraph.validate(items) else {
            return XCTFail("expected a parent cycle")
        }
        XCTAssertEqual(edge, .parent)
    }

    func testAcyclicGraphValidates() {
        let items = [
            item("a"),
            item("b", dependsOn: ["a"]),
            item("c", dependsOn: ["a", "b"], parent: nil),
            item("c1", parent: "c"),
        ]
        XCTAssertNil(WorkItemGraph.validate(items))
    }

    func testSelfReferenceRejected() {
        XCTAssertEqual(WorkItemGraph.validate([item("a", dependsOn: ["a"])]), .selfReference(id: "a"))
        XCTAssertEqual(WorkItemGraph.validate([item("a", parent: "a")]), .selfReference(id: "a"))
    }

    func testDanglingReferenceRejected() {
        XCTAssertEqual(
            WorkItemGraph.validate([item("a", dependsOn: ["ghost"])]),
            .danglingReference(id: "ghost"))
    }

    func testConsumesCycleIsAllowed() {
        // consumes is a ripple edge, not an ordering DAG — a cycle there is not
        // rejected by validate (only depends_on / parent are acyclic).
        let items = [
            item("a", consumes: ["b"]),
            item("b", consumes: ["a"]),
        ]
        XCTAssertNil(WorkItemGraph.validate(items))
    }

    // MARK: - Reverse-ripple invalidation (§1.7)

    func testInvalidationRipplesToVerifiedDoneConsumers() {
        let items = [
            item("up", state: .verifiedDone),
            item("mid", state: .verifiedDone, consumes: ["up"]),
            item("down", state: .verifiedDone, consumes: ["mid"]),
            item("unrelated", state: .verifiedDone),
        ]
        let hit = WorkItemGraph.invalidatedDownstream(of: ["up"], in: items)
        XCTAssertEqual(hit, ["mid", "down"])
        XCTAssertFalse(hit.contains("up"))
        XCTAssertFalse(hit.contains("unrelated"))
    }

    func testInvalidationSkipsNonVerifiedConsumersButRippleContinues() {
        // 'mid' is still active (not verifiedDone) so it isn't itself invalidated,
        // but the ripple must still reach 'down' which consumed 'mid'.
        let items = [
            item("up", state: .verifiedDone),
            item("mid", state: .active, consumes: ["up"]),
            item("down", state: .verifiedDone, consumes: ["mid"]),
        ]
        let hit = WorkItemGraph.invalidatedDownstream(of: ["up"], in: items)
        XCTAssertFalse(hit.contains("mid"))
        XCTAssertTrue(hit.contains("down"))
    }

    // MARK: - work_next candidacy (each exclusion reason)

    func testReadyAutoLeafIsCandidate() {
        let items = [item("a")]
        XCTAssertTrue(WorkItemQueue.isCandidate(items[0], in: items))
        XCTAssertTrue(WorkItemQueue.candidacy(of: items[0], in: items).isEmpty)
    }

    func testParentIsNotCandidate() {
        let items = [item("p"), item("c", parent: "p")]
        XCTAssertTrue(WorkItemQueue.candidacy(of: items[0], in: items).contains(.notLeaf))
        XCTAssertTrue(WorkItemQueue.isCandidate(items[1], in: items))
    }

    func testUnsatisfiedDependencyExcludes() {
        let items = [
            item("up", state: .active),       // not closed/abandoned → unsatisfied
            item("dn", dependsOn: ["up"]),
        ]
        XCTAssertTrue(WorkItemQueue.candidacy(of: items[1], in: items).contains(.unsatisfiedDependency))
        // Once upstream is closed, downstream becomes a candidate.
        let satisfied = [item("up", state: .closed), item("dn", dependsOn: ["up"])]
        XCTAssertTrue(WorkItemQueue.isCandidate(satisfied[1], in: satisfied))
    }

    func testStaleUpstreamExcludes() {
        let items = [
            item("up", state: .assumptionsInvalidated),
            item("dn", consumes: ["up"]),
        ]
        XCTAssertTrue(WorkItemQueue.candidacy(of: items[1], in: items).contains(.staleUpstream))
    }

    func testContentionExcludes() {
        let items = [
            item("a", state: .active, touches: ["b"]),
            item("b", touches: ["a"]),
        ]
        XCTAssertTrue(WorkItemQueue.candidacy(of: items[1], in: items).contains(.contention))
    }

    func testSupervisedGateAndHumanParkAndBudgetAndAcceptanceAndStaleContext() {
        XCTAssertTrue(WorkItemQueue.candidacy(
            of: item("a", gate: .supervised), in: [item("a", gate: .supervised)]).contains(.autonomyGate))
        let parked = item("a", state: .parked, parkReason: .awaitingDecision)
        XCTAssertTrue(WorkItemQueue.candidacy(of: parked, in: [parked]).contains(.autonomyGate))
        let noBudget = item("a", budgetRemaining: false)
        XCTAssertTrue(WorkItemQueue.candidacy(of: noBudget, in: [noBudget]).contains(.budgetExhausted))
        let noAcc = item("a", hasAcceptance: false)
        XCTAssertTrue(WorkItemQueue.candidacy(of: noAcc, in: [noAcc]).contains(.noAcceptance))
        let stale = item("a", contextFresh: false)
        XCTAssertTrue(WorkItemQueue.candidacy(of: stale, in: [stale]).contains(.staleContext))
    }

    // MARK: - work_next ranking (deterministic)

    func testRankingTierThenUnblockThenAgeThenId() {
        let items = [
            item("z", tier: 1, sequence: 0),                 // worse tier → later
            item("blocker", tier: 0, sequence: 5),           // unblocks two → earlier
            item("y", tier: 0, sequence: 1),                 // tier 0, no unblock weight
            item("x", dependsOn: ["blocker"], tier: 0, sequence: 2),
            item("w", dependsOn: ["blocker"], tier: 0, sequence: 3),
        ]
        let ranked = WorkItemQueue.workNext(items).map(\.id)
        // 'blocker' unblocks x and w (weight 2) so it leads tier 0; x/w are excluded
        // (depends on an unfinished blocker); y is tier 0 weight 0; z is tier 1.
        XCTAssertEqual(ranked.first, "blocker")
        XCTAssertEqual(ranked.last, "z")
        XCTAssertFalse(ranked.contains("x"))
        XCTAssertFalse(ranked.contains("w"))
    }

    func testStableIdTiebreak() {
        let items = [
            item("b", tier: 0, sequence: 0),
            item("a", tier: 0, sequence: 0),
        ]
        XCTAssertEqual(WorkItemQueue.workNext(items).map(\.id), ["a", "b"])
    }

    func testNextReturnsTopOrNil() {
        XCTAssertEqual(WorkItemQueue.next([item("a")])?.id, "a")
        XCTAssertNil(WorkItemQueue.next([item("a", gate: .supervised)]))
    }

    // MARK: - Autonomy gate

    func testAutoRunnableRequiresAllThreeAffirmatives() {
        let auto = item("a", gate: .auto)
        XCTAssertTrue(WorkItemQueue.isAutoRunnable(auto, in: [auto]))
        let gated = item("a", gate: .gated)
        XCTAssertFalse(WorkItemQueue.isAutoRunnable(gated, in: [gated]))
        // auto but blocked by contention → not auto-runnable.
        let contended = [item("a", state: .active, touches: ["b"]), item("b", gate: .auto, touches: ["a"])]
        XCTAssertFalse(WorkItemQueue.isAutoRunnable(contended[1], in: contended))
    }

    func testConfidenceEscalation() {
        XCTAssertTrue(WorkItemQueue.shouldEscalateOnConfidence(
            item("a", confidence: 0.3, escalationThreshold: 0.5)))
        XCTAssertFalse(WorkItemQueue.shouldEscalateOnConfidence(
            item("a", confidence: 0.8, escalationThreshold: 0.5)))
    }

    // MARK: - Roll-up projection (worst-wins precedence)

    func testRollupHumanParkBubblesAndPings() {
        let items = [
            item("p"),
            item("c1", state: .active, parent: "p"),
            item("c2", state: .parked, parkReason: .awaitingDecision, parent: "p"),
        ]
        let rolled = WorkItemRollup.rollup(of: "p", in: items)
        XCTAssertEqual(rolled, .blockedHuman)
        XCTAssertTrue(WorkItemRollup.shouldPing(rolled))
    }

    func testRollupAutoParkIsSilent() {
        let items = [
            item("p"),
            item("c1", state: .parked, parkReason: .awaitingDependency, parent: "p"),
            item("c2", state: .ready, parent: "p"),
        ]
        // ready child outranks an auto-park? No — precedence: active > autoPark > ready.
        // Here no active, autoPark present → blockedAuto wins over ready.
        let rolled = WorkItemRollup.rollup(of: "p", in: items)
        XCTAssertEqual(rolled, .blockedAuto)
        XCTAssertFalse(WorkItemRollup.shouldPing(rolled))
    }

    func testRollupActiveOutranksAutoPark() {
        let items = [
            item("p"),
            item("c1", state: .active, parent: "p"),
            item("c2", state: .parked, parkReason: .awaitingDependency, parent: "p"),
        ]
        XCTAssertEqual(WorkItemRollup.rollup(of: "p", in: items), .active)
    }

    func testRollupSettledNotAutoClosed() {
        let items = [
            item("p"),
            item("c1", state: .verifiedDone, parent: "p"),
            item("c2", state: .verifiedDone, parent: "p"),
        ]
        // All children verified-done → parent SETTLED (eligible for own review), NOT closed.
        XCTAssertEqual(WorkItemRollup.rollup(of: "p", in: items), .settled)
    }

    func testRollupAllClosed() {
        let items = [
            item("p"),
            item("c1", state: .closed, parent: "p"),
            item("c2", state: .closed, parent: "p"),
        ]
        XCTAssertEqual(WorkItemRollup.rollup(of: "p", in: items), .closed)
    }

    func testRollupMixedTerminalNeedsAttention() {
        let items = [
            item("p"),
            item("c1", state: .verifiedDone, parent: "p"),
            item("c2", state: .abandoned, parent: "p"),
        ]
        XCTAssertEqual(WorkItemRollup.rollup(of: "p", in: items), .needsAttention)
    }

    func testRollupEmptyParent() {
        XCTAssertEqual(WorkItemRollup.rollup(of: "p", in: [item("p")]), .empty)
    }
}
