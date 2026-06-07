import Foundation

/// UX-A (#224) — the PRESENTATION layer for the content-toolbar's
/// view-mode control.
///
/// ## Why a separate presentation type (and not a `ViewMode` rewrite)
///
/// The underlying `ViewMode` enum + `DocumentModel` load/routing are
/// load-bearing and brittle: a prior attempt to re-route view modes
/// caused the "file cannot load / Editor shows HEX" regression (see
/// `LESSONS.md`, Session 2026-06-02/03, and the `fix(loadbug)` commit).
/// So UX-A does NOT touch `ViewMode` or `setCurrentViewMode`. Instead it
/// adds a thin, PURE mapping on top: the user thinks in terms of three
/// primary lenses — **Render · Editor · HEX** — plus a **View Only**
/// toggle and a conditional **Format** button, and this type translates
/// that mental model to/from the EXISTING `ViewMode` cases the model
/// already knows how to route.
///
/// The owner-resolved model (#224, decision A):
///
/// | Control      | View Only | Underlying `ViewMode`                       |
/// |--------------|-----------|---------------------------------------------|
/// | **Render**   | n/a (on)  | `.rendered` (md/mermaid/html), `.preview`   |
/// |              |           | (image/audio/video/pdf/sqlite), `.table`    |
/// |              |           | (csv/tsv), `.diff` (.diff/.patch), else      |
/// |              |           | `.source` for a plain text file.            |
/// | **Editor**   | ON        | `.source`  — read-only highlighted text.    |
/// | **Editor**   | OFF       | `.editor`  — editable CM6 buffer.           |
/// | **HEX**      | ON / OFF  | `.hex`     — editable byte grid.            |
/// | **Format**   | n/a       | `.formatted` — pretty-printed source.       |
///
/// So **Source = Editor + View Only**, exactly as the owner specified.
///
/// ## Round-trip contract
///
/// `present(_:)` collapses any `ViewMode` onto a `(primary, viewOnly)`
/// pair so the toolbar can render its three-button selection from the
/// model's current mode. `resolve(...)` maps a button tap + the View
/// Only flag back onto the concrete `ViewMode` the model should be set
/// to — gated by the file's `availableModes`, so a tap that the current
/// file can't satisfy falls back to that file's nearest available lens
/// rather than forcing an unavailable mode (which `setCurrentViewMode`
/// would reject anyway, leaving the picker desynced).
public enum ViewModeControl {

    /// The three primary lenses the toolbar surfaces as buttons. `Format`
    /// is intentionally NOT a primary — it is a separate conditional
    /// button (only for pretty-printable types), so it isn't part of the
    /// three-way segmented selection.
    public enum Primary: String, Equatable, Sendable, CaseIterable {
        case render
        case editor
        case hex

        /// Short button label.
        public var label: String {
            switch self {
            case .render: return "Render"
            case .editor: return "Editor"
            case .hex:    return "HEX"
            }
        }

        /// SF Symbol for the button (compact toolbars use the glyph).
        public var systemImage: String {
            switch self {
            case .render: return "doc.richtext"
            case .editor: return "square.and.pencil"
            case .hex:    return "number"
            }
        }
    }

    /// How the toolbar should render itself for a given underlying mode:
    /// which primary button is selected, whether View Only reads on, and
    /// whether the Format button is currently the active lens.
    public struct Presentation: Equatable, Sendable {
        public let primary: Primary
        public let viewOnly: Bool
        /// True only when the underlying mode is `.formatted`. The Format
        /// button (when shown) reflects active/inactive off this.
        public let isFormatted: Bool

        public init(primary: Primary, viewOnly: Bool, isFormatted: Bool) {
            self.primary = primary
            self.viewOnly = viewOnly
            self.isFormatted = isFormatted
        }
    }

