import SwiftUI

/// Layout constants shared across sidebar sections — Bookmarks,
/// Search, Git panel body, Claude timeline, FILES.
///
/// Lives in one place so all section bodies render at the same fixed
/// height. Previously each section used its own ad-hoc `maxHeight`
/// (220 / 240 / 280 / 320) and bodies shrank to fit smaller data —
/// leading to constant layout shifts as data refreshed. Now: every
/// section body is exactly `sectionBodyHeight` tall; content scrolls
/// inside if it overflows.
public enum SidebarConstants {
    /// Height of every section body (Bookmarks / Search results /
    /// Git panel content / Claude timeline). Fixed — not adaptive.
    /// Tuned so a ~250 px sidebar can show ~10 rows per section
    /// without feeling cramped.
    public static let sectionBodyHeight: CGFloat = 220
}
