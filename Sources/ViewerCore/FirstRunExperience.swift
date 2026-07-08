import Foundation

/// TSK-1448 — the first-run experience's host core: a new user opens the app
/// to NOTHING today. This supplies (1) the one-shot decision (offer the
/// sample document exactly once, dismissable forever), and (2) the sample
/// document itself — a markdown tour that exercises the viewer's own lenses
/// (outline, table, code highlight, mermaid, task list) so the first thing a
/// user sees demonstrates the app. The Help-menu entries and the open-on-
/// launch wiring are the render tail.
public enum FirstRunExperience {

    static let shownKey = "MarkdownViewer.firstRunSampleShown"

    /// Whether to offer the sample on this launch — true exactly until
    /// `markShown` (the user saw it or dismissed it; either way, never again).
    public static func shouldOffer(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: shownKey)
    }

    /// One-shot latch: the sample was shown (or dismissed) — never offer again.
    public static func markShown(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: shownKey)
    }

    /// The sample tour document. Each section exercises a real capability so
    /// the outline panel, table lens, highlighter, and mermaid renderer all
    /// demonstrate themselves on the user's first open.
    public static let sampleDocument = """
    # Welcome to TextView

    This sample shows a few things the app can do. Close it any time — it \
    won't open again (find it later via **Help ▸ Open Sample Document**).

    ## Outline

    The headings in this file power the **outline panel** — open it to jump \
    between sections, filter headings, and watch the highlight follow your \
    scroll.

    ## Tables

    | Lens      | What it does                     |
    | --------- | -------------------------------- |
    | Rendered  | This view — formatted markdown   |
    | Source    | The raw text with highlighting   |
    | Hex       | Raw bytes for any file           |

    ## Code

    ```swift
    // Syntax highlighting runs on a Rust core.
    func greet(_ name: String) -> String {
        "Hello, \\(name)!"
    }
    ```

    ## Diagrams

    ```mermaid
    graph LR
        Open[Open a file] --> Lens{Pick a lens}
        Lens --> Rendered
        Lens --> Source
        Lens --> Hex
    ```

    ## Try next

    - [ ] Press **⌘K** — the command palette reaches everything
    - [ ] Open a CSV to see the table grid
    - [ ] **Help ▸ Capabilities** lists the full tour
    """

    /// Write the sample into `dir` (collision-safe via `OutputNaming` — a
    /// re-run or an existing user file named the same is never overwritten).
    /// Returns the written URL.
    public static func writeSample(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let desired = dir.appendingPathComponent("Welcome to TextView.md")
        let target = OutputNaming.nonColliding(desired: desired) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try sampleDocument.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
