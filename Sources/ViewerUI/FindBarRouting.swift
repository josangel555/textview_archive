import ViewerKit
import ViewerCore

/// Which find bar ⌘F toggles for the active surface. Pure decision (host-tested)
/// extracted from `main.swift`'s `findInPage` so the routing can't silently
/// regress — a wrong branch means ⌘F opens a find bar that can't search the
/// current content (the exact bug PDF find hit: ⌘F fell through to the source bar).
public enum FindBarTarget: String, Equatable, Sendable {
    case rendered   // rendered-markdown WKWebView find
    case editor     // CodeMirror 6 editor find
    case pdf        // PDFView reader find (TSK-1140)
    case source     // source/text NSTextView find (the default)
}

public enum FindBarRouting {
    /// Mirrors `findInPage`'s branch ORDER exactly:
    ///   1. rendered — only when the file supports the rendered lens AND it's shown;
    ///   2. editor — CM6 editor mode;
    ///   3. pdf — a `.pdf` tab (TSK-1140);
    ///   4. source — everything else (source view, plaintext, code, …).
    /// Order matters: editor/rendered win over the category (e.g. a `.pdf` shown in
    /// an editor lens, if that ever happens, routes to the editor bar).
    public static func target(
        viewMode: ViewMode,
        category: FileCategory?,
        supportsViewModeToggle: Bool
    ) -> FindBarTarget {
        if supportsViewModeToggle && viewMode == .rendered { return .rendered }
        if viewMode == .editor { return .editor }
        if category == .pdf { return .pdf }
        return .source
    }
}
