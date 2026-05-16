import Foundation

/// Two-system icon language for the file tree (see file-icons design).
/// `chip` is the file's extension rendered as legible text in a tinted
/// rounded rect (no fake language logos). `glyph` is an SF Symbol on a
/// tinted square — used for symbolic types (folders, media, README,
/// Dockerfile, etc.) where a pictogram beats text. `folder` is its own
/// case so callers can encode collapsed/open/root/hidden/locked state.
public enum FileIconKind: Equatable, Sendable {
    case chip(text: String, category: IconCategory)
    case glyph(symbol: String, category: IconCategory)
    case folder(state: FolderState)
}

public enum IconCategory: String, Equatable, Sendable, CaseIterable {
    case code      // blue   — TS / RS / GO …
    case markup    // pink   — HTML / XML / SVG
    case style     // teal   — CSS / SCSS
    case config    // green  — JSON / YAML / TOML
    case data      // amber  — CSV / LOG / LOCK / PARQUET
    case secret    // red    — ENV / keys / pem
    case doc       // purple — MD / PDF / RST
    case media     // warm   — audio / video / image / font
    case bin       // neutral— unknown binary / archive
    case generic   // light  — txt, .gitignore, makefiles
}

public enum FolderState: Equatable, Sendable {
    case collapsed
    case open
    case root      // workspace root / contains .git
    case hidden    // dot-prefixed dirs
    case locked    // node_modules, vendor, dist, .build…
    case symlink
}
