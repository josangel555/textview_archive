import XCTest

/// TSK-849 — the fixed-duration-sleep ratchet.
///
/// Fixed `Thread.sleep(forTimeInterval:)` / `usleep()` waits in the test tree
/// are the run-floor tax: they pay their full duration EVERY run regardless of
/// whether the awaited condition already holds, and they're the #1 source of
/// "tests are slow / flaky under load" (a sleep tuned on a fast host times out
/// or under-waits on a loaded one). The rule is **condition-polling, not fixed
/// sleeps**: spin a short poll loop on the observable predicate
/// (`waitUntil { … }` / `XCTestExpectation` + `wait(for:timeout:)`), which
/// returns the instant the condition is met and only burns wall-clock when it
/// genuinely has to wait.
///
/// This test is a RATCHET, not a ban: the existing sleeps (mostly FSEvents /
/// forkpty / WindowServer settle waits that have no cheap observable signal,
/// and the heavy VM-only visual-regression tiers) are grandfathered via the
/// baseline below. The guard FAILS if the count GROWS — i.e. a NEW fixed sleep
/// is introduced — forcing the author to either use condition-polling or, if a
/// fixed wait is genuinely unavoidable, lower the floor elsewhere first and
/// bump the baseline deliberately (with justification in the commit).
///
/// Host-safe and window-free: it only reads the test sources off disk, so it
/// runs in the headless merge gate.
final class SleepRatchetGuardTests: XCTestCase {

    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ViewerCoreTests
        .deletingLastPathComponent()  // Tests

    /// Patterns that denote a FIXED-DURATION blocking sleep (the floor tax).
    /// `Task.sleep` is intentionally NOT counted — it yields the cooperative
    /// thread rather than blocking it, and async tests legitimately use short
    /// `Task.sleep` to let an actor-hop settle; the expensive serial-blocking
    /// forms are the ones we ratchet.
    private static let sleepPatterns = [
        "Thread.sleep(forTimeInterval",
        "usleep(",
    ]

    /// Frozen baseline — the count of fixed-duration sleep sites across the
    /// test tree at the time of TSK-849. Measured with:
    ///   grep -rn 'Thread\.sleep(forTimeInterval' Tests | wc -l   # 70
    ///   grep -rn 'usleep('                          Tests | wc -l   #  5
    /// LOWER this when you remove sleeps; only RAISE it with explicit
    /// justification (a fixed wait with no observable predicate to poll).
    /// 2026-06-19: 75 → 77 — the ultracode-wave integration folded test files
    /// (from other wave commits) that carry 2 pre-existing fixed sleeps; the
    /// 849 baseline predated them. Follow-up: convert those 2 to polling.
    /// 2026-06-28: 77 → 79 — TSK-1279's dark-mode T5 pixel guard
    /// (SourceViewVisualRegressionTests.captureDarkFraction) adds 2 spawn/
    /// render-settle fixed sleeps, mirroring the suite's 5 existing identical
    /// ones (terminate-quiesce + post-launch render settle). Polling a SPAWNED
    /// app's cross-process render-readiness has no clean predicate, so these
    /// match the established T5-capture pattern rather than introduce polling.
    /// 2026-07-02: 79 → 82 — M3.S7/TSK-1378: CanvasOverlaySceneHarness
    /// carries the standard T5 spawn plumbing (terminate-quiesce,
    /// activate-settle, scene-apply/paint settle before capture) — the same
    /// three sleeps every T5 visual suite in this baseline carries; no
    /// pollable signal exists for "the spawned app painted its scene".
    /// 2026-07-30: 82 → 85 — PartialT6SceneCaptureTests (the owner-directed
    /// pixel-verification rig) carries the same standard three T5 spawn
    /// sleeps (terminate-quiesce, windowid poll tick, scene-apply/paint
    /// settle) as every capture suite above.
    /// 2026-07-31: 85 → 89 — AXChromeInteractionTests (the AX tier
    /// bootstrap): the same terminate-quiesce + windowid poll tick +
    /// paint-settle trio as every spawn rig, plus the `waitUntil` poll
    /// INTERVAL tick — which IS condition-polling (returns the instant
    /// the predicate holds); the sleep is its sampling period.
    /// 2026-08-01: 89 → 90 — the AX rig's activation-retry BACKOFF
    /// (osascript -609 while a prior same-named instance unwinds in
    /// WindowServer): a bounded retry-until-rc==0 loop; the sleep only
    /// burns when activation genuinely failed, and there is no pollable
    /// predicate for "WindowServer finished unwinding the old instance".
    private static let baseline = 90

    func test_noNewFixedDurationSleeps() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: Self.testsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return XCTFail("could not enumerate \(Self.testsRoot.path)")
        }

        var total = 0
        var perFile: [(String, Int)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // This guard file itself names the patterns in string literals —
            // skip it so it doesn't count its own allowlist as offenders.
            if url.lastPathComponent == "SleepRatchetGuardTests.swift" { continue }
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var fileCount = 0
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                // Ignore commented-out lines so a `// Thread.sleep(...)` note
                // doesn't trip the ratchet.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for pat in Self.sleepPatterns where line.contains(pat) {
                    fileCount += 1
                }
            }
            if fileCount > 0 {
                total += fileCount
                perFile.append((url.lastPathComponent, fileCount))
            }
        }

        if total > Self.baseline {
            perFile.sort { $0.1 > $1.1 }
            let breakdown = perFile.map { "    \($0.1)  \($0.0)" }.joined(separator: "\n")
            XCTFail("""
                Fixed-duration sleeps grew to \(total) (baseline \(Self.baseline)).
                A NEW Thread.sleep(forTimeInterval:)/usleep() was introduced.
                Use condition-polling (waitUntil { … } / expectation +
                wait(for:timeout:)) instead — it returns the instant the
                condition holds and only burns wall-clock when it must wait.
                If a fixed wait is truly unavoidable (no observable predicate),
                lower the floor elsewhere first, then bump `baseline` with a
                justification. Current per-file counts:
                \(breakdown)
                """)
        }

        // Tripwire the other way: if we DROP below baseline, lower it so the
        // ratchet stays tight (otherwise removed-sleep headroom silently lets a
        // new one slip back in). A soft note via XCTAttachment would be nicer,
        // but a plain assert keeps it visible in the gate log.
        if total < Self.baseline {
            // Not a failure — just surface that the baseline can tighten.
            print("note(SleepRatchetGuard): fixed sleeps now \(total) "
                  + "(baseline \(Self.baseline)); consider lowering the baseline.")
        }
    }
}
