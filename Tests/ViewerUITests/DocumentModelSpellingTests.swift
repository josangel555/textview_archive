import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1505 — command-path coverage for the spelling verbs (nav / fix / learn /
/// ignore / language / report) on a hermetic `DocumentModel`. Navigation is
/// pinned deterministically off SEEDED diagnostics (no NSSpellChecker
/// dependency); the fix / ignore / report paths exercise the real host
/// NSSpellChecker over a known misspelling ("recieve"), which macOS flags
/// reliably. The learn path unlearns its nonsense word so the host user
/// dictionary is never polluted.
@MainActor
final class DocumentModelSpellingTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpellingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SpellingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    /// Open a `.txt` tab with `contents` and seed its editor buffer.
    @discardableResult
    private func openProse(_ contents: String, in model: DocumentModel) throws -> UUID {
        let url = tmpDir.appendingPathComponent("note-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.editor.updateEditorText(contents, forTabID: id)
        return id
    }

    private func seedIssues(_ specs: [(String, Int, Int)], forTabID id: UUID, in model: DocumentModel) {
        let issues = specs.map { word, loc, len in
            SpellingIssue(word: word, range: NSRange(location: loc, length: len),
                          line: 0, column: loc)
        }
        model.editor.setEditorSpellDiagnostics(issues, forTabID: id)
    }

    // MARK: - Navigation (deterministic, seeded)

    func test_nextMisspelling_walksAndWraps_selectingEachRange() throws {
        let model = makeModel()
        let id = try openProse("aaa bbb ccc", in: model)
        seedIssues([("aaa", 0, 3), ("bbb", 4, 3), ("ccc", 8, 3)], forTabID: id, in: model)

        XCTAssertTrue(model.spellNextMisspelling())          // → issue 0
        XCTAssertEqual(model.editor.editorSelectRequest?.anchor, 0)
        XCTAssertEqual(model.editor.editorSelectRequest?.head, 3)

        XCTAssertTrue(model.spellNextMisspelling())          // → issue 1
        XCTAssertEqual(model.editor.editorSelectRequest?.anchor, 4)

        XCTAssertTrue(model.spellNextMisspelling())          // → issue 2
        XCTAssertEqual(model.editor.editorSelectRequest?.anchor, 8)

        XCTAssertTrue(model.spellNextMisspelling())          // wraps → issue 0
        XCTAssertEqual(model.editor.editorSelectRequest?.anchor, 0)
    }

    func test_prevMisspelling_fromStart_wrapsToLast() throws {
        let model = makeModel()
        let id = try openProse("aaa bbb ccc", in: model)
        seedIssues([("aaa", 0, 3), ("bbb", 4, 3), ("ccc", 8, 3)], forTabID: id, in: model)

        XCTAssertTrue(model.spellPrevMisspelling())          // nil cursor + prev → last
        XCTAssertEqual(model.editor.editorSelectRequest?.anchor, 8)
    }

    func test_navigate_returnsFalse_whenNoMisspellings() throws {
        let model = makeModel()
        _ = try openProse("all correct words here", in: model)
        // No seeded issues (and the real pass finds none) → nothing to navigate.
        XCTAssertFalse(model.spellNextMisspelling())
        XCTAssertFalse(model.spellPrevMisspelling())
    }

    // MARK: - Fix (real NSSpellChecker suggestion)

    func test_fixCurrent_replacesMisspellingWithSuggestion() throws {
        let model = makeModel()
        let id = try openProse("I recieve it", in: model)
        // The real pass should flag "recieve"; if the host dictionary somehow
        // doesn't, seed it so the fix path is still exercised deterministically.
        if model.editor.spellIssues(forTabID: id).isEmpty {
            seedIssues([("recieve", 2, 7)], forTabID: id, in: model)
        }
        XCTAssertTrue(model.spellNextMisspelling(), "precondition: a misspelling exists")
        XCTAssertTrue(model.spellFixCurrent(), "fix applies the top suggestion")
        let text = model.editor.editorBuffers[id]?.text ?? ""
        XCTAssertFalse(text.contains("recieve"),
            "the misspelled word must be replaced; got: \(text)")
    }

    func test_fixCurrent_returnsFalse_withNoCurrentIssue() throws {
        let model = makeModel()
        _ = try openProse("all fine", in: model)
        XCTAssertFalse(model.spellFixCurrent(), "no navigated issue → nothing to fix")
    }

    // MARK: - Ignore (session ignore set)

    func test_ignoreCurrentWord_addsToIgnoreSet() throws {
        let model = makeModel()
        let id = try openProse("I recieve it", in: model)
        if model.editor.spellIssues(forTabID: id).isEmpty {
            seedIssues([("recieve", 2, 7)], forTabID: id, in: model)
        }
        XCTAssertTrue(model.spellNextMisspelling())
        XCTAssertTrue(model.spellIgnoreCurrentWord())
        XCTAssertTrue(model.editor.spellIgnoredWords.contains("recieve"),
            "ignore-word must add the current word to the session ignore set")
    }

    // MARK: - Language

    func test_setLanguage_invalidTagFallsBackToDefault_returnsFalse() throws {
        let model = makeModel()
        _ = try openProse("hello", in: model)
        XCTAssertFalse(model.spellSetLanguage("zz_NOTALANG"),
            "an unavailable tag reports false…")
        XCTAssertNil(model.editor.spellLanguage, "…and falls back to the system default (nil)")
    }

    func test_setLanguage_availableTagApplies_returnsTrue() throws {
        let model = makeModel()
        _ = try openProse("hello", in: model)
        guard let tag = SpellCheckEngine.availableLanguages.first else {
            throw XCTSkip("no spell languages installed on this host")
        }
        XCTAssertTrue(model.spellSetLanguage(tag))
        XCTAssertEqual(model.editor.spellLanguage, tag)
    }

    // MARK: - Learn (dictionary-safe: nonsense word, unlearned)

    func test_learnCurrentWord_returnsTrue_thenUnlearn() throws {
        let model = makeModel()
        let nonsense = "zqxwtbbq"
        let id = try openProse("a \(nonsense) b", in: model)
        seedIssues([(nonsense, 2, nonsense.utf16.count)], forTabID: id, in: model)
        XCTAssertTrue(model.spellNextMisspelling())
        XCTAssertTrue(model.spellLearnCurrentWord(), "add-to-dictionary learns the current word")
        // Clean up so the host user dictionary is not polluted by the test.
        NSSpellChecker.shared.unlearnWord(nonsense)
    }

    func test_learnCurrentWord_returnsFalse_withNoCurrentIssue() throws {
        let model = makeModel()
        _ = try openProse("clean", in: model)
        XCTAssertFalse(model.spellLearnCurrentWord())
    }

    // MARK: - Whole-document report → tool-results panel

    func test_checkSpellingDocument_presentsRowsForIssues() throws {
        let model = makeModel()
        _ = try openProse("I recieve it", in: model)
        XCTAssertTrue(model.runSpellCheckToPanel())
        guard let results = model.toolResults else {
            return XCTFail("spell report must present a tool-results set")
        }
        // "recieve" is reliably flagged → at least one row; each row carries a line.
        XCTAssertFalse(results.rows.isEmpty, "the report must list the misspelling(s)")
        XCTAssertTrue(results.rows.allSatisfy { $0.line != nil },
            "each spell row must be click-to-line navigable")
    }

    func test_checkSpellingDocument_returnsFalse_withNoTextTab() throws {
        let model = makeModel()
        XCTAssertFalse(model.runSpellCheckToPanel(), "no active text tab → nothing to report")
    }
}
