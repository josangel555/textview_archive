import SwiftUI

/// PreferenceKey-based registration of anchor surfaces for the
/// walkthrough overlay.
///
/// Each surface that can be a popover anchor target (sidebar root, git
/// panel root, etc.) calls `.walkthroughAnchor(.sidebar)` on its view.
/// That installs a `GeometryReader` in the background that publishes
/// the surface's frame (in the overlay's coordinate space, named
/// `.walkthroughOverlay`) up the view tree via the preference key.
///
/// The window-root overlay registers a matching coordinate space and
/// consumes the merged preferences via `onPreferenceChange`, giving it
/// real rectangles to anchor popovers against instead of approximate
/// `Alignment`-based offsets.
///
/// Notes on coordinate spaces:
///   - SwiftUI's `.global` is the window-content coordinate space,
///     which is fine for our use-case (popovers live in the same
///     window). We use a named coordinate space `.walkthroughOverlay`
///     anyway, attached to the overlay's `ZStack` root, so the math
///     stays correct even if the overlay later moves under a window
///     translation.
public enum WalkthroughAnchorSurface: String, Hashable, Sendable {
    case sidebar
    case gitTab
    case editor

    /// Stable identifier used as the dict key in `WalkthroughAnchorKey`.
    /// Two registrations with the same surface (e.g. two sidebars in
    /// split mode) merge; the reducer keeps the last writer.
    var id: String { rawValue }
}

/// Preference carrying the most recent frames published by each
/// anchor surface, keyed by surface id. `reduce` keeps the latest
/// writer's value (per-surface) so re-registering on layout change
/// updates the rect rather than appending stale entries.
public struct WalkthroughAnchorKey: PreferenceKey {
    public static let defaultValue: [String: CGRect] = [:]

    public static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        for (k, v) in nextValue() {
            value[k] = v
        }
    }
}

/// Named coordinate space attached to the overlay root. Anchor
/// surfaces convert their frames into this space before publishing.
public extension CoordinateSpace {
    static var walkthroughOverlay: CoordinateSpace { .named("walkthroughOverlay") }
}

public extension View {
    /// Register this view's frame as the anchor rect for a walkthrough
    /// popover target. The overlay reads the merged preferences and
    /// positions any `.sidebar` / `.gitTab` popover against the exact
    /// rect rather than a SwiftUI `Alignment`.
    func walkthroughAnchor(_ surface: WalkthroughAnchorSurface) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: WalkthroughAnchorKey.self,
                        value: [surface.id: proxy.frame(in: .walkthroughOverlay)]
                    )
            }
        )
    }
}
