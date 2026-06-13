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
}
