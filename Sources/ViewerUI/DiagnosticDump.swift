import AppKit
import CoreGraphics
import PDFKit
import WebKit

/// Runtime introspection of the realized NSView/CALayer/NSTextView tree.
/// Emits a JSON document that captures every property that determines
/// whether content is *visible on screen* — properties AX cannot reach:
/// alpha, isHidden, layer state, text/background colors, glyph
/// generation, ancestor visibility. Plus `recursiveDescription` (private
/// NSView debug method) as a flat human-readable dump for forensic
/// review of any failing test.
///
/// Used by:
///   - `MarkdownViewer --diagnose <file>` for debugging.
///   - L3 introspection tests (see Tests/ViewerUITests/HostingIntrospectionTests).
@MainActor
public enum DiagnosticDump {

    public struct Options {
        /// If true, include recursiveDescription. It's a private API call so
        /// we gate behind a flag — production code paths shouldn't depend on it.
        public var includeRecursiveDescription: Bool
        /// If true, drop fields that may carry user document content
        /// (e.g. `string_head`, the first 120 chars of an NSTextView's
        /// string). Release/SIGUSR1 dumps land in a per-user tmp file;
        /// even at 0600 we don't want a forensic dump to embed a slice
        /// of whatever the user happens to have open. Tests and the
        /// `--diagnose` headless path keep content (default false) since
        /// that output never persists past the process.
        public var redactContent: Bool
        public init(
            includeRecursiveDescription: Bool = true,
            redactContent: Bool = false
        ) {
            self.includeRecursiveDescription = includeRecursiveDescription
            self.redactContent = redactContent
        }
    }

    /// Top-level dump of a window: window-level state + a recursive view
    /// tree. Walk it like a JSON tree from the test side.
    public static func dump(window: NSWindow, options: Options = Options()) -> [String: Any] {
        var out: [String: Any] = [:]
        out["window"] = [
            "title": window.title,
            "isVisible": window.isVisible,
            "isKeyWindow": window.isKeyWindow,
            "isMainWindow": window.isMainWindow,
            "alphaValue": window.alphaValue,
            "frame": rectString(window.frame),
            "contentRect": rectString(
                window.contentRect(forFrameRect: window.frame)
            ),
            "occlusionState_visible":
                window.occlusionState.contains(.visible),
            "backingScaleFactor": window.backingScaleFactor,
            "screen_frame": window.screen.map { rectString($0.frame) } ?? "nil"
        ]
        if let cv = window.contentView {
            out["contentView"] = describeView(cv, depth: 0,
                                              includeRecursive: options.includeRecursiveDescription,
                                              redactContent: options.redactContent)
        } else {
            out["contentView"] = NSNull()
        }
        if options.includeRecursiveDescription, let cv = window.contentView {
            // `recursiveDescription` is a private NSView debug selector.
            // KVC `value(forKey:)` on a key the receiver doesn't implement
            // throws an *uncatchable* ObjC `NSUnknownKeyException` →
            // SIGABRT. Guard with a responds-to-selector probe so a future
            // AppKit that drops the method yields "<unavailable>" instead
            // of crashing the dump (CR-06).
            out["recursiveDescription"] = Self.recursiveDescription(of: cv)
        }
        return out
    }

    /// Safely read the private `recursiveDescription` debug selector.
    /// Returns "<unavailable>" if the receiver doesn't respond to it
    /// (e.g. Apple removes/renames it on a future macOS) rather than
    /// letting an uncatchable `NSUnknownKeyException` abort the process.
    private static func recursiveDescription(of view: NSView) -> String {
        let sel = NSSelectorFromString("recursiveDescription")
        guard view.responds(to: sel) else { return "<unavailable>" }
        // perform(_:) returns an Unmanaged<AnyObject>?; recursiveDescription
        // returns an autoreleased NSString, so we don't take ownership.
        let result = view.perform(sel)?.takeUnretainedValue()
        return (result as? String) ?? "<unavailable>"
    }

