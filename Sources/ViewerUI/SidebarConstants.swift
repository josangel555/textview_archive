import SwiftUI
import ViewerCore

/// Layout constants shared across sidebar sections — Bookmarks,
/// Search, Git panel body, Claude timeline, FILES.
///
/// Originally every section body rendered at a fixed
/// `sectionBodyHeight`; resizable-sections (2026-05) made this
/// per-section, overridable via the
/// `\.sidebarSectionBodyHeight` SwiftUI environment value. Sections
/// continue to read the constant by default; the parent (`SidebarView`)
/// injects a per-section override + drag handle that adjusts it.
public enum SidebarConstants {
    /// Default uncollapsed body height. Used both as the static
    /// fallback for section bodies that haven't opted into the
    /// resizable environment value and as the default value of
    /// `\.sidebarSectionBodyHeight`.
    public static let sectionBodyHeight: CGFloat = 220
}

private struct SidebarSectionBodyHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = SidebarConstants.sectionBodyHeight
}

public extension EnvironmentValues {
    /// Height a sidebar section's scrollable body should occupy when
    /// expanded. Defaults to `SidebarConstants.sectionBodyHeight`;
    /// `SidebarView` overrides it per section so users can drag a
    /// section's bottom edge to resize.
    var sidebarSectionBodyHeight: CGFloat {
        get { self[SidebarSectionBodyHeightKey.self] }
        set { self[SidebarSectionBodyHeightKey.self] = newValue }
    }
}

// MARK: - Section container chrome
//
// Every section above the FILES tree (Bookmarks, Search, Git, Claude,
// LSP outline, plugin sections, and future additions such as the LSP
// "Problems" panel) wraps its body in `.sidebarSectionContainer()`.
// That keeps the visual treatment in one spot: a subtle background
// swatch + small outer vertical gap so the resizable dividers between
// sections breathe, and each section reads as its own card.
//
// Adding a new section is then a one-line opt-in (apply the modifier
// in the section's body) — no per-section bg/padding boilerplate.

struct SidebarSectionContainer: ViewModifier {
    /// The swatch is a STORED property, resolved at the call site — an
    /// empty modifier struct reading `Palette` (→ global `ChromeTheme`)
    /// inside `body` is invisible to SwiftUI's diff, so a runtime theme
    /// switch left section cards painted in the launch theme (the stale
    /// git-band bug, 2026-08-08). Stored here, the section's re-body on
    /// the theme republish hands the modifier a new value and it repaints.
    let background: Color

    func body(content: Content) -> some View {
        content
            // Single sidebar-panel background swatch. See
            // `Palette.sidebarPanelBackground` for the dark/light
            // values. Centralising the token here means a future
            // theme tweak is one edit, not N section files.
            // (The old 2px vertical padding is GONE — it let the sidebar
            // background peek through as white bars around the divider,
            // the "white → line → white" seam; owner 2026-08-09. The
            // divider is now a visible gutter band and needs no gap.)
            .background(background)
    }
}

extension View {
    /// Apply the standard sidebar-section chrome: subtle background
    /// tint + outer vertical padding so sections read as cards and the
    /// resize handle between them has visible breathing room.
    @MainActor
    func sidebarSectionContainer() -> some View {
        modifier(SidebarSectionContainer(background: Palette.sidebarPanelBackground))
    }
}

// MARK: - Section body frame (fixed height vs flex-fill)
//
// Owner 2026-08-09 ("see what special treatment we do for filenav and
// generalize it"): FILES fills the shoulder because it renders OUTSIDE the
// accordion scroll with `maxHeight: .infinity` — every other panel hard-froze
// to `\.sidebarSectionBodyHeight`. The env value `.infinity` is now the
// "flex-fill" sentinel; sections apply their body frame through this ONE
// modifier so fixed-vs-fill is decided in a single place. `SidebarView`
// renders the fill-target panel outside its bounded scroll and injects
// `.infinity` — the literal FILES treatment, generalized.

struct SidebarSectionBodyFrame: ViewModifier {
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    func body(content: Content) -> some View {
        if bodyHeight == .infinity {
            content.frame(maxHeight: .infinity)
        } else {
            content.frame(height: bodyHeight)
        }
    }
}

extension View {
    /// Size a section's scrollable body: the injected fixed height normally,
    /// flex-fill when the environment carries the `.infinity` sentinel.
    func sidebarSectionBodyFrame() -> some View {
        modifier(SidebarSectionBodyFrame())
    }
}

