import Foundation
import RustCore
import os

/// TSK-1518 (stateful-core S3) — the SHADOW-MODE differential net.
///
/// With `MDV_RUST_DOCSTORE=shadow`, every CM6 edit batch that updates the
/// Swift-side text mirror is ALSO mirrored into the rust-core `DocRegistry`
/// (open once, deltas thereafter), and the two are compared:
/// - **every batch**: the core's post-apply `len_utf16` vs the host mirror's
///   UTF-16 count (free — it rides the delta response);
/// - **every `fullCompareStride`-th batch and on save**: full text equality
///   (S4/TSK-1519 rides the same hook at snapshot time).
///
/// A divergence increments the process-wide counter, logs, and RESYNCS by
/// re-opening the core doc from the host text (the host stays authoritative
/// in shadow mode — user-facing behavior is UNCHANGED by construction). The
/// exit gate to authority-flip (S5/S6, owner-supervised) is this counter
/// staying at ZERO across real sessions.
@MainActor
public final class CoreDocShadow {

    /// Shadow gate: `MDV_RUST_DOCSTORE=shadow` (off by default; `off` wins if
    /// the core lacks the capability).
    public static let isShadowMode: Bool =
        ProcessInfo.processInfo.environment["MDV_RUST_DOCSTORE"] == "shadow"
            && CoreDocStore.isAvailable

    /// Test seam: the env gate is process-fixed, so host tests flip this to
    /// exercise the net. `nil` = follow `isShadowMode`.
    public static var shadowOverrideForTesting: Bool?

    /// The effective gate every entry point checks.
    private static var shadowActive: Bool { shadowOverrideForTesting ?? isShadowMode }

    /// Process-wide divergence count (the S5/S6 exit-gate metric).
    public private(set) static var divergenceCount = 0
    /// Process-wide mirrored-batch count (denominator for the gate metric).
    public private(set) static var batchCount = 0

    /// Full-text compare cadence (every Nth batch; len-compare is every batch).
    private let fullCompareStride: Int

    private var docId: UInt64?
    private var localBatches = 0
    private static let log = Logger(subsystem: "com.markdownviewer", category: "CoreDocShadow")

    public init(fullCompareStride: Int = 16) {
        self.fullCompareStride = max(1, fullCompareStride)
    }

    /// Mirror one applied edit batch. `base` is the pre-batch text (used only
    /// for the first-touch open); `applied` is the host's post-batch text —
    /// the authority the core is checked against.
    public func mirror(edits: [CMEdit], base: String, applied: String) {
        guard Self.shadowActive else { return }
        Self.batchCount += 1
        localBatches += 1
        do {
            let id = try openIfNeeded(base: base)
            let result = try CoreDocStore.applyDelta(
                docId: id,
                edits: edits.map { .init(from: Int64($0.from), to: Int64($0.to), insert: $0.insert) }
            )
            guard result.found else {
                // Evicted (should not happen while mirrored-live: host pin is
                // set at open) — reopen and count it as a divergence-class event.
                recordDivergence("doc evicted mid-shadow; reopening")
                docId = nil
                _ = try openIfNeeded(base: applied)
                return
            }
            guard result.changed else {
                // The core REJECTED a batch the host applied — a real
                // divergence in validation semantics. Resync.
                recordDivergence("core rejected a host-applied batch")
                try resync(to: applied)
                return
            }
            if result.lenUTF16 != UInt64(applied.utf16.count) {
                recordDivergence(
                    "len mismatch core=\(result.lenUTF16) host=\(applied.utf16.count)")
                try resync(to: applied)
                return
            }
            if localBatches % fullCompareStride == 0 {
                try fullCompare(against: applied, context: "stride")
            }
        } catch {
            // FFI faults are counted but never surface to the user (shadow).
            recordDivergence("shadow FFI fault: \(error)")
            docId = nil
        }
    }

    /// Full-compare hook for the save path (and S4/TSK-1519: the hot-exit
    /// snapshot path calls this right before capturing — proving the core
    /// could BE the snapshot source before authority ever flips).
    /// Also records the save into the core (baseline reset) on match.
    public func verifyOnSave(hostText: String) {
        guard Self.shadowActive, let id = docId else { return }
        do {
            try fullCompare(against: hostText, context: "save")
            _ = try CoreDocStore.markSaved(docId: id)
        } catch {
            recordDivergence("save-verify FFI fault: \(error)")
        }
    }

    /// S4 (TSK-1519): shadow-verified snapshot read — returns the CORE's text
    /// for the snapshot IF it matches the host byte-for-byte (and counts a
    /// divergence + returns nil otherwise). Callers keep writing host bytes;
    /// this proves the core-sourced snapshot on every real capture.
    public func snapshotTextIfVerified(hostText: String) -> String? {
        guard Self.shadowActive, let id = docId else { return nil }
        guard let coreText = try? CoreDocStore.text(docId: id) else { return nil }
        if coreText == hostText { return coreText }
        recordDivergence("snapshot compare mismatch (core len \(coreText.utf16.count) vs host \(hostText.utf16.count))")
        try? resync(to: hostText)
        return nil
    }

    /// A v1 FULL-TEXT change replaced the host mirror wholesale (drift
    /// recovery, programmatic setText). The delta stream is broken at this
    /// point, so resync the core doc to the new authority text.
    public func noteFullReplace(_ text: String) {
        guard Self.shadowActive, docId != nil else { return }
        try? resync(to: text)
    }

    /// Editor closed — release the core doc.
    public func close() {
        guard let id = docId else { return }
        try? CoreDocStore.close(docId: id)
        docId = nil
    }

    // MARK: - Internals

    private func openIfNeeded(base: String) throws -> UInt64 {
        if let id = docId { return id }
        let id = try CoreDocStore.open(text: base)
        // Host pin while the editor is live (dirty⇒pinned composes core-side).
        _ = try? CoreDocStore.setPinned(docId: id, pinned: true)
        docId = id
        return id
    }

    private func resync(to text: String) throws {
        if let id = docId {
            try? CoreDocStore.close(docId: id)
        }
        docId = nil
        _ = try openIfNeeded(base: text)
    }

    private func fullCompare(against hostText: String, context: String) throws {
        guard let id = docId else { return }
        guard let coreText = try CoreDocStore.text(docId: id) else {
            recordDivergence("full-compare(\(context)): doc missing")
            docId = nil
            return
        }
        if coreText != hostText {
            recordDivergence("full-compare(\(context)) text mismatch")
            try resync(to: hostText)
        }
    }

    private func recordDivergence(_ reason: String) {
        Self.divergenceCount += 1
        Self.log.error("DOCSTORE SHADOW DIVERGENCE #\(Self.divergenceCount, privacy: .public): \(reason, privacy: .public)")
    }

    /// Test seam: reset the process-wide counters.
    public static func resetCountersForTesting() {
        divergenceCount = 0
        batchCount = 0
    }
}
