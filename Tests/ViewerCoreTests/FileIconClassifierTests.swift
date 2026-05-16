import XCTest
@testable import ViewerCore
import ViewerKit

final class FileIconClassifierTests: XCTestCase {

    // MARK: - Helpers

    private func icon(_ path: String, isDirectory: Bool = false,
                      isExpanded: Bool = false,
                      isGitRoot: Bool = false,
                      isSymlink: Bool = false) -> FileIconKind {
        FileIconClassifier.icon(
            for: URL(fileURLWithPath: path),
            isDirectory: isDirectory, isExpanded: isExpanded,
            isGitRoot: isGitRoot, isSymlink: isSymlink
        )
    }

    private func assertChip(_ k: FileIconKind, _ text: String,
                            _ category: IconCategory,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case let .chip(t, c) = k else {
            XCTFail("expected chip got \(k)", file: file, line: line); return
        }
        XCTAssertEqual(t, text, file: file, line: line)
        XCTAssertEqual(c, category, file: file, line: line)
    }

    private func assertGlyph(_ k: FileIconKind, symbol: String? = nil,
                             category: IconCategory? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case let .glyph(s, c) = k else {
            XCTFail("expected glyph got \(k)", file: file, line: line); return
        }
        if let symbol { XCTAssertEqual(s, symbol, file: file, line: line) }
        if let category { XCTAssertEqual(c, category, file: file, line: line) }
    }

    private func assertFolder(_ k: FileIconKind, _ state: FolderState,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case let .folder(s) = k else {
            XCTFail("expected folder got \(k)", file: file, line: line); return
        }
        XCTAssertEqual(s, state, file: file, line: line)
    }

    // MARK: - Folders

    func test_folder_states() {
        assertFolder(icon("/x/src", isDirectory: true, isExpanded: false), .collapsed)
        assertFolder(icon("/x/src", isDirectory: true, isExpanded: true),  .open)
        assertFolder(icon("/x/proj", isDirectory: true, isGitRoot: true),  .root)
        assertFolder(icon("/x/.github", isDirectory: true),                 .hidden)
        assertFolder(icon("/x/node_modules", isDirectory: true),            .locked)
        assertFolder(icon("/x/vendor", isDirectory: true),                  .locked)
        assertFolder(icon("/x/.build", isDirectory: true),                  .locked)
        assertFolder(icon("/x/alias", isDirectory: true, isSymlink: true),  .symlink)
        // Hidden takes precedence over expansion (`.git` opened still hidden).
        assertFolder(icon("/x/.config", isDirectory: true, isExpanded: true), .hidden)
        // Single-dot (current) shouldn't be flagged hidden.
        assertFolder(icon("/.", isDirectory: true), .collapsed)
    }

    /// Batch A wired sidebar's git-root URL into the file-tree icon
    /// call site. The classifier's precedence rule says symlink wins
    /// over root, root wins over locked/hidden/expanded. Lock that in.
    func test_folder_state_precedence_gitRoot_beats_locked_hidden_expanded() {
        // Expanded + isGitRoot=true → root (not open).
        assertFolder(
            icon("/x/repo", isDirectory: true, isExpanded: true, isGitRoot: true),
            .root
        )
        // Hidden-looking name + isGitRoot=true → root (not hidden).
        assertFolder(
            icon("/x/.dotrepo", isDirectory: true, isGitRoot: true),
            .root
        )
        // node_modules + isGitRoot=true (weird but possible) → root.
        assertFolder(
            icon("/x/node_modules", isDirectory: true, isGitRoot: true),
            .root
        )
    }

    func test_folder_state_precedence_symlink_wins_over_everything() {
        // Symlink wins over isGitRoot — symlinked repos shouldn't
        // get the "root" tint because the real repo is elsewhere.
        assertFolder(
            icon("/x/alias", isDirectory: true, isGitRoot: true, isSymlink: true),
            .symlink
        )
        assertFolder(
            icon("/x/.gitalias", isDirectory: true, isSymlink: true),
            .symlink
        )
    }

    // MARK: - Code chips

    func test_code_typescript_variants() {
        assertChip(icon("/x/a.ts"), "TS", .code)
        assertChip(icon("/x/a.mts"), "TS", .code)
        assertChip(icon("/x/a.cts"), "TS", .code)
        assertChip(icon("/x/a.tsx"), "TSX", .code)
    }

    func test_code_other_languages() {
        assertChip(icon("/x/a.py"), "PY", .code)
        assertChip(icon("/x/a.rs"), "RS", .code)
        assertChip(icon("/x/a.go"), "GO", .code)
        assertChip(icon("/x/a.swift"), "SWFT", .code)
        assertChip(icon("/x/a.cpp"), "CPP", .code)
        assertChip(icon("/x/a.h"), "C", .code)
        assertChip(icon("/x/a.sh"), "SH", .code)
        assertChip(icon("/x/a.sql"), "SQL", .code)
    }

    // MARK: - Markup / style

    func test_markup_and_style() {
        assertChip(icon("/x/a.html"), "HTML", .markup)
        assertChip(icon("/x/a.xml"),  "XML",  .markup)
        assertChip(icon("/x/a.svg"),  "SVG",  .markup)
        assertChip(icon("/x/a.css"),  "CSS",  .style)
        assertChip(icon("/x/a.scss"), "SCSS", .style)
    }

