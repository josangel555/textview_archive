# Stage B — Swift twin deletion plan (TSK-649 endgame)

Stage A is complete: all ten capabilities route Rust by default; every Swift
engine twin is fallback-only. Stage B makes the deprecation real: delete the
twins, one owner-signed package per engine.

## The policy decision (owner gate)

When a twin is deleted, its capability's fail-safe fallback necessarily
retires with it. Proposed end state per engine:

- **The adapter collapses to a direct Rust call.** A bridge fault stops
  being "silently fall back to Swift" and becomes a typed, *visible*
  feature error (or a safe degraded value where one exists — e.g. indent
  `"—"`, find `[]`). Rationale: a permanent invisible fallback would keep
  the twin alive forever and mask Rust regressions; stage A's quiet soak is
  the evidence the Rust path holds.
- **The gate case + env var + Settings toggle for that capability retire.**
  No dual-engine routing remains to toggle.
- **A/B parity suites convert to GOLDEN suites**: the Swift oracle is gone,
  so the expected values are FROZEN from the current (already
  parity-proven) outputs. The cross-language behavior pins survive; only
  the oracle changes from "compute via Swift" to "literal expected values".
- **The twin's own unit tests retarget or retire** (their behavior pins
  move to the golden suites / rust unit tests, which already exist for
  every engine).

## Package contents (per engine, one commit, one owner review)

1. Delete the twin source file(s).
2. Collapse the adapter (or inline the wrapper call at consumers).
3. Remove the `RustCoreCapability` case + probe-test updates.
4. Convert the A/B suite to golden; retarget/retire twin unit tests.
5. Gate green + the engine's golden suite demonstrably has teeth.
6. `CoreCapabilities.requiredByShippingAdapters` gains the engine's bit
   (the linked core MUST now have it — no fallback exists).

## Proposed order (blast radius, smallest first)

| # | Engine | Twin file(s) | Notes |
|---|--------|--------------|-------|
| 1 | indent | `IndentDetector.swift` | one consumer; tiny; THE TEMPLATE |
| 2 | hex search | `HexSearchEngine.swift` | parse() helper stays (query→pattern is UI-side) |
| 3 | hex render | `HexDumpBuilder.swift` | windowed chunk build must move first OR stays until Phase-1 windowing |
| 4 | diff | `DiffParser`/`DiffHunkParser` | three consumers, all adapter-routed |
| 5 | csv | `CSVParser`/`CSVFilter` | the beachhead; session APIs are handle-based (DocId precondition?) — assess |
| 6 | fuzzy | `FuzzyMatcher.swift` | CARVE-OUT: `FileTreeFilter` still calls per-node `match` — must move to batch or keep a thin scorer |
| 7 | find | `FindEngine.swift` | ICU-fallback channel retires: lookaround/backref patterns become typed errors (BEHAVIOR CHANGE — owner must accept) |
| 8 | transcript | `ClaudeLogParser*.swift` | `ClaudeSessionIndex` uses record-classification helpers — those survive or port first (TSK-658 family) |
| 9 | markdown | `HTMLVisitor` structural | sanitizer/mermaid host/TreeSitter spans STAY (chunk contract); PARSE-03 guards retire with the cmark path |

Engines 5–9 carry real caveats (listed); 1–4 are clean. The recommendation
is to sign #1 (indent) as the template, review the diff, then batch-approve
2–4, with 5–9 each getting their caveat resolved in the package.

## What does NOT change

- The sans-IO core, the FFI surface, the capability bitmap (bits are ABI).
- mdv-serve / RemoteTransport (already Swift-twin-free).
- Host-coupled Swift: sanitizer (render trust boundary), TreeSitter (until
  TSK-660), MermaidSourceParser (already core-side for markdown; the Swift
  copy retires with #9), FSEvents/local IO.

## Risks

- **No fallback = Rust regressions surface as user-visible errors.** The
  mitigations are the golden suites + the engines' rust unit tests + the
  audit log's core-call failure events (TSK-636) making any fault loud.
- **The find ICU channel** (#7) is the one genuine behavior REMOVAL:
  today a lookbehind regex silently falls back to ICU and works; after
  deletion it errors. Acceptable for a viewer's find? Owner call.