// MARK: - Section header recipe
//
// Every accordion-section header (FILES, BOOKMARKS, SEARCH, GIT,
// CLAUDE, OUTLINE, REFERENCES/WORKSPACE SYMBOLS, PROBLEMS, plugins)
// renders the same chrome: chevron + uppercase label, optional
// trailing controls, fixed font / weight / padding envelope.
//
// Concentrate the recipe in one place — `SidebarSectionHeaderLabel`
// for the chevron + label sub-unit, `.sidebarHeaderRow()` for the
// outer HStack envelope. Future sections opt in with a one-liner;
// no more per-section font-size drift.
public enum SidebarSectionHeaderMetrics {
    /// Base font size for the section label (passed through
    /// `model.uiSize(_:)` so user-controlled UI zoom still applies).
    public static let labelFontSize: CGFloat = 10
    /// Chevron glyph point size — matches the label's design weight.
    public static let chevronFontSize: CGFloat = 9
    /// Leading frame width reserved for the chevron so labels line up
    /// across sections regardless of expand/collapse state.
    public static let chevronFrameWidth: CGFloat = 10
    /// Horizontal inset for the header row content.
    public static let horizontalPadding: CGFloat = 10
    /// Vertical inset for the header row content.
    public static let verticalPadding: CGFloat = 4
}

/// Standard chevron + uppercase label sub-unit for a sidebar section
/// header. Sections wrap this inside a Button (for collapse toggle)
/// and an HStack with any trailing controls (counts, menus, refresh
/// buttons). The `uiSize` closure threads `DocumentModel.uiSize(_:)`
/// through so user zoom still scales the label; defaults to identity
/// for call sites without a model.
///
/// TSK-327: when `dragKind` is set, the label is a DRAG SOURCE for the
/// tool-window drag-to-snap system — dragging the section header onto a
/// shoulder rail / the sidebar (`panelDropZone`) redocks the panel.
/// This is the one shared chokepoint every dockable section's header
/// passes through, so the accordion gets its drag handles in one place.
/// `nil` (the default) keeps non-dockable headers (FILES, per-plugin
/// inner sections) inert.
struct SidebarSectionHeaderLabel: View {
    let title: String
    let isExpanded: Bool
    var uiSize: (CGFloat) -> CGFloat = { $0 }
    var dragKind: SidebarPanelKind? = nil

    var body: some View {
        if let kind = dragKind {
            labelRow.draggable(PanelDragPayload(kind)) {
                PanelDragChip(kind: kind)
            }
        } else {
            labelRow
        }
    }

    private var labelRow: some View {
        HStack(spacing: 4) {
            // UX-F (#228): chevron glyph + its reserved frame scale with the
            // same `uiSize` closure as the label, so the whole header row
            // grows uniformly under UI zoom (was fixed at 9pt / 10pt).
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(
                    size: uiSize(SidebarSectionHeaderMetrics.chevronFontSize),
                    weight: .semibold
                ))
                .frame(width: uiSize(SidebarSectionHeaderMetrics.chevronFrameWidth))
            Text(title.uppercased())
                .font(.system(
                    size: uiSize(SidebarSectionHeaderMetrics.labelFontSize),
                    weight: .semibold
                ))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SidebarHeaderRowModifier: ViewModifier {
    /// UX-F (#228): zoom-scale helper. Defaults to identity so the legacy
    /// parameterless `.sidebarHeaderRow()` renders at the base padding.
    var uiSize: (CGFloat) -> CGFloat = { $0 }
    /// Header tint (owner 2026-08-09): stored on the modifier (not read
    /// inside body) so a theme republish re-evaluates it — the
    /// SidebarSectionContainer diff-skip lesson.
    private let headerBackground = Palette.sectionHeaderBackground
    func body(content: Content) -> some View {
        content
            .padding(
                .horizontal,
                uiSize(SidebarSectionHeaderMetrics.horizontalPadding)
            )
            .padding(
                .vertical,
                uiSize(SidebarSectionHeaderMetrics.verticalPadding)
            )
            .background(headerBackground)
    }
}

extension View {
    /// Apply the standard sidebar-section header row envelope:
    /// matching horizontal + vertical padding. Sections wrap their
    /// header HStack with this so every section's header has the
    /// same outer geometry.
    func sidebarHeaderRow() -> some View {
        modifier(SidebarHeaderRowModifier())
    }

    /// UX-F (#228) zoom-aware variant: the header-row padding scales with
    /// the unified UI zoom so the section header grows uniformly with its
    /// label/chevron. Pass `model.uiSize`.
    func sidebarHeaderRow(uiSize: @escaping (CGFloat) -> CGFloat) -> some View {
        modifier(SidebarHeaderRowModifier(uiSize: uiSize))
    }
}

// MARK: - Empty-state placeholder
//
// One-line text shown inside a section's ScrollView when it has no
// content. Centralised so the look is uniform across sections.
struct SidebarEmptyPlaceholder: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
