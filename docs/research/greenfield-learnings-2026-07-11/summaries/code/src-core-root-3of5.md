# ViewerCore Root Slice 3/5: Format Handling, Security, & Pure Logic (positions 103–153)

**Slice 3 focus:** Hex/JSON/HTML rendering; security policies (sanitizer, trust gates, binary confinement); pure line-diff engine; text processing utilities; storage & observation patterns.

---

## Files Analyzed (51 total)

**Sources/ViewerCore/HexLayout.swift** (69 LOC) — Hex viewer layout math: row/column counts, character offsets for hex/ASCII rendering.
- notable: Pure arithmetic, fence-aware terminator preservation; no UI imports.
- carry: **KEEP** — tight, reusable layout kernel; no format-specific lock-in.

**Sources/ViewerCore/HexSearchEngine.swift** (114 LOC) — Hex/ASCII search for binary files; non-overlapping match strategy (Sublime/VSCode convention).
- notable: Unsafe-byte loop for perf on Data; conservative on pattern validation.
- carry: **KEEP** — clean separation of parse + find; migration-safe for either viewer or standalone tool.

**Sources/ViewerCore/HistoryContentFilter.swift** (162 LOC) — Secret/binary detector for Local History: NUL-byte check, control-char ratio, credential pattern matching.
- notable: Conservative vendor-token prefixes (ghp_, ghs_, sk-ant_, AIza, etc.); assignment-pattern syntax check; bounded prefix scan (256KB).
- carry: **KEEP** — polished, production-grade secret detection; appropriate for any file-capture gate.

**Sources/ViewerCore/HistoryStore.swift** (176 LOC) — Recently opened files persistence (path-keyed, newest-first, capped list).
- notable: `pruneMissing` filesystem check is injectable; forward-compat `Kind` decode is lenient (unknown → `.file`).
- carry: **KEEP** — stable API, testable pattern; applies to any recents list.

**Sources/ViewerCore/HorizontalScrollerVisibility.swift** (157 LOC) — CM6 horizontal scroller hysteresis state machine.
- notable: Pure, host-testable; fixes the `overflow: auto` flap via asymmetric dead-band (show 2px, hide 8px); handles zero viewport gracefully.
- carry: **KEEP** — excellent boundary-condition design; exemplary UI state machine for rebuild.

**Sources/ViewerCore/HotExitSpill.swift** (86 LOC) — Large unsaved-buffer spill: FNV-1a-64 path hash, 1 MB inline→spill threshold.
- notable: Stable path hash (not tab-id), pruning via path-key set.
- carry: **KEEP** — clean spill pattern; applies to any hot-exit buffer management.

**Sources/ViewerCore/HTMLDocumentPolicy.swift** (362 LOC) — Security policy for rendering untrusted `.html` files: L0 size cap, L1 sanitizer, L2 JS default-deny, L3 CSP + sub-resource policy, L4 link policy.
- notable: **Defense-in-depth:** six independent layers; CSP as fail-closed meta-tag; TSK-1189 trust mode relaxes script-src but NOT exfil fence (`connect-src 'none'`); path-containment check mirrors sanitizer logic.
- carry: **KEEP** — exemplary security architecture; production-grade reference for any sandboxing rebuild.

**Sources/ViewerCore/HtmlExport.swift** (140 LOC) — Standalone HTML export with looser CSP (permits `img-src https:`), inline-image base64 conversion.
- notable: TSK-966 two-layer defense: render in `.escape` mode (no live markup) + CSP envelope.
- carry: **KEEP** — clean export pattern; migration-safe from Rust.

**Sources/ViewerCore/HTMLRenderer.swift** (250+) — Markdown→HTML via `RustMarkdownAdapter` (the Swift visitor was deleted TSK-649); retains utility surface: `htmlEscape` (byte-level perf), slug logic, highlight-run spanning.
- notable: PARSE-03 leading-nesting guards (deprecated post-port); PERF-06-escape byte-walk beats grapheme cost.
- carry: **KEEP** (utilities); **REDO** (if Rust engine changes output format).

