import Foundation
import RustCore

// Canvas M5.S1 (TSK-1389) — the UI-Design MODE, Tier 1 (M5-PLAN §S1).
// THE THIN-MODE LAW: a mode is DATA — a `mode.ui-design` document token
// (io-persisted, vocab-visible; the kit-pin trick) + a create-time template
// + presets the existing surfaces read. ZERO engine branches on mode.

public enum CanvasUIDesignMode {

    /// The well-known mode token path.
    public static let modeTokenPath = "mode.ui-design"

    public enum Template: String, CaseIterable, Sendable {
        case desktop
        case mobile
        case both
    }

    /// Artboard presets (widths in px; the S2 chrome reads role=artboard).
    static func artboardDSL(_ template: Template) -> String {
        let desktop = """
            frame #artboard-desktop role=artboard note="Desktop — 1280" \
            minW=1280 maxW=1280 fill=$color.bg padding=$space.lg gap=16 {
              hole #desktop-todo note="design the desktop layout"
            }
            """
        let mobile = """
            frame #artboard-mobile role=artboard note="Mobile — 390" \
            minW=390 maxW=390 fill=$color.bg padding=$space.md gap=12 {
              hole #mobile-todo note="design the mobile layout"
            }
            """
        switch template {
        case .desktop: return desktop
        case .mobile: return mobile
        case .both: return desktop + "\n" + mobile
        }
    }

    /// Seed a fresh document as a UI-Design doc: the kit, the mode token,
    /// and the artboard template — all through the ordinary apply path.
    @MainActor
    public static func seed(
        into doc: CanvasOpenDocument, template: Template
    ) throws {
        _ = try CanvasStarterKit.importKit(into: doc)
        let rev = try doc.adapter.currentRev()
        let dsl = "token set \(modeTokenPath) \"active\"\n" + artboardDSL(template)
        let applied = try doc.adapter.applyDSL(baseRev: rev, dsl)
        doc.noteRevision(applied.rev)
    }

    /// Is `doc` a UI-Design document? (Shells read this — the engine never
    /// does; the thin-mode law.)
    @MainActor
    public static func isUIDesign(_ doc: CanvasOpenDocument) -> Bool {
        ((try? doc.adapter.recordedKitPin(tokenPath: modeTokenPath)) ?? nil) != nil
    }
}
