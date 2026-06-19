import CoreGraphics
import Foundation

/// A merged call-stack profile — the data model behind a flame chart.
///
/// Foundation slice of TSK-715 ("Profiling / Memory diffs / Flame charts /
/// composition charts"). Parses the universal **folded-stacks** text format
/// (one collapsed stack per line, used by `flamegraph.pl`, Linux `perf script
/// | stackcollapse-perf.pl`, `py-spy`, `rbspy`, async-profiler, etc.) into a
/// merged frame tree where each node carries:
///   - `total`: samples in this frame AND everything it called (its subtree),
///   - `self`:  samples that landed exactly here (leaf hits).
///
/// Pure logic — no AppKit/SwiftUI — so the whole thing is host-testable, the
/// same posture as `TreemapLayout` / `DependencyGraphLayout`. A flame chart is
/// then a depth/width layout over this tree (`FlameLayout.lay`); a memory diff
/// is two profiles subtracted frame-for-frame (`FlameProfile.diff`).
///
/// Folded-stacks grammar (one sample group per line):
///
///     frameA;frameB;frameC <count>
///
/// where frames are separated by `;` (root first, leaf last) and `<count>` is
/// a positive integer weight (samples / bytes / nanoseconds — the unit is
/// caller-defined). Lines are summed, so duplicate stacks merge. A folded file
/// for a CPU profile counts samples; for a heap profile it counts bytes — the
/// model is unit-agnostic, which is exactly why one parser backs both the
/// flame-chart and the memory-diff sub-surfaces.
public struct FlameProfile: Equatable, Sendable {

    /// One node in the merged call tree. Identity within a parent is `name`
    /// (sibling frames with the same symbol merge — that IS the flame-graph
    /// folding). The synthetic root carries every top stack as its children.
    public struct Frame: Equatable, Sendable, Identifiable {
        /// Symbol / function name for this frame (the synthetic root is `""`).
        public let name: String
        /// Samples in this frame's subtree (this frame plus all descendants).
        public let total: Int64
        /// Samples that ended exactly in this frame (leaf hits) — `total`
        /// minus the sum of the children's `total`.
        public let selfWeight: Int64
        /// Direct callees, sorted by `total` descending then `name` ascending
        /// so layout is deterministic and the heaviest child leads.
        public let children: [Frame]

        /// Stable path-based identity: the `;`-joined names from root to here.
        /// Distinguishes two frames with the same `name` under different
        /// callers (recursion / shared leaves), which `name` alone cannot.
        public let id: String

        public init(
            name: String,
            total: Int64,
            selfWeight: Int64,
            children: [Frame],
            id: String
        ) {
            self.name = name
            self.total = total
            self.selfWeight = selfWeight
            self.children = children
            self.id = id
        }

        /// Total number of frames in this subtree, including this one.
        public var frameCount: Int {
            children.reduce(1) { $0 + $1.frameCount }
        }

        /// Greatest call depth below this frame (a leaf is `0`).
        public var maxDepth: Int {
            (children.map(\.maxDepth).max() ?? -1) + 1
        }
    }

    /// The synthetic root. Its `total` is the grand sample total; its
    /// `children` are the top (outermost) frames of every recorded stack.
    public let root: Frame
    /// Lines that could not be parsed (no weight, non-positive weight, empty
    /// stack). Surfaced so the UI can warn "N malformed lines skipped" rather
    /// than silently dropping data — same posture as `FolderSizeStats.truncated`.
    public let malformedLineCount: Int

    public init(root: Frame, malformedLineCount: Int) {
        self.root = root
        self.malformedLineCount = malformedLineCount
    }

    /// Grand total weight across every recorded stack (= `root.total`).
    public var totalWeight: Int64 { root.total }
    /// `true` when no stack parsed (empty / all-malformed input).
    public var isEmpty: Bool { root.children.isEmpty }
}

// MARK: - Folded-stacks parsing

public extension FlameProfile {

    /// Mutable accumulator tree used only while parsing — keyed by child name
    /// for O(1) merge of repeated stacks, then frozen into the immutable,
    /// sorted `Frame` tree.
    private final class BuildNode {
        var total: Int64 = 0
        var children: [String: BuildNode] = [:]
    }

