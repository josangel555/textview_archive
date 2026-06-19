import XCTest
@testable import ViewerCore

/// Host-safe (T1m) tests for the `.agent` SessionKind added for the New ▸
/// Session ▸ Kind menu (TSK-373). The other kinds' seed-once layout is
/// already covered in ViewerUITests/Sessions/SessionTypeSeedTests; this
/// pins the *new* case's pure metadata + seed layout.
final class SessionKindAgentTests: XCTestCase {

    func test_agentKind_hasDistinctMetadata() {
        XCTAssertEqual(SessionKind.agent.rawValue, "agent")
        XCTAssertEqual(SessionKind.agent.displayName, "Agent Session")
        XCTAssertFalse(SessionKind.agent.symbolName.isEmpty)
        XCTAssertFalse(SessionKind.agent.menuSubtitle.isEmpty)
    }

    func test_agentKind_seedsClaudeTimelineAndGit() {
        let layout = SessionKind.agent.defaultPanelLayout
        XCTAssertFalse(layout.isDefault,
                       "an agent session must seed a non-default layout")
        let overrides = PanelVisibilityOverrides.decoded(layout.overrides)
        XCTAssertEqual(overrides.state(.claudeTimeline), .shown,
                       "agent session forwards the Claude timeline")
        XCTAssertEqual(overrides.state(.git), .shown,
                       "agent session keeps git visible")
    }

    func test_agentKind_roundTripsRawValue() {
        XCTAssertEqual(SessionKind(rawValue: "agent"), .agent)
    }

    func test_allCases_includesAgent() {
        XCTAssertTrue(SessionKind.allCases.contains(.agent))
    }

    func test_eachKind_hasUniqueSymbol() {
        // Distinct icons so the menu rows are visually distinguishable.
        let symbols = SessionKind.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count,
                       "each kind must have a unique SF Symbol")
    }
}
