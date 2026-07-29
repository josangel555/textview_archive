import XCTest
@testable import ViewerCore

/// TSK-1605 — the New-File name prompt's validation rules (owner 2026-07-25:
/// "New file should first ask the filename. Do not create Untitled.txt.").
/// Same rule set as `FileRenamer` (one in-directory component) plus the
/// no-clobber check, so creating and renaming can't disagree.
final class NewFileNameValidatorTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/tmp/newfile-validator")

    private func validate(
        _ name: String, existing: Set<String> = []
    ) -> NewFileNameValidator.Verdict {
        NewFileNameValidator.validate(name, in: dir) { url in
            existing.contains(url.lastPathComponent)
        }
    }

    func test_acceptsAPlainName_andTrimsIt() {
        XCTAssertEqual(validate("notes.md"), .ok("notes.md"))
        XCTAssertEqual(validate("  spaced.txt  "), .ok("spaced.txt"),
                       "surrounding whitespace is trimmed, not rejected")
        XCTAssertEqual(validate("no-extension"), .ok("no-extension"),
                       "an extension is not required")
    }

    func test_rejectsEmpty() {
        XCTAssertEqual(validate(""), .empty)
        XCTAssertEqual(validate("   "), .empty)
        XCTAssertNotNil(NewFileNameValidator.message(for: .empty))
    }

    func test_rejectsPathTraversalAndSeparators() {
        // A name carrying a separator would let the create escape the folder.
        XCTAssertEqual(validate("sub/notes.md"), .invalid("sub/notes.md"))
        XCTAssertEqual(validate("../escape.txt"), .invalid("../escape.txt"))
        XCTAssertEqual(validate("."), .invalid("."))
        XCTAssertEqual(validate(".."), .invalid(".."))
        XCTAssertEqual(validate("nul\u{0}name"), .invalid("nul\u{0}name"),
                       "an embedded NUL truncates in C APIs — reject it")
    }

    func test_rejectsAnExistingName_ratherThanClobberingOrRenaming() {
        XCTAssertEqual(validate("taken.txt", existing: ["taken.txt"]), .exists("taken.txt"))
        // The whole point of the prompt: don't silently invent "taken 2.txt".
        let msg = NewFileNameValidator.message(for: .exists("taken.txt"))
        XCTAssertTrue(msg?.contains("already exists") == true,
                      "the reason is surfaced to the user: \(msg ?? "nil")")
    }

    func test_messageIsNilForOK() {
        XCTAssertNil(NewFileNameValidator.message(for: .ok("fine.txt")))
    }

    func test_suggestionMatchesTheTypeExtension() {
        XCTAssertEqual(NewFileNameValidator.suggestion(for: .text), NewFileType.text.baseName)
        XCTAssertEqual(NewFileNameValidator.suggestion(for: .markdown), NewFileType.markdown.baseName)
        XCTAssertTrue(NewFileNameValidator.suggestion(for: .markdown).hasSuffix(".md"))
    }
}
