import XCTest
import ViewerKit

@testable import ViewerCore

/// THE CLAUDE-DESIGN GAUNTLET (M4.S6, TSK-1385; 06-MILESTONES-UAT §M4).
///
/// Ten realistic design briefs — PRE-COMMITTED in docs/canvas/plans/
/// M4-PLAN.md §S6 BEFORE S1–S5 were built (no tailoring the exam) — each
/// solved through ONLY the MCP tool surface (kit allowed), then scored:
///
///   - completed: every apply landed + the read-back carries the brief's
///     structural markers;
///   - escape hatches: the `embed` kind (the HARD escape — raw HTML because
///     the abstraction couldn't express the design);
///   - findings: expressiveness gaps hit while solving (recorded VERBATIM —
///     these feed the owner review + M5 planning).
///
/// THE PIVOT CRITERION AS AN ASSERT (owner): escape rate > 30% FAILS this
/// suite. The CANVAS-M4-GAUNTLET report prints per-brief + aggregate.
@MainActor
final class CanvasGauntletTests: XCTestCase {

    private var host: FakeAutomationHost!

    override func setUp() async throws {
        host = FakeAutomationHost()
    }

    override func tearDown() async throws {
        host = nil
    }

    private func call(_ tool: String, _ args: [String: MCP.Value]) throws -> MCP.Value {
        try MCPToolCatalog.dispatch(name: tool, args: .object(args), host: host)
    }

    private struct Brief {
        let name: String
        /// DSL steps (each applied in sequence; kit imported first when used).
        let usesKit: Bool
        let steps: [String]
        /// Read-back markers that prove the structure landed.
        let markers: [String]
        /// True when the SOLUTION required the embed escape hatch.
        let usedEscape: Bool
        /// Expressiveness gaps hit while authoring (the abstraction-gap log).
        let findings: [String]
    }

