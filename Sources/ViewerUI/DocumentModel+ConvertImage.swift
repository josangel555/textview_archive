import Foundation
import ViewerCore

/// TSK-1325 — the Image Convert panel's DocumentModel wiring. Opens the panel seeded with the
/// active image tab's URL; the converted output opens in a new tab. The off-main convert lives on
/// `ConvertImageViewModel`; this is the open + output-handling glue (host-testable).
extension DocumentModel {

    /// Image extensions the converter can decode (the ImageIO source side).
    static let convertibleImageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    /// Whether `url` looks like a convertible image (by extension).
    public static func isConvertibleImage(_ url: URL) -> Bool {
        convertibleImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Open the Image Convert panel for the active image tab. No-op if the active tab isn't an image.
    public func openConvertImage() {
        guard let url = tabs.selected?.url, Self.isConvertibleImage(url) else { return }
        convertImageVM = ConvertImageViewModel(sourceURL: url)
        showConvertImage = true
    }

    /// Open a converted image file in a new tab (the panel's output handler).
    public func openConvertedImage(_ url: URL) {
        openInNewTab(url)
    }
}
