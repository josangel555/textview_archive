import ApplicationServices
import CoreGraphics
import Foundation
import ViewerCore

/// TSK-1254 slice 2 — the real macOS `AXUIElement` adapter conforming to
/// `AXDriverCore.AXNode` (ViewerCore). The OUT-OF-PROCESS driver attaches to the
/// running app via `AXUIElementCreateApplication(pid)` and walks the live AX tree
/// through this; the host-tested `AXDriverCore.find` / `resolvePress` then operate
/// on it without knowing it's a real element.
///
/// The attribute reads + `AXUIElementPerformAction` need a RUNNING app + the
/// Accessibility TCC grant, so the live traversal is VM/owner-validated (review
/// ceiling — same gate class as the T5 pixel lane). The pure `AXValue → CGRect`
/// frame assembly IS host-tested (`AXUIElementNodeTests`).
public struct AXUIElementNode: AXNode {

    public let element: AXUIElement

    public init(_ element: AXUIElement) { self.element = element }

    /// The accessibility root for a running application by pid.
    public static func application(pid: pid_t) -> AXUIElementNode {
        AXUIElementNode(AXUIElementCreateApplication(pid))
    }

    public var axIdentifier: String? { Self.stringAttribute(element, kAXIdentifierAttribute) }

    public var axRole: String? { Self.stringAttribute(element, kAXRoleAttribute) }

    public var axFrame: CGRect? {
        guard let pos = Self.axValueAttribute(element, kAXPositionAttribute),
              let size = Self.axValueAttribute(element, kAXSizeAttribute) else { return nil }
        return Self.cgRect(positionValue: pos, sizeValue: size)
    }

    public var axActions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let arr = names as? [String] else { return [] }
        return arr
    }

    public var axChildren: [AXNode] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.map(AXUIElementNode.init)
    }

    /// Perform a native AX action (e.g. `kAXPressAction`). Returns success.
    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    // MARK: - Attribute helpers (live; VM/TCC-validated)

    private static func stringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axValueAttribute(_ el: AXUIElement, _ attr: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    // MARK: - Frame assembly (PURE; host-tested)

    /// Assemble a `CGRect` from the AX position (`.cgPoint`) + size (`.cgSize`)
    /// `AXValue`s. Returns nil if either box isn't the expected geometry type.
    public static func cgRect(positionValue: AXValue, sizeValue: AXValue) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
