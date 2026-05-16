import SwiftUI
import ViewerCore
import ViewerKit

/// Render a `FileIconKind` as a tinted square. Chips show the
/// extension text; glyphs show an SF Symbol. The container is always
/// the same size for visual alignment in tree rows. Color comes from
/// the category palette and adapts to light/dark.
public struct FileIconView: View {
    public enum Size {
        case tree     // tight, used inside FileTree rows
        case row      // bookmarks / tabs (slightly larger)
        case gallery  // settings / preview surfaces
    }

    let kind: FileIconKind
    let size: Size

    public init(kind: FileIconKind, size: Size = .tree) {
        self.kind = kind
        self.size = size
    }

    /// Convenience: derive the icon from a URL without the caller
    /// importing the classifier.
    public init(url: URL, isDirectory: Bool, isExpanded: Bool = false,
                isGitRoot: Bool = false, isSymlink: Bool = false,
                size: Size = .tree) {
        self.kind = FileIconClassifier.icon(
            for: url, isDirectory: isDirectory, isExpanded: isExpanded,
            isGitRoot: isGitRoot, isSymlink: isSymlink
        )
        self.size = size
    }

    public var body: some View {
        switch kind {
        case let .chip(text, category):
            chipBody(text: text, category: category)
        case let .glyph(symbol, category):
            glyphBody(symbol: symbol, category: category)
        case let .folder(state):
            folderBody(state: state)
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chipBody(text: String, category: IconCategory) -> some View {
        let m = metrics
        let pair = category.palette
        RoundedRectangle(cornerRadius: m.corner, style: .continuous)
            .fill(pair.background)
            .frame(width: m.container, height: m.container)
            .overlay(
                Text(text)
                    .font(.system(size: chipFontSize(for: text), weight: .bold,
                                  design: .monospaced))
                    .kerning(-0.4)
                    .foregroundStyle(pair.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
            )
    }

    private func chipFontSize(for text: String) -> CGFloat {
        // Same staircase as the design: 1-char gets the largest size,
        // 4-char gets a tight one so kerning doesn't blow out.
        let base: CGFloat
        switch size {
        case .tree:    base = 7.5
        case .row:     base = 9.0
        case .gallery: base = 13.0
        }
        switch text.count {
        case 1:  return base + 1.0
        case 2:  return base + 0.5
        case 3:  return base
        default: return base - 1.0
        }
    }

    // MARK: - Glyph

    @ViewBuilder
    private func glyphBody(symbol: String, category: IconCategory) -> some View {
        let m = metrics
        let pair = category.palette
        RoundedRectangle(cornerRadius: m.corner, style: .continuous)
            .fill(pair.background)
            .frame(width: m.container, height: m.container)
            .overlay(
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: m.glyphSize, weight: .medium))
                    .foregroundStyle(pair.foreground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
            )
    }

    // MARK: - Folder

    @ViewBuilder
    private func folderBody(state: FolderState) -> some View {
        let m = metrics
        let pair = state.palette
        let symbol = state.symbol
        RoundedRectangle(cornerRadius: m.corner, style: .continuous)
            .fill(pair.background)
            .frame(width: m.container, height: m.container)
            .overlay(
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: m.glyphSize, weight: .medium))
                    .foregroundStyle(pair.foreground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
            )
    }

    // MARK: - Sizing

    private struct Metrics {
        let container: CGFloat
        let corner: CGFloat
        let glyphSize: CGFloat
    }

    private var metrics: Metrics {
        switch size {
        case .tree:    return Metrics(container: 16, corner: 3,  glyphSize: 10)
        case .row:     return Metrics(container: 20, corner: 4,  glyphSize: 12)
        case .gallery: return Metrics(container: 38, corner: 8,  glyphSize: 20)
        }
    }
}

// MARK: - Color palette

extension IconCategory {
    struct Pair {
        let background: Color
        let foreground: Color
    }

