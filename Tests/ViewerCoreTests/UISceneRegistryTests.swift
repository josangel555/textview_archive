import XCTest
@testable import ViewerCore

/// TSK-492 (Foundation) — host tests for the deterministic UI-scene REGISTRY.
///
/// The registry is the pure, byte-reproducible control surface the visual-eval
/// harness builds on (`scripts/ui-snapshot.sh`, `scripts/vm-uitest.sh`,
/// `PixelTestCase`/T5). These pin the selection contract on the HOST so a
/// regression — a dropped scene id, a non-deterministic spec, an unknown id
/// silently accepted — fails the merge gate without any window/VM. The pixel
/// capture/diff itself stays the VM lane.
final class UISceneRegistryTests: XCTestCase {

    // MARK: - Enumeration & uniqueness

    func test_everyEnumeratedSceneIDResolvesToACompleteSpec() {
        for id in UISceneRegistry.allSceneIDs {
            guard let spec = UISceneRegistry.resolve(id) else {
                return XCTFail("enumerated scene id '\(id)' must resolve to a spec")
            }
            XCTAssertEqual(spec.id, id, "the spec must carry its own canonical id")
            XCTAssertFalse(spec.summary.isEmpty, "'\(id)' must carry a non-empty summary")
        }
    }

    func test_enumeratedSceneIDsAreUnique() {
        let ids = UISceneRegistry.allSceneIDs
        XCTAssertEqual(Set(ids).count, ids.count, "scene ids must be unique: \(ids)")
    }

    func test_allSceneIDsIncludeBothStaticAndParametricRepresentatives() {
        let ids = Set(UISceneRegistry.allSceneIDs)
        // A representative sample across the catalog — guards against a family
        // being dropped from the enumeration.
        for expected in ["landing", "folder-only", "theme-dark", "lsp-rename",
                         "metadata-checksum", "code-actions",
                         "terminal", "terminal-paneright", "tabs", "preview"] {
            XCTAssertTrue(ids.contains(expected), "registry must enumerate '\(expected)'")
        }
    }

    // MARK: - Unknown ids are REJECTED (not silently defaulted)

    func test_unknownSceneIsRejected_notDefaulted() {
        XCTAssertNil(UISceneRegistry.resolve("bogus-scene"))
        XCTAssertNil(UISceneRegistry.resolve("terminalx"))
        XCTAssertNil(UISceneRegistry.resolve("tab"))          // not "tabs"
        XCTAssertNil(UISceneRegistry.resolve("preview-bogus-token"))
        XCTAssertFalse(UISceneRegistry.isKnown("definitely-not-a-scene"))
    }

    func test_parametricFamiliesRejectStrayTokens_exactRecognition() {
        // A typo'd token inside a known family must REJECT (not silently fall
        // back to the family default) so a fat-fingered scene id can't capture
        // the wrong pixels and false-green.
        XCTAssertNil(UISceneRegistry.resolve("terminal-foo"))
        XCTAssertNil(UISceneRegistry.resolve("terminal-paneright-foo"))
        XCTAssertNil(UISceneRegistry.resolve("tabs-foo"))
        XCTAssertNil(UISceneRegistry.resolve("tabs-3-extra"))
        // But the legitimate compositions still resolve.
        XCTAssertNotNil(UISceneRegistry.resolve("terminal-right-paneleft-4"))
        XCTAssertNotNil(UISceneRegistry.resolve("tabs-3"))
    }

    func test_emptyOrWhitespaceSceneIsRejected() {
        XCTAssertNil(UISceneRegistry.resolve(""))
        // A bare unknown token (no family head) is rejected.
        XCTAssertNil(UISceneRegistry.resolve("xyzzy"))
    }

    // MARK: - Determinism (byte-reproducible across resolutions)

    func test_resolutionIsDeterministic_acrossTwoResolutions() {
        // Equatable on every field → two resolutions of the same id are ==,
        // proving NO randomness/timestamp/process state leaks into a spec.
        for id in UISceneRegistry.allSceneIDs {
            let a = UISceneRegistry.resolve(id)
            let b = UISceneRegistry.resolve(id)
            XCTAssertEqual(a, b, "scene '\(id)' must resolve identically every time")
        }
    }

    func test_resolutionIsCaseInsensitive_andCanonicalizes() {
        let upper = UISceneRegistry.resolve("TERMINAL-PANERIGHT")
        let lower = UISceneRegistry.resolve("terminal-paneright")
        XCTAssertNotNil(upper)
        XCTAssertEqual(upper, lower, "case must not affect the resolved spec")
        XCTAssertEqual(upper?.id, "terminal-paneright", "id is canonicalized to lowercase")
    }

    // MARK: - Per-family spec contracts

    func test_landing_isEmptyStateNoTabsNoTerminal() {
        let spec = UISceneRegistry.resolve("landing")
        XCTAssertEqual(spec?.fixture, UISceneRegistry.Fixture.none)
        XCTAssertNil(spec?.terminal, "landing leaves the terminal closed")
        XCTAssertEqual(spec?.overlay, UISceneRegistry.Overlay.none)
        XCTAssertNil(spec?.themeID)
    }