    /// Collapse a concrete `ViewMode` onto the toolbar's `(primary,
    /// viewOnly, isFormatted)` projection.
    ///
    /// - `.rendered` / `.preview` / `.table` / `.diff` → **Render** (the
    ///   rich lens for the type), View Only on. These are all read-only
    ///   "look at the structured/native rendering" lenses, so they fold
    ///   onto the single Render button.
    /// - `.source` → **Editor**, View Only ON (read-only text).
    /// - `.editor` → **Editor**, View Only OFF (editable).
    /// - `.hex`    → **HEX**.
    /// - `.formatted` → **Editor** primary (it IS a text-source lens),
    ///   `isFormatted` true, so the Format button reads active while the
    ///   Editor button stays the structural "this is text" selection.
    public static func present(_ mode: ViewMode) -> Presentation {
        switch mode {
        case .rendered, .preview, .table, .diff:
            return Presentation(primary: .render, viewOnly: true, isFormatted: false)
        case .source:
            return Presentation(primary: .editor, viewOnly: true, isFormatted: false)
        case .editor:
            return Presentation(primary: .editor, viewOnly: false, isFormatted: false)
        case .formatted:
            // Format is a text-derived lens; surface Editor as the primary
            // (so leaving Format via the Editor button is natural) and flag
            // the Format button active.
            return Presentation(primary: .editor, viewOnly: true, isFormatted: true)
        case .hex:
            // There is a single `.hex` ViewMode for both read-only and
            // byte-edit, so the mode alone can't say which. Report View Only
            // ON as the mode-only default; the per-tab edit-armed flag lives
            // on DocumentModel, which overrides this in `viewModePresentation`
            // (#234 / TSK-467).
            return Presentation(primary: .hex, viewOnly: true, isFormatted: false)
        }
    }

    /// Map a primary-button tap + the View Only flag onto the concrete
    /// `ViewMode` the model should be set to, gated by `available` (the
    /// file's `ViewModeOptions.availableModes`). Returns `nil` only when
    /// `available` is empty (no file) — callers treat that as "do nothing".
    ///
    /// Gating rationale: `setCurrentViewMode` rejects an unavailable
    /// `.rendered` on a plain-text tab (LOADBUG SC-MENU-01), so the
    /// presentation layer must not hand it a mode the file can't satisfy.
    /// For each primary we pick the best available lens:
    ///
    /// - **Render**: the file's rich lens — `.rendered` if offered, else
    ///   `.preview`, else `.table`, else `.diff`, else fall back to
    ///   `.source` (a plain `.txt` has no rich lens, so "Render" lands on
    ///   the source text — the closest read-only rendering).
    /// - **Editor**: `.source` when View Only on; `.editor` when off (and
    ///   the file actually offers `.editor`, else `.source`). A media/PDF
    ///   tab offers neither — it falls back to its `.preview`/`.hex`.
    /// - **HEX**: always `.hex` (every file with bytes offers it).
    public static func resolve(
        primary: Primary, viewOnly: Bool, available: [ViewMode]
    ) -> ViewMode? {
        guard !available.isEmpty else { return nil }
        func firstAvailable(_ prefs: [ViewMode]) -> ViewMode? {
            prefs.first { available.contains($0) }
        }
        switch primary {
        case .render:
            // Rich-render preference order; .source is the universal
            // text fallback so a plain text file's "Render" still resolves.
            return firstAvailable([.rendered, .preview, .table, .diff, .source])
                ?? available.first
        case .editor:
            if viewOnly {
                // Read-only text. `.source` for text; for media/PDF/binary
                // (no `.source`) fall back to the file's natural lens.
                return firstAvailable([.source, .preview, .hex]) ?? available.first
            } else {
                // Editable. Prefer `.editor`; degrade to `.source` if the
                // file doesn't offer an editable buffer (diff / oversized /
                // media), then to its natural lens.
                return firstAvailable([.editor, .source, .preview, .hex]) ?? available.first
            }
        case .hex:
            return available.contains(.hex) ? .hex : available.first
        }
    }

    /// Whether the `Format` button should be shown for `available`. Mirrors
    /// the existing pretty-print gating: the button appears only when the
    /// file offers the `.formatted` mode (JSON / XML / plist / SVG / HTML /
    /// …) — i.e. `availableModes` includes `.formatted`.
    public static func showsFormat(available: [ViewMode]) -> Bool {
        available.contains(.formatted)
    }

    /// Whether the `Editor` primary is even applicable for `available`.
    /// Media / PDF / binary tabs (which offer only `.preview` + `.hex`, or
    /// `.hex` alone) have no text lens, so the Editor button is hidden for
    /// them — the toolbar shows just Render (if any rich lens) + HEX.
    public static func showsEditor(available: [ViewMode]) -> Bool {
        available.contains(.source) || available.contains(.editor)
    }

    /// Whether a `Render` primary is meaningful — i.e. the file offers any
    /// rich/structured/native lens distinct from plain source. A bare
    /// `.txt` (only `.source`/`.editor`/`.hex`) has no rich render, so the
    /// Render button is hidden and Editor becomes the leftmost lens.
    public static func showsRender(available: [ViewMode]) -> Bool {
        available.contains(.rendered)
            || available.contains(.preview)
            || available.contains(.table)
            || available.contains(.diff)
    }
}
