import Testing
import Foundation
@testable import ViewerCore

/// Owner 2026-08-27 ("I often find it maximized") — per-display-layout
/// window-frame memory. The invariant that kills the one-way ratchet: a
/// clamp/record on ONE screen layout never touches another layout's
/// remembered frame, so the external display's frame survives a
/// laptop-only interlude.
struct WindowFrameMemoryTests {

    private let laptop = [CGRect(x: 0, y: 0, width: 1512, height: 945)]
    private let external = [
        CGRect(x: 0, y: 0, width: 1512, height: 945),
        CGRect(x: 1512, y: 0, width: 2560, height: 1415),
    ]

    @Test func layoutKey_isOrderIndependent_andRoundsSubpointJitter() {
        let forward = WindowFrameMemory.layoutKey(visibleFrames: external)
        let backward = WindowFrameMemory.layoutKey(visibleFrames: external.reversed())
        #expect(forward == backward)

        let jittered = [
            CGRect(x: 0.4, y: 0.2, width: 1511.8, height: 945.1),
            CGRect(x: 1512.3, y: 0, width: 2559.9, height: 1414.6),
        ]
        #expect(WindowFrameMemory.layoutKey(visibleFrames: jittered) == forward,
                "sub-point float jitter must not fork the layout key")
        #expect(WindowFrameMemory.layoutKey(visibleFrames: laptop) != forward)
    }

    @Test func theRatchetKiller_bigLayoutFrameSurvivesALaptopInterlude() {
        var memory = WindowFrameMemory()
        let bigKey = WindowFrameMemory.layoutKey(visibleFrames: external)
        let smallKey = WindowFrameMemory.layoutKey(visibleFrames: laptop)
        let bigFrame = CGRect(x: 1600, y: 100, width: 2200, height: 1300)

        memory.record(frame: bigFrame, layoutKey: bigKey)
        // The laptop interlude: a clamped, screen-sized frame gets recorded
        // under the LAPTOP key — the exact write that used to destroy the
        // external preference in the single-slot autosave.
        memory.record(frame: laptop[0], layoutKey: smallKey)

        #expect(memory.frame(forLayoutKey: bigKey) == bigFrame,
                "the external layout's remembered frame must survive")
        #expect(memory.frame(forLayoutKey: smallKey) == laptop[0])
    }

    @Test func record_replacesSameLayout_andEvictsBeyondCapacity() {
        var memory = WindowFrameMemory(capacity: 2)
        memory.record(frame: CGRect(x: 0, y: 0, width: 100, height: 100), layoutKey: "a")
        memory.record(frame: CGRect(x: 0, y: 0, width: 200, height: 200), layoutKey: "a")
        #expect(memory.entries.count == 1)
        #expect(memory.frame(forLayoutKey: "a")?.width == 200)

        memory.record(frame: CGRect(x: 0, y: 0, width: 300, height: 300), layoutKey: "b")
        memory.record(frame: CGRect(x: 0, y: 0, width: 400, height: 400), layoutKey: "c")
        #expect(memory.entries.count == 2)
        #expect(memory.frame(forLayoutKey: "a") == nil, "LRU tail evicted")
        #expect(memory.frame(forLayoutKey: "c")?.width == 400)
    }

    @Test func encodeDecode_roundTripsEntriesInMRUOrder() {
        var memory = WindowFrameMemory()
        memory.record(frame: CGRect(x: 1, y: 2, width: 300, height: 400), layoutKey: "old")
        memory.record(frame: CGRect(x: 5.5, y: 6.5, width: 700.25, height: 800), layoutKey: "new")

        let back = WindowFrameMemory.decode(memory.encoded())
        #expect(back == memory)
        #expect(back.entries.first?.layoutKey == "new", "MRU order preserved")
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 0, height: 100),
        CGRect(x: 0, y: 0, width: 100, height: 0),
        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
    ])
    func degenerateFrames_areRefused(_ bad: CGRect) {
        var memory = WindowFrameMemory()
        memory.record(frame: bad, layoutKey: "k")
        #expect(memory.entries.isEmpty)
    }

    @Test func decode_skipsGarbageLines() {
        let back = WindowFrameMemory.decode(
            ["not-an-entry", "key\tonly,three,parts", "ok\t1.0,2.0,300.0x400.0"])
        #expect(back.entries.count == 1)
        #expect(back.frame(forLayoutKey: "ok") ==
                CGRect(x: 1, y: 2, width: 300, height: 400))
    }
}
