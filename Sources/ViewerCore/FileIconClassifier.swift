import Foundation
import ViewerKit

/// Pure classifier for file-tree icons. No filesystem reads, no UI.
/// Order of precedence:
///   1. Directories → folder(state)
///   2. Basename matches (README, Dockerfile, package.json, …) — they
///      override extension because `README.md` should read as README,
///      not as a markdown chip.
///   3. Extension → chip text + category
///   4. Extension → glyph (media, archive, db, font, …)
///   5. Fallback: short ext as a generic chip, or `bin` glyph for
///      no-extension files.
public enum FileIconClassifier {

    public static func icon(
        for url: URL,
        isDirectory: Bool,
        isExpanded: Bool = false,
        isGitRoot: Bool = false,
        isSymlink: Bool = false
    ) -> FileIconKind {
        if isDirectory {
            return .folder(state: folderState(
                name: url.lastPathComponent,
                isExpanded: isExpanded,
                isGitRoot: isGitRoot,
                isSymlink: isSymlink
            ))
        }
        let name = url.lastPathComponent
        if let special = specialBasename(name) { return special }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            if let chip = chipForExtension(ext) { return chip }
            if let glyph = glyphForExtension(ext) { return glyph }
            // Unknown extension → use the ext itself as a generic chip,
            // truncated to 4 chars so the visual stays consistent.
            let label = String(ext.prefix(4)).uppercased()
            return .chip(text: label, category: .generic)
        }
        // No extension and no special basename — treat as plain text.
        return .chip(text: "TXT", category: .generic)
    }

    // MARK: - Folder state

    /// Directory names that almost always mean "generated / vendored,
    /// don't pollute search or watch." Keeping the list short keeps the
    /// rule predictable; users see the `locked` tint and know not to
    /// dig in unless intentional.
    private static let lockedFolderNames: Set<String> = [
        "node_modules", "vendor", "dist", "build", ".build",
        "target", ".next", ".nuxt", ".turbo", ".cache", ".gradle",
        "DerivedData", ".venv", "venv", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".tox", "coverage", ".nyc_output"
    ]

    private static func folderState(
        name: String,
        isExpanded: Bool,
        isGitRoot: Bool,
        isSymlink: Bool
    ) -> FolderState {
        if isSymlink { return .symlink }
        if isGitRoot { return .root }
        if lockedFolderNames.contains(name) { return .locked }
        if name.hasPrefix(".") && name.count > 1 { return .hidden }
        return isExpanded ? .open : .collapsed
    }

    // MARK: - Special basenames

    /// Matched as exact basename (case-insensitive) or by suffix.
    /// Returns nil if no rule matches — caller falls through to ext.
    private static func specialBasename(_ name: String) -> FileIconKind? {
        let lower = name.lowercased()

        // README — book glyph, doc tint.
        if lower == "readme" || lower.hasPrefix("readme.") {
            return .glyph(symbol: "book.closed", category: .doc)
        }
        // LICENSE / COPYING / NOTICE — seal glyph, config tint.
        if lower == "license" || lower.hasPrefix("license.")
            || lower == "copying" || lower.hasPrefix("copying.")
            || lower == "notice"  || lower.hasPrefix("notice.") {
            return .glyph(symbol: "checkmark.seal", category: .config)
        }
        // CHANGELOG / HISTORY — list glyph, doc tint.
        if lower == "changelog" || lower.hasPrefix("changelog.")
            || lower == "history" || lower.hasPrefix("history.") {
            return .glyph(symbol: "list.bullet.rectangle", category: .doc)
        }
        // .gitignore / .gitattributes / .gitmodules — nosign glyph.
        if lower == ".gitignore" || lower == ".gitattributes"
            || lower == ".gitmodules" || lower == ".mailmap" {
            return .glyph(symbol: "circle.slash", category: .generic)
        }
        // Dockerfile / *.Dockerfile / .dockerignore — shipping box.
        if lower == "dockerfile" || lower.hasSuffix(".dockerfile")
            || lower == ".dockerignore"
            || lower == "compose.yaml" || lower == "compose.yml"
            || lower == "docker-compose.yaml" || lower == "docker-compose.yml" {
            return .glyph(symbol: "shippingbox", category: .code)
        }
        // Makefile / GNUmakefile / *.mk — hammer.
        if lower == "makefile" || lower == "gnumakefile" || lower.hasSuffix(".mk") {
            return .glyph(symbol: "hammer", category: .generic)
        }
        // package.json / package-lock.json — cube. (Match before the
        // generic JSON chip rule.)
        if lower == "package.json" || lower == "package-lock.json"
            || lower == "pnpm-workspace.yaml" {
            return .glyph(symbol: "cube", category: .code)
        }
        // Lockfiles in general — chip "LOCK" / data tint.
        if lower.hasSuffix(".lock") || lower == "pnpm-lock.yaml"
            || lower == "yarn.lock" || lower == "poetry.lock"
            || lower == "gemfile.lock" || lower == "cargo.lock"
            || lower == "composer.lock" || lower == "podfile.lock" {
            return .chip(text: "LOCK", category: .data)
        }
        // Agent / AI context files — sparkles, doc tint.
        if lower == "claude.md" || lower == "agents.md"
            || lower == ".cursorrules" || lower == ".clauderules"
            || lower == ".aider.conf.yml" {
            return .glyph(symbol: "sparkles", category: .doc)
        }
        // .env family — secret chip.
        if lower == ".env" || lower.hasPrefix(".env.") {
            return .chip(text: "ENV", category: .secret)
        }
        // Secret / key files — key glyph.
        if lower == ".npmrc" || lower == ".netrc" || lower == ".pypirc"
            || lower.hasSuffix(".pem") || lower.hasSuffix(".key")
            || lower.hasSuffix(".p12") || lower.hasSuffix(".pfx")
            || lower.hasSuffix(".crt") || lower.hasSuffix(".cer") {
            return .glyph(symbol: "key", category: .secret)
        }
        return nil
    }

    // MARK: - Extension → chip

    /// Map of `ext` → `(text, category)`. The text is what's drawn in
    /// the chip; usually a 2-4 char upper-case rendering.
    private static let extChips: [String: (String, IconCategory)] = [
        // Code (blue)
        "ts": ("TS", .code), "mts": ("TS", .code), "cts": ("TS", .code),
        "tsx": ("TSX", .code),
        "js": ("JS", .code), "mjs": ("JS", .code), "cjs": ("JS", .code),
        "jsx": ("JSX", .code),
        "py": ("PY", .code), "pyi": ("PY", .code), "pyx": ("PY", .code),
        "rs": ("RS", .code),
        "go": ("GO", .code),
        "rb": ("RB", .code), "erb": ("RB", .code),
        "c": ("C", .code), "h": ("C", .code),
        "cpp": ("CPP", .code), "cc": ("CPP", .code),
        "hpp": ("CPP", .code), "hh": ("CPP", .code),
        "cxx": ("CPP", .code), "hxx": ("CPP", .code),
        "sh": ("SH", .code), "bash": ("SH", .code), "zsh": ("SH", .code),
        "fish": ("SH", .code),
        "sql": ("SQL", .code),
        "swift": ("SWFT", .code),
        "java": ("JAVA", .code),
        "kt": ("KT", .code), "kts": ("KT", .code),
        "php": ("PHP", .code),
        "scala": ("SCAL", .code),
        "clj": ("CLJ", .code), "cljs": ("CLJ", .code),
        "ex": ("EX", .code), "exs": ("EX", .code),
        "lua": ("LUA", .code),
        "pl": ("PL", .code), "pm": ("PL", .code),
        "r": ("R", .code),
        "dart": ("DART", .code),
        "zig": ("ZIG", .code),

        // Markup (pink)
        "html": ("HTML", .markup), "htm": ("HTML", .markup),
        "xhtml": ("HTML", .markup),
        "xml": ("XML", .markup),
        "plist": ("XML", .markup),
        "svg": ("SVG", .markup),

        // Style (teal)
        "css": ("CSS", .style),
        "scss": ("SCSS", .style), "sass": ("SCSS", .style),
        "less": ("LESS", .style),
        "styl": ("STYL", .style),

        // Config (green)
        "json": ("JSON", .config), "json5": ("JSON", .config), "jsonc": ("JSON", .config),
        "yaml": ("YML", .config), "yml": ("YML", .config),
        "toml": ("TOML", .config),

        // Data (amber)
        "ini": ("INI", .data), "conf": ("INI", .data), "cfg": ("INI", .data),
        "csv": ("CSV", .data), "tsv": ("CSV", .data),
        "log": ("LOG", .data), "out": ("LOG", .data),
        "parquet": ("PRQT", .data), "arrow": ("PRQT", .data), "feather": ("PRQT", .data),
        "tsv2": ("TSV", .data),

        // Doc (purple)
        "md": ("MD", .doc), "mdx": ("MDX", .doc), "markdown": ("MD", .doc),
        "mdown": ("MD", .doc), "mkd": ("MD", .doc), "mkdn": ("MD", .doc),
        "rst": ("RST", .doc),
        "tex": ("TEX", .doc),
        "adoc": ("ADOC", .doc),

        // Generic text
        "txt": ("TXT", .generic), "text": ("TXT", .generic),
    ]

    private static func chipForExtension(_ ext: String) -> FileIconKind? {
        guard let pair = extChips[ext] else { return nil }
        return .chip(text: pair.0, category: pair.1)
    }

    // MARK: - Extension → glyph

    /// Symbolic types where a pictogram reads faster than text — and
    /// importantly, the format has a *universally readable* visual:
    /// waveform, frame, disc, archive.
    private static let extGlyphs: [String: (String, IconCategory)] = [
        // Images
        "png": ("photo", .media), "jpg": ("photo", .media), "jpeg": ("photo", .media),
        "gif": ("photo", .media), "bmp": ("photo", .media),
        "tiff": ("photo", .media), "tif": ("photo", .media),
        "heic": ("photo", .media), "heif": ("photo", .media),
        "webp": ("photo", .media), "avif": ("photo", .media),
        "ico": ("photo", .media), "icns": ("photo", .media),

        // Audio
        "mp3": ("waveform", .media), "m4a": ("waveform", .media),
        "aac": ("waveform", .media), "wav": ("waveform", .media),
        "aiff": ("waveform", .media), "aif": ("waveform", .media),
        "flac": ("waveform", .media), "ogg": ("waveform", .media),
        "opus": ("waveform", .media), "caf": ("waveform", .media),

        // Video
        "mp4": ("film", .media), "m4v": ("film", .media),
        "mov": ("film", .media), "avi": ("film", .media),
        "mkv": ("film", .media), "webm": ("film", .media),
        "wmv": ("film", .media), "flv": ("film", .media),
        "mpg": ("film", .media), "mpeg": ("film", .media),

        // Fonts
        "ttf": ("textformat", .media), "otf": ("textformat", .media),
        "woff": ("textformat", .media), "woff2": ("textformat", .media),
        "eot": ("textformat", .media),

        // Archives
        "zip": ("archivebox", .bin), "tar": ("archivebox", .bin),
        "gz": ("archivebox", .bin), "tgz": ("archivebox", .bin),
        "bz2": ("archivebox", .bin), "xz": ("archivebox", .bin),
        "7z": ("archivebox", .bin), "rar": ("archivebox", .bin),

        // Databases
        "db": ("cylinder", .data), "sqlite": ("cylinder", .data),
        "sqlite3": ("cylinder", .data), "db3": ("cylinder", .data),

        // PDF / office docs (visual matters here)
        "pdf": ("doc.richtext", .doc),
        "docx": ("doc.text", .doc), "rtf": ("doc.text", .doc),
        "odt": ("doc.text", .doc), "pages": ("doc.text", .doc),
        "epub": ("book", .doc),

        // Generic binary / executable
        "bin": ("square.grid.3x3.fill", .bin),
        "dmg": ("internaldrive", .bin),
        "iso": ("opticaldiscdrive", .bin),
        "exe": ("square.grid.3x3.fill", .bin),
        "dylib": ("square.grid.3x3.fill", .bin),
        "so": ("square.grid.3x3.fill", .bin),
        "a": ("square.grid.3x3.fill", .bin),
    ]

    private static func glyphForExtension(_ ext: String) -> FileIconKind? {
        guard let pair = extGlyphs[ext] else { return nil }
        return .glyph(symbol: pair.0, category: pair.1)
    }
}
