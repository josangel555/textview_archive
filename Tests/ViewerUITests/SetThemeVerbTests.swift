import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-641: the `set-theme` headless theming seam — the automation/UAT
/// equivalent of the Settings → Appearance picker, and the entry point a VM T5
/// chrome-pixel test drives to validate the chrome surface (the one theming
/// surface with no host coverage). Pins the verb → `model.selectedThemeID`
/// wiring + the persistence didSet; the picker UI is the user-facing twin.
@MainActor
final class SetThemeVerbTests: XCTestCase {

    private var savedSelection: String?

    override func setUp() {
        super.setUp()
        // selectedThemeID's didSet writes ThemeStore.shared (a process-wide
        // singleton) — snapshot + restore so this test doesn't bleed into others.
        savedSelection = ThemeStore.shared.selectedID
    }

    override func tearDown() {
        ThemeStore.shared.selectedID = savedSelection
        super.tearDown()
    }

    func test_setThemeVerb_selectsBuiltInById() {
        let harness = HeadlessHarness(label: "SetThemeVerbTests-select")
        defer { harness.cleanup() }

        ScriptVerb.apply(verb: "set-theme xcode-dark",
                         to: harness.model, sessions: harness.sessions)
        XCTAssertEqual(harness.model.selectedThemeID, "xcode-dark",
                       "the verb must select the theme by id")
        XCTAssertEqual(ThemeStore.shared.selectedID, "xcode-dark",
                       "the selection persists via the model's didSet")
    }

    func test_setThemeVerb_emptyArgFollowsSystem() {
        let harness = HeadlessHarness(label: "SetThemeVerbTests-follow")
        defer { harness.cleanup() }

        ScriptVerb.apply(verb: "set-theme xcode-light",
                         to: harness.model, sessions: harness.sessions)
        XCTAssertEqual(harness.model.selectedThemeID, "xcode-light")

        // No id ⇒ Follow System (nil selection).
        ScriptVerb.apply(verb: "set-theme",
                         to: harness.model, sessions: harness.sessions)
        XCTAssertNil(harness.model.selectedThemeID,
                     "an empty arg clears the selection back to Follow System")
        XCTAssertNil(ThemeStore.shared.selectedID)
    }
}
