import XCTest
@testable import ViewerCore

/// Host tests for the Project Management foundation slice (TSK-345) — the pure
/// work-item model: lifecycle state machine, dependency graph, work_next queue,
/// autonomy gate, and parent roll-up. Every test pins a BEHAVIOUR (a model/state
/// outcome) so a logic regression fails the host gate; there is no render path
/// in this slice, so it is fully host-validatable.
final class WorkItemModelTests: XCTestCase {

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

    // MARK: - State classification

    func testStateOpennessAndTerminality() {
        XCTAssertTrue(State.ready.isOpen)
        XCTAssertTrue(State.parked.isOpen)
        XCTAssertFalse(State.closed.isOpen)
        XCTAssertFalse(State.abandoned.isOpen)
        XCTAssertFalse(State.rejected.isOpen)
        XCTAssertTrue(State.closed.isTerminal)
        XCTAssertTrue(State.abandoned.isTerminal)
        XCTAssertTrue(State.rejected.isTerminal)
        XCTAssertFalse(State.active.isTerminal)
    }

    func testOrderingSatisfaction() {
        XCTAssertTrue(State.closed.satisfiesOrdering)
        XCTAssertTrue(State.abandoned.satisfiesOrdering)
        XCTAssertFalse(State.verifiedDone.satisfiesOrdering)
        XCTAssertFalse(State.active.satisfiesOrdering)
    }

    // MARK: - ParkReason behavioural axes

