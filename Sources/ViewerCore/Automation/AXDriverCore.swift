import Foundation
import CoreGraphics

// TSK-1254 — the host-testable BRAIN of the out-of-process native-chrome UAT /
// agent-drive driver.
//
// The in-process accessibility tree is EMPTY (SwiftUI materializes AX elements
// only for EXTERNAL AX clients — see ClickTargetRegistry's note), so the real
// driver runs OUT-OF-PROCESS: it attaches to the running app via
// AXUIElementCreateApplication(pid) and walks the live AX tree. That AXUIElement
// adapter — turning real AXUIElementRefs into `AXNode`s and performing
// AXUIElementPerformAction / posting CGEvents — is the VM-tail slice (it needs a
// running app + AX TCC). THIS file is the pure logic that sits on top: find a
// control by its `mdv.*` accessibilityIdentifier and resolve HOW to act on it.
// It is fully host-tested against a fake tree (AXDriverCoreTests).

/// An abstract accessibility node — the seam over a real macOS `AXUIElement`.
/// The VM-tail adapter conforms a wrapper of `AXUIElement` to this; host tests
/// feed a fake tree.
public protocol AXNode {
    /// The control's `accessibilityIdentifier` (the `AXIdentifier` attribute),
    /// e.g. `"mdv.hexView"`. `nil` for elements that publish no identifier.
    var axIdentifier: String? { get }
    /// `AXRole`, e.g. `"AXButton"`, `"AXTextField"`, `"AXStaticText"`.
    var axRole: String? { get }
    /// On-screen frame in screen coordinates — drives the CGEvent fallback.
    var axFrame: CGRect? { get }
    /// Action names the element advertises (`AXUIElementCopyActionNames`),
    /// e.g. `["AXPress"]`.
    var axActions: [String] { get }
    /// Child nodes, in tree (declaration) order.
    var axChildren: [AXNode] { get }
}

/// A query against the AX tree. A plain string is an EXACT identifier match; a
/// trailing `*` (or `.*`) makes it a PREFIX match, for the dynamic ids the app
/// mints per-row (e.g. `mdv.archive.entry.<name>` ← `"mdv.archive.entry.*"`).
public struct AXQuery: Equatable, Sendable {
    public enum Match: Equatable, Sendable { case exact, prefix }
    public let stem: String
    public let match: Match

    public init(_ identifier: String) {
        if identifier.hasSuffix(".*") {
            stem = String(identifier.dropLast(1))   // keep the trailing "."
            match = .prefix
        } else if identifier.hasSuffix("*") {
            stem = String(identifier.dropLast(1))
            match = .prefix
        } else {
            stem = identifier
            match = .exact
        }
    }

    public func matches(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        switch match {
        case .exact:  return identifier == stem
        case .prefix: return identifier.hasPrefix(stem)
        }
    }
}

/// The resolved mechanism for activating a matched node.
public enum AXResolvedAction: Equatable {
    /// A native AX action (preferred — routes through the real control
    /// regardless of occlusion/scroll, no coordinates needed).
    case axAction(String)
    /// CGEvent fallback: synthesize a click at this screen point (the frame
    /// center) when the node advertises no actionable AX action.
    case clickAtFrame(CGPoint)
    /// Neither a usable AX action nor a usable frame — the driver cannot act.
    case unavailable(String)
}

public enum AXDriverCore {

    /// First node matching `query`, depth-first pre-order (deterministic:
    /// declaration order). Pre-order so an addressable container is found
    /// before its descendants.
    public static func find(_ query: AXQuery, in root: AXNode) -> AXNode? {
        if query.matches(root.axIdentifier) { return root }
        for child in root.axChildren {
            if let hit = find(query, in: child) { return hit }
        }
        return nil
    }

    /// Convenience: parse `identifier` into an `AXQuery` and find.
    public static func find(_ identifier: String, in root: AXNode) -> AXNode? {
        find(AXQuery(identifier), in: root)
    }

    /// All nodes matching `query`, depth-first pre-order.
    public static func findAll(_ query: AXQuery, in root: AXNode) -> [AXNode] {
        var out: [AXNode] = []
        func walk(_ node: AXNode) {
            if query.matches(node.axIdentifier) { out.append(node) }
            node.axChildren.forEach(walk)
        }
        walk(root)
        return out
    }

    /// AX "press"-family actions, in resolution priority. Native-first because
    /// these route through the real control regardless of occlusion or scroll
    /// offset; a coordinate click can hit an occluding sibling.
    public static let pressActionPriority = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]

    /// Resolve how to activate `node`: prefer a native press-family AX action,
    /// else a CGEvent click at the frame center, else `.unavailable`.
    public static func resolvePress(_ node: AXNode) -> AXResolvedAction {
        for action in pressActionPriority where node.axActions.contains(action) {
            return .axAction(action)
        }
        if let frame = node.axFrame, frame.width > 0, frame.height > 0 {
            return .clickAtFrame(CGPoint(x: frame.midX, y: frame.midY))
        }
        return .unavailable("node '\(node.axIdentifier ?? "?")' has no press AX action and no usable frame")
    }

    // MARK: - Plan resolution (the executor's host-testable entry)

    /// A fully-resolved drive operation — everything the out-of-process executor
    /// needs to ACT, decoupled from the live `AXUIElement` so the resolution is
    /// host-testable (assert the op, not node identity). The executor maps each
    /// case to an `AXUIElementPerformAction` / CGEvent / attribute read+write.
    public enum ResolvedDriveOp: Equatable {
        /// Activate the matched node (native AX action or CGEvent-at-frame).
        case press(AXResolvedAction)
        /// Scroll the matched node; `frame` lets the executor target a wheel event.
        case scroll(AXScrollDirection, frame: CGRect?)
        /// Read the matched node's value/label (role + frame for the executor).
        case read(role: String?, frame: CGRect?)
        /// Set the matched node's value.
        case setValue(String)
        /// No element matched the plan's query.
        case targetNotFound(AXQuery)
    }

    /// Resolve a parsed `AXDrivePlan` against the AX tree `root` into a
    /// `ResolvedDriveOp`. Pure: find the target, then map the plan's action to
    /// the concrete operation. The executor performs the op on the live element.
    public static func resolve(_ plan: AXDrivePlan, in root: AXNode) -> ResolvedDriveOp {
        guard let node = find(plan.query, in: root) else {
            return .targetNotFound(plan.query)
        }
        switch plan.action {
        case .press:            return .press(resolvePress(node))
        case .scroll(let dir):  return .scroll(dir, frame: node.axFrame)
        case .read:             return .read(role: node.axRole, frame: node.axFrame)
        case .setValue(let v):  return .setValue(v)
        }
    }
}
