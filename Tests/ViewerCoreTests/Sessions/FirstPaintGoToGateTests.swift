import XCTest
@testable import ViewerCore

/// Pure-logic tests for `FirstPaintGoToGate`. Runs on host.
final class FirstPaintGoToGateTests: XCTestCase {

    // MARK: - arm

    func test_recordOpenFolder_forceNewTrue_armsGate() {
        var gate = FirstPaintGoToGate()
        XCTAssertFalse(gate.isArmed)
        gate.recordOpenFolder(forceNew: true)
        XCTAssertTrue(gate.isArmed)
    }

    func test_recordOpenFolder_forceNewFalse_doesNotArm() {
        var gate = FirstPaintGoToGate()
        gate.recordOpenFolder(forceNew: false)
        XCTAssertFalse(gate.isArmed)
    }

    func test_recordActivate_doesNotArm() {
        var gate = FirstPaintGoToGate()
        gate.recordActivate(id: UUID())
        XCTAssertFalse(gate.isArmed)
    }

    // MARK: - take (read+clear)

    func test_take_returnsTrueOnceAfterArming() {
        var gate = FirstPaintGoToGate()
        gate.recordOpenFolder(forceNew: true)
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.take(), "Gate should disarm after first take().")
        XCTAssertFalse(gate.isArmed)
    }

    func test_take_falseWhenNotArmed() {
        var gate = FirstPaintGoToGate()
        XCTAssertFalse(gate.take())
    }

    // MARK: - interleaved sequences

    func test_activateAfterArm_keepsGateArmedUntilTake() {
        var gate = FirstPaintGoToGate()
        gate.recordOpenFolder(forceNew: true)
        // A plain activate must NOT consume the pending arm —
        // otherwise an LRU re-activation that races with the openFolder
        // would silently drop the auto-prompt.
        gate.recordActivate(id: UUID())
        XCTAssertTrue(gate.isArmed)
        XCTAssertTrue(gate.take())
    }

    func test_doubleOpenFolder_armOnlyOnce() {
        var gate = FirstPaintGoToGate()
        gate.recordOpenFolder(forceNew: true)
        gate.recordOpenFolder(forceNew: true)
        // After one take it's done — the second openFolder set the
        // flag but a single take consumes it.
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.take())
    }

    func test_armed_initializerSeedsFlag() {
        var gate = FirstPaintGoToGate(isArmed: true)
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.isArmed)
    }
}