    /// Describe a single view + its subtree. Captures every property
    /// relevant to visibility:
    ///   - geometry (frame, bounds, visibleRect)
    ///   - opacity / hidden (view + layer + ancestor inheritance)
    ///   - layer state (frame, contents non-nil, backgroundColor alpha,
    ///     opacity, masksToBounds)
    /// Plus type-specific deep dives (NSTextView, WKWebView, NSScrollView).
    public static func describeView(
        _ view: NSView,
        depth: Int,
        includeRecursive: Bool,
        redactContent: Bool = false,
        // Nearest non-empty `accessibilityIdentifier()` seen on an ancestor
        // during the walk. SwiftUI's `.accessibilityIdentifier(_:)` lands on
        // an outer hosting NSView, NOT on the inner `HostingScrollView` /
        // `DocumentView` that backs a panel's scroll body — so a collapsed
        // (zero-sized) panel host has no id of its own and is unattributable
        // in isolation. Carrying the enclosing id down lets the dump name
        // WHICH panel a zero-sized host belongs to (SFB-05).
        enclosingAXIdentifier: String? = nil
    ) -> [String: Any] {
        var d: [String: Any] = [
            "class": String(describing: type(of: view)),
            "frame": rectString(view.frame),
            "bounds": rectString(view.bounds),
            "visibleRect": rectString(view.visibleRect),
            "alphaValue": view.alphaValue,
            "isHidden": view.isHidden,
            "isHiddenOrHasHiddenAncestor": view.isHiddenOrHasHiddenAncestor,
            "wantsLayer": view.wantsLayer,
            "subviewCount": view.subviews.count,
            "depth": depth
        ]
        let axid = view.accessibilityIdentifier()
        if !axid.isEmpty {
            d["accessibilityIdentifier"] = axid
        }
        // The id to hand down to children: this view's own id if it has one,
        // else whatever ancestor id we inherited. A node without its own id
        // surfaces the inherited one under a distinct key so a zero-sized
        // host can still be tied back to its enclosing panel envelope. The
        // separate key keeps "owns this id" vs "lives under it" unambiguous.
        let childAXIdentifier = axid.isEmpty ? enclosingAXIdentifier : axid
        if axid.isEmpty, let enclosing = enclosingAXIdentifier {
            d["enclosingAccessibilityIdentifier"] = enclosing
        }
        // Zero-size detection — these are the silent killers. A view can
        // be present in the tree, have correct text content, correct
        // colors, but be drawn at 0x0 or 0xN or Nx0. Flag explicitly so
        // tests can grep `"zeroSize"` in the dump.
        let isZeroWidth = view.frame.width <= 0.5
        let isZeroHeight = view.frame.height <= 0.5
        let isCollapsedDim = view.frame.width <= 1 || view.frame.height <= 1
        if isZeroWidth || isZeroHeight || isCollapsedDim {
            d["zeroSize"] = [
                "width0": isZeroWidth,
                "height0": isZeroHeight,
                "collapsedDim": isCollapsedDim
            ]
        }
        if let layer = view.layer {
            var l: [String: Any] = [
                "frame": rectString(NSRectFromCGRect(layer.frame)),
                "opacity": layer.opacity,
                "isHidden": layer.isHidden,
                "masksToBounds": layer.masksToBounds,
                "hasContents": layer.contents != nil
            ]
            if let bg = layer.backgroundColor {
                l["backgroundColor_alpha"] = bg.alpha
                if let comps = bg.components {
                    l["backgroundColor_components"] = comps
                }
            }
            d["layer"] = l
        } else {
            d["layer"] = NSNull()
        }

        if let tv = view as? NSTextView {
            d["nsTextView"] = describeTextView(tv, redactContent: redactContent)
        }
        if let tf = view as? NSTextField {
            // TSK-620: lets a UAT assert a SwiftUI TextField's RENDERED text
            // (e.g. the GoTo prompt's "~" prefill, TSK-314) — the model layer
            // can't prove what the field actually shows. Same redaction
            // posture as the NSTextView head: persisted dumps never embed
            // user content.
            d["nsTextField"] = [
                "stringValue": redactContent
                    ? "<redacted>" : String(tf.stringValue.prefix(120)),
                "placeholder": tf.placeholderString ?? "",
                "isEditable": tf.isEditable,
            ]
        }
        if let sv = view as? NSScrollView {
            d["nsScrollView"] = describeScrollView(sv)
        }
        if let web = view as? WKWebView {
            d["wkWebView"] = describeWebView(web)
        }
        if let term = view as? TerminalNSView {
            // TSK-493: emulator grid vs bounds — a correct frame can still
            // hide a stale 1-row grid; the dump is the cheap arbiter.
            d["terminal"] = term.diagnosticGridInfo()
        }

        if !view.subviews.isEmpty {
            d["subviews"] = view.subviews.map {
                describeView($0, depth: depth + 1, includeRecursive: false,
                             redactContent: redactContent,
                             enclosingAXIdentifier: childAXIdentifier)
            }
        }
        return d
    }