    func testParkReasonHumanAndAutoResume() {
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingDecision.requiresHuman)
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingApproval.requiresHuman)
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingInput.requiresHuman)
        XCTAssertFalse(WorkItemModel.ParkReason.awaitingDependency.requiresHuman)
        XCTAssertFalse(WorkItemModel.ParkReason.awaitingGate.requiresHuman)

        XCTAssertTrue(WorkItemModel.ParkReason.awaitingDependency.autoResumes)
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingGate.autoResumes)
        XCTAssertFalse(WorkItemModel.ParkReason.awaitingDecision.autoResumes)
    }

    func testParkReasonNotificationPolicy() {
        // Dependency waits are silent; decision/approval/input ping.
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingDecision.pingsHuman)
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingApproval.pingsHuman)
        XCTAssertTrue(WorkItemModel.ParkReason.awaitingInput.pingsHuman)
        XCTAssertFalse(WorkItemModel.ParkReason.awaitingDependency.pingsHuman)
        XCTAssertFalse(WorkItemModel.ParkReason.awaitingGate.pingsHuman)
    }

    // MARK: - Lifecycle: legal transitions

    func testHappyPathTransitions() {
        XCTAssertTrue(WorkItemLifecycle.isLegalEdge(from: .proposed, to: .ready))
        XCTAssertTrue(WorkItemLifecycle.isLegalEdge(from: .ready, to: .active))
        XCTAssertTrue(WorkItemLifecycle.isLegalEdge(from: .active, to: .claimedDone))
        XCTAssertTrue(WorkItemLifecycle.isLegalEdge(from: .claimedDone, to: .verifiedDone))
        XCTAssertTrue(WorkItemLifecycle.isLegalEdge(from: .verifiedDone, to: .closed))
    }

    func testIllegalEdgesRejected() {
        // Teeth: skipping the review gate must be impossible.
        XCTAssertFalse(WorkItemLifecycle.isLegalEdge(from: .active, to: .closed))
        XCTAssertFalse(WorkItemLifecycle.isLegalEdge(from: .active, to: .verifiedDone))
        XCTAssertFalse(WorkItemLifecycle.isLegalEdge(from: .proposed, to: .active))
        XCTAssertFalse(WorkItemLifecycle.isLegalEdge(from: .closed, to: .active))
    }

    // MARK: - Lifecycle: transition OWNERSHIP (the safety boundary)

    func testAgentCannotSelfCertifyDone() {
        // claimedDone → verifiedDone is the verifier gate; an AGENT firing it
        // must be rejected — the structural realization of "never self-certify".
        XCTAssertEqual(
            WorkItemLifecycle.validate(
                from: .claimedDone, to: .verifiedDone, actor: .agent, parkReason: nil),
            .actorNotAuthorized(from: .claimedDone, to: .verifiedDone, actor: .agent))
        // The system (verifier) may.
        XCTAssertNil(
            WorkItemLifecycle.validate(
                from: .claimedDone, to: .verifiedDone, actor: .system, parkReason: nil))
    }

    func testAgentCannotAdmitOrAbandon() {
        // proposed → ready is human-only admission.
        XCTAssertEqual(
            WorkItemLifecycle.validate(from: .proposed, to: .ready, actor: .agent, parkReason: nil),
            .actorNotAuthorized(from: .proposed, to: .ready, actor: .agent))
        // active → abandoned is human-only.
        XCTAssertEqual(
            WorkItemLifecycle.validate(from: .active, to: .abandoned, actor: .agent, parkReason: nil),
            .actorNotAuthorized(from: .active, to: .abandoned, actor: .agent))
    }

    func testAgentMayProposeDoneAndSelfPark() {
        XCTAssertNil(
            WorkItemLifecycle.validate(from: .active, to: .claimedDone, actor: .agent, parkReason: nil))
        XCTAssertNil(
            WorkItemLifecycle.validate(
                from: .active, to: .parked, actor: .agent, parkReason: .awaitingGate))
    }

    func testNoSuchEdgeError() {
        XCTAssertEqual(
            WorkItemLifecycle.validate(from: .closed, to: .active, actor: .human, parkReason: nil),
            .noSuchEdge(from: .closed, to: .active))
    }

    // MARK: - Lifecycle: parkReason invariant

    func testParkRequiresReasonAndOthersForbidIt() {
        XCTAssertEqual(
            WorkItemLifecycle.validate(from: .active, to: .parked, actor: .agent, parkReason: nil),
            .parkReasonMismatch)
        XCTAssertEqual(
            WorkItemLifecycle.validate(
                from: .active, to: .claimedDone, actor: .agent, parkReason: .awaitingGate),
            .parkReasonMismatch)
    }

    func testApplyCouplesStateAndParkReason() {
        let i = item("a", state: .active)
        // Park: reason is set.
        guard case .success(let parked) = WorkItemLifecycle.apply(
            i, to: .parked, actor: .agent, parkReason: .awaitingDependency) else {
            return XCTFail("park should succeed")
        }
        XCTAssertEqual(parked.state, .parked)
        XCTAssertEqual(parked.parkReason, .awaitingDependency)

        // Resume: reason is cleared even if the item still carried one.
        guard case .success(let resumed) = WorkItemLifecycle.apply(
            parked, to: .active, actor: .system, parkReason: nil) else {
            return XCTFail("resume should succeed")
        }
        XCTAssertEqual(resumed.state, .active)
        XCTAssertNil(resumed.parkReason)
    }

    func testApplyRejectsIllegalActor() {
        let i = item("a", state: .claimedDone)
        guard case .failure = WorkItemLifecycle.apply(i, to: .verifiedDone, actor: .agent) else {
            return XCTFail("agent self-certify must be rejected")
        }
    }

    // MARK: - Lifecycle: escalation as a state edge

    func testGateEscalationConvertsToDecisionWhenRetriesSpent() {
        XCTAssertEqual(
            WorkItemLifecycle.escalatedReason(for: .awaitingGate, retriesRemaining: 0),
            .awaitingDecision)
        XCTAssertNil(WorkItemLifecycle.escalatedReason(for: .awaitingGate, retriesRemaining: 3))
        // Non-gate parks never escalate this way.
        XCTAssertNil(WorkItemLifecycle.escalatedReason(for: .awaitingDecision, retriesRemaining: 0))
    }
}
