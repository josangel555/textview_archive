import AppKit
import Foundation
import ViewerCore

// MARK: - TSK-1597 — Compare Selection with Clipboard
//
// Owner ask (2026-07-24): select text → right-click → "Compare with
// Clipboard" → the diff view opens showing selection vs clipboard.
//
// Pipeline: `UnifiedDiffGenerator` (the pure Swift two-string differ that
// already emits the exact dialect `RustDiffAdapter.parse` handles — no git
// subprocess, no repo required) → a scratch `.diff` file → the EPHEMERAL
// preview slot (TSK-1594: throwaway comparisons don't leave tabs behind) →
// the `.diff` lens renders it in the web diff view with the Line|Word|Char
// granularity picker.
extension DocumentModel {

    /// Deterministic scratch path so re-comparing reuses ONE tab (the
    /// preview-slot dedup keys off the URL).
    static let clipboardCompareFileName = "clipboard-compare.diff"

    /// Pure half (host-tested): unified-diff text for selection → clipboard.
    /// Empty result = the two texts are identical.
    nonisolated static func clipboardCompareDiffText(
        selection: String, clipboard: String
    ) -> String {
        UnifiedDiffGenerator.generate(
            old: selection, new: clipboard, path: "selection → clipboard")
    }

    /// Diff the selection against the clipboard and open the result in the
    /// ephemeral diff preview. Identical contents post an info toast instead
    /// of opening an empty diff. `pasteboard` and `scratchDirectory` are
    /// injectable for tests (the shared cache dir + deterministic filename
    /// would otherwise race across `--parallel` test processes).
    public func compareSelectionWithClipboard(
        selection: String, pasteboard: NSPasteboard = .general,
        scratchDirectory: URL? = nil
    ) {
        guard !selection.isEmpty else { return }
        guard let clipboard = pasteboard.string(forType: .string) else {
            ToastCenter.shared.post(.info, "Clipboard has no text to compare")
            return
        }
        let diffText = Self.clipboardCompareDiffText(
            selection: selection, clipboard: clipboard)
        guard !diffText.isEmpty else {
            ToastCenter.shared.post(.info, "Selection matches the clipboard")
            return
        }
        let dir = scratchDirectory ?? ScratchStore.cacheSubdir("diffs")
        ScratchStore.prune(directory: dir)
        let out = dir.appendingPathComponent(Self.clipboardCompareFileName)
        do {
            try diffText.write(to: out, atomically: true, encoding: .utf8)
        } catch {
            ToastCenter.shared.post(.info, "Couldn't write the comparison diff")
            return
        }
        openPreview(url: out)
    }
}