    private static func describeTextView(
        _ tv: NSTextView,
        redactContent: Bool = false
    ) -> [String: Any] {
        var t: [String: Any] = [
            // O(1) UTF-16 length (matches the NSRange-based metrics below);
            // `tv.string.count` would force a full grapheme walk over the
            // entire backing store on every dump (PERF: per-step/SIGUSR1).
            "string_length": (tv.string as NSString).length,
            // `string_head` echoes the first 120 chars of the document.
            // Redact it in persisted (release/SIGUSR1) dumps so a forensic
            // file never embeds a slice of the user's content (OBS-1).
            "string_head": redactContent ? "<redacted>" : String(tv.string.prefix(120)),
            "drawsBackground": tv.drawsBackground,
            // TextKit engine actually live at runtime (TSK-267): non-nil
            // textLayoutManager ⇒ TK2 viewport layout; nil ⇒ TK1 (something
            // — e.g. a `layoutManager` access — forced the downgrade).
            // Reading `textLayoutManager` does NOT itself downgrade.
            "usesTextKit2": tv.textLayoutManager != nil,
            "isEditable": tv.isEditable,
            "isSelectable": tv.isSelectable,
            "isRichText": tv.isRichText,
            "textContainerInset": sizeString(tv.textContainerInset),
            "textColor_description": tv.textColor?.description ?? "nil",
            "backgroundColor_description": tv.backgroundColor.description,
            "textColor_alpha": tv.textColor?.alphaComponent ?? -1,
            "backgroundColor_alpha": tv.backgroundColor.alphaComponent,
            "font_description": tv.font?.description ?? "nil"
        ]
        // The single most important check: text and bg must contrast.
        // Compute RGB components in sRGB and emit a `contrastsWithBackground`
        // boolean. If false → user sees nothing.
        if let fg = tv.textColor?.usingColorSpace(.sRGB),
           let bg = tv.backgroundColor.usingColorSpace(.sRGB) {
            t["textColor_sRGB"] = [fg.redComponent, fg.greenComponent, fg.blueComponent, fg.alphaComponent]
            t["backgroundColor_sRGB"] = [bg.redComponent, bg.greenComponent, bg.blueComponent, bg.alphaComponent]
            let dr = fg.redComponent - bg.redComponent
            let dg = fg.greenComponent - bg.greenComponent
            let db = fg.blueComponent - bg.blueComponent
            let distance = (dr * dr + dg * dg + db * db).squareRoot()
            t["color_distance"] = distance
            // Conservative threshold: anything below 0.3 is effectively
            // invisible on a typical display. Pure white text on pure
            // white bg → 0; system labelColor on textBackgroundColor
            // → ~0.95 (light mode) or ~0.85 (dark mode).
            t["contrastsWithBackground"] = distance > 0.3
        }

        // Layout manager status: are glyphs actually generated?
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let glyphRange = lm.glyphRange(for: tc)
            let bounding = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            t["glyph_range_length"] = glyphRange.length
            t["glyph_boundingRect"] = rectString(bounding)
            t["numberOfGlyphs"] = lm.numberOfGlyphs
        }
        return t
    }

    private static func describeScrollView(_ sv: NSScrollView) -> [String: Any] {
        [
            "drawsBackground": sv.drawsBackground,
            "backgroundColor_description": sv.backgroundColor.description,
            "documentView_class":
                sv.documentView.map { String(describing: type(of: $0)) } ?? "nil",
            "documentView_frame":
                sv.documentView.map { rectString($0.frame) } ?? "nil",
            "contentSize": sizeString(sv.contentSize),
            "hasVerticalRuler": sv.hasVerticalRuler,
            "rulersVisible": sv.rulersVisible
        ]
    }

    private static func describeWebView(_ web: WKWebView) -> [String: Any] {
        [
            "isLoading": web.isLoading,
            "estimatedProgress": web.estimatedProgress,
            "url": web.url?.absoluteString ?? "nil",
            "title": web.title ?? "nil"
        ]
    }

    private static func rectString(_ r: NSRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    private static func sizeString(_ s: NSSize) -> String {
        String(format: "%.1fx%.1f", s.width, s.height)
    }

    /// Capture the app's own window to a PNG. Same-process window capture
    /// does **not** require Screen Recording permission on macOS — the
    /// permission gate is for capturing *other* processes' windows. The
    /// resulting PNG can be opened by any image viewer or piped into
    /// vision-LLM analysis without OCR/manual screenshot tooling.
    ///
    /// Returns true on success, false if the window can't be captured
    /// (e.g. windowNumber=0 because the window isn't yet ordered front).
    @discardableResult
    public static func captureWindowToPNG(_ window: NSWindow, path: String) -> Bool {
        // CGWindowListCreateImage was removed in macOS 15; ScreenCaptureKit
        // is the official replacement but it's async + needs permission
        // for cross-process captures. For our own window, NSView's
        // cacheDisplay path is simpler and permission-free.
        guard let content = window.contentView else { return false }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            return false
        }
        content.cacheDisplay(in: bounds, to: rep)
        // `cacheDisplay` walks the view/CALayer display tree but does NOT
        // composite PDFKit's layer-hosted / Metal-backed page surface, so a
        // mounted-and-laid-out `PDFView` comes out blank in the same-process
        // snapshot (UAT PV-03 — a capture-fidelity limit, not a render bug).
        // Re-draw any visible PDF pages into the same bitmap via PDFKit's own
        // CG drawing API so the artifact faithfully shows the page. This only
        // touches the captured PNG; on-screen rendering is unaffected.
        overlayPDFViews(in: content, into: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    /// Re-draw the visible pages of every mounted `PDFView` directly into
    /// `rep`, on top of the `cacheDisplay` snapshot of `root`. `cacheDisplay`
    /// captures ordinary `drawRect:`/CALayer content but misses PDFKit's
    /// layer-hosted page surface, leaving the page area blank. PDFKit exposes
    /// no public "render to bitmap" entry point for `PDFView` itself, so we
    /// drop to `PDFPage.draw(with:to:)` per visible page — the same primitive
    /// `PDFView` uses internally — mapped into the captured coordinate space.
    private static func overlayPDFViews(
        in root: NSView, into rep: NSBitmapImageRep
    ) {
        let pdfViews = collectPDFViews(in: root)
        guard !pdfViews.isEmpty,
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        // `NSGraphicsContext(bitmapImageRep:)` is bottom-left origin; `cacheDisplay`
        // already rendered the snapshot into it matching the view's visual layout.
        // Our `target` rects come from `NSView.convert(_:to: root)`, i.e. they are
        // in `root`'s coordinate space. When `root` is flipped (top-left origin —
        // the SwiftUI hosting case), translate+flip the CG context so those rects
        // land at the same place the snapshot did.
        if root.isFlipped {
            cg.translateBy(x: 0, y: root.bounds.height)
            cg.scaleBy(x: 1, y: -1)
        }
        for pdf in pdfViews {
            guard let document = pdf.document, document.pageCount > 0 else { continue }
            // Visible pages only — singlePageContinuous can mount many.
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                // The page's bounds in PDFView coordinates, then up into the
                // captured `root` space (rep is in `root.bounds` units).
                let pageRectInView = pdf.convert(
                    page.bounds(for: pdf.displayBox), from: page)
                let target = pdf.convert(pageRectInView, to: root)
                // Skip pages scrolled fully out of the captured rect.
                guard target.intersects(root.bounds),
                      target.width > 1, target.height > 1 else { continue }
                cg.saveGState()
                // Map the page's own (PDF) coordinate box onto `target`.
                let box = page.bounds(for: pdf.displayBox)
                cg.translateBy(x: target.minX, y: target.minY)
                if box.width > 0, box.height > 0 {
                    cg.scaleBy(x: target.width / box.width,
                               y: target.height / box.height)
                }
                cg.translateBy(x: -box.minX, y: -box.minY)
                // White page backing so transparent PDFs aren't see-through
                // onto whatever cacheDisplay left underneath.
                cg.setFillColor(NSColor.white.cgColor)
                cg.fill(box)
                page.draw(with: pdf.displayBox, to: cg)
                cg.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Depth-first collect every `PDFView` in the subtree rooted at `view`.
    private static func collectPDFViews(in view: NSView) -> [PDFView] {
        var out: [PDFView] = []
        if let pdf = view as? PDFView { out.append(pdf) }
        for sub in view.subviews { out.append(contentsOf: collectPDFViews(in: sub)) }
        return out
    }
}