    // MARK: - Config / data / secret

    func test_config_chips() {
        assertChip(icon("/x/a.json"), "JSON", .config)
        assertChip(icon("/x/a.yaml"), "YML",  .config)
        assertChip(icon("/x/a.yml"),  "YML",  .config)
        assertChip(icon("/x/a.toml"), "TOML", .config)
    }

    func test_data_chips() {
        assertChip(icon("/x/a.csv"), "CSV", .data)
        assertChip(icon("/x/a.log"), "LOG", .data)
        assertChip(icon("/x/a.ini"), "INI", .data)
    }

    func test_secrets() {
        assertChip(icon("/x/.env"),            "ENV", .secret)
        assertChip(icon("/x/.env.local"),      "ENV", .secret)
        assertChip(icon("/x/.env.production"), "ENV", .secret)
        assertGlyph(icon("/x/key.pem"),  symbol: "key", category: .secret)
        assertGlyph(icon("/x/cert.crt"), symbol: "key", category: .secret)
        assertGlyph(icon("/x/.npmrc"),   symbol: "key", category: .secret)
    }

    // MARK: - Documents

    func test_docs() {
        assertChip(icon("/x/a.md"),       "MD",  .doc)
        assertChip(icon("/x/a.mdx"),      "MDX", .doc)
        assertChip(icon("/x/a.markdown"), "MD",  .doc)
        assertChip(icon("/x/a.rst"),      "RST", .doc)
    }

    // MARK: - Glyph extensions (media etc.)

    func test_media_glyphs() {
        assertGlyph(icon("/x/a.png"), symbol: "photo",      category: .media)
        assertGlyph(icon("/x/a.jpg"), symbol: "photo",      category: .media)
        assertGlyph(icon("/x/a.mp3"), symbol: "waveform",   category: .media)
        assertGlyph(icon("/x/a.mp4"), symbol: "film",       category: .media)
        assertGlyph(icon("/x/a.ttf"), symbol: "textformat", category: .media)
    }

    func test_archive_glyphs() {
        assertGlyph(icon("/x/a.zip"), symbol: "archivebox", category: .bin)
        assertGlyph(icon("/x/a.tar"), symbol: "archivebox", category: .bin)
        assertGlyph(icon("/x/a.7z"),  symbol: "archivebox", category: .bin)
    }

    func test_database_glyphs() {
        assertGlyph(icon("/x/a.db"),      symbol: "cylinder", category: .data)
        assertGlyph(icon("/x/a.sqlite"),  symbol: "cylinder", category: .data)
        assertGlyph(icon("/x/a.sqlite3"), symbol: "cylinder", category: .data)
    }

    // MARK: - Special basenames (override extension)

    func test_readme_glyph_overrides_md_chip() {
        assertGlyph(icon("/x/README"),     symbol: "book.closed", category: .doc)
        assertGlyph(icon("/x/README.md"),  symbol: "book.closed", category: .doc)
        assertGlyph(icon("/x/README.txt"), symbol: "book.closed", category: .doc)
        assertGlyph(icon("/x/readme.rst"), symbol: "book.closed", category: .doc)
    }

    func test_special_basenames() {
        assertGlyph(icon("/x/LICENSE"),       symbol: "checkmark.seal",        category: .config)
        assertGlyph(icon("/x/COPYING"),       symbol: "checkmark.seal",        category: .config)
        assertGlyph(icon("/x/CHANGELOG.md"),  symbol: "list.bullet.rectangle", category: .doc)
        assertGlyph(icon("/x/.gitignore"),    symbol: "circle.slash",          category: .generic)
        assertGlyph(icon("/x/Dockerfile"),    symbol: "shippingbox",           category: .code)
        assertGlyph(icon("/x/api.Dockerfile"),symbol: "shippingbox",           category: .code)
        assertGlyph(icon("/x/Makefile"),      symbol: "hammer",                category: .generic)
        assertGlyph(icon("/x/package.json"),  symbol: "cube",                  category: .code)
        assertGlyph(icon("/x/CLAUDE.md"),     symbol: "sparkles",              category: .doc)
        assertGlyph(icon("/x/AGENTS.md"),     symbol: "sparkles",              category: .doc)
    }

    func test_lockfiles() {
        assertChip(icon("/x/Cargo.lock"),       "LOCK", .data)
        assertChip(icon("/x/pnpm-lock.yaml"),   "LOCK", .data)
        assertChip(icon("/x/yarn.lock"),        "LOCK", .data)
        assertChip(icon("/x/Gemfile.lock"),     "LOCK", .data)
        assertChip(icon("/x/poetry.lock"),      "LOCK", .data)
        // package-lock.json gets the package glyph, not LOCK chip.
        assertGlyph(icon("/x/package-lock.json"), symbol: "cube", category: .code)
    }

    // MARK: - Fallback

    func test_unknown_extension_falls_back_to_generic_chip() {
        assertChip(icon("/x/a.xyzzy"), "XYZZ", .generic)
        assertChip(icon("/x/a.foo"),   "FOO",  .generic)
    }

    func test_no_extension_no_special_basename_is_plain_text() {
        assertChip(icon("/x/justaname"), "TXT", .generic)
    }
}
