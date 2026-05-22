import XCTest
import Foundation

/// Common protocol for all Page Objects in this suite.
///
/// The "app" handle is a per-step JSON dump (one element of the
/// `[[String: Any]]` produced by `AppLauncher.runScript`). Page Objects
/// are stateless wrappers — they hold a reference to the dump and offer
/// domain-named accessors / assertion helpers built on top of it.
///
/// Reading from the dump on every access keeps Page Objects free of
/// caching surprises: if a test asserts something twice across two
/// scenarios it wraps two separate dump snapshots, no memoisation.
protocol DumpPage {
    /// The raw step-dump JSON this page wraps. Top-level keys include
    /// `window`, `contentView`, `model`. See `AppDumpSession.swift`
    /// (in the live app) for the exact schema.
    var dump: [String: Any] { get }
}

extension DumpPage {

    // MARK: - Window helpers

    /// `dump["window"]["title"]`.
    var windowTitle: String? {
        (dump["window"] as? [String: Any])?["title"] as? String
    }

    /// Parsed `(width, height)` from `dump["window"]["frame"]`. Frames
    /// are emitted as `"{{x, y}, {w, h}}"` or similar — we tolerate
    /// minor formatting drift across macOS versions by extracting all
    /// numerics.
    var windowSize: (width: Int, height: Int)? {
        guard let w = dump["window"] as? [String: Any],
              let f = w["frame"] as? String else { return nil }
        let nums = f.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(whereSeparator: { ",x{} ".contains($0) })
            .compactMap { Double($0) }
        guard nums.count >= 4 else { return nil }
        return (Int(nums[2]), Int(nums[3]))
    }

    // MARK: - Model helpers

    /// `dump["model"]` as a dictionary, or `[:]` when absent.
    var model: [String: Any] {
        (dump["model"] as? [String: Any]) ?? [:]
    }

    /// `model.currentViewMode` (`"source"`, `"rendered"`, `"hex"`...).
    var currentViewMode: String? {
        model["currentViewMode"] as? String
    }

    /// `model.zoom` (always a `Double` in the dump schema).
    var zoom: Double? {
        model["zoom"] as? Double
    }

    // MARK: - View-tree walks

    /// All descendants of the content view whose `class` matches.
    func nodes(ofClass cls: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ n: [String: Any]) {
            if (n["class"] as? String) == cls { out.append(n) }
            if let subs = n["subviews"] as? [[String: Any]] { subs.forEach(walk) }
        }
        if let cv = dump["contentView"] as? [String: Any] { walk(cv) }
        return out
    }

    /// First descendant carrying the given `mdv.*` accessibility id, or
    /// `nil`. Used to anchor surface-specific subtree lookups.
    func subtree(withIdentifier id: String) -> [String: Any]? {
        var found: [String: Any]?
        func walk(_ n: [String: Any]) {
            if found != nil { return }
            if (n["accessibilityIdentifier"] as? String) == id {
                found = n; return
            }
            if let kids = n["subviews"] as? [[String: Any]] { kids.forEach(walk) }
        }
        if let cv = dump["contentView"] as? [String: Any] { walk(cv) }
        return found
    }

    /// Total node count in the content-view subtree. Cheap proxy for
    /// "did the view tree grow / shrink" assertions used by palette
    /// show/dismiss tests.
    var totalNodeCount: Int {
        var count = 0
        func walk(_ n: [String: Any]) {
            count += 1
            if let s = n["subviews"] as? [[String: Any]] { s.forEach(walk) }
        }
        if let cv = dump["contentView"] as? [String: Any] { walk(cv) }
        return count
    }
}
