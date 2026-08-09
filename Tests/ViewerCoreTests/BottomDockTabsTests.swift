import Testing
import ViewerCore

/// Pure selection resolution for the TABBED bottom dock (owner rework
/// 2026-08-09): one visible panel at a time; a hidden stored choice falls
/// back to the first visible panel instead of rendering an empty band.
@Suite struct BottomDockTabsTests {

    @Test func noSelection_fallsBackToFirstVisible() {
        #expect(BottomDockTabs.resolve(selection: nil, visible: [.git, .lspProblems]) == .git)
    }

    @Test func selectionStillVisible_wins() {
        #expect(BottomDockTabs.resolve(
            selection: .lspProblems, visible: [.git, .lspProblems]) == .lspProblems)
    }

    @Test func hiddenSelection_fallsBackToFirstVisible() {
        #expect(BottomDockTabs.resolve(
            selection: .recentlyOpened, visible: [.git, .lspProblems]) == .git)
    }

    @Test func emptyVisibleSet_resolvesNil() {
        #expect(BottomDockTabs.resolve(selection: .git, visible: []) == nil)
        #expect(BottomDockTabs.resolve(selection: nil, visible: []) == nil)
    }

    /// The persisted-key contracts — never derive-and-change.
    @Test func storageKeys_areStable() {
        #expect(BottomDockTabs.selectionKey == "MarkdownViewer.dock.bottom.selectedPanel")
        #expect(BottomDockTabs.bandHeightKey == "MarkdownViewer.dock.bottom.bandHeight")
    }
}
