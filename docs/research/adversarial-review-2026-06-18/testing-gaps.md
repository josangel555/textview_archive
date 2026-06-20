# Adversarial Code Review — Testing Gaps (2026-06-18)

Dimension: **testing-gaps** — critical untested paths (especially pure-logic / model / parser / FFI that *could* be host-tested but isn't), missing edge-case coverage, and tests that assert nothing meaningful.

The Rust core and the FFI boundary are, in general, very well covered (51 FFI tests, 28 unit-tested core modules, a dedicated negative/fuzz suite for the Swift MessagePack reader). The real gaps are concentrated where hostile/untrusted input meets recursion or string-pattern logic on the Swift side: the hand-rolled MessagePack decoder has *no* recursion-depth guard and *no* deeply-nested-input test (it crashes with SIGSEGV — reproduced below), and the HTML sanitizer's `javascript:`-neutralization tests pin only the literal-scheme happy path while the regex misses three textbook XSS evasions (entity-encoded scheme, embedded control chars). A handful of documented security-critical redaction paths (`thinking.signature`, `image.source` truncation) are headlined in the source but never exercised by a test. Each finding below was verified empirically (standalone Swift reproductions) rather than asserted from reading.

### MessagePack decoder has no recursion-depth limit and no deeply-nested-input test — remote-triggerable stack-overflow crash (SIGSEGV)

**Severity:** critical

**Location:** `Sources/RustCore/MessagePack.swift:92` (`MsgPackReader.decode()`), `:157` (`array`), `:172` (`map`); reached on the remote path at `Sources/RustCore/RemoteTransport.swift:233`. Negative suite that *should* cover it: `Tests/RustCoreTests/MsgPackDecoderNegative_Audit_Sources_RustCore_MessagePack_swift_Tests.swift`.

**Why:** `decode()` recurses unboundedly for nested arrays/maps. The negative/fuzz suite carefully covers truncation, OOM-reserve clamping, bad tags, and trailing bytes — but has **zero** coverage for nesting depth. A frame that is N nested single-element fixarrays (`0x91 0x91 … 0xc0`) drives N stack frames and overflows the stack, which is an unrecoverable SIGSEGV — *not* a catchable `throw`. Reproduced standalone: a 200,000-deep frame exits with signal 139 (128+11 = SIGSEGV). This is reachable on the `RemoteTransport` reader thread: `readLoop` caps the frame at 16 MB (`RemoteTransport.swift:222`) but a sub-16 MB envelope of repeated `0x91` is ~8M deep — far past the crash threshold — and is handed straight to `reader.decode()` (`:233`). For the transport-agnostic remote-core goal this is a remote DoS that brings down the whole app, and it presents exactly as the "looks like an FFI/unwinding bug, is actually a Swift crash" class the project has been bitten by before.

**Fix:** Add a depth parameter (or `pos`-tracked depth counter) to `decode()` and throw a new `MsgPackError.tooDeep` once it exceeds a sane bound (e.g. 64 — deeper than any real core response). Add a teeth test that crafts an N-deep nested-array frame and asserts it `throws .tooDeep` rather than crashing, plus a boundary test at the limit that still decodes. Without the cap, no test can be written that passes without crashing — which is itself the tell that the guard is missing.

**VERDICT: CONFIRMED** — Reproduced standalone: a 200k-deep `0x91…0xc0` frame fed to the exact recursive `decode()`/`array()` exits with signal 139 (SIGSEGV). `decode()` (line 92) has no depth guard; the negative suite (`MsgPackDecoderNegative_…`) covers truncation/OOM-clamp/bad-tags/trailing only, zero depth; `RemoteTransport.readLoop`'s 16 MB cap (line 222) admits ~16M-deep nesting straight to `reader.decode()` (line 232). Remote-triggerable uncatchable crash.

### HTMLSanitizer `javascript:`-URL neutralization passes textbook XSS evasions; tests pin only the literal happy path

**Severity:** high

**Location:** `Sources/ViewerCore/HTMLSanitizer.swift:249` (`neutralizeJavaScriptURLs`); tests `Tests/ViewerCoreTests/HTMLSanitizerTests.swift:101-121`.

**Why:** The neutralizer matches `javascript`/`vbscript`/`data:text/html` *literally* in the attribute value. WebKit, however, decodes HTML entities and strips control characters from URL attributes before navigating. Reproduced standalone against the exact regexes — three payloads survive untouched while `<a href="javascript:alert(1)">` is correctly neutralized:

- `<a href="&#x6a;avascript:alert(1)">` — entity-encoded `j` → **UNCHANGED** (executes after WebKit decodes the entity).
- `<a href="java\tscript:alert(1)">` — tab inside the scheme → **UNCHANGED** (executes after WebKit strips the tab).
- `<a href="jav\nascript:alert(1)">` — newline inside the scheme → **UNCHANGED**.

The class docstring disclaims being a hard security boundary, but the *tests* assert the sanitizer DOES neutralize `javascript:` URLs, which manufactures false confidence that this layer stops scheme-based XSS when it stops only the unobfuscated form. There is no test for any obfuscated scheme. (This is both a missing-coverage gap and a real underlying defect; tagged here because the absent edge-case tests are what let the defect persist undetected.)

**Fix:** Before pattern-matching, normalize the candidate value: strip ASCII control chars (`\t\r\n\0` and the rest of `\x00-\x1f`) and decode numeric/named HTML entities for the scheme prefix, then re-check the leading token against the blocklist. Add tests for each evasion above (entity-encoded char, embedded tab, embedded newline, mixed-case-plus-entity) asserting the result is `about:blank`. Demonstrate teeth by confirming each test fails against the current regex.

**VERDICT: CONFIRMED** — Reproduced against the exact `quoted`/`unquoted` regexes (HTMLSanitizer.swift:252/256): plain `javascript:` → `about:blank`, but `&#x6a;avascript:`, `java\tscript:`, and `jav\nascript:` all survive UNCHANGED. The full `sanitize()` pipeline runs `neutralizeJavaScriptURLs` last over the raw string with no control-char strip / entity-decode upstream, so the evasions reach it intact. Tests (HTMLSanitizerTests.swift:101-121) assert only the literal happy path; no obfuscated-scheme test. Real defect (defense-in-depth layer, behind CSP + nav-policy delegate per the docstring) plus a genuine coverage gap that manufactures false confidence.

### Documented security-critical redaction paths (`thinking.signature`, `image.source`) have no test coverage

**Severity:** high

**Location:** `Sources/ViewerCore/ClaudeLogParser+SystemRecords.swift:43` (`redact`), `:78` (`redactImageSource`); existing redaction tests `Tests/ViewerCoreTests/ClaudeTranscriptSearchTests.swift:57` and `Tests/ViewerUITests/ClaudeTimelineRedactionTests.swift:42`.

**Why:** The file header (lines 8–14) enumerates three documented secrets that must never surface: `thinking.signature` (the *primary* extended-thinking crypto blob), `system.api_error.error.headers` (set-cookie carrier), and `image.source` (large base64 blob, must be truncated). The only redaction tests in the suite exercise the `headers` key inside a `tool_use` input. There is **no** test that:
1. Puts a `signature` inside a nested `thinking` content block and asserts it is replaced — the headlined threat.
2. Exercises `redactImageSource` at all — neither the string form (>256-byte blob collapses to a placeholder) nor the object form (`{data: <blob>}` truncation), and not the boundary at `maxImageSourceBytes`.

The recursion is key-name-driven so the *code* probably catches nested `signature`, but "probably" is exactly what a teeth test is for — a future refactor that, say, stops recursing into arrays-of-blocks would silently start leaking thinking signatures with the whole suite still green. The image-source truncation is wholly unverified, so a regression there (e.g. a blob leaking into the search index / timeline summary) would ship undetected.

**Fix:** Add focused redaction tests: (a) an assistant record with a `content[].thinking.signature` blob, asserting the surfaced/redacted object carries `[REDACTED]` and not the blob; (b) `redactImageSource` for both the >256-byte string form and the object `{data:…}` form, asserting the placeholder and that short refs (URLs) pass through; (c) a boundary case at exactly `maxImageSourceBytes`. These are pure `[String: Any]` transforms — fully host-testable, no VM.

**VERDICT: REFUTED** — The two headlined paths ARE covered. `ClaudeSessionIndexTests.test_redaction_stripsThinkingSignatureAndApiErrorHeaders` (line 209) puts a `signature` inside a nested `thinking` content block and asserts `ClaudeLogParser.redact(obj)` strips it (also `test_redaction_keepsThinkingTextAndErrorStatus` line 254, and `RustTranscriptAdapterTests.test_gateOn_redactionBarrierHolds` for nested-in-tool-input). `test_redaction_dropsLargeImageSourceBlob` (line 241) exercises `redactImageSource` directly on a 10 KB string-form source, asserting the "image source omitted" placeholder and no blob leak. The finding's two central claims ("NO test … signature in nested thinking", "exercises redactImageSource at all … neither string nor object form") are false. Only minor untested edges remain — the object `{data:…}` form and the exact 256-byte boundary — which do not support a "high"/"wholly unverified" framing.

### `ClaudeLogParser.parseTimestamp` does not guard non-finite Doubles; produces an invalid `Date` and is untested for it

**Severity:** medium

**Location:** `Sources/ViewerCore/ClaudeLogParser.swift:271-280` (`parseTimestamp`).

**Why:** `JSONSerialization` will hand back `Double.infinity` for a numeric timestamp like `-1e400` (reproduced: `-1e400` → `-inf`; note `+1e400` happens to fail JSON parse, but the negative does not). `Date(timeIntervalSince1970: -inf)` does not crash but yields a degenerate `Date` whose description is empty. That non-finite `Date` then flows into event sorting / timeline ordering, where `<` comparisons against `±inf`/NaN give undefined ordering — a silent correctness bug for a hostile or corrupt transcript. There is no test feeding `parseTimestamp` a non-finite or absurd numeric value; transcript input is explicitly an untrusted, "loose-y goose-y" format.

**Fix:** Guard the numeric branch with `if let n = raw as? Double, n.isFinite { return Date(timeIntervalSince1970: n) }` (and optionally clamp to a sane epoch range). Add a unit test passing `Double.infinity`, `Double.nan`, and an out-of-range value, asserting `nil` (treated as "no timestamp") rather than a degenerate `Date`.

**VERDICT: CONFIRMED** — Reproduced: `JSONSerialization` parses `{"ts":-1e400}` → `Double(-inf)`; `parseTimestamp` (no `isFinite` guard, line 276-278) returns `Date(timeIntervalSince1970: -inf)` whose `.description` is empty and interval is `-inf`. That `Date?` flows into `>=`/`<` comparisons (e.g. duration pairing `ClaudeMonitorLog.swift:239`, event ordering). No test feeds the private `parseTimestamp` a non-finite/absurd numeric, despite the transcript being an explicitly untrusted format. Real (silent-correctness) defect + genuine coverage gap; medium is fair.

### Windowed CSV snapshot (`snapshot_window_frame`) has no Rust unit test for its clamping edges

**Severity:** low

**Location:** `rust-core/crates/core/src/session.rs:227` (`snapshot_window_frame`); `session.rs` `mod tests` (9 tests, none named/touching `window`).

**Why:** This is a newer Phase-1-contract public API (the O(window) paging surface, TSK-559). Its clamping math — `offset.min(len)`, `start.saturating_add(limit).min(len)`, `.get(start..end).unwrap_or(&[])` — is the canonical place off-by-ones and underflow live, and it reads as correct, but it has **zero** dedicated Rust unit test (the sibling `tests/Audit_…_snapshot_frame.rs` covers the non-windowed `snapshot_frame`). The Swift round-trip `ABTests.testSnapshotWindowAndFilteredCount` does cover mid-range and offset-past-end, but not `limit == 0`, `offset == len` exactly, or `offset + limit` overflowing `usize` — and it tests via the FFI, not the unit, so a Rust-level regression in the clamp could be masked by encode/decode noise. Per the project's "every change ships with tests, cover all tiers that apply" mandate this clamping logic should have host-Rust teeth at the boundaries.

**Fix:** Add Rust `#[test]`s for `snapshot_window_frame` covering: `limit == 0` (empty window, total preserved), `offset == len` (empty), `offset > len` (empty), and `offset + limit` saturating past the visible set (returns the tail, not a panic). Pure-logic, host-runnable in the `rust-core-gate`.

**VERDICT: CONFIRMED** — `session.rs` `mod tests` (line 342, 9 `#[test]`s) has none touching `snapshot_window_frame`; the clamping is exercised only through the FFI (`ffi/src/tests.rs:498-557`: offset=0/50/95/200, limit=10/100_000/3). The three cited edges — `limit == 0`, `offset == len` exactly, and `offset + limit` saturating overflow — are untested at any layer, and there is no session-unit `#[test]` for the clamp math. Accurate, appropriately scoped "low".
