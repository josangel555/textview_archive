import Foundation
import ViewerCore

/// Debounced, off-main markdown rendering for the split pane (audit THEME 6,
/// fixed 2026-07-29).
///
/// The split pane used to call `HTMLRenderer().renderPage(...)` INSIDE its
/// SwiftUI `body`, synchronously, with no size cap. The pane mirrors the
/// editor's live buffer, so every keystroke re-bodied the pane and re-rendered
/// the FULL document on the main thread — multi-second freezes per keystroke
/// on MB-sized markdown.
///
/// This model moves the render off-main and debounces it. Policy (mirrors the
/// owner's find-scan directive, 2026-07-29): under 1 MiB the debounce is short
/// (typing feels live); above it the render waits for a typing pause instead
/// of chasing every keystroke. Nothing is refused — a huge file still renders,
/// it just stops billing the main thread for it.
@MainActor
public final class SplitMarkdownRenderModel: ObservableObject {

    /// The rendered page, published when a render completes. Nil until the
    /// first render lands (the view shows a spinner).
    @Published public private(set) var html: String?

    private var pending: Task<Void, Never>?
    private var lastRenderedText: String?

    /// Files at/under this render on the short debounce; larger ones wait for
    /// a typing pause. Same 1 MiB line the find scan uses.
    public static let largeThresholdBytes = 1 * 1024 * 1024

    public init() {}

    /// Debounce policy — pure, host-tested.
    /// - first render: immediate (opening the split shows content promptly);
    /// - small file:   150 ms (live-feeling while typing);
    /// - large file:   1 s (renders on the pause, not per keystroke).
    public static func debounceMilliseconds(byteCount: Int, isFirstRender: Bool) -> Int {
        if isFirstRender { return 0 }
        return byteCount > largeThresholdBytes ? 1_000 : 150
    }

    /// Schedule a render of `text`. Coalesces: a newer call cancels the
    /// in-flight one; identical text is a no-op (a re-body with an unchanged
    /// buffer must not re-render).
    public func schedule(text: String, isMermaid: Bool) {
        guard text != lastRenderedText else { return }
        pending?.cancel()
        let ms = Self.debounceMilliseconds(
            byteCount: text.utf8.count, isFirstRender: html == nil)
        pending = Task { [weak self] in
            if ms > 0 {
                try? await Task.sleep(for: .milliseconds(ms))
                guard !Task.isCancelled else { return }
            }
            // `.mmd` standalone files get wrapped into a single mermaid fence
            // so the same renderer path handles them (moved verbatim from the
            // old inline-body render).
            let body = isMermaid ? "```mermaid\n\(text)\n```\n" : text
            let stylesheet = MarkdownStylesheet.cached
            let shim = MermaidBundle.shimCSS
            let rendered = await Task.detached(priority: .userInitiated) {
                HTMLRenderer().renderPage(
                    body, stylesheet: stylesheet, extraStylesheet: shim)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.lastRenderedText = text
            self.html = rendered
        }
    }
}
