import XCTest
import Foundation
@testable import ViewerKit

/// TSK-790 — the data behind the Settings "Supported languages" section:
/// `fileExtensions` (lang→exts) and `supportedForDisplay` (the listed set).
/// The round-trip test is the load-bearing guard — it keeps `fileExtensions`
/// in lock-step with `detect(from:)` so the Settings list can't claim an
/// extension the detector doesn't actually route.
final class HighlightLanguageTests: XCTestCase {

    func test_fileExtensions_roundTripThroughDetect() {
        for lang in HighlightLanguage.allCases {
            for ext in lang.fileExtensions {
                let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
                XCTAssertEqual(
                    HighlightLanguage.detect(from: url), lang,
                    "extension '.\(ext)' is listed under \(lang.displayName) but detect() routes it elsewhere — fileExtensions drifted from detect(from:)")
            }
        }
    }

    // TSK-901: extensionless / misnamed scripts → detect language from the shebang.
    func test_detectFromShebang_recognizesCommonInterpreters() {
        // env-style (basename after `env`)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/env python3\nprint(1)\n"), .python)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/env node"), .javascript)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/env ruby"), .ruby)
        // absolute-path interpreters
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/bin/bash\necho hi\n"), .shell)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/bin/sh"), .shell)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/python2.7"), .python)
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/lua"), .lua)
        // `env VAR=val interp` — skip the assignment
        XCTAssertEqual(HighlightLanguage.detect(fromShebang: "#!/usr/bin/env FOO=bar python"), .python)
    }

    func test_detectFromShebang_nilForNonScriptsAndUnknownInterpreters() {
        XCTAssertNil(HighlightLanguage.detect(fromShebang: "print('hi')\n"), "no shebang")
        XCTAssertNil(HighlightLanguage.detect(fromShebang: "/bin/bash\n"), "missing #! prefix")
        XCTAssertNil(HighlightLanguage.detect(fromShebang: "#!/usr/bin/env perl"), "unrecognized interpreter")
        XCTAssertNil(HighlightLanguage.detect(fromShebang: ""), "empty")
    }

    func test_supportedForDisplay_excludesPlainText_andIsSortedByName() {
        let listed = HighlightLanguage.supportedForDisplay
        XCTAssertFalse(listed.contains(.plainText),
                       "Plain Text is the no-highlight fallback, not a 'supported language'")
        // TSK-897: the list now reflects what we can ACTUALLY highlight (a real
        // bundled grammar), not merely "everything except plainText" — that older
        // invariant advertised go/html/css/sql/ruby/kotlin/yaml as modes that
        // rendered plain. It must equal the count of highlightable cases.
        let highlightableCount = HighlightLanguage.allCases.filter(\.isHighlightable).count
        XCTAssertEqual(listed.count, highlightableCount,
                       "every highlightable language (and only those) is listed")
        let names = listed.map(\.displayName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                       "the Settings list is alphabetised by display name")
    }

    func test_everyRealGrammarHasAtLeastOneExtension() {
        for lang in HighlightLanguage.supportedForDisplay {
            XCTAssertFalse(lang.fileExtensions.isEmpty,
                           "\(lang.displayName) is listed as supported but maps from no file extension")
        }
    }

    // MARK: - TSK-897: highlightable-language honesty + extension coverage

    /// `supportedForDisplay` (drives the Language Mode menu AND the Settings
    /// "Supported languages" list) MUST only contain languages the View-mode
    /// engine can actually color — never a case whose `isHighlightable` is false.
    /// Before TSK-897 it listed go/html/css/sql/ruby/kotlin, which render plain
    /// (no bundled grammar), so the menu offered modes that did nothing.
    func test_supportedForDisplay_containsOnlyHighlightableLanguages() {
        for lang in HighlightLanguage.supportedForDisplay {
            XCTAssertTrue(lang.isHighlightable,
                          "\(lang.displayName) is offered as a selectable highlight mode but isHighlightable == false — it would render plain")
        }
        // And it must contain EVERY highlightable case (no false omissions).
        let listed = Set(HighlightLanguage.supportedForDisplay)
        for lang in HighlightLanguage.allCases where lang.isHighlightable {
            XCTAssertTrue(listed.contains(lang),
                          "\(lang.displayName) is highlightable but missing from supportedForDisplay")
        }
    }

    /// The TSK-897 gap, pinned: these cases detect (badge shows their name) but
    /// have NO bundled View-mode grammar, so they must report isHighlightable ==
    /// false and stay out of the menu. If a grammar is later bundled, flip the
    /// flag in HighlightLanguage AND the engine — the ViewerCore parity test
    /// guards that pairing.
    func test_languagesWithoutBundledGrammar_areNotHighlightable() {
        for lang in [HighlightLanguage.go, .html, .css, .sql, .ruby, .kotlin, .yaml] {
            XCTAssertFalse(lang.isHighlightable,
                           "\(lang.displayName) has no bundled grammar yet — must report isHighlightable == false")
            XCTAssertFalse(HighlightLanguage.supportedForDisplay.contains(lang),
                           "\(lang.displayName) renders plain — must not appear in the selectable-mode list")
        }
        XCTAssertFalse(HighlightLanguage.plainText.isHighlightable,
                       "Plain Text is the no-highlight fallback")
    }

    /// Newly-routed extensions (TSK-897) must resolve to the intended language —
    /// these are the "renders plain" cases users reported. Each target maps to an
    /// already-bundled grammar (so it genuinely colors, not just badges).
    func test_detect_newlyRoutedExtensions() {
        let cases: [(String, HighlightLanguage)] = [
            // C / C++ family
            ("foo.c++", .cpp), ("foo.hxx", .cpp), ("foo.h++", .cpp),
            ("foo.ipp", .cpp), ("foo.ino", .cpp), ("foo.inl", .cpp),
            ("foo.cppm", .cpp), ("foo.ixx", .cpp), ("foo.tcc", .cpp),
            ("foo.m", .c),
            // C#
            ("foo.csx", .csharp),
            // shell
            ("foo.ksh", .shell), ("foo.ash", .shell), ("foo.command", .shell),
            ("foo.bashrc", .shell), ("foo.zshrc", .shell),
            // python (cython)
            ("foo.pyx", .python), ("foo.pxd", .python),
            // javascript / typescript module variants
            ("foo.mjs", .javascript), ("foo.es6", .javascript),
            ("foo.mts", .typescript), ("foo.cts", .typescript),
            // json variants
            ("foo.json5", .json), ("foo.jsonc", .json), ("foo.ndjson", .json),
            // xml family (project/manifest files)
            ("foo.xsd", .xml), ("foo.xslt", .xml), ("foo.csproj", .xml),
            ("foo.vcxproj", .xml), ("foo.pom", .xml), ("foo.rss", .xml),
            // markdown variants
            ("foo.mdwn", .markdown), ("foo.qmd", .markdown),
        ]
        for (name, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(HighlightLanguage.detect(from: url), expected,
                           "'\(name)' should detect as \(expected.displayName)")
        }
    }

    /// Every newly-routed extension that targets a grammar'd language must ALSO
    /// be highlightable — i.e. we only widened detection toward real grammars,
    /// never toward a plain-rendering case.
    func test_newlyRoutedExtensions_targetHighlightableGrammars() {
        let exts = ["c++", "hxx", "m", "csx", "ksh", "pyx", "mjs", "mts",
                    "json5", "xsd", "csproj"]
        for ext in exts {
            let lang = HighlightLanguage.detect(from: URL(fileURLWithPath: "/tmp/f.\(ext)"))
            XCTAssertTrue(lang.isHighlightable,
                          ".\(ext) routes to \(lang.displayName), which must be highlightable")
        }
    }

    /// CM6 Editor coverage honesty: `editorHighlightable` is the source of truth
    /// for which languages the Edit-mode pixels actually color. Pinned to the
    /// known CM6 pack set (markdown/js/ts/tsx/python/json). A file can be
    /// View-highlightable yet Editor-plain (e.g. Rust, C) — that's the second
    /// half of TSK-897, gated on bundling more @codemirror/lang-* packs.
    func test_editorHighlightable_matchesBundledCM6Packs() {
        let cm6 = Set<HighlightLanguage>([.markdown, .javascript, .typescript, .tsx, .python, .json])
        for lang in HighlightLanguage.allCases {
            XCTAssertEqual(lang.editorHighlightable, cm6.contains(lang),
                           "\(lang.displayName).editorHighlightable drifted from the bundled CM6 pack set")
        }
        // Every editor-highlightable language must also be View-highlightable
        // (the editor never colors something the engine can't).
        for lang in HighlightLanguage.allCases where lang.editorHighlightable {
            XCTAssertTrue(lang.isHighlightable,
                          "\(lang.displayName) colors in the editor but not in View mode — inconsistent")
        }
    }
}