    func test_terminalDefault_isBottomEdgeLeftStripTwoTabs() {
        let spec = UISceneRegistry.resolve("terminal")
        let term = spec?.terminal
        XCTAssertEqual(term?.edge, .bottom, "default dock edge is bottom (no inherited prefs)")
        XCTAssertEqual(term?.tabPosition, .left, "default tab strip is left")
        XCTAssertEqual(term?.tabCount, UISceneRegistry.defaultTerminalTabCount)
        XCTAssertEqual(term?.height, UISceneRegistry.terminalHeight)
        XCTAssertEqual(term?.width, UISceneRegistry.terminalWidth)
    }

    func test_terminalDirectionalAndPaneTokens_mapToTheRightAxes() {
        // Tab-strip position vs pane dock edge are DISTINCT tokens.
        XCTAssertEqual(UISceneRegistry.resolve("terminal-top")?.terminal?.tabPosition, .top)
        XCTAssertEqual(UISceneRegistry.resolve("terminal-right")?.terminal?.tabPosition, .right)
        XCTAssertEqual(UISceneRegistry.resolve("terminal-paneright")?.terminal?.edge, .right)
        XCTAssertEqual(UISceneRegistry.resolve("terminal-paneleft")?.terminal?.edge, .left)
        // A paneright scene keeps the default LEFT strip unless a strip token is set.
        XCTAssertEqual(UISceneRegistry.resolve("terminal-paneright")?.terminal?.tabPosition, .left)
    }

    func test_terminalNumericToken_setsTabCount() {
        XCTAssertEqual(UISceneRegistry.resolve("terminal-3")?.terminal?.tabCount, 3)
        XCTAssertEqual(UISceneRegistry.resolve("terminal-right-5")?.terminal?.tabCount, 5)
        // tabCount is floored at 1.
        XCTAssertEqual(UISceneRegistry.resolve("terminal-0")?.terminal?.tabCount, 1)
    }

    func test_tabsFamily_carriesThrowawayMarkdownCount() {
        XCTAssertEqual(UISceneRegistry.resolve("tabs")?.fixture,
                       .throwawayMarkdown(count: UISceneRegistry.defaultFileTabCount))
        XCTAssertEqual(UISceneRegistry.resolve("tabs-14")?.fixture,
                       .throwawayMarkdown(count: 14))
        XCTAssertEqual(UISceneRegistry.resolve("tabs-1")?.fixture,
                       .throwawayMarkdown(count: 1))
        XCTAssertNil(UISceneRegistry.resolve("tabs")?.terminal, "tabs scene opens no terminal")
    }

    func test_previewFamily_usesEnvFixtureAndFlagsPromotion() {
        XCTAssertEqual(UISceneRegistry.resolve("preview")?.fixture, .previewFromEnv)
        XCTAssertEqual(UISceneRegistry.resolve("preview-promoted")?.fixture, .previewFromEnv)
        // The two preview ids resolve to DISTINCT specs (promotion differs in
        // the summary; the applier promotes for -promoted).
        XCTAssertNotEqual(UISceneRegistry.resolve("preview"),
                          UISceneRegistry.resolve("preview-promoted"))
    }

    func test_overlayScenes_declareTheirOverlay() {
        XCTAssertEqual(UISceneRegistry.resolve("lsp-rename")?.overlay, .lspRenamePrompt)
        XCTAssertEqual(UISceneRegistry.resolve("code-actions")?.overlay, .codeActionPicker)
        XCTAssertEqual(UISceneRegistry.resolve("metadata-checksum")?.overlay, .metadataPanel)
    }

    func test_themeDark_selectsTheDarkBuiltin() {
        XCTAssertEqual(UISceneRegistry.resolve("theme-dark")?.themeID, "xcode-dark")
    }

    func test_codeActionsScene_isFlaggedDebugOnly() {
        // The code-action picker uses a DEBUG-only present seam; the spec flags
        // it so a release build can reject it loudly (never a false green).
        XCTAssertTrue(UISceneRegistry.resolve("code-actions")?.isDebugOnly ?? false)
        // The other overlay scenes are NOT debug-only.
        XCTAssertFalse(UISceneRegistry.resolve("lsp-rename")?.isDebugOnly ?? true)
    }

    func test_closesExistingTabs_setOnlyWhereTheFixtureMustBeSole() {
        // metadata-checksum + folder-only must close the auto-opened doc so the
        // intended fixture is the sole foreground surface.
        XCTAssertTrue(UISceneRegistry.resolve("metadata-checksum")?.closesExistingTabs ?? false)
        XCTAssertTrue(UISceneRegistry.resolve("folder-only")?.closesExistingTabs ?? false)
        // theme-dark deliberately keeps the default doc open.
        XCTAssertFalse(UISceneRegistry.resolve("theme-dark")?.closesExistingTabs ?? true)
    }
}
