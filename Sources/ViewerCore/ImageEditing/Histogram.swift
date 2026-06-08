import Foundation

/// Per-channel intensity distribution of a rendered image: how many pixels fall
/// into each of the 256 8-bit intensity buckets, for red / green / blue and a
/// Rec.601 luma channel. A read-only *analysis* of pixels — it never mutates the
/// image and is deliberately NOT an `EditOp` (it changes no geometry or samples),
/// so an image-editor UI can draw a live histogram readout alongside the tonal
/// sliders without polluting the lossless edit history (TSK-344).
///
/// Samples are reported in **straight (un-premultiplied) sRGB8** space: the
/// engine's canonical raster is premultiplied, so each sample is divided back
/// out by its alpha before binning — the distribution therefore reflects the
/// true per-channel colors regardless of transparency. Fully-transparent pixels
/// (alpha 0) have no defined color and are counted into bucket 0 of every
/// channel.
///
/// `Sendable` + `Equatable` value type so it can cross actor boundaries to the
/// UI and be diffed for change detection (skip a redraw when the histogram is
/// unchanged).
public struct Histogram: Sendable, Equatable {
    /// Buckets per channel — 8-bit intensity resolution.
    public static let binCount = 256

    /// Per-bucket pixel counts, each exactly `binCount` long. Index `i` is the
    /// number of pixels whose straight 8-bit value in that channel equals `i`.
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    /// Rec.601 luma — `round(0.299·R + 0.587·G + 0.114·B)` — binned identically.
    public let luma: [Int]
    /// Total pixels sampled (`width · height`). Each channel's bins sum to this.
    public let pixelCount: Int

    init(red: [Int], green: [Int], blue: [Int], luma: [Int], pixelCount: Int) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luma = luma
        self.pixelCount = pixelCount
    }

    /// The most-populated bucket of a channel (its modal intensity), or `0` for
    /// an empty image. A convenience for "where is this channel's mass" — e.g.
    /// the UI's auto-levels hint or a quick exposure read.
    public static func peakBin(_ channel: [Int]) -> Int {
        var best = 0
        var bestCount = -1
        for (i, c) in channel.enumerated() where c > bestCount {
            bestCount = c
            best = i
        }
        return best
    }
}
