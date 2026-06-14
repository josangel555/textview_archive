import AppKit
import XCTest
@testable import ViewerCore
@testable import ViewerUI

/// TSK-707: the pure flag→event classifier behind the double-Shift command-
/// palette monitor. The live `flagsChanged` NSEvent monitor is VM-only, but the
/// MAPPING from raw modifier transitions to `DoubleTapModifierDetector.Event`
/// is window-free and pinned here so a wiring regression fails the host gate.
///
/// Tier: window-free pure assertions — host-safe.
@MainActor
final class DoubleShiftMonitorTests: XCTestCase {

    func testNonModifierKeyDownIsReset() {
        // Any non-modifier key-down breaks a clean double-tap.
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: false, deviceFlags: [.shift], wasShiftDown: true, timestamp: 1.0
            ),
            .reset
        )
    }

    func testBareShiftDownMapsToModifierDownWithTimestamp() {
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true, deviceFlags: [.shift], wasShiftDown: false, timestamp: 2.5
            ),
            .modifierDown(at: 2.5)
        )
    }

    func testShiftReleaseMapsToModifierUp() {
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true, deviceFlags: [], wasShiftDown: true, timestamp: 3.0
            ),
            .modifierUp
        )
    }

    func testShiftWithCommandIsAChordReset() {
        // ⌘⇧ together is a chord, not a bare Shift tap.
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true,
                deviceFlags: [.shift, .command],
                wasShiftDown: false,
                timestamp: 4.0
            ),
            .reset
        )
    }

    func testCommandJoiningWhileShiftHeldResets() {
        // Shift state unchanged but a chord modifier appears → reset.
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true,
                deviceFlags: [.shift, .command],
                wasShiftDown: true,
                timestamp: 5.0
            ),
            .reset
        )
    }

    func testCapsLockToggleAloneIsIgnored() {
        // Caps-Lock noise with Shift state unchanged must NOT reset an armed
        // gesture — the classifier returns nil (no state change).
        XCTAssertNil(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true, deviceFlags: [.capsLock], wasShiftDown: false, timestamp: 6.0
            )
        )
    }

    func testCapsLockDoesNotBlockShiftDown() {
        // Shift down while Caps-Lock happens to be on is still a bare Shift tap.
        XCTAssertEqual(
            DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: true,
                deviceFlags: [.shift, .capsLock],
                wasShiftDown: false,
                timestamp: 7.0
            ),
            .modifierDown(at: 7.0)
        )
    }

    /// End-to-end through the same pure pieces the monitor uses: a real
    /// down→up→down transition stream (with a Caps-Lock blip that must not
    /// derail it) fires exactly once.
    func testClassifierFeedingDetectorFiresOnCleanDoubleTap() {
        var detector = DoubleTapModifierDetector(interval: 0.30)
        var wasShiftDown = false
        // (isFlagsChanged, flags, timestamp)
        let stream: [(Bool, NSEvent.ModifierFlags, TimeInterval)] = [
            (true, [.shift], 0.00),          // down
            (true, [], 0.05),                // up
            (true, [.capsLock], 0.07),       // caps blip (ignored)
            (true, [.shift, .capsLock], 0.10), // down again → FIRE
        ]
        var fires = 0
        for (isFlags, flags, ts) in stream {
            let ev = DoubleShiftMonitor.detectorEvent(
                isFlagsChanged: isFlags,
                deviceFlags: flags.intersection(.deviceIndependentFlagsMask),
                wasShiftDown: wasShiftDown,
                timestamp: ts
            )
            if isFlags { wasShiftDown = flags.contains(.shift) }
            if let ev, detector.handle(ev) { fires += 1 }
        }
        XCTAssertEqual(fires, 1)
    }
}
