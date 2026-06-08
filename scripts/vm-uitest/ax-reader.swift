// ax-reader.swift — out-of-process Accessibility reader for the VM UI lane.
//
// WHY: SwiftUI's accessibility tree is NOT populated in-process for an
// NSHostingView (proven empty by TerminalAccessibilityTests), so AX must be
// read from a SEPARATE process against the RUNNING app via AXUIElement — the
// same path screen readers / XCUITest use. This is the semantic+interaction
// complement to the pixel lane: it asserts elements EXIST with the right
// `accessibilityIdentifier` (and can be extended to AXPress them), without any
// image processing.
//
// Run inside the Aqua session (the LaunchAgent) — like screencapture, AX of
// another app needs a GUI session AND the **Accessibility** TCC grant for the
// reader's binary (System Settings → Privacy & Security → Accessibility).
//
// Usage:  ax-reader <bundleID> [requiredIdentifier]
//   Prints every non-empty accessibilityIdentifier found, one per line.
//   Exit 0 if (no required) or (required found); 3 = app not running;
//   4 = AX read blocked (Accessibility not granted → empty tree); 5 = required
//   identifier absent.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
let bundleID = args.count > 1 ? args[1] : "com.markdownviewer.MarkdownViewer"
let required: String? = args.count > 2 ? args[2] : nil

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == bundleID }) else {
    err("ax-reader: app not running (\(bundleID))"); exit(3)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

var found = Set<String>()
func walk(_ el: AXUIElement, _ depth: Int) {
    if depth > 60 { return }
    if let id = copyAttr(el, kAXIdentifierAttribute as String) as? String, !id.isEmpty {
        found.insert(id)
    }
    if let kids = copyAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
        for k in kids { walk(k, depth + 1) }
    }
}
walk(axApp, 0)

// An empty tree with windows present is the signature of a denied Accessibility
// grant (the app has AXWindows but we can read nothing through them).
let windows = copyAttr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]
if found.isEmpty && (windows?.isEmpty ?? true) {
    err("ax-reader: AX tree empty — Accessibility not granted for this binary?")
    exit(4)
}

for id in found.sorted() { print(id) }

if let required = required {
    if found.contains(required) { exit(0) }
    err("ax-reader: required identifier not found: \(required)"); exit(5)
}
exit(0)
