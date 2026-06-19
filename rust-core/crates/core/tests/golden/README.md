# rust-core shared golden corpus (differential parity)

Recorded canonical outputs for the rust-core engines, asserted byte-for-byte by
the differential parity tests in `crates/core/tests/golden_corpus_*.rs`
(TSK-586). This is the **single source of truth** the engines' three consumers
must all agree with:

- the **Swift FFI** (`mdvcore_diff_parse` / `mdvcore_markdown_render`),
- the **TUI / serve remote path** (`mdvcore-serve` dispatches `"diff_parse"` /
  `"markdown_render"` to the SAME `*_wire` functions),
- a future **web serve path**.

All three funnel through ONE function per engine — `diff::parse_wire` /
`markdown::render_wire` — so pinning the wire output here means a drift fails
the `rust-core-gate` for every consumer at once, instead of silently diverging
in one of them.

## Layout

```
golden/
  diff/
    inputs/    *.diff   — engine inputs
    expected/  *.txt    — recorded canonical output (one per input stem)
  markdown/
    inputs/    *.md
    expected/  *.txt
```

Each `expected/<stem>.txt` is a deterministic, human-reviewable text rendering
of the **decoded wire response** (not raw MessagePack — kept diffable). Every
field the wire carries appears, so any field-level drift changes the text.

## What the test asserts

For every input the test:

1. builds the request frame exactly as the FFI/serve callers do
   (`wire::encode_frame(&{text})`),
2. calls the shared `*_wire` entry point,
3. decodes the response frame and renders canonical text → compares to the
   golden,
4. cross-checks that the **in-process** API (`diff::parse` / `markdown::render`)
   agrees with the wire-decoded structure — a mismatch means the positional
   wire records drifted from the owned types.

## Adding / updating fixtures

1. Add an input under `<engine>/inputs/` (`.diff` or `.md`).
2. Regenerate the goldens:

   ```sh
   MDV_REGEN_GOLDEN=1 cargo test -p mdvcore-core \
     --test golden_corpus_diff --test golden_corpus_markdown
   ```

3. **Review the diff** of the `expected/` files — that review is the point.
   Commit inputs + goldens together.

Without `MDV_REGEN_GOLDEN`, the gate compares against the committed goldens and
**FAILS on any drift** with a unified before/after dump.

## Coverage today

- **diff**: simple modify, new file, deleted file, rename, binary, multi-file,
  no-newline-at-EOF.
- **markdown**: headings + slug de-dupe, inline formatting + soft/hard breaks,
  nested + ordered + task lists, GFM tables, code-fence chunking, link URL-scheme
  allowlist (`javascript:` neutralized), raw-HTML chunking + sentinel splice.
