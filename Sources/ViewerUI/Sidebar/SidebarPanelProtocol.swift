import SwiftUI
import ViewerCore

/// Marker protocol for "this SwiftUI view IS a sidebar panel."
///
/// The accordion `SidebarView` still composes panels by hand for now
/// (heights, dividers, etc.) — but every panel view declares its
/// `kind` here, which is the seam the future activity-bar UI will use
/// to enumerate panels + look up display metadata.
///
/// Display name + SF Symbol icon are sourced from the kind so a single
/// rename in `SidebarPanelKind` flows through to every conformer.
@MainActor
public protocol SidebarPanelProtocol: View {
    static var kind: SidebarPanelKind { get }
}

public extension SidebarPanelProtocol {
    static var displayName: String { kind.displayName }
    static var systemImage: String { kind.systemImage }
}
