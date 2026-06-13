import AppKit
import QuartzCore
import SwiftUI

/// TSK-275 — render-FPS / jank instrumentation for the observability
/// surface.
///
/// Pure rolling-window statistics over display-link timestamps. Hitches
/// are judged against the display's NOMINAL cadence (a 120 Hz ProMotion
/// panel isn't graded against 60, and a clean 60 Hz panel isn't flagged
/// for being 60): an interval longer than 1.5× nominal is a missed frame.
public struct FrameStats: Equatable, Sendable {
    /// Frames per second over the window.
    public let fps: Double
    /// Missed-frame count over the window (interval > 1.5× nominal).
    public let hitchCount: Int
    /// The display's nominal refresh rate the stats were judged against.
    public let nominalFPS: Double

    /// The "<60fps highlight" contract, generalized per-display: janky =
    /// any hitch in the window, or sustained fps below 95% of nominal.
    public var isJanky: Bool {
        hitchCount > 0 || (nominalFPS > 0 && fps < nominalFPS * 0.95)
    }

    public init(fps: Double, hitchCount: Int, nominalFPS: Double) {
        self.fps = fps
        self.hitchCount = hitchCount
        self.nominalFPS = nominalFPS
    }

    /// Compute stats from a monotonic timestamp sequence (seconds) and the
    /// nominal frame interval. Headless-testable — the display link only
    /// supplies the inputs.
    public static func compute(
        timestamps: [TimeInterval], nominalInterval: TimeInterval
    ) -> FrameStats {
        let nominalFPS = nominalInterval > 0 ? 1.0 / nominalInterval : 0
        guard timestamps.count >= 2, nominalInterval > 0,
              let first = timestamps.first, let last = timestamps.last,
              last > first else {
            return FrameStats(fps: 0, hitchCount: 0, nominalFPS: nominalFPS)
        }
        let fps = Double(timestamps.count - 1) / (last - first)
        var hitches = 0
        for i in 1..<timestamps.count
        where timestamps[i] - timestamps[i - 1] > nominalInterval * 1.5 {
            hitches += 1
        }
        return FrameStats(fps: fps, hitchCount: hitches, nominalFPS: nominalFPS)
    }
}

/// Drives `FrameStats` from a `CADisplayLink` on the hosting window.
///
/// PUBLISH DISCIPLINE (the #215 rule): the link ticks at 60–120 Hz but
/// `stats` publishes at most every 0.5 s — the observability window's
/// SwiftUI tree must not re-body per frame. Lifecycle is view-bound:
/// `start(for:)` on appear, `stop()` on disappear — zero cost while the
/// observability window is closed.
@MainActor
public final class FrameRateMonitor: ObservableObject {
    @Published public private(set) var stats: FrameStats?

    private var link: CADisplayLink?
    private var stamps: [TimeInterval] = []
    private var lastPublish = Date.distantPast
    /// Rolling window: ~2 s at 120 Hz.
    static let windowSize = 240
    /// Publish cadence floor.
    static let publishInterval: TimeInterval = 0.5

    public init() {}

    public func start(for window: NSWindow) {
        guard link == nil else { return }
        let l = window.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    public func stop() {
        link?.invalidate()
        link = nil
        stamps.removeAll()
        stats = nil
        lastPublish = .distantPast
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if stamps.count > Self.windowSize {
            stamps.removeFirst(stamps.count - Self.windowSize)
        }
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= Self.publishInterval else { return }
        lastPublish = now
        stats = FrameStats.compute(timestamps: stamps, nominalInterval: link.duration)
    }
}
