import XCTest
@testable import ViewerCore

/// TSK-1318 — the pure menu-organization model (group by category, order, omit empties).
final class MenuOrganizerTests: XCTestCase {

    private func cmd(_ id: String, _ title: String, _ cat: CommandCategory,
                     verb: String? = "verb") -> CommandDescriptor {
        CommandDescriptor(id: id, title: title, category: cat, scriptVerb: verb)
    }

    func test_groupsByCategory_inDeclarationOrder() {
        // Deliberately out of order; edit comes after view in CommandCategory.
        let cmds = [
            cmd("e1", "Copy", .edit),
            cmd("f1", "New", .file),
            cmd("v1", "Zoom In", .view),
        ]
        let sections = MenuOrganizer.organize(cmds)
        // file < view < edit per CommandCategory declaration order.
        XCTAssertEqual(sections.map(\.category), [.file, .view, .edit])
        XCTAssertEqual(sections.map(\.title), ["File", "View", "Edit"])
    }

    func test_omitsEmptyCategories() {
        let sections = MenuOrganizer.organize([cmd("f1", "New", .file)])
        XCTAssertEqual(sections.count, 1, "only the non-empty category renders")
        XCTAssertEqual(sections[0].category, .file)
    }

    func test_byTitle_sortsWithinSection_caseInsensitive() {
        let cmds = [
            cmd("f3", "save", .file),
            cmd("f1", "New", .file),
            cmd("f2", "open", .file),
        ]
        let section = MenuOrganizer.organize(cmds).first!
        XCTAssertEqual(section.commands.map(\.title), ["New", "open", "save"])
    }

    func test_byTitle_idBreaksTies() {
        let cmds = [cmd("z", "Same", .file), cmd("a", "Same", .file)]
        let section = MenuOrganizer.organize(cmds).first!
        XCTAssertEqual(section.commands.map(\.id), ["a", "z"], "equal titles → id order")
    }

    func test_byRegistration_preservesInputOrder() {
        let cmds = [cmd("f1", "New", .file), cmd("f2", "Open", .file), cmd("f3", "Save", .file)]
        let section = MenuOrganizer.organize(cmds, order: .byRegistration).first!
        XCTAssertEqual(section.commands.map(\.title), ["New", "Open", "Save"],
                       "logical input order kept")
    }

    func test_menuInvokableOnly_dropsNoVerbCommands() {
        let cmds = [
            cmd("f1", "New", .file, verb: "new"),
            cmd("f2", "Window Thing", .file, verb: nil),  // NSApp-coupled, no verb
        ]
        let all = MenuOrganizer.organize(cmds)
        XCTAssertEqual(all.first!.commands.count, 2, "default includes everything")
        let invokable = MenuOrganizer.organize(cmds, menuInvokableOnly: true)
        XCTAssertEqual(invokable.first!.commands.map(\.id), ["f1"], "no-verb dropped")
    }

    func test_empty_producesNoSections() {
        XCTAssertTrue(MenuOrganizer.organize([]).isEmpty)
    }

    func test_realBuiltInRegistry_organizesCleanly() {
        // The real catalog groups without empty/duplicate sections.
        let sections = MenuOrganizer.organize(CommandRegistry.builtIn.commands)
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(Set(sections.map(\.category)).count, sections.count, "no dup sections")
        XCTAssertTrue(sections.allSatisfy { !$0.commands.isEmpty }, "no empty section")
        // Sections stay in declaration order (monotonic).
        let order = CommandCategory.allCases
        let idxs = sections.map { order.firstIndex(of: $0.category)! }
        XCTAssertEqual(idxs, idxs.sorted(), "sections in category declaration order")
    }
}
