import Foundation
import RustCore

// Canvas M6.S1 (TSK-1395) — the PRESENTATION MODE, Tier 1 (M6-PLAN §S1).
// THE THIN-MODE LAW (as M5): a mode is DATA — a `mode.presentation` token
// (io-persisted) + a create-time slide template + presets. Slides are
// role=slide frames (16:9), reusing the M5 artboard machinery. ZERO engine
// branches on mode.

public enum CanvasPresentationMode {

    /// The well-known mode token path.
    public static let modeTokenPath = "mode.presentation"

    /// A 16:9 slide (1280×720) — role=slide reuses the artboard chrome.
    static func slideDSL(index: Int) -> String {
        """
        frame #slide-\(index) role=slide note="Slide \(index + 1)" \
        minW=1280 maxW=1280 minH=720 maxH=720 fill=$color.bg padding=$space.xl gap=16 {
          hole #slide-\(index)-todo note="design slide \(index + 1)"
        }
        """
    }

    /// Seed a fresh document as a deck: the kit, the mode token, and `count`
    /// slides — all through the ordinary apply path.
    @MainActor
    public static func seed(into doc: CanvasOpenDocument, slides count: Int) throws {
        let n = max(1, min(count, 100))
        _ = try CanvasStarterKit.importKit(into: doc)
        let rev = try doc.adapter.currentRev()
        let slides = (0..<n).map { slideDSL(index: $0) }.joined(separator: "\n")
        let dsl = "token set \(modeTokenPath) \"active\"\n" + slides
        let applied = try doc.adapter.applyDSL(baseRev: rev, dsl)
        doc.noteRevision(applied.rev)
    }

    /// Is `doc` a presentation deck? (Shells read this — the engine never does.)
    @MainActor
    public static func isPresentation(_ doc: CanvasOpenDocument) -> Bool {
        ((try? doc.adapter.recordedKitPin(tokenPath: modeTokenPath)) ?? nil) != nil
    }
}
