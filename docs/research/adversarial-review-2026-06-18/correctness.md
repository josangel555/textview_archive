# Adversarial Correctness Review — TextView / MarkdownViewer (2026-06-18)

I hunted for real, production-biting correctness defects across the highest-risk surfaces in both
the Rust core (`rust-core/crates/`) and the Swift packages (`Sources/`): the `extern "C"` FFI
boundary, the hand-rolled JSON / MessagePack codecs, the diff/hex/find/transcript parsers, the
CodeMirror edit applier and its UTF-16 offset math, the terminal ANSI parser (hostile input), the
CSV session windowing, the highlight-run byte→UTF-16 conversion, the git graph layout, and the
arithmetic-heavy view-layer geometry. The overall finding is that this codebase has an unusually
**low correctness-defect density** — it is visibly audit-hardened: edge cases are pinned in tests,
the Rust side runs a no-panic discipline with `saturating_*`/`try_from`-clamp everywhere, integer
inputs from C are clamped at the edge (`MAX_HEX_WIDTH`, hunk `MAX_COORD`, depth caps), and the Swift
side guards nearly every `removeFirst`/`max()!`/`first!` and divide site. The handful of genuine
issues below are the residue after that hardening; none is a crash on normal input, but each is a
real behavioral defect on hostile or boundary input.

### Hand-rolled JSON number parser accepts malformed numbers `JSONSerialization` rejects (parity gap)

**Severity:** medium

**Location:** `rust-core/crates/core/src/json.rs:264-300` (`Parser::number`)

**Why:** The transcript projection has a Swift twin (`Sources/ViewerCore/ClaudeLogParser.swift`) that
decodes JSONL through Foundation's `JSONSerialization`, and the Rust port (`json.rs`, owner-decided
"no `serde_json`") is documented to hold "Foundation parity" / "conservative semantics" (module doc
lines 1-21). The number grammar diverges from strict JSON (and from `JSONSerialization`) in two ways:

  1. **Leading zeros accepted.** `number()` does `while digits` with no leading-zero rule, so `0123`
     parses as `Int(123)`. Strict JSON (and `JSONSerialization`) reject `0123`.
  2. **Trailing decimal point / missing fractional digit accepted.** After consuming `.`, the parser
     does another `while digits` that may match zero digits, so `1.` parses as `Float(1.0)`. JSON
     requires at least one digit after `.`; `JSONSerialization` rejects `1.`.

The grammar also does NOT require a digit before `.` (e.g. `-` alone is correctly rejected because
`"-".parse::<i64>()`/`f64` both fail, but a token like `-.5` would surface differently). The net
effect: a transcript record whose JSON contains a malformed number is **parsed by the Rust core but
skipped by the Swift twin** (or the reverse for a case `JSONSerialization` happens to accept). Because
both sides are *tolerant* (malformed line → skipped, never fatal), the user-visible symptom is a
transcript record/event appearing in one front-end (TUI / web / Rust-backed path) but not the other —
a silent A/B parity break that the corpus test may not cover for adversarial number tokens. It is
also a latent correctness hole if any consumer ever treats a Rust-parsed number as canonical.

**Fix:** Tighten `number()` to the JSON grammar: reject a leading `0` followed by another digit
(allow bare `0`, `0.x`, `0e…`), and require ≥1 digit in the fractional and exponent parts (track a
`saw_frac_digit` / `saw_exp_digit` bool and `err("invalid number")` if a `.`/`e` is not followed by a
digit). Add tests for `0123`, `1.`, `-.5`, `1e`, `01.5` asserting `is_err()` so the parity contract
has teeth.

**CONFIRMED** — empirically reproduced: Rust accepts `0123`→Int(123), `1.`→Float(1.0), `-.5`→Float(-0.5),
`01.5`→Float(1.5) while `JSONSerialization` returns nil for all (and drops the whole record at
`ClaudeLogParser.swift:176` via `try?`). Real A/B parity divergence. (Minor: `1e` is already
rejected by Rust's f64 parse, so it's the wrong teeth-test example, but the gap itself is real.)

### `CMEditApplier` overlap check accepts two zero-length inserts at the same offset (order-dependent divergence)

**Severity:** low

**Location:** `Sources/ViewerCore/CMEditApplier.swift:49-54,63-69`

