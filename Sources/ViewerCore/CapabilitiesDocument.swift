import Foundation

/// TSK-1575 — the Help ▸ Capabilities page content. The canonical source is
/// `docs/CAPABILITIES.md`, copied into the app bundle at build time
/// (`build-app.sh` → `Contents/Resources/CAPABILITIES.md`) so the file stays the
/// SINGLE source. In dev / tests (where the resource isn't staged) it falls back
/// to a short embedded pointer, so the open path is exercisable without the
/// bundle. The Help-menu entry + the rendered open are the render tail.
public enum CapabilitiesDocument {

    static let resourceName = "CAPABILITIES"

    /// The capabilities markdown: the bundled `CAPABILITIES.md` when present
    /// (non-empty), else the embedded fallback. Never nil — a Help page must
    /// always open with *something*.
    public static func markdown(in bundle: Bundle = .main) -> String {
        if let url = bundle.url(forResource: resourceName, withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return fallbackMarkdown
    }

    /// Shown only when the bundled resource is missing (dev / unit tests). Kept
    /// short — the real guide is the bundled file.
    public static let fallbackMarkdown = """
    # TextView — Capabilities

    The full capabilities guide ships with the app. In a development build it \
    lives at `docs/CAPABILITIES.md` in the repository.

    Press **⌘K** to reach every command, or open **Help** for the sample tour and \
    keyboard shortcuts.
    """
}