    /// Parse folded-stacks text into a merged `FlameProfile`.
    ///
    /// Robustness rules (a real profiler dump is messy):
    ///   - blank lines and lines beginning `#` (comments) are ignored;
    ///   - the weight is the LAST whitespace-delimited token; everything
    ///     before it is the stack. This tolerates frames that themselves
    ///     contain spaces (e.g. C++ templated signatures) as long as the
    ///     count is the final token;
    ///   - a non-integer or non-positive trailing token ⇒ the line is counted
    ///     `malformed` and skipped;
    ///   - empty frame names produced by `;;` or leading/trailing `;` are
    ///     dropped (they carry no symbol); a stack that is entirely empty
    ///     after this ⇒ malformed.
    /// Duplicate stacks across lines accumulate (the whole point of folding).
    static func parseFolded(_ text: String) -> FlameProfile {
        let synthetic = BuildNode()
        var malformed = 0

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return }

            // Split off the trailing count: last whitespace run in the line.
            guard let lastSpace = trimmed.lastIndex(where: { $0 == " " || $0 == "\t" }) else {
                malformed += 1; return
            }
            let stackPart = trimmed[..<lastSpace]
            let countPart = trimmed[trimmed.index(after: lastSpace)...]
                .trimmingCharacters(in: .whitespaces)
            guard let weight = Int64(countPart), weight > 0 else {
                malformed += 1; return
            }

            let frames = stackPart
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !frames.isEmpty else { malformed += 1; return }

            // Walk/extend the tree, crediting `total` at every level.
            synthetic.total += weight
            var node = synthetic
            for name in frames {
                let child: BuildNode
                if let existing = node.children[name] {
                    child = existing
                } else {
                    child = BuildNode()
                    node.children[name] = child
                }
                child.total += weight
                node = child
            }
        }

        let root = Self.freeze(synthetic, name: "", path: "")
        return FlameProfile(root: root, malformedLineCount: malformed)
    }

    /// Convert one build node (and its subtree) into the immutable, sorted
    /// `Frame`, computing `selfWeight = total − Σ child.total`.
    private static func freeze(_ node: BuildNode, name: String, path: String) -> Frame {
        var kids: [Frame] = []
        kids.reserveCapacity(node.children.count)
        var childrenTotal: Int64 = 0
        for (childName, childNode) in node.children {
            let childPath = path.isEmpty ? childName : "\(path);\(childName)"
            kids.append(freeze(childNode, name: childName, path: childPath))
            childrenTotal += childNode.total
        }
        kids.sort { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        let selfW = max(0, node.total - childrenTotal)
        return Frame(name: name, total: node.total, selfWeight: selfW,
                     children: kids, id: path)
    }
}

// MARK: - Hot-frame ranking

public extension FlameProfile {

    /// A leaf-cost ("hot") row: a symbol and the total `self` time charged to
    /// it across every call path. This is the "top functions" table that sits
    /// beside a flame chart — the actual answer to "where did time/bytes go?".
    struct HotFrame: Equatable, Sendable, Identifiable {
        public let name: String
        public let selfWeight: Int64
        public var id: String { name }
        public init(name: String, selfWeight: Int64) {
            self.name = name
            self.selfWeight = selfWeight
        }
    }

    /// Symbols ranked by total self-cost (merged across all call paths),
    /// heaviest first. `limit == nil` returns every non-zero-self symbol.
    func hotFrames(limit: Int? = nil) -> [HotFrame] {
        var bySymbol: [String: Int64] = [:]
        func walk(_ frame: Frame) {
            if frame.selfWeight > 0 && !frame.name.isEmpty {
                bySymbol[frame.name, default: 0] += frame.selfWeight
            }
            for c in frame.children { walk(c) }
        }
        walk(root)
        let ranked = bySymbol
            .map { HotFrame(name: $0.key, selfWeight: $0.value) }
            .sorted { $0.selfWeight != $1.selfWeight
                ? $0.selfWeight > $1.selfWeight : $0.name < $1.name }
        if let limit { return Array(ranked.prefix(max(0, limit))) }
        return ranked
    }
}
