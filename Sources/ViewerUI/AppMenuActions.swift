import Foundation

/// Compile-checked names for the app-level menu / toolbar actions that SwiftUI
/// controls in `ViewerUI` dispatch down the responder chain via
/// `NSApp.sendAction(_:to:from:)`.
///
/// The action methods live on the `AppDelegate` (in the top-level
/// `MarkdownViewer` module), which `ViewerUI` cannot import — so these call
/// sites historically used `NSSelectorFromString("openDocument:")`, a
/// stringly-typed selector that silently fails if the target method is renamed
/// (TSK-476: loose-ends-audit).
///
/// Referencing the actions through `#selector(AppMenuActions.openDocument(_:))`
/// instead gives compile-time verification that the selector names a *declared*
/// method. The `AppDelegate` conforms to this protocol, so renaming any action
/// method breaks the build at the conformance too — closing the silent-failure
/// gap end to end. The generated Objective-C selector is byte-identical to the
/// old string (pinned by `AppMenuActionsTests`), so responder-chain dispatch is
/// unchanged.
@MainActor @objc public protocol AppMenuActions {
    /// Show the Open-file panel (menu `File ▸ Open…`, toolbar). Selector
    /// `openDocument:`.
    func openDocument(_ sender: Any?)
    /// Show the Open-folder panel (menu `File ▸ Open Folder…`, toolbar).
    /// Selector `openFolder:`.
    func openFolder(_ sender: Any?)
    /// Open the Settings window (menu `App ▸ Settings…`, session-bar gear).
    /// Selector `showSettings:`.
    func showSettings(_ sender: Any?)
}
