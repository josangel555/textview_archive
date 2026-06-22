import XCTest
@testable import ViewerCore

/// Differential parity fuzz for the Claude-transcript parser — Swift `ClaudeLogParser`
/// vs the Rust port (`RustTranscriptAdapter`, A/B'd by the `.transcript` gate env
/// `MDV_RUST_TRANSCRIPT`) over random JSONL transcripts mixing the event shapes the
/// parser recognizes: string + block `content`, text / thinking / tool_use / tool_result
/// blocks, with timestamps. The 4th and most complex dual-twin (real divergence surface:
/// timestamp parsing, content-block projection, tool input/summary stringification).
///
/// Every line carries an explicit `uuid` (and every tool_use an explicit `id`) so event
/// ids are deterministic in both engines — sidestepping the adapter's DOCUMENTED
/// divergence (a record with neither uuid nor id gets a `line-<n>` id from the core vs a
/// random UUID from Swift). `redacting:false` avoids the secret-redaction regex path,
/// which is two different regex engines (an expected, not-a-bug divergence).
final class TranscriptDifferentialFuzzTests: XCTestCase {
    private struct Xorshift {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    // Letters, digits, space — JSON-string-safe (no quotes/backslashes/braces/newlines).
    private let alphabet = Array("abcdef 0123")

    private func randomText(_ rng: inout Xorshift, _ maxLen: Int) -> String {
        let n = rng.int(1, maxLen)
        var s = ""
        for _ in 0..<n { s.append(alphabet[rng.int(0, alphabet.count - 1)]) }
        return s
    }

    func test_swift_rust_transcript_parse_parity() throws {
        let ts = "2026-06-22T10:00:00Z"
        for seed in UInt64(1)...UInt64(50) {
            var rng = Xorshift(s: ((seed &+ DifferentialFuzz.seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<20 { // 50 seeds × 20 = 1000 random transcripts
                var lines: [String] = []
                let n = rng.int(1, 6)
                for i in 0..<n {
                    let t = randomText(&rng, 12)
                    let uid = "U\(seed)-\(i)"
                    let tid = "T\(seed)-\(i)"
                    switch rng.int(0, 5) {
                    case 0:
                        lines.append("{\"type\":\"user\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\",\"content\":\"\(t)\"}}")
                    case 1:
                        lines.append("{\"type\":\"assistant\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":\"\(t)\"}}")
                    case 2:
                        lines.append("{\"type\":\"assistant\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(t)\"}]}}")
                    case 3:
                        lines.append("{\"type\":\"assistant\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\(t)\"}]}}")
                    case 4:
                        lines.append("{\"type\":\"assistant\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"\(tid)\",\"name\":\"\(randomText(&rng, 5))\",\"input\":{\"k\":\"\(t)\"}}]}}")
                    default:
                        lines.append("{\"type\":\"user\",\"uuid\":\"\(uid)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(tid)\",\"content\":\"\(t)\"}]}}")
                    }
                }
                let jsonl = lines.joined(separator: "\n")
                let data = Data(jsonl.utf8)
                let rust = RustTranscriptAdapter.outcome(data, redacting: false,
                                                         environment: ["MDV_RUST_TRANSCRIPT": "1"]).value
                let swift = RustTranscriptAdapter.outcome(data, redacting: false,
                                                          environment: ["MDV_RUST_TRANSCRIPT": "0"]).value
                XCTAssertEqual(rust, swift, "transcript parse parity diverged:\n\(jsonl)")
            }
        }
    }

    /// Teeth: prove the MDV_RUST_TRANSCRIPT env A/B genuinely switches engines.
    func test_transcript_AB_toggle_actually_switches_engines() {
        let data = Data("{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}".utf8)
        let rust = RustTranscriptAdapter.outcome(data, redacting: false,
                                                 environment: ["MDV_RUST_TRANSCRIPT": "1"])
        let swift = RustTranscriptAdapter.outcome(data, redacting: false,
                                                  environment: ["MDV_RUST_TRANSCRIPT": "0"])
        XCTAssertEqual(rust.source, .rust, "gate-on must run the Rust engine")
        XCTAssertEqual(swift.source, .swiftBecauseGateOff, "gate-off must run Swift")
    }
}
