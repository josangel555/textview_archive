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
