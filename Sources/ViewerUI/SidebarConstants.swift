import SwiftUI

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
    func body(content: Content) -> some View {
        content
            // Subtle tint distinct from the sidebar's `Palette.textBackground`,
            // light enough to remain unobtrusive in both dark and light
            // appearances. `controlBackgroundColor` is dynamic so it
            // re-resolves on appearance changes.
            .background(Palette.controlBackground.opacity(0.4))
            // Outer breathing room between adjacent sections. The
            // `ResizableSectionDivider` lives in this gap.
            .padding(.vertical, 2)
    }
}

extension View {
    /// Apply the standard sidebar-section chrome: subtle background
    /// tint + outer vertical padding so sections read as cards and the
    /// resize handle between them has visible breathing room.
    func sidebarSectionContainer() -> some View {
        modifier(SidebarSectionContainer())
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