**Why:** The overlap guard is `if e.from < lastTo { return nil }` with `lastTo` initialized to `-1`
and updated to each edit's `to`. For two pure insertions at the same offset (`{from:5,to:5}` and a
second `{from:5,to:5}`), the second passes the guard (`5 < 5` is false), so both are applied. The
build loop then emits both inserts back-to-back at cursor 5, in the batch's *sorted* order. The sort
comparator is `from` asc, then `to` asc (line 42-45) — but two identical `(from,to)` pairs are sorted
only by Swift's *stable* sort, i.e. their original array order. CM6's reducer applies same-position
inserts in *transaction* order, which after a debounce-window accumulation in JS may not equal the
array order this code sees. The doc claims "byte-identical to what CM6 produces from the same batch,"
but for the colliding-zero-length-insert case the concatenation order is whatever order the two edits
happen to sit in the input array, which can diverge from CM6. Since the divergence later trips the
`contentLength` mismatch → full-text resync, it self-heals; hence low severity, not a corruption. But
the "byte-identical" guarantee is not actually held for this input shape.

**Fix:** Either (a) reject the case explicitly — treat `e.from < lastTo || (e.from == lastTo &&
e.to == e.from && previousWasZeroLengthInsertAtSamePoint)` as an overlap and return `nil` to force a
resync, or (b) document that same-offset zero-length inserts are order-defined-by-array and add a test
proving the chosen order. Given the resync fallback already exists, (a) is the safer call and keeps
the "byte-identical" claim honest.

**REFUTED** — the colliding-insert input shape is not producible by the real encoder: the JS bridge
ships a *composed, normalized* CM6 `ChangeSet` via `iterChanges` (`codemirror.html:128-138,165`), which by
CM6's contract yields non-overlapping position-sorted changes with no duplicate-offset entries. And for
a genuine multi-change array dispatch, CM6 itself applies same-offset inserts in array order — exactly
what the applier does — so the "byte-identical" claim holds. No divergence.

### `GraphLayout` lane-cap check can return `nil` one row late for a merge that opens multiple new lanes

**Severity:** low

**Location:** `Sources/ViewerCore/Git/GraphLayout.swift:36-86`

**Why:** The function is documented to return `nil` when "any row would need more than `maxLanes`
active concurrent lanes" so the caller falls back to a flat list. The cap is checked twice: after
finding/opening the commit's own lane (line 49) and after placing parents (line 68). The
parent-placement loop (lines 58-67) can `lanes.append(parent)` multiple times for a multi-parent merge
(an octopus merge with N parents, each not already present, appends up to N lanes). The width is only
re-checked once *after* the whole loop (line 68), and the final compaction (line 73) trims trailing
nils, so `lanes.count` after compaction can be ≤ the transient peak. Concretely, `observedMax` (lines
80-82) is computed from `before.count`/`after.count`, but the *transient* mid-row width during the
merge expansion (before compaction) is never measured against `maxLanes` per-parent — only the
post-loop `lanes.count`. For a row whose parents fan out wide then several parents are already-present
(so they `continue` and get compacted away), the post-loop count can pass `maxLanes` even though the
row genuinely needed more than `maxLanes` lanes mid-placement. The renderer would then draw a row
wider than the 4-lane cap it promised the caller, instead of bailing to the flat list.

**Fix:** Check `lanes.count > maxLanes` *inside* the parent loop immediately after each `append`
(return `nil` on the first over-cap append), not only once after the loop. Add a test with an
octopus merge (≥5 parents, none pre-present) at `maxLanes:4` asserting `layout(...) == nil`.

**REFUTED** — `lanes.count` is monotonically non-decreasing through the parent loop (appends grow it;
`continue` / in-place `lanes[free]=parent` never shrink it), and the compaction (`removeLast` of
trailing nils, line 73) runs *after* the cap check at line 68. So the post-loop check equals the true
mid-row peak; compaction cannot mask an over-cap. Verified: octopus-6-parents returns nil, and a
200k-DAG fuzz found zero cases where true peak > 4 but the function returned non-nil.

### `MsgPackValue` equality treats positive `int` and `uint` of the same value as unequal

**Severity:** low

**Location:** `Sources/RustCore/MessagePack.swift:26-41`

