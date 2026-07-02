import CryptoKit
import Foundation
import RustCore

// Canvas M4.S5 (TSK-1384) — the vendored starter kit (M4-PLAN §S5;
// 07-DSL-SPIKE §6): six reusable components DEFINED IN THE DSL and imported
// by COPY (vendored + pinned — no live cross-doc links; drift is DETECTED,
// never silently synced). The pin is the kit source's SHA-256, recorded as
// a document token (`kit.starter`: visible in the vocabulary, persisted by
// the canonical io, zero new storage machinery).

public enum CanvasStarterKit {

    /// The kit source — component definitions only (token statements ride
    /// the same import so kit components theme correctly out of the box).
    public static let source = """
        component #kit-card {
          frame #kit-card-body fill=$color.surface padding=$space.md gap=8 radius=$radius.md {
            text #kit-card-title "Card title" font=$font.h2 color=$color.fg
            text #kit-card-copy "Card copy" color=$color.muted
          }
        }
        component #kit-button {
          frame #kit-button-body fill=$color.accent padding=$space.sm radius=$radius.sm {
            text #kit-button-label "Button" color=$color.bg
          }
        }
        component #kit-badge {
          frame #kit-badge-body fill=$color.surface padding=$space.xs radius=$radius.lg {
            text #kit-badge-label "Badge" color=$color.accent
          }
        }
        component #kit-header {
          frame #kit-header-row direction=row gap=16 padding=$space.md {
            text #kit-header-title "Page title" font=$font.h1 color=$color.fg
            text #kit-header-sub "subtitle" color=$color.muted
          }
        }
        component #kit-two-col {
          frame #kit-two-col-row direction=row gap=24 {
            frame #kit-two-col-left gap=8 grow=1 {
              text #kit-two-col-left-copy "Left column"
            }
            frame #kit-two-col-right gap=8 grow=1 {
              text #kit-two-col-right-copy "Right column"
            }
          }
        }
        component #kit-kpi {
          frame #kit-kpi-body padding=$space.md gap=4 fill=$color.surface radius=$radius.md {
            text #kit-kpi-value "42" font=$font.h1 color=$color.accent
            text #kit-kpi-label "Metric" color=$color.muted
          }
        }
        """

    /// The pin: SHA-256 of the kit source (hex).
    public static var pinHash: String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The well-known pin token path.
    public static let pinTokenPath = "kit.starter"

    public struct ImportResult: Equatable, Sendable {
        /// True when definitions were (re)applied this call.
        public let imported: Bool
        /// True when a PREVIOUS import's pin differs from this kit version —
        /// the vendored copy has drifted from the kit (or the kit updated).
        public let driftDetected: Bool
    }

    /// Import (or re-import) the kit into `doc`: apply the definitions,
    /// then record the pin. Definition replays are idempotent at the op
    /// layer; drift = a recorded pin that differs from this kit's hash.
    @MainActor
    public static func importKit(into doc: CanvasOpenDocument) throws -> ImportResult {
        let recorded = try? doc.adapter.recordedKitPin(tokenPath: pinTokenPath)
        let drift = recorded.flatMap { $0 } != nil && recorded.flatMap { $0 } != pinHash

        let rev = try doc.adapter.currentRev()
        do {
            let applied = try doc.adapter.applyDSL(
                baseRev: rev,
                source + "\ntoken set \(pinTokenPath) \"pin-\(pinHash)\"")
            doc.noteRevision(applied.rev)
            return ImportResult(imported: true, driftDetected: drift)
        } catch let rejection as CanvasRejection where rejection.kind == "idInUse" {
            // The vendored copy was EDITED (a kit id now holds different
            // content): the plan's rule — drift is DETECTED, never silently
            // overwritten. The caller decides (rename the edited component,
            // or remove it and re-import).
            return ImportResult(imported: false, driftDetected: true)
        }
    }
}
