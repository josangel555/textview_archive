import AppKit

/// TSK-259 — the user-selectable monospace font for the text surfaces.
///
/// Resolution is FAIL-SAFE: a nil/unknown/deleted family degrades to the
/// system monospaced font, never a crash and never a proportional
/// fallback (the source view's gutter math assumes fixed pitch).
public enum FontPreference {

    /// Resolve the preferred font at `size`. nil or an unresolvable name
    /// → `monospacedSystemFont` (SF Mono).
    public static func resolvedFont(
        name: String?, size: CGFloat, weight: NSFont.Weight = .regular
    ) -> NSFont {
        if let name, !name.isEmpty, let f = NSFont(name: name, size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// TSK-732: the CSS `font-family` token for `name` — the family AppKit
    /// ACTUALLY resolves it to (via `NSFont.familyName`), so the CM6 editor
    /// names the SAME family the AppKit views render through `resolvedFont`.
    /// Feeding CM6 the raw picker string instead let a name AppKit resolved
    /// diverge from what the webview's CSS matched (the reported View/Edit
    /// mismatch). Returns nil for a nil/empty/unresolvable name, mirroring
    /// `resolvedFont`'s system-monospace fallback (CM6 then keeps its bundled
    /// monospace default). The webview wraps this in quotes + the shared
    /// `"SF Mono", Menlo, monospace` stack, so a family it can't match still
    /// degrades to the same SF Mono the AppKit nil-path uses.
    public static func cssFamily(for name: String?) -> String? {
        guard let name, !name.isEmpty, let f = NSFont(name: name, size: 12) else {
            return nil
        }
        return f.familyName ?? name
    }

    /// Fixed-pitch font FAMILY names for the picker, sorted. Probed via a
    /// representative font per family (`isFixedPitch`); proportional
    /// families never appear — offering Helvetica for a code view would
    /// just break the gutter.
    public static func monospaceFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let f = NSFont(name: family, size: 12) else { return false }
            return f.isFixedPitch
        }.sorted()
    }

    /// TSK-1151: the line-height MULTIPLE the AppKit source view (NSTextView)
    /// renders at, so the CM6 editor can match it instead of its hardcoded 1.45
    /// (~18% taller). NSTextView sets no explicit `lineHeightMultiple`, so its
    /// effective line height is the layout manager's default for the resolved
    /// font; dividing by the point size yields the font-relative multiple CM6
    /// needs (typically ~1.16–1.20 for monospace). Computed off `resolvedFont`
    /// so a nil/unknown family uses the same SF Mono the views fall back to.
    public static func editorLineHeightMultiple(name: String?, size: CGFloat) -> Double {
        let font = resolvedFont(name: name, size: size)
        let h = NSLayoutManager().defaultLineHeight(for: font)
        guard size > 0, h > 0 else { return 1.2 }
        return Double(h / size)
    }
}
