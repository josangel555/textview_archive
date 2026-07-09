import Foundation
import ViewerCore

// TSK-1505 — spelling as a first-class, automatable feature. The verb-facing
// entry points (palette / menu / `--script`) for the full loop an agent drives
// with verbs alone: find (next/prev) → fix → learn/ignore → language → report.
// The DECISION + config + report layer here is host-testable; the on-screen
// caret-jump + text replacement land through the CM6 bridge (the render tail).
extension DocumentModel {

    /// The active editor/source tab id, or nil when no text tab is selected.
    private var activeSpellTabID: UUID? { tabs.selected?.id }

    /// Live text for a tab — the editor buffer if editing, else the loaded copy.
    private func spellText(forTabID id: UUID) -> String {
        if let buf = editor.editorBuffers[id] { return buf.text }
        if let tab = tabs.tabs.first(where: { $0.id == id }),
           case .loaded(let f) = tab.state { return f.contents }
        return ""
    }

    /// Re-run the spell pass for one tab (used after a language / ignore / learn
    /// change re-invalidates the whole document's squiggles).
    private func reSpellTab(_ id: UUID) {
        editor.runEditorSpellPass(
            text: spellText(forTabID: id),
            url: tabs.tabs.first(where: { $0.id == id })?.url,
            forTabID: id)
    }

    /// The misspelled word the nav cursor currently points at (for fix / learn /
    /// ignore), or nil when there's no current issue.
    private func currentSpellWord(forTabID id: UUID) -> String? {
        guard let issue = editor.currentSpellIssue(forTabID: id) else { return nil }
        let word = SpellNavigation.word(
            atUTF16: issue.from, issue.to, in: spellText(forTabID: id))
        return word.isEmpty ? nil : word
    }

    // MARK: - Verb entry points

    /// Move to the next / previous misspelling (wrapping) and select it. Returns
    /// false when no text tab is active or the document has no misspellings.
    @discardableResult
    public func spellNextMisspelling() -> Bool {
        guard let id = activeSpellTabID else { return false }
        return editor.navigateSpell(forTabID: id, direction: +1) != nil
    }

    @discardableResult
    public func spellPrevMisspelling() -> Bool {
        guard let id = activeSpellTabID else { return false }
        return editor.navigateSpell(forTabID: id, direction: -1) != nil
    }

    /// Replace the current misspelling with its top suggestion. Returns false when
    /// there's no current issue or the checker offers no suggestion.
    @discardableResult
    public func spellFixCurrent() -> Bool {
        guard let id = activeSpellTabID,
              let issue = editor.currentSpellIssue(forTabID: id),
              let word = currentSpellWord(forTabID: id) else { return false }
        let engine = SpellCheckEngine(
            language: editor.spellLanguage, ignoredWords: editor.spellIgnoredWords)
        guard let fix = engine.suggestions(for: word).first else { return false }
        let text = spellText(forTabID: id)
        let corrected = SpellNavigation.correctedText(
            replacingUTF16: issue.from, issue.to, with: fix, in: text)
        guard corrected != text else { return false }
        editor.updateEditorText(corrected, forTabID: id)
        return true
    }

    /// Add the current misspelling's word to the user dictionary (persistent).
    @discardableResult
    public func spellLearnCurrentWord() -> Bool {
        guard let id = activeSpellTabID, let word = currentSpellWord(forTabID: id)
        else { return false }
        return editor.learnSpellWord(word) { [weak self] in self?.reSpellTab($0) }
    }

    /// Ignore the current misspelling's word for this session.
    @discardableResult
    public func spellIgnoreCurrentWord() -> Bool {
        guard let id = activeSpellTabID, let word = currentSpellWord(forTabID: id)
        else { return false }
        editor.ignoreSpellWord(word) { [weak self] in self?.reSpellTab($0) }
        return true
    }

    /// Set the spell-check language (BCP-47, e.g. "en_GB"); empty / unavailable
    /// falls back to the system default. Returns false when the tag was
    /// unavailable (still applied the fallback) so the caller can report it.
    @discardableResult
    public func spellSetLanguage(_ tag: String?) -> Bool {
        editor.setSpellLanguage(tag) { [weak self] in self?.reSpellTab($0) }
    }

    /// Whole-document spell report into the shared tool-results panel (click a row
    /// to jump to its line). Returns false when no prose text tab is active.
    @discardableResult
    public func runSpellCheckToPanel() -> Bool {
        guard let id = activeSpellTabID, tabs.selected != nil else { return false }
        let text = spellText(forTabID: id)
        guard !text.isEmpty else { return false }
        let engine = SpellCheckEngine(
            language: editor.spellLanguage, ignoredWords: editor.spellIgnoredWords)
        let issues = engine.misspelledSpans(in: text, withSuggestions: true)
        if issues.isEmpty {
            presentToolResults(.note(
                title: "Spelling — no issues",
                message: "No misspellings found\(editor.spellLanguage.map { " (\($0))" } ?? "")."))
        } else {
            let rows = issues.enumerated().map { i, issue -> ToolResultRow in
                let hint = issue.suggestions.first.map { " → \($0)" } ?? ""
                return ToolResultRow(
                    id: i, severity: .warning, line: issue.line + 1,
                    message: "\(issue.word)\(hint)", tag: "spelling")
            }
            presentToolResults(ToolResults(
                title: "Spelling — \(issues.count) issue\(issues.count == 1 ? "" : "s")",
                rows: rows))
        }
        return true
    }
}
