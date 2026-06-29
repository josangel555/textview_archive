import XCTest
import AppKit
@testable import ViewerUI
import ViewerCore

/// Pure colour-math coverage for `TerminalPalette` — no window, host-safe.
/// Guards the memoization perf fix (shared `NSColor` per palette index, so
/// the terminal draw path stops allocating per attribute-run per frame)
/// AND that the resolved colours still match the original per-call math.
@MainActor
final class TerminalPaletteTests: XCTestCase {

    private func rgba(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }

    private func assertClose(_ a: CGFloat, _ b: CGFloat, _ msg: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: 0.002, msg, file: file, line: line)
    }

    func test_default_isNil() {
        XCTAssertNil(TerminalPalette.nsColor(.default))
    }

    func test_paletteEntries_areMemoized_sameInstance() {
        // The perf fix: identical indices must hand back the SAME object,
        // not a freshly-allocated one each call.
        for n: UInt8 in [0, 7, 15, 16, 128, 231, 232, 255] {
            let a = TerminalPalette.nsColor(.indexed(n))
            let b = TerminalPalette.nsColor(.indexed(n))
            XCTAssertNotNil(a)
            XCTAssertTrue(a === b, "indexed(\(n)) should be memoized (same instance)")
        }
        // `.ansi(n)` and `.indexed(n)` alias the same entry for 0...15.
        for n: UInt8 in 0...15 {
            XCTAssertTrue(TerminalPalette.nsColor(.ansi(n)) === TerminalPalette.nsColor(.indexed(n)),
                          "ansi(\(n)) and indexed(\(n)) must resolve to the same entry")
        }
    }

    func test_ansi_tunedAnchors_unchanged() {
        // Anchor a few tuned values so the memoized table can't silently drift.
        let red = rgba(TerminalPalette.nsColor(.ansi(1))!)
        assertClose(red.0, 0.80, "red.r"); assertClose(red.1, 0.16, "red.g"); assertClose(red.2, 0.13, "red.b")
        let brightWhite = rgba(TerminalPalette.nsColor(.ansi(15))!)
        assertClose(brightWhite.0, 0.96, "bw.r"); assertClose(brightWhite.2, 0.96, "bw.b")
    }

    func test_indexed_cubeAndGreyscale_unchanged() {
        // 6×6×6 cube corner: index 16 = (0,0,0).
        let cube0 = rgba(TerminalPalette.nsColor(.indexed(16))!)
        assertClose(cube0.0, 0, "cube0.r"); assertClose(cube0.1, 0, "cube0.g"); assertClose(cube0.2, 0, "cube0.b")
        // Greyscale ramp: index 232 = level 0 → v = 8/255.
        let grey0 = rgba(TerminalPalette.nsColor(.indexed(232))!)
        let v = CGFloat(8) / 255
        assertClose(grey0.0, v, "grey0.r"); assertClose(grey0.1, v, "grey0.g"); assertClose(grey0.2, v, "grey0.b")
    }

    func test_rgb_truecolor_verbatim() {
        let c = rgba(TerminalPalette.nsColor(.rgb(10, 20, 30))!)
        assertClose(c.0, 10.0/255, "r"); assertClose(c.1, 20.0/255, "g"); assertClose(c.2, 30.0/255, "b")
        assertClose(c.3, 1, "a")
    }
}
