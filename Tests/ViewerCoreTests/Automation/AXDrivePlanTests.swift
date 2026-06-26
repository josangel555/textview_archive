import Foundation
import Testing
@testable import ViewerCore

/// TSK-1254 — the agent-drive command grammar (AXDrivePlan): parse a drive
/// command into a (target, action) plan + round-trip. Pins the grammar an agent
/// uses to drive native chrome by mdv.* id; malformed-input rejection matters
/// because the command is untrusted.
struct AXDrivePlanTests {

    private static let valid: [(String, AXDrivePlan)] = [
        ("press mdv.hexView",
         AXDrivePlan(query: AXQuery("mdv.hexView"), action: .press)),
        ("read mdv.breadcrumb",
         AXDrivePlan(query: AXQuery("mdv.breadcrumb"), action: .read)),
        ("scroll mdv.csvTable down",
         AXDrivePlan(query: AXQuery("mdv.csvTable"), action: .scroll(.down))),
        ("set mdv.csvFind.field hello world",
         AXDrivePlan(query: AXQuery("mdv.csvFind.field"), action: .setValue("hello world"))),
        ("press mdv.tab.*",
         AXDrivePlan(query: AXQuery("mdv.tab.*"), action: .press)),
    ]

    @Test func parsesEachAction() {
        for (cmd, expected) in Self.valid {
            #expect(AXDrivePlan(parsing: cmd) == expected, "parse failed: \(cmd)")
        }
    }

    @Test func roundTrips() {
        for (_, plan) in Self.valid {
            #expect(AXDrivePlan(parsing: plan.serialized) == plan,
                    "round-trip failed for \(plan.serialized)")
        }
    }

    @Test func globTargetParsesAsPrefix() {
        let plan = AXDrivePlan(parsing: "scroll mdv.tab.* up")
        #expect(plan?.query.match == .prefix)
        #expect(plan?.query.matches("mdv.tab.dirtyDot") == true)
        if case .scroll(.up) = plan?.action {} else { Issue.record("expected scroll up") }
    }

    @Test func setKeepsMultiWordValue() {
        let plan = AXDrivePlan(parsing: "set mdv.x hello there world")
        #expect(plan?.action == .setValue("hello there world"))   // rest-of-line preserved
    }

    @Test(arguments: [
        "",
        "press",                       // missing id
        "press notmdv.x",              // id must be mdv.*
        "press mdv.hexView extra",     // press takes no arg
        "read mdv.x trailing",         // read takes no arg
        "scroll mdv.x diagonal",       // bad direction
        "scroll mdv.x",                // missing direction
        "set mdv.x",                   // set needs a value
        "frobnicate mdv.x",            // unknown verb
    ])
    func rejectsMalformed(_ bad: String) {
        #expect(AXDrivePlan(parsing: bad) == nil, "should reject: \(bad)")
    }

    @Test func bridgesToAXQueryForTheDriver() {
        let plan = AXDrivePlan(parsing: "press mdv.commandPaletteButton")
        #expect(plan?.query.matches("mdv.commandPaletteButton") == true)
    }
}