**Sources/ViewerCore/HTMLSanitizer.swift** (250+) — HTML allowlist: drops `<script>/<style>/<iframe>/…`, strips `on*=` handlers, neutralizes `javascript:`/`vbscript:`/`data:text/html` URLs.
- notable: WV-3 quote-aware tag-end tokenizer; H1b handler anchor handles `href="x"onclick=…` and `<svg/onload=…>` boundary cases; iterates tag bodies to avoid double-escaping.
- carry: **KEEP** — robust regex-free DOM-free sanitizer; single-sourced with `HTMLSanitizerPolicy`.

**Sources/ViewerCore/HTMLSanitizerPolicy.swift** (54 LOC) — Single-source truth for native/web sanitizer parity: dropped elements, trusted-kept elements, URL-bearing attributes, dangerous schemes.
- notable: Wire contract serialized to `schemas/html-sanitizer-policy.json` for Rust parity; guard test `HTMLSanitizerPolicyGuardTests` enforces divergence.
- carry: **KEEP** — excellent cross-subsystem consistency pattern; model for any multi-language feature.

**Sources/ViewerCore/HTMLTrustPolicy.swift** (142 LOC) — Trust gate for local .html: eligibility check (file-URL, not quarantined), per-document opt-in, path-keying (symlink-resolved).
- notable: TSK-1189 trust mode; `FileQuarantine` xattr read for download flag; TSK-1203 network consent store (per-document allowed https origins, CSP validated).
- carry: **KEEP** — well-designed trust escalation + network-consent separation; production-grade security model.

**Sources/ViewerCore/HTTPClientCore.swift** (250+) — HTTP client foundation: request model, URL/method/header validation, response parsing, timeout clamping.
- notable: No dependency; header deduplication via `addValue` (preserves Set-Cookie repeats); body applied only when method allows; all errors are typed + user-facing message.
- carry: **KEEP** — clean, testable API; migration-safe design.

**Sources/ViewerCore/HTTPRequestStore.swift** (233 LOC) — HTTP history & saved requests: newest-first, content-dedup signature (ignores ephemeral row UUIDs).
- notable: Two-file store (history.json + saved.json); per-file byte cap; lenient array decode (PERSIST-02); off-main coalesced writes via `JSONFileStore`.
- carry: **KEEP** — applies to any request-builder history/save pattern.

**Sources/ViewerCore/HunkReviewState.swift** (43 LOC) — Agent diff hunk approval/rejection state: toggle per hunk, resolve via `AgentDiffApply`.
- notable: Data-safety guard for file-write feature; state-based not imperative.
- carry: **KEEP** — clean hunk model; applies to any review UI.

**Sources/ViewerCore/IndentConverter.swift** (93 LOC) — Tab↔space conversion: preserves alignment tabs post-first-nonwhitespace, preserves terminators (LF/CRLF/CR) per-line.
- notable: Scalar walk (CRLF-grapheme trap handled); flushing pattern; line-local transform.
- carry: **KEEP** — solid, reusable indent tool.

**Sources/ViewerCore/IndentStyleDetector.swift** (63 LOC) — Detect dominant leading-indent style (tabs vs spaces + width): GCD-ish heuristic (minimum indent step).
- notable: Heuristic robust to 2/4/8; ignores 1-space continuations & trailing spaces; good quality signal.
- carry: **KEEP** — practical, low-cost detector.

**Sources/ViewerCore/InFileCompletion.swift** (69 LOC) — Zero-server fallback completion: in-file identifier extraction, frequency+length+alphabetical ranking.
- notable: Handles cursor position; omits digit-leading runs; configurable limit.
- carry: **KEEP** — solid fallback; applies to any editor without LSP.

