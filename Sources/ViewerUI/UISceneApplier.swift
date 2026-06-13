import Foundation
import ViewerCore

/// TSK-492 (Layer 1) — the deterministic UI-scene → model-state mapping.
///
/// `MDV_UI_SCENE` drives the live model into an EXACT state at launch so the
/// visual-eval harness (`scripts/vm-uitest.sh` / `ui-snapshot.sh`) captures a
/// reproducible state without fighting persisted defaults/AX. The scene→model
/// logic lived inline in the `MarkdownViewer` EXECUTABLE target
/// (`Diagnostics.applyUISceneIfRequested`), which the test targets don't link —
/// so the scene catalog the harness depends on had NO regression guard. This
/// extracts the pure mapping into `ViewerUI` (host-testable) with the env/
/// dispatch/stderr shell staying in `Diagnostics`. Behaviour-identical to the
/// pre-extraction inline code; the returned string is what `Diagnostics` writes
/// to stderr (`ui-scene: …`).
///
/// Inputs are passed in (not read from the environment here) so a host test can
/// drive it: `previewFile` is `MDV_PREVIEW_FILE`; `tabsBaseDir` is where the
/// `tabs-<N>` scene writes its throwaway markdown (the per-pid tmp dir in the
/// app; a test tmp dir under test).
@MainActor
public enum UISceneApplier {

    /// Apply `scene` (already lowercased) to `model`. Returns the status line
    /// describing what was applied (or the error/unknown message).
    @discardableResult
    public static func apply(
        scene: String,
        to model: DocumentModel,
        previewFile: URL?,
        tabsBaseDir: URL
    ) -> String {
        let parts = scene.split(separator: "-").map(String.init)

        // Preview-tab scenes (TSK-306 / TSK-272): drive the ONE ephemeral preview
        // slot. `preview-promoted` then promotes it to a permanent (upright) tab.
        if parts.first == "preview" {
            guard let url = previewFile else {
                return "ui-scene: 'preview' needs MDV_PREVIEW_FILE"
            }
            model.openPreview(url: url)
            if parts.contains("promoted") {
                model.open(url: url)   // the Enter / double-click commit path
            }
            return "ui-scene: applied '\(scene)' tabs=\(model.tabs.tabs.count) preview=\(model.tabs.previewTabID != nil)"
        }

        // FILE tab-strip scenes (TSK-261/268/331): `tabs-<N>` opens N throwaway
        // markdown files as PERMANENT tabs so the top TabBar is on screen with a
        // deterministic population. Files live under `tabsBaseDir` (never
        // ~/Documents — see CLAUDE.md).
        if parts.first == "tabs" {
            let count = max(1, parts.compactMap { Int($0) }.first ?? 3)
            try? FileManager.default.createDirectory(
                at: tabsBaseDir, withIntermediateDirectories: true)
            for i in 1...count {
                let f = tabsBaseDir.appendingPathComponent(String(format: "tab-%02d.md", i))
                try? "# tab \(i)\n".write(to: f, atomically: true, encoding: .utf8)
                model.open(url: f)
            }
            // Select the FIRST tab: the strip starts unscrolled, and the last
            // tab carries no selection tint (which would mask a missing trailing
            // divider in the pixel tests).
            model.selectTab(at: 0)
            return "ui-scene: applied '\(scene)' tabs=\(model.tabs.tabs.count)"
        }

        guard parts.first == "terminal" else {
            return "ui-scene: unknown scene '\(scene)'"
        }
        let pane = model.terminalPane
        pane.setOpen(true)                      // open FIRST so height applies to the live pane
        if parts.contains("top") { pane.setTabPosition(.top) }
        else if parts.contains("right") { pane.setTabPosition(.right) }
        else { pane.setTabPosition(.left) }
        // Pane DOCK edge (TSK-491) — distinct tokens from the tab-strip position.
        // ALWAYS set it (default .bottom) so a scene is DETERMINISTIC and doesn't
        // inherit a persisted edge from a prior launch.
        if parts.contains("paneright") { pane.setPaneEdge(.right) }
        else if parts.contains("paneleft") { pane.setPaneEdge(.left) }
        else { pane.setPaneEdge(.bottom) }
        pane.setHeight(320)
        pane.setWidth(360)
        let count = max(1, parts.compactMap { Int($0) }.first ?? 2)
        while pane.tabs.count < count { pane.addTab() }
        return "ui-scene: applied '\(scene)' tabs=\(pane.tabs.count) height=\(pane.height) edge=\(pane.paneEdge.rawValue) width=\(pane.sideWidth)"
    }
}
