import XCTest
@testable import ViewerCore

/// TSK-678 — `KeyboardShortcutsCatalog`: grouping, ordering, debug-exclusion,
/// and the search filter that drive the Keyboard Shortcuts help page. Pure;
/// host-safe. Uses a synthetic registry for deterministic structure plus the
/// real `CommandRegistry.builtIn` for a sanity check.
final class KeyboardShortcutsCatalogTests: XCTestCase {

    /// A small registry: one bound File command, one UNBOUND File command
    /// (must be excluded), one bound View command, one bound Debug command.
    private func syntheticRegistry() -> CommandRegistry {
        CommandRegistry(commands: [
            CommandDescriptor(id: "file.save", title: "Save", category: .file,
                              defaultShortcut: Shortcut(key: "s", modifiers: [.command])),
            CommandDescriptor(id: "file.open", title: "Open…", category: .file,
                              defaultShortcut: nil),  // unbound → omitted
            CommandDescriptor(id: "view.toggle", title: "Toggle Rendered", category: .view,
                              defaultShortcut: Shortcut(key: "r", modifiers: [.command, .shift])),
            CommandDescriptor(id: "debug.dump", title: "Dump", category: .debug,
                              defaultShortcut: Shortcut(key: "d", modifiers: [.command, .control])),
        ])
    }

    // MARK: Build / grouping

    func test_onlyBoundCommands_appear() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        // file.open is unbound → excluded; debug excluded by default.
        XCTAssertEqual(cat.totalCount, 2)
        let ids = cat.sections.flatMap { $0.entries.map(\.id) }
        XCTAssertEqual(Set(ids), ["file.save", "view.toggle"])
        XCTAssertFalse(ids.contains("file.open"), "an unbound command must not appear")
    }

    func test_sections_inCategoryDeclarationOrder() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        XCTAssertEqual(cat.sections.map(\.category), [.file, .view],
                       "File precedes View (CommandCategory declaration order)")
        XCTAssertEqual(cat.sections.first?.title, "File")
    }

    func test_entry_carriesTitleAndGlyph() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        let save = cat.sections.first?.entries.first
        XCTAssertEqual(save?.title, "Save")
        XCTAssertEqual(save?.glyph, "⌘S")
        let toggle = cat.sections.first(where: { $0.category == .view })?.entries.first
        XCTAssertEqual(toggle?.glyph, "⇧⌘R")
    }

    func test_debugExcludedByDefault_includedOnRequest() {
        XCTAssertNil(KeyboardShortcutsCatalog(registry: syntheticRegistry())
            .sections.first(where: { $0.category == .debug }),
            "Debug commands are off the user-facing list by default")
        let withDebug = KeyboardShortcutsCatalog(registry: syntheticRegistry(), includeDebug: true)
        XCTAssertNotNil(withDebug.sections.first(where: { $0.category == .debug }))
        XCTAssertEqual(withDebug.totalCount, 3)
    }

    // MARK: Filter

    func test_emptyQuery_returnsUnchanged() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        XCTAssertEqual(cat.filtered("").totalCount, cat.totalCount)
        XCTAssertEqual(cat.filtered("   ").sections, cat.sections)
    }

    func test_filterByTitle_keepsOnlyMatchingSectionsAndEntries() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        let r = cat.filtered("save")
        XCTAssertEqual(r.totalCount, 1)
        XCTAssertEqual(r.sections.map(\.category), [.file])
        XCTAssertEqual(r.sections.first?.entries.first?.id, "file.save")
    }

    func test_filterByKeystroke_matchesGlyphAndConfigForm() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        // Glyph-form search.
        XCTAssertEqual(cat.filtered("⇧⌘R").sections.first?.entries.first?.id, "view.toggle")
        // Config-form search (cmd+s) also hits, via the searchKey.
        XCTAssertEqual(cat.filtered("cmd+s").sections.first?.entries.first?.id, "file.save")
    }

    func test_noMatch_yieldsEmpty() {
        let cat = KeyboardShortcutsCatalog(registry: syntheticRegistry())
        XCTAssertTrue(cat.filtered("zzzznope").sections.isEmpty)
        XCTAssertEqual(cat.filtered("zzzznope").totalCount, 0)
    }

    // MARK: Real registry sanity

    func test_builtInRegistry_producesNonEmptyGroupedCatalog() {
        let cat = KeyboardShortcutsCatalog(registry: .builtIn)
        XCTAssertGreaterThan(cat.totalCount, 20, "the built-in catalog has many bound shortcuts")
        XCTAssertFalse(cat.sections.isEmpty)
        // Every listed entry must actually carry a glyph (no blank rows).
        for section in cat.sections {
            for entry in section.entries {
                XCTAssertFalse(entry.glyph.isEmpty, "\(entry.id) rendered an empty glyph")
                XCTAssertFalse(entry.title.isEmpty)
            }
        }
        // A couple of well-known bindings resolve as expected.
        let all = cat.sections.flatMap { $0.entries }
        if let save = all.first(where: { $0.id == "file.save" }) {
            XCTAssertEqual(save.glyph, "⌘S")
        } else {
            XCTFail("file.save should be a bound, listed shortcut")
        }
    }
}
