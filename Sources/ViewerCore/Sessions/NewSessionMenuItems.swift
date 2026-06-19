import Foundation

/// The ordered set of entries for the **New ▸ Session ▸ Kind** menu and
/// the matching command-palette rows (TSK-373).
///
/// This is the single, pure, host-testable source of truth so the AppKit
/// `NSMenu`, any SwiftUI `Menu`, and the command palette can NOT drift on
/// which kinds are offered, in what order, with what label / icon / verb.
/// The view layers iterate `NewSessionMenuItems.all` and bind each entry's
/// `kind` straight into the existing `SessionsCoordinator.openFolder(kind:)`
/// path (the backend is already wired + seed-once tested — this just
/// surfaces the *picker* that was missing).
public enum NewSessionMenuItems {

    /// One row in the New Session ▸ Kind menu / palette.
    public struct Item: Equatable, Sendable, Identifiable {
        /// The session kind this row creates.
        public let kind: SessionKind
        /// Menu / palette title (e.g. "Code Review").
        public let title: String
        /// One-line subtitle describing the seeded layout.
        public let subtitle: String
        /// SF Symbol name for the row's icon.
        public let symbolName: String
        /// Command-palette search text — the title prefixed with the
        /// surface name so "new session" / "new code review" both match.
        public let paletteSearchText: String

        public var id: String { kind.rawValue }

        public init(kind: SessionKind) {
            self.kind = kind
            self.title = kind.displayName
            self.subtitle = kind.menuSubtitle
            self.symbolName = kind.symbolName
            self.paletteSearchText = "New \(kind.displayName) Session"
        }
    }

    /// All kinds offered in the New Session menu, in display order.
    ///
    /// Order is deliberate (Project first as the neutral default, then the
    /// task-shaped kinds the owner asked for — Code Review, Agent Session —
    /// then the dashboard-ish ones). `SessionKind.allCases` order is the
    /// source; we keep this explicit so a future-added enum case doesn't
    /// silently jump into the menu in an arbitrary position.
    public static let order: [SessionKind] = [
        .project, .codeReview, .agent, .cicd, .metrics,
    ]

    /// The menu rows, in order.
    public static let all: [Item] = order.map(Item.init)

    /// Look up the item for a given kind (nil if not surfaced in the menu).
    public static func item(for kind: SessionKind) -> Item? {
        all.first { $0.kind == kind }
    }
}
