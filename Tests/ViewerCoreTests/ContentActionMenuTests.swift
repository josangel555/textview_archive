import Testing
import ViewerKit
@testable import ViewerCore

/// TSK-1319 — the dynamic content-menu model: per-`FileCategory` action sets +
/// the verb-token cohesion guard.
struct ContentActionMenuTests {

    @Test func markdown_offersMarkdownTools() {
        let actions = ContentActionMenu.actions(for: .markdown)
        #expect(actions.map(\.verb).contains("lint-markdown"))
        #expect(actions.map(\.verb).contains("check-links"))
        #expect(actions.map(\.verb).contains("edit-insert-toc"))
        #expect(ContentActionMenu.menuTitle(for: .markdown) == "Markdown")
    }

    @Test func mermaid_sharesTheMarkdownMenu() {
        #expect(ContentActionMenu.actions(for: .mermaid) == ContentActionMenu.actions(for: .markdown))
    }

    @Test func plainText_offersCSVTools_titledData() {
        let verbs = ContentActionMenu.actions(for: .plainText).map(\.verb)
        #expect(verbs.contains("csv-summary"))
        #expect(verbs.contains("copy-csv-as-json"))
        #expect(ContentActionMenu.menuTitle(for: .plainText) == "Data")
    }

    @Test func code_offersJSONTools() {
        let verbs = ContentActionMenu.actions(for: .code).map(\.verb)
        #expect(verbs.contains("edit-minify-json"))
        #expect(verbs.contains("copy-json-as-csv"))
        #expect(ContentActionMenu.menuTitle(for: .code) == "Code")
    }

    @Test func nonTextCategories_haveNoMenu() {
        for category: FileCategory in [.image, .audio, .video, .pdf, .sqlite,
                                       .archive, .canvas, .binary, .unknown] {
            #expect(ContentActionMenu.actions(for: category).isEmpty)
            #expect(ContentActionMenu.menuTitle(for: category) == nil,
                    "no dynamic menu for \(category)")
        }
    }

    @Test func everyCategoryIsMapped_noCrash() {
        // Exhaustive over FileCategory — the switch must be total (a new case
        // would fail to compile, but this also pins that lookups never trap).
        for category in FileCategory.allCases {
            _ = ContentActionMenu.actions(for: category)
            _ = ContentActionMenu.menuTitle(for: category)
        }
    }

    /// COHESION TEETH: every action verb the menu would dispatch must be a REAL
    /// `ScriptVerbCatalog` token — else the menu advertises an action that
    /// silently no-ops (the CommandVerbCohesion failure mode, one layer up).
    @Test func everyActionVerb_isARealCatalogToken() {
        let tokens = ScriptVerbCatalog.tokens
        for category in FileCategory.allCases {
            for action in ContentActionMenu.actions(for: category) {
                #expect(tokens.contains(action.verb),
                        "\(category) action '\(action.title)' uses unknown verb '\(action.verb)'")
            }
        }
    }

    @Test func actionTitles_areNonEmpty() {
        for category in FileCategory.allCases {
            for action in ContentActionMenu.actions(for: category) {
                #expect(!action.title.isEmpty)
            }
        }
    }
}
