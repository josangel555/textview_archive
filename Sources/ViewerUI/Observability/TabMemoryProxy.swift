import Foundation

/// Per-tab *content-byte proxy* for the memory readout.
///
/// **This is explicitly not a per-tab RSS number.** A tab is not a
/// process; `WKWebView`-backed (Markdown) tabs split their resident
/// memory across shared XPC helpers and source/CSV/hex tabs share the
/// main-process heap with no per-tab accounting boundary
/// (`LESSONS.md`, triage-instrumentation.md). The only honest per-tab
/// figure is the *loaded content size in bytes* — what the document
/// itself weighs — which the UI shows with a tooltip making the
/// distinction clear. `hasLiveWebView` flags tabs that additionally
/// carry a `WKWebView` (so their true cost lands in the shared "WebKit
/// helpers" line, not here).
///
/// Stage-2b populates these from the live tab list (reading each loaded
/// document's `byteCount` / `totalByteCount`); keeping the value type
/// here, decoupled from `DocumentModel`, lets the view compile + unit-
/// test without touching the hot file.
public struct TabMemoryProxy: Identifiable, Sendable, Equatable {
    /// Stable tab identity (the host's tab id, stringified).
    public let id: String
    /// Display title (file name) for the row.
    public let title: String
    /// Loaded content size in bytes — the honest per-tab proxy. `nil`
    /// for tabs with no loaded document yet (loading/error/blank).
    public let contentBytes: Int?
    /// Whether the tab is backed by a live `WKWebView` (its real memory
    /// is in the shared helper processes, not attributable here).
    public let hasLiveWebView: Bool

    public init(
        id: String,
        title: String,
        contentBytes: Int?,
        hasLiveWebView: Bool
    ) {
        self.id = id
        self.title = title
        self.contentBytes = contentBytes
        self.hasLiveWebView = hasLiveWebView
    }
}

/// Byte formatting shared by the memory + logs views. Binary units
/// (KiB/MiB) to match Activity Monitor's convention so the numbers are
/// directly comparable when a user cross-checks.
enum ByteFormat {
    static func mib(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mib)
    }

    static func human(_ bytes: Int) -> String {
        human(UInt64(max(0, bytes)))
    }

    static func human(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}