**Sources/ViewerCore/InFileSearch.swift** (43 LOC) — In-file literal search: case-insensitive, line-number preserving (via `enumerateLines` to handle CRLF/CR).
- notable: Clean API; handles CRLF correctly (doesn't split on \n alone).
- carry: **KEEP** — reusable, correct text search.

**Sources/ViewerCore/InsertionOrderedCache.swift** (68 LOC) — Insertion-ordered FIFO-eviction cache: batch eviction (cap → 2/3 cap on overflow, not full wipe).
- notable: TSK-591 fix: old policy thrashed caches whose working set > cap; batch eviction keeps hot recent entries resident.
- carry: **KEEP** — production-grade cache pattern; applies to sidebar icon/repo caches.

**Sources/ViewerCore/InstanceRegistry.swift** (230 LOC) — CLI↔GUI instance discovery: filesystem-based pid records, liveness probe, message encoding for remote transport.
- notable: Pure encode/decode; injectable liveness; discovery self-heals (prunes stale pids); protocol versioning.
- carry: **KEEP** — clean transport-agnostic model; foundation for multi-instance coordination.

**Sources/ViewerCore/InteractionProfiler.swift** (168 LOC) — Per-interaction felt-perf measurement: frame percentiles (p50/p95/p99/worst), per-kind budget verdicts, rolling history.
- notable: TSK-1488 numbers-based perf flagging (p95 budget vs observed); nearest-rank percentiles; MDV_PERF_HUD env gate.
- carry: **KEEP** — excellent perf observability model; applies to any interaction-traced app.

**Sources/ViewerCore/JQRunner.swift** (132 LOC) — Out-of-process jq filter runner: PATH probing, CPU/file-size/fd/output rlimits, wall-clock timeout + RLIMIT_CPU defense-in-depth.
- notable: CR-05 / SCALE-2 output cap (256 MB); refuses truncated results; robust resource-limit config; ProcessRunner integration.
- carry: **KEEP** — exemplary subprocess safety pattern; applies to any untrusted filter tool.

**Sources/ViewerCore/JsonConvert.swift** (73 LOC) — JSON array-of-objects to CSV: union of columns, sorted, RFC-4180 quoting, nested objects as compact JSON.
- notable: Numbers compact (no decimals for integers < 1e15); null/missing empty; deterministic (sorted keys).
- carry: **KEEP** — solid conversion; migration-safe from Rust.

**Sources/ViewerCore/JSONFileStore.swift** (212 LOC) — Shared JSON read/write/coalesce utilities: max-size guard, lenient array decode (PERSIST-02), atomic+durable writes (fsync + directory fsync), off-main coalesced queue per URL.
- notable: P2 (main-thread I/O) solved via serial DispatchQueue + coalescing; `flushSync()` for `applicationWillTerminate`; FailableDecodable pattern for robustness.
- carry: **KEEP** — production-grade JSON persistence layer; applies to any persisted-list pattern.

**Sources/ViewerCore/JSONSyntaxChecker.swift** (202 LOC) — Pure RFC-8259 validator: line/column reporting, depth-cap (512, PARSE-03 lesson), escape/number/literal validation.
- notable: Bounds-checks prevent infinite recursion; structural validation (no value materialization); clear error messages.
- carry: **KEEP** — exemplary JSON validator reference.

**Sources/ViewerCore/JSStringEmbedding.swift** (34 LOC) — Escape U+2028/U+2029 (line/para separators) for JavaScript string embedding.
- notable: Idempotent (escapes already valid); common hazard (PDF→Markdown, Word paste, LSP docs).
- carry: **KEEP** — critical safety utility for any JS eval embedding.

**Sources/ViewerCore/JSTransform.swift** (160 LOC) — Pure JS transform over JSON: ECMAScript-only sandbox (no fetch/require/DOM), async off-main + soft timeout, input format support (json/lines/csv).
- notable: TSK-698 slice 2 approach B (race eval vs timeout); OneShot continuation guard; input preparation for logs/CSV.
- carry: **KEEP** — clean sandbox + timeout pattern; applies to any user-script safety.

**Sources/ViewerCore/LaunchArgs.swift** (59 LOC) — Command-line arg parser: positional paths, flag-with-value consumption.
- notable: Simple positional model; injectable via static parse().
- carry: **KEEP** — minimal, correct CLI parsing.

**Sources/ViewerCore/LaunchpadSections.swift** (53 LOC) — New-tab launchpad section model: build from recents + bookmarks, dedup by path, cap per section.
- notable: Clean builder pattern; empty sections omitted.
- carry: **KEEP** — reusable launchpad data model.

**Sources/ViewerCore/LaunchpadSelection.swift** (53 LOC) — Launchpad keyboard-nav state: omni field (nil) vs row index, up/down movement with clamping.
- notable: Simple state machine; reclamping after list changes.
- carry: **KEEP** — solid nav model; applies to any palette/menu.

**Sources/ViewerCore/LineAgeColoring.swift** (95 LOC) — Git blame age→color ramp: DarkBlue (old) to LightBlue (recent), with untracked green; parses git blame --line-porcelain.
- notable: Bucket-based age bucketing (hours/days/weeks/months/year); Lerp interpolation; handlesMissing/uncommitted lines.
- carry: **KEEP** — production-grade blame visualization model.

**Sources/ViewerCore/LineDiff.swift** (250+) — Optimal line-diff engine (Myers O(N·D), linear-space Hirschberg): intern lines → int ids, trim common prefix/suffix, divide-and-conquer edit script, serialisable patch format.
- notable: **TSK-1103:** size-guard (1 MiB cap on diff inputs) + O(N) memory prevents the O(n·m) matrix 77 GB runaway when diffing multi-MB versions; two faces (hunks for UI, patch for storage); context-line config.
- carry: **KEEP** — exemplary diff engine; applies to any version/delta system.

**Sources/ViewerCore/LineEndingConverter.swift** (59 LOC) — Normalize line endings: scalar-walk to split CRLF pairs correctly, apply target terminator per line, preserve final newline state.
- notable: Handles lone CR (classic Mac); preserves trailing newline decision.
- carry: **KEEP** — correct, reusable conversion.

**Sources/ViewerCore/LineEndingDetector.swift** (78 LOC) — Detect dominant line ending: CRLF/CR/LF/mixed/none, with optional bounded sample for large files.
- notable: Scalar-based (CRLF-grapheme trap avoided); sample cap for hot-path status-bar use.
- carry: **KEEP** — efficient, correct detector.

**Sources/ViewerCore/LineOps.swift** (92 LOC) — Whole-file line operations: sort, reverse, remove duplicates, remove empty, collapse blank-line runs.
- notable: Preserves trailing-newline state and dominant line ending; scalar-walk for terminator preservation.
- carry: **KEEP** — solid batch line-edit operations.

**Sources/ViewerCore/LocalHistoryPolicy.swift** (143 LOC) — Local history capture policy: default-ON, 50 versions/file, 20 MB/file, text-only, exclude `.env`/`*.pem`/`*.key`/credential-named files.
- notable: Owner policy codified as pure decision gates; env override; comprehensive secret filename list; `HistoryContentFilter` integration for both path + content detection.
- carry: **KEEP** — production-grade policy enforcement pattern.

**Sources/ViewerCore/LocalHistoryStore.swift** (250+) — On-disk local file version history: adaptive representation (full snapshot vs diff, store smaller), FNV-1a-64 path→dir hashing, size-guard on diff, byte-cap pruning.
- notable: **TSK-1103:** anchor model (diffs only against nearest full snapshot, O(1) reconstruct cost), size-guard caps diff inputs at 1 MiB (product-layer bound on 77 GB runaway), per-file 20 MB budget with oldest-first pruning + orphaned snapshot promotion.
- carry: **KEEP** — exemplary versioning + storage layer; applies to any delta-based persistence.

**Sources/ViewerCore/LocalHistoryVersionSource.swift** (132 LOC) — VersionSource bridge over LocalHistoryStore: list/content/diff/cumulative APIs, diff-vs-current via `UnifiedDiffGenerator`.
- notable: Live `currentContent` closure; timestamps as sort keys; id-based version mapping.
- carry: **KEEP** — applies to any version viewer integration.

**Sources/ViewerCore/LogPatternClusterer.swift** (233 LOC) — Auto-cluster recurring log patterns: token-by-token masking (timestamp, UUID, IPv4, hex, number, quoted), Drain-style template bucketing.
- notable: **Order matters:** specific patterns (ISO timestamp) before generic (number); masked form is bucket key; frequency-ranked + tie-break by first-seen index for determinism.
- carry: **KEEP** — exemplary log-analysis pattern; applies to any log viewer.

**Sources/ViewerCore/LSPBinaryTrust.swift** (63 LOC) — Workspace-local LSP binary security gate: path containment check (standardized, symlink-resolved, trailing-separator boundary).
- notable: Pure decision; mirrors `HTMLDocumentPolicy.isWithinDocumentTree`; symlink resolution means a binary linking OUT of tree is judged by real path.
- carry: **KEEP** — exemplary path-confinement primitive; applies to any in-workspace tool trust.

**Sources/ViewerCore/LSPTrustPrompt.swift** (23 LOC) — One-time trust prompt handler stub: callback injection, fails closed when no handler installed.
- notable: Deliberate no-op for headless contexts (automation, CI).
- carry: **KEEP** — minimal harness design.

**Sources/ViewerCore/LSPTrustStore.swift** (107 LOC) — Persisted LSP binary trust grants: per-workspace-local-binary, canonicalized paths, persistence via sorted JSON, grant/revoke/decision API.
- notable: Thread-safe via lock; max-entry cap guards against runaway files.
- carry: **KEEP** — production-grade trust store pattern.

**Sources/ViewerCore/MarkdownHeadingShift.swift** (101 LOC) — Promote/demote headings: delta-based level shift, fence-aware (``` / ~~~), HTML-comment-aware, preserves indentation + line terminators.
- notable: Scalar walk for CRLF-grapheme trap; CommonMark tab=4-col stops; detects indented code blocks (≥4 spaces → not a heading).
- carry: **KEEP** — solid, fence-aware text transform.

**Sources/ViewerCore/MarkdownLinks.swift** (181 LOC) — Extract & check local Markdown links: inline link/image extraction, bracket-depth/paren-depth-aware, inline-code-span skipping, reference-link/indented-code NOT modeled.
- notable: Backslash-escape handling; optional title dropping; broken-local-links filter via injectable `exists` predicate.
- carry: **KEEP** — production-grade link extractor; applies to any docs maintenance.

**Sources/ViewerCore/MarkdownLint.swift** (67 LOC) — Quality linter: image-alt (accessibility), heading-skip (outline shape), dup-anchor (GitHub slug collisions).
- notable: Uses `MarkdownOutline`/`MarkdownLinks`/`MarkdownTOC` (no vendor dep); small, focused rules.
- carry: **KEEP** — exemplary composable linter design.

**Sources/ViewerCore/MarkdownOutline.swift** (250+) — Heading outline extraction: ATX + setext, fence-skip, YAML front-matter skip, HTML-comment-aware, LSP document symbols generation.
- notable: Scalar-based line-split (CRLF trap); covers core CommonMark subset; setext underline as level 2; supports both lazy-initialization (just headings) and LSP tree-building.
- carry: **KEEP** — excellent outline parser; applies to any markdown-aware tool.

**Sources/ViewerCore/MarkdownOverview.swift** (200+) — Minimap model: segment + band projection, density calculation (blank-line ratio), click↔line mapping, viewport marker.
- notable: Segments = block boundaries (headings), bands = pixel projection; proportional scaling; clamping for rounding gaps.
- carry: **KEEP** — clean minimap geometry model; applies to any document visualization.

**Sources/ViewerCore/MarkdownPreviewMap.swift** (250+) — Source line ↔ rendered block ordinal alignment for scroll-sync: ordinal-based (not sourcepos), split source into blocks, positionally pair with rendered blocks.
- notable: Graceful clamping when counts diverge; round-trip property (line→block→line returns start line); block→line is inverse.
- carry: **KEEP** — elegant alignment model for split-view sync.

**Sources/ViewerCore/MarkdownSpellMask.swift** (66 LOC) — Exclude code ranges from spell-check: fenced blocks + inline backticks, union ranges, filter spell issues to prose only.
- notable: Regex match for inline code; line-enumeration for fence state.
- carry: **KEEP** — applies to any spell-check integration.

**Sources/ViewerCore/MarkdownTOC.swift** (96 LOC) — Generate & insert idempotent TOC: `<!-- toc -->` markers, nested bullet list, GitHub-style anchor deduplication (`slug`, `slug-1`, `slug-2`), front-matter-aware insertion.
- notable: Aligns slug generation with renderer's `HTMLVisitor.uniqueSlug` (double-source truth risk, but codified in policy).
- carry: **KEEP** — solid TOC generation; applies to any docs editor.

---

## Module Summary

This slice handles **formats, security, and pure logic**:

1. **Hex/Binary Viewers** (HexLayout, HexSearchEngine): Clean, reusable layout + search kernels.
2. **HTML Security** (HTMLDocumentPolicy, HTMLSanitizer, HTMLTrustPolicy, HtmlExport): Defense-in-depth exemplars (six layers, policy codification, trust escalation).
3. **JSON/HTTP** (JSONSyntaxChecker, JSONFileStore, HTTPClientCore, HTTPRequestStore): Production-grade parsers, cleanly typed errors, off-main I/O coalescing.
4. **Markdown Tooling** (MarkdownOutline, MarkdownLinks, MarkdownLint, MarkdownTOC, MarkdownHeadingShift, MarkdownSpellMask, MarkdownPreviewMap, MarkdownOverview): Composable parsers, fence-aware, CRLF-trap-conscious.
5. **Pure Logic Engines** (LineDiff, LogPatternClusterer, IndentDetector, LineAgeColoring): Exemplary algorithm implementations with clear trade-offs.
6. **Persistence & Observation** (LocalHistoryStore, LocalHistoryPolicy, HTTPRequestStore, JSONFileStore, InteractionProfiler, LSPTrustStore): Production-grade patterns for versioning, metrics, and trust.
7. **Security Gates** (LSPBinaryTrust, HTMLTrustPolicy, HistoryContentFilter): Fail-closed design, testable decision kernels.

### Design Patterns Worth Porting
1. **Defense-in-depth:** HTMLDocumentPolicy layers six independent checks (size, sanitizer, JS default-deny, CSP, sub-resource, link). Each is testable independently; combined, they're nearly unbreakable.
2. **Policy codification:** HTMLSanitizerPolicy single-sources policy to a wire contract (`schemas/html-sanitizer-policy.json`), synced with Rust; guard tests enforce divergence.
3. **Fail-closed defaults:** Trust policies assume untrusted unless explicitly opted in (LSP binaries, .html files, network consent).
4. **Scalar-walk for line-splitting:** CRLF-grapheme trap avoided by walking Unicode scalars, not Characters; enables correct terminator preservation across LF/CRLF/CR.
5. **Injection testing:** File-existence checks, liveness probes, spell-check filters all take injectable predicates → pure logic, fully testable without I/O.
6. **Off-main coalesced writes:** JSONFileStore serializes bursty writes to one per URL, drains via `flushSync()` on shutdown; applies to any persisted-list pattern.
7. **Adaptive storage:** LocalHistoryStore chooses full-snapshot vs diff (store smaller); size-guard (1 MiB cap) + product-layer bounds on diff inputs prevents algorithmic runaway.
8. **Boundary-condition state machines:** HorizontalScrollerVisibility's asymmetric hysteresis (show 2px, hide 8px) is the "how to avoid a state machine's flickering" template.

### Anti-Patterns / Regrets
1. **Double-sourcing policy:** MarkdownTOC / MarkdownLint slug generation reads from HTMLVisitor (the old Swift renderer) rather than a Rust-core source. When the Rust engine's slug changes, both must update. Guard tests exist but coupling is fragile.
2. **Enum-based config + inheritance trap:** LaunchArgs, LocalHistoryPolicy use enum + static func patterns that don't compose well with subclassing; a rebuild might use a struct builder or trait-based config.
3. **Large file handling in memory:** HTMLSanitizer, HTMLRenderer do regex operations over the entire document; multi-MB files can stall the main thread. Mark for potential async refactor.
4. **Pure vs side-effect mix in discovery:** InstanceRegistry.discover() prunes stale pids as a side-effect while discovering; cleaner to separate discovery (pure) from pruning (side-effect).

### Gotchas & Surprises
1. **CRLF-grapheme-cluster trap:** At least ten files (LineOps, LineEndingDetector, LineEndingConverter, MarkdownOutline, MarkdownHeadingShift, MarkdownLinks, MarkdownPreviewMap, LineAgeColoring, LogPatternClusterer) document scalar-walk fixes for Swift's treatment of `\r\n` as a single Character. All future text-processing code must adopt this.
2. **The 77 GB linediff runaway (TSK-1103):** Full history of a 262k-line file with O(n·m) DP matrix → 550 GB nominal memory, ~77 GB compressed. Fixed by: trim common pre/suffix → intern lines → Myers O(N·D) linear-space. Size-guard (1 MiB cap) + product-layer bound ensure the diff never runs on huge inputs. **Any rebuild must port or re-validate this fix.**
3. **`overflow: auto` flap (TSK-895):** HorizontalScrollerVisibility's asymmetric hysteresis kills the classic "long line nudges scrollbar visible/hidden on keystroke" flicker. Not obvious until tested live.
4. **JSON fsync fragility (TSK-1011):** JSONFileStore's writeDurably fsyncs the temp file BEFORE rename and fsyncs the directory AFTER. Data.write(.atomic) alone leaves truncated files after crash. **Any rebuild must use this pattern.**
5. **LSP binary "workspace-local" detection:** Path containment requires symlink resolution (a binary linking OUT of the workspace is unsafe) AND trailing-separator boundary (so `/ws` doesn't match `/ws-evil`). Subtle but load-bearing.

---

## Rebuild Considerations

### What to Keep Intact
- **Markdown parsing:** Outline, links, lint, TOC are composed, castle-tested, and vendor-free. Use them directly or rebuild only if the Rust engine output changes incompatibly.
- **Line-diff engine:** The Myers implementation + size-guard combo is irreplaceable for version storage without runaway. Keep as-is or verify any port preserves O(N) memory.
- **Security primitives:** HTMLDocumentPolicy, LSPBinaryTrust, HTMLTrustPolicy have no industry equivalents in simplicity. Copy the architecture, not just the code.
- **JSON I/O:** JSONFileStore's coalesced-write + durable-fsync pattern applies to every persisted list. Use it verbatim or lose data-safety guarantees.

### Where Redesign is OK
- **Markdown renderer:** If porting to Rust-core, swap the HTMLRenderer output consumer (e.g., if Rust emits sourcepos attributes, rebuild MarkdownPreviewMap to use them instead of ordinal alignment).
- **Local history store:** Current on-disk format (header JSON + payload) is stable but not optimal. A rebuild could optimize the record format (e.g., msgpack) as long as the anchor model (diffs vs full, reconstruction O(1) reads, byte-cap pruning) survives.
- **Indent/line-ending detection:** Current heuristics are production-proven but could evolve (e.g., machine-learning-based indent detection); keep the interface.

### Architecture Recommendations for Rebuild
1. **Separate policy from enforcement:** HTMLSanitizerPolicy worked because it's just data + contract validation. Do this for any security/config decision.
2. **Inject all I/O:** File existence, process liveness, DNS resolve — make them injectable closures for testability.
3. **Codify cross-subsystem contracts:** When two subsystems (native sanitizer + Rust sanitizer, source outline + renderer block boundaries) must agree, version + guard the contract at build time.
4. **Use value semantics for state machines:** HorizontalScrollerVisibility, LaunchpadSelection are easier to test and reason about than class-based state holders.
5. **Line-process text as scalars, not Characters:** Document this in a README and cite the CRLF-grapheme trap; new developers will re-invent the bug otherwise.

---

## Quality Signals

- **Testability:** ~85% of this slice is pure logic (no I/O, no UI). Host-gate green is high-signal for correctness.
- **Documentation:** Security decisions (HTMLDocumentPolicy, LSPBinaryTrust) have inline 2–3 page preambles. Production-ready quality.
- **Error handling:** All user-facing APIs return typed errors with messages (HTTPClientCore, JSONSyntaxChecker, JSTransform). No generic exception spam.
- **Robustness:** Lenient JSON decode (PERSIST-02), injectable predicates for I/O, fail-closed defaults on trust gates. Designed to degrade gracefully, not crash.

