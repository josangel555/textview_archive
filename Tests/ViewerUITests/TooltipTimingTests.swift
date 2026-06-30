import XCTest
@testable import ViewerUI

/// TSK-1209 — the tooltip appear-delay was relaxed 0.3→0.6s (0.3 fired too soon — a pointer merely
/// passing over a control flashed a bubble). Pure timing constants, host-tested so the relaxed delay
/// can't silently regress, and the re-chain (glide-across-controls) shortcut stays correct.
final class TooltipTimingTests: XCTestCase {

    func test_appearDelay_isRelaxedTo06s_TSK1209() {
        XCTAssertEqual(TooltipTiming.appearDelay, 0.6, accuracy: 0.0001,
            "0.3s flashed on pass-through hovers; 0.6s lets a transient pass go by (still beats the ~1.5s system default)")
    }

    func test_delay_coldHoverUsesAppearDelay_visibleUsesRechain_TSK1209() {
        XCTAssertEqual(TooltipTiming.delay(bubbleAlreadyVisible: false), TooltipTiming.appearDelay, accuracy: 0.0001,
            "a cold first hover waits the full appear delay")
        XCTAssertEqual(TooltipTiming.delay(bubbleAlreadyVisible: true), TooltipTiming.rechainDelay, accuracy: 0.0001,
            "gliding across controls while a bubble already shows re-targets with the short re-chain delay")
        XCTAssertLessThan(TooltipTiming.rechainDelay, TooltipTiming.appearDelay,
            "re-chain must be shorter than a cold hover")
    }
}
