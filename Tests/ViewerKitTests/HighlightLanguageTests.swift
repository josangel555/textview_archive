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
        XCTAssertEqual(listed.count, HighlightLanguage.allCases.count - 1,
                       "every real grammar is listed (allCases minus plainText)")
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
}