    /// The ten pre-committed briefs, solved with today's vocabulary.
    private static let briefs: [Brief] = [
        Brief(
            name: "landing-hero", usesKit: true,
            steps: ["""
                frame #hero fill=$color.surface padding=$space.xl gap=16 {
                  text #hero-title "Ship faster with Canvas" font=$font.h1 color=$color.fg
                  text #hero-sub "One engine for agents and humans" color=$color.muted maxW=480
                  use #kit-button #hero-cta override text #kit-button-label "Get started"
                }
                """],
            markers: ["Ship faster", "#hero-cta", "Get started"],
            usedEscape: false, findings: []),
        Brief(
            name: "pricing-table", usesKit: true,
            steps: ["""
                frame #pricing direction=row gap=24 padding=$space.lg {
                  use #kit-card #plan-free override text #kit-card-title "Free" override text #kit-card-copy "$0 — 3 documents"
                  use #kit-card #plan-pro override text #kit-card-title "Pro" override text #kit-card-copy "$12 — unlimited"
                  use #kit-card #plan-team override text #kit-card-title "Team" override text #kit-card-copy "$49 — SSO + audit"
                }
                """],
            markers: ["#plan-free", "#plan-pro", "#plan-team", "unlimited"],
            usedEscape: false, findings: []),
        Brief(
            name: "dashboard-kpis", usesKit: true,
            steps: ["""
                frame #kpis direction=row gap=16 {
                  use #kit-kpi #kpi-rev override text #kit-kpi-value "$1.2M" override text #kit-kpi-label "Revenue"
                  use #kit-kpi #kpi-users override text #kit-kpi-value "8,412" override text #kit-kpi-label "Users"
                  use #kit-kpi #kpi-churn override text #kit-kpi-value "1.9%" override text #kit-kpi-label "Churn"
                }
                """],
            markers: ["$1.2M", "8,412", "Churn"],
            usedEscape: false, findings: []),
        Brief(
            name: "signup-form", usesKit: true,
            steps: ["""
                frame #signup fill=$color.surface padding=$space.lg gap=12 maxW=420 {
                  text #signup-title "Create your account" font=$font.h2
                  frame #field-email stroke=$color.border radius=$radius.sm padding=$space.sm {
                    text #field-email-ph "email@company.com" color=$color.muted
                  }
                  frame #field-pass stroke=$color.border radius=$radius.sm padding=$space.sm {
                    text #field-pass-ph "password" color=$color.muted
                  }
                  use #kit-button #signup-cta override text #kit-button-label "Sign up"
                }
                """],
            markers: ["Create your account", "email@company.com", "#signup-cta"],
            usedEscape: false,
            findings: ["no input/form primitives — fields are mocked as bordered frames (fine for design mocks; interactive forms need an M5+ kind)"]),
        Brief(
            name: "testimonial-grid", usesKit: true,
            steps: ["""
                frame #testimonials direction=row wrap=true gap=16 {
                  use #kit-card #quote-1 override text #kit-card-copy "Cut our design cycle in half. — Ada"
                  use #kit-card #quote-2 override text #kit-card-copy "The agent builds, I polish. — Lin"
                  use #kit-card #quote-3 override text #kit-card-copy "Retheming is instant. — Sam"
                  use #kit-card #quote-4 override text #kit-card-copy "One source of truth. — Rio"
                }
                """],
            markers: ["Ada", "Lin", "Sam", "Rio"],
            usedEscape: false,
            findings: ["no grid primitive — row+wrap approximates a 2x2 (acceptable; column-count control would need grid in M5+)"]),
        Brief(
            name: "nav-bar", usesKit: false,
            steps: ["""
                frame #nav direction=row gap=24 padding=$space.md fill=$color.bg {
                  text #nav-logo "Canvas" font=$font.h2 color=$color.accent
                  text #nav-docs "Docs" color=$color.fg
                  text #nav-pricing "Pricing" color=$color.fg
                  text #nav-login "Log in" color=$color.muted
                }
                """],
            markers: ["#nav-logo", "Docs", "Pricing"],
            usedEscape: false,
            findings: ["no spacer/justify-between shorthand on one child — justify on the container covers most cases"]),
        Brief(
            name: "article-layout", usesKit: false,
            steps: ["""
                frame #article gap=12 padding=$space.lg maxW=720 {
                  text #article-h1 "The lowering compiler pattern" font=$font.h1
                  text #article-lede "Why structured documents beat raw HTML for agents." color=$color.muted maxW=600
                  text #article-p1 "A flat record store with typed operations gives both humans and agents one write path." maxW=600
                  text #article-p2 "Design tokens keep every document rethemeable after the fact." maxW=600
                }
                """],
            markers: ["lowering compiler", "one write path", "rethemeable"],
            usedEscape: false, findings: []),
        Brief(
            name: "feature-grid", usesKit: true,
            steps: ["""
                frame #features gap=16 {
                  frame #features-row1 direction=row gap=16 {
                    use #kit-card #feat-1 override text #kit-card-title "Typed ops" override text #kit-card-copy "Atomic, undoable, conflict-safe"
                    use #kit-card #feat-2 override text #kit-card-title "Live retheme" override text #kit-card-copy "One patch, whole document"
                    use #kit-card #feat-3 override text #kit-card-title "Components" override text #kit-card-copy "Edit once, update everywhere"
                  }
                  frame #features-row2 direction=row gap=16 {
                    use #kit-card #feat-4 override text #kit-card-title "Co-editing" override text #kit-card-copy "Agents and humans, one stream"
                    use #kit-card #feat-5 override text #kit-card-title "Teaching errors" override text #kit-card-copy "Rejections carry the fix"
                    use #kit-card #feat-6 override text #kit-card-title "Vendored kits" override text #kit-card-copy "Pinned, drift-detected"
                  }
                }
                """],
            markers: ["Typed ops", "Live retheme", "Vendored kits"],
            usedEscape: false,
            findings: ["2x3 grid hand-assembled from two rows — grid primitive would collapse this to one container"]),
        Brief(
            name: "footer", usesKit: false,
            steps: ["""
                frame #footer direction=row gap=48 padding=$space.lg fill=$color.surface {
                  frame #footer-product gap=6 {
                    text #footer-product-h "Product" font=$font.h2
                    text #footer-product-1 "Canvas" color=$color.muted
                    text #footer-product-2 "Pricing" color=$color.muted
                  }
                  frame #footer-company gap=6 {
                    text #footer-company-h "Company" font=$font.h2
                    text #footer-company-1 "About" color=$color.muted
                    text #footer-company-2 "Careers" color=$color.muted
                  }
                }
                """],
            markers: ["Product", "Company", "Careers"],
            usedEscape: false, findings: []),
        Brief(
            name: "stats-banner", usesKit: true,
            steps: [
                "token set base.blue #1a6feb",
                """
                frame #banner fill=$color.accent padding=$space.lg direction=row gap=32 {
                  use #kit-kpi #stat-docs override text #kit-kpi-value "40k" override text #kit-kpi-label "Documents"
                  use #kit-kpi #stat-teams override text #kit-kpi-value "900+" override text #kit-kpi-label "Teams"
                }
                """],
            markers: ["40k", "900+", "Teams"],
            usedEscape: false,
            findings: ["kit components on a tinted banner keep their surface fill — per-instance root-prop overrides cover it when needed"]),
    ]

