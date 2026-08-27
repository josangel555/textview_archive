import Foundation

/// Per-display-layout window-frame memory (owner 2026-08-27: "I often find
/// it maximized — plugging in a monitor, relaunching").
///
/// The one-way ratchet this kills: AppKit's frame autosave keeps exactly ONE
/// frame. A frame saved on a big external display gets clamped to the
/// laptop's visible frame on a laptop-only launch (that clamp IS the
/// "maximized" window), the autosave immediately overwrites the record with
/// the clamped frame — and when the external display returns, the original
/// preference is gone. Display plug/unplug while running does the same via
/// AppKit's window reconfiguration.
///
/// This model remembers the frame PER SCREEN LAYOUT (keyed by the set of
/// visible frames), so each arrangement keeps its own memory: unplug →
/// laptop layout uses (and records) a laptop frame; replug → the external
/// layout's remembered frame comes back intact. Pure value logic —
/// persistence is a string array the caller stores wherever it likes.
public struct WindowFrameMemory: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        public let layoutKey: String
        public let frame: CGRect
    }

    /// MRU-first. Bounded so decades of hot-desking can't grow the pref.
    public private(set) var entries: [Entry]
    public let capacity: Int

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
        self.entries = []
    }

    /// A stable key for a screen arrangement: every display's visible frame,
    /// origin+size rounded to whole points (sub-point float jitter across
    /// reboots must not fork the key), sorted so enumeration order is
    /// irrelevant.
    public static func layoutKey(visibleFrames: [CGRect]) -> String {
        visibleFrames
            .map { r in
                "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),"
                    + "\(Int(r.width.rounded()))x\(Int(r.height.rounded()))"
            }
            .sorted()
            .joined(separator: "|")
    }

    /// Remember `frame` as the user's intent for `layoutKey` (MRU-front,
    /// replaces any prior entry for the same layout, evicts beyond capacity).
    public mutating func record(frame: CGRect, layoutKey: String) {
        guard frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite else { return }
        entries.removeAll { $0.layoutKey == layoutKey }
        entries.insert(Entry(layoutKey: layoutKey, frame: frame), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// The remembered frame for a layout, or nil.
    public func frame(forLayoutKey key: String) -> CGRect? {
        entries.first { $0.layoutKey == key }?.frame
    }

    // MARK: persistence (string-array codec — UserDefaults-friendly)

    /// "layoutKey\tx,y,wxh" per entry, MRU order.
    public func encoded() -> [String] {
        entries.map { e in
            "\(e.layoutKey)\t\(e.frame.origin.x),\(e.frame.origin.y),"
                + "\(e.frame.width)x\(e.frame.height)"
        }
    }

    public static func decode(_ lines: [String], capacity: Int = 16) -> WindowFrameMemory {
        var memory = WindowFrameMemory(capacity: capacity)
        // Decode back-to-front so record()'s MRU-front insert restores order.
        for line in lines.reversed() {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let nums = parts[1]
                .split(whereSeparator: { $0 == "," || $0 == "x" })
                .compactMap { Double($0) }
            guard nums.count == 4 else { continue }
            memory.record(
                frame: CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]),
                layoutKey: parts[0])
        }
        return memory
    }
}