    /// Light/dark adaptive bg+fg pair per category. Light values are
    /// taken verbatim from the design tokens; dark values are derived
    /// by inverting lightness while keeping the hue stable.
    var palette: Pair {
        switch self {
        case .code:
            return Pair(
                background: Color.adaptive(light: 0.890, 0.925, 0.973, dark: 0.110, 0.180, 0.300),
                foreground: Color.adaptive(light: 0.102, 0.267, 0.502, dark: 0.560, 0.760, 0.980)
            )
        case .markup:
            return Pair(
                background: Color.adaptive(light: 0.961, 0.882, 0.925, dark: 0.290, 0.130, 0.220),
                foreground: Color.adaptive(light: 0.545, 0.165, 0.416, dark: 0.940, 0.620, 0.820)
            )
        case .style:
            return Pair(
                background: Color.adaptive(light: 0.878, 0.937, 0.961, dark: 0.080, 0.220, 0.290),
                foreground: Color.adaptive(light: 0.082, 0.353, 0.471, dark: 0.500, 0.800, 0.920)
            )
        case .config:
            return Pair(
                background: Color.adaptive(light: 0.878, 0.937, 0.902, dark: 0.100, 0.240, 0.150),
                foreground: Color.adaptive(light: 0.122, 0.376, 0.220, dark: 0.520, 0.840, 0.620)
            )
        case .data:
            return Pair(
                background: Color.adaptive(light: 0.953, 0.918, 0.859, dark: 0.300, 0.230, 0.110),
                foreground: Color.adaptive(light: 0.478, 0.353, 0.118, dark: 0.940, 0.780, 0.460)
            )
        case .secret:
            return Pair(
                background: Color.adaptive(light: 0.961, 0.871, 0.871, dark: 0.320, 0.130, 0.130),
                foreground: Color.adaptive(light: 0.576, 0.122, 0.122, dark: 0.960, 0.560, 0.560)
            )
        case .doc:
            return Pair(
                background: Color.adaptive(light: 0.925, 0.863, 0.949, dark: 0.250, 0.130, 0.350),
                foreground: Color.adaptive(light: 0.325, 0.165, 0.522, dark: 0.820, 0.640, 0.960)
            )
        case .media:
            return Pair(
                background: Color.adaptive(light: 0.941, 0.902, 0.847, dark: 0.270, 0.210, 0.120),
                foreground: Color.adaptive(light: 0.416, 0.310, 0.122, dark: 0.900, 0.760, 0.490)
            )
        case .bin:
            return Pair(
                background: Color.adaptive(light: 0.910, 0.922, 0.937, dark: 0.190, 0.210, 0.240),
                foreground: Color.adaptive(light: 0.353, 0.376, 0.416, dark: 0.700, 0.730, 0.780)
            )
        case .generic:
            return Pair(
                background: Color.adaptive(light: 0.933, 0.941, 0.953, dark: 0.200, 0.220, 0.250),
                foreground: Color.adaptive(light: 0.290, 0.314, 0.353, dark: 0.740, 0.760, 0.800)
            )
        }
    }
}

extension FolderState {
    var palette: IconCategory.Pair {
        switch self {
        case .collapsed: return IconCategory.bin.palette
        case .open:      return IconCategory.code.palette
        case .root:      return IconCategory.config.palette
        case .hidden:    return IconCategory.generic.palette
        case .locked:    return IconCategory.media.palette
        case .symlink:   return IconCategory.doc.palette
        }
    }

    var symbol: String {
        // Keep the folder silhouette across states; tint carries the
        // state signal (per design). Only symlink swaps to a different
        // glyph because it's not really a folder in the workspace
        // sense — it points outside.
        switch self {
        case .collapsed: return "folder"
        case .open:      return "folder.fill"
        case .root:      return "folder.fill.badge.gearshape"
        case .hidden:    return "folder.badge.questionmark"
        case .locked:    return "folder.fill"
        case .symlink:   return "arrow.up.forward.square.fill"
        }
    }
}

// MARK: - Color light/dark helper

extension Color {
    /// Build a Color that swaps RGB triplets between light and dark
    /// appearance. We bypass asset catalogs to keep the icon palette
    /// pure-source — easy to grep, no Resources/ shuffle.
    static func adaptive(
        light lr: Double, _ lg: Double, _ lb: Double,
        dark  dr: Double, _ dg: Double, _ db: Double,
        opacity a: Double = 1.0
    ) -> Color {
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: a)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: a)
        }
        return Color(nsColor: dynamic)
    }
}