    func test_the_gauntlet_ten_briefs_over_the_mcp_surface() throws {
        var completedCount = 0
        var escapeCount = 0
        var reportLines: [String] = []
        var allFindings: [String] = []

        for brief in Self.briefs {
            guard case .object(let n) = try call("canvas_new", [:]),
                case .string(let doc)? = n["doc"] else {
                return XCTFail("canvas_new failed for \(brief.name)")
            }
            if brief.usesKit {
                _ = try call("canvas_kit_import", ["doc": .string(doc)])
            }
            var applied = true
            var lintCount = 0
            for step in brief.steps {
                let openDoc = try host.automationCanvasStore.doc(doc)
                let rev = try openDoc.adapter.currentRev()
                guard case .object(let result) = try call("canvas_apply", [
                    "doc": .string(doc), "baseRev": .int(Int(rev)), "dsl": .string(step),
                ]) else { applied = false; break }
                if result["rejected"] != nil {
                    applied = false
                    reportLines.append("  REJECTED \(brief.name): \(result)")
                    break
                }
                if case .array(let lint)? = result["lint"] { lintCount += lint.count }
            }
            // Structural read-back.
            var complete = applied
            if applied {
                guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
                    case .string(let dsl)? = read["dsl"] else {
                    return XCTFail("read failed for \(brief.name)")
                }
                let escaped = dsl.contains("embed ")
                XCTAssertEqual(escaped, brief.usedEscape,
                               "\(brief.name): declared escape usage must match the projection")
                for marker in brief.markers where !dsl.contains(marker) {
                    complete = false
                    reportLines.append("  MISSING marker '\(marker)' in \(brief.name)")
                }
            }
            if complete { completedCount += 1 }
            if brief.usedEscape { escapeCount += 1 }
            allFindings.append(contentsOf: brief.findings.map { "\(brief.name): \($0)" })
            reportLines.append(String(
                format: "  %@ %@ escape=%@ lint=%d",
                complete ? "PASS" : "FAIL", brief.name,
                brief.usedEscape ? "YES" : "no", lintCount))
        }

        let escapeRate = Double(escapeCount) / Double(Self.briefs.count)
        print("CANVAS-M4-GAUNTLET report:")
        reportLines.forEach { print($0) }
        print("CANVAS-M4-GAUNTLET findings (the abstraction-gap log):")
        allFindings.forEach { print("  - \($0)") }
        print(String(
            format: "CANVAS-M4-GAUNTLET aggregate: %d/%d completed, escape rate %.0f%%",
            completedCount, Self.briefs.count, escapeRate * 100))

        XCTAssertEqual(completedCount, Self.briefs.count, "every brief must complete")
        // THE PIVOT CRITERION (owner): >30% escape rate = stop and revisit
        // the abstraction before M5.
        XCTAssertLessThanOrEqual(escapeRate, 0.30, "the abstraction failed the gauntlet")
    }
}