**Why:** The hand-rolled `==` has separate `.int`/`.uint` arms and a catch-all `default: return false`,
so `.int(5) != .uint(5)`. MessagePack does not canonicalize: a non-negative value can legitimately be
decoded as `.int` (from `0xd0..0xd3` / negative-fixint path) or `.uint` (positive fixint / `0xcc..cf`),
and the *decoder here actually produces both* — positive fixint `0x00..0x7f` decodes to `.uint`
(line 95) while `0xd0` signed-int-8 of a positive value decodes to `.int` (line 104). So two frames
encoding the same logical non-negative number with different tags compare unequal. Today this is
test-only (a grep shows no production dedup/`Set`/`firstIndex` over `MsgPackValue`), so the blast
radius is a potentially flaky/false-negative wire round-trip assertion if a frame's integer tagging
ever changes — not a live bug. Flagged because it is a real equality-invariant violation that would
silently bite the moment `MsgPackValue` equality is used semantically (e.g. snapshot dedup).

**Fix:** In `==`, add a cross-arm case that compares numeric value across `int`/`uint`:
`case let (.int(a), .uint(b)), let (.uint(b), .int(a)): return a >= 0 && UInt64(a) == b`. Or document
loudly that `MsgPackValue` equality is tag-sensitive and must never be used for semantic comparison.

**REFUTED** — the tag-sensitive equality is a *deliberate, documented design contract*: the encoder
(`MessagePack.swift:273-276`) intentionally keeps `.int` on signed tags and `.uint` on unsigned ones
"so the value's case survives the round-trip exactly," and the round-trip test depends on that. Cross-tag
numeric equality would BREAK the round-trip property, not fix a bug. There is no semantic-equality consumer
(grep: no `Set`/dedup/`firstIndex` over `MsgPackValue` in production). Intended behavior, not a defect.

### Diff path-split strategy (2) can mis-pair `a/X b/X` when `X` itself contains ` b/`

**Severity:** low

**Location:** `rust-core/crates/core/src/diff.rs:196-238` (`parse_diff_git_paths`)

**Why:** Strategy (2) scans every ` b/` occurrence and returns the first where the prefix is `a/PATH`
and the suffix equals `PATH`. For a same-file path that legitimately contains the literal substring
` b/` (e.g. a file at `a/foo b/bar.txt b/foo b/bar.txt` for a path named `foo b/bar.txt`), the first
` b/` match splits at the *interior* ` b/`, where `a_part = "a/foo"`, `b_part = "bar.txt b/foo b/bar.txt"`,
which fails the `a_path == b_part` equality, so it falls through to the next ` b/` — eventually it can
find the correct split, but only if an *interior* ` b/` doesn't coincidentally satisfy the equality
for a wrong substring. Git's own `diff --git` quoting escapes such names, and the quoted-form strategy
(1) handles the realistic hostile case, so this is a narrow unquoted-pathological input. It is faithful
to the documented "4-strategy Swift splitter" (parity-locked), so changing it risks an A/B break — but
the pairing is genuinely ambiguous for paths embedding ` b/`, and a mis-split yields a wrong
`old_path`/`new_path` in the diff view (mislabeled file header), not a crash.

**Fix:** No code change without re-validating the Swift A/B contract; document the known ambiguity for
unquoted paths containing ` b/` (git escapes these, so it is mostly theoretical), and ensure the
quoted-form path (strategy 1) is preferred whenever the input is quoted. If hardening is wanted, prefer
the *last* equal-prefix split over the first to bias toward the real `a/X b/X` boundary, and add a test
with a path embedding ` b/`.

**REFUTED** — the cited mechanism (an interior ` b/` coincidentally satisfying `a_path == b_part`) is
structurally impossible for a same-file path: any interior split's `b_part` strictly contains the trailing
copy of the path, so it can never equal the shorter `a_path`. The reviewer's own concrete example
(`a/foo b/bar.txt b/foo b/bar.txt`) parses *correctly*, and a brute-force search over all ` b/`-embedding
same-file paths found zero mis-splits. The only residual case is a *rename* with embedded ` b/` (genuinely
undecidable without quoting — git always quotes such names, handled by strategy 1), and the Swift twin is
parity-locked to identical behavior, so there is no A/B divergence. Documentation-only at most, not a defect.
