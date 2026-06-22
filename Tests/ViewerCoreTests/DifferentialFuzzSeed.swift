import Foundation
import XCTest

/// Shared seed-base for the differential parity fuzzes (Formula/Fuzzy/Find/Transcript).
///
/// The merge gate leaves `MDV_FUZZ_SEED_BASE` unset → base 0 → the DETERMINISTIC
/// fixed-seed corpus that is the regression guard (and the corpus that found
/// TSK-1218..1221). The nightly VM lane sets `MDV_FUZZ_SEED_BASE` to a run-varying
/// value (e.g. the workflow run number) so the same fuzzes explore NEW regions of the
/// input space over time — TSK-1125's "varying seeds nightly" half. Because base 0
/// leaves the seeding arithmetic unchanged, the gate's exact sequences are preserved;
/// a non-zero base simply shifts every seed. Each fuzz logs its concrete inputs in the
/// failure message, so a nightly red on a varied seed is reproducible without the seed.
enum DifferentialFuzz {
    static var seedBase: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["MDV_FUZZ_SEED_BASE"],
              let value = UInt64(raw) else { return 0 }
        return value
    }
}

final class DifferentialFuzzSeedTests: XCTestCase {
    /// Guards the merge gate's determinism: with no `MDV_FUZZ_SEED_BASE` set (the gate
    /// case), the base MUST be 0 so the fixed-seed corpus is reproducible. The nightly
    /// lane sets the env, so the assertion is skipped there (this is not a nightly check).
    func test_seed_base_defaults_to_zero_when_env_unset() {
        guard ProcessInfo.processInfo.environment["MDV_FUZZ_SEED_BASE"] == nil else {
            return // nightly lane overrides the base; default-determinism check is moot here
        }
        XCTAssertEqual(DifferentialFuzz.seedBase, 0,
                       "merge gate must run seed base 0 — only the nightly lane sets MDV_FUZZ_SEED_BASE")
    }
}
