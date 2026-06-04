import XCTest
@testable import ViewerKit

/// Coverage for the known-basename map + config-extension allowlist added so
/// dev config / dotfiles / build files resolve to a cheap text category
/// (plainText/code via NSTextView) instead of `.unknown`. Owner ask
/// (2026-06-04): "default plain text / allow-list known plain-text formats."
final class FileTypeDetectorKnownTextTests: XCTestCase {

    private func cat(_ name: String) -> FileCategory {
        FileTypeDetector.category(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // Build/project files identified by whole name → code (worth highlighting).
    func test_buildFiles_resolveToCode() {
        for n in ["Dockerfile", "dockerfile", "Makefile", "CMakeLists.txt",
                  "Rakefile", "Gemfile", "Podfile", "Vagrantfile", "Justfile"] {
            XCTAssertEqual(cat(n), .code, "\(n) should be .code")
        }
    }

    // Dotfiles + doc files → plainText.
    func test_dotfilesAndDocs_resolveToPlainText() {
        for n in [".gitignore", ".gitattributes", ".dockerignore", ".editorconfig",
                  ".env", ".npmrc", ".nvmrc", ".gitconfig",
                  "LICENSE", "LICENCE", "README", "CHANGELOG", "AUTHORS",
                  "NOTICE", "COPYING", "CODEOWNERS"] {
            XCTAssertEqual(cat(n), .plainText, "\(n) should be .plainText")
        }
    }

    // Shell rc dotfiles → code.
    func test_shellRcFiles_resolveToCode() {
        for n in [".bashrc", ".zshrc", ".bash_profile", ".profile", ".prettierrc"] {
            XCTAssertEqual(cat(n), .code, "\(n) should be .code")
        }
    }

    // Config/lock extensions → plainText (kept off the WebView editor path).
    func test_configExtensions_resolveToPlainText() {
        for n in ["app.conf", "settings.ini", "tool.cfg", "build.properties",
                  "Package.resolved", "go.sum", "yarn.lock", "service.env",
                  "cert.pem", "deploy.dist", "config.sample"] {
            XCTAssertEqual(cat(n), .plainText, "\(n) should be .plainText")
        }
    }

    // Regression: real types must NOT be shadowed by the new rules.
    func test_knownTypes_unchanged() {
        XCTAssertEqual(cat("README.md"), .markdown)   // basename "readme.md" ≠ "readme"
        XCTAssertEqual(cat("LICENSE.txt"), .plainText) // ext path
        XCTAssertEqual(cat("main.swift"), .code)
        XCTAssertEqual(cat("photo.png"), .image)
        XCTAssertEqual(cat("data.csv"), .plainText)
        XCTAssertEqual(cat("page.html"), .html)
        XCTAssertEqual(cat("db.sqlite"), .sqlite)
        XCTAssertEqual(cat("movie.mp4"), .video)
        XCTAssertEqual(cat("diagram.mmd"), .mermaid)
        XCTAssertEqual(cat("notes.md"), .markdown)
    }
}
