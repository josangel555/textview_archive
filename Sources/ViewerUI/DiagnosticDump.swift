import AppKit
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
        public init(includeRecursiveDescription: Bool = true) {
            self.includeRecursiveDescription = includeRecursiveDescription
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
                                              includeRecursive: options.includeRecursiveDescription)
        } else {
            out["contentView"] = NSNull()
        }
        if options.includeRecursiveDescription, let cv = window.contentView {
            out["recursiveDescription"] = (cv.value(forKey: "recursiveDescription") as? String) ?? "<unavailable>"
        }
        return out
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
        includeRecursive: Bool
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
            d["nsTextView"] = describeTextView(tv)
        }
        if let sv = view as? NSScrollView {
            d["nsScrollView"] = describeScrollView(sv)
        }
        if let web = view as? WKWebView {
            d["wkWebView"] = describeWebView(web)
        }

        if !view.subviews.isEmpty {
            d["subviews"] = view.subviews.map {
                describeView($0, depth: depth + 1, includeRecursive: false)
            }
        }
        return d
    }

    private static func describeTextView(_ tv: NSTextView) -> [String: Any] {
        var t: [String: Any] = [
            "string_length": tv.string.count,
            "string_head": String(tv.string.prefix(120)),
            "drawsBackground": tv.drawsBackground,
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
}
