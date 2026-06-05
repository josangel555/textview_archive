# SwiftUI → TUI/Web feature port plan (2026-06-04)

Source: `feature-port-discovery` workflow (`wf_a57d04eb-8b8`, 10 agents) — surveyed the
SwiftUI app's feature surface vs. the current ratatui TUI + std-only web front-ends,
ranked the gaps, and produced a per-feature port plan under the **"one core, three
front-ends"** model (logic in `mdvcore-core::view`, front-ends are thin renderers).

**31 features** (29 no-dep + 2 owner-dep-gated). Ranking favors **high value × no new
dep × clean structural TUI/Web parity** (add to `core::view` so both render the same
model). Each is filed as a task (`[PORT]` prefix). Dep-gated ones carry
`blocker: owner-dep-approval`.

> Architecture facts validated against code: core ships `view` (Text/Hex/Table only —
> **no Diff/Formatted yet**), `diff` (parse + hunk_marks), `hex` (full hex_search),
> `filter`, `session` (CsvSession), `wire` (MessagePack via rmp-serde, **already a dep**),
> `indent`. FFI already exports `diff_parse`, `diff_hunk_marks`, `hex_search`,
> `hex_render`, `session_*`, `cm_apply`, `indent_detect`. Both binaries currently
> **duplicate** `read_capped` / `sort_by` / `column_widths` / `short()` → shared-core wins.

## First wave — no-dep, highest value (implement these first)

These 12 are no new dependency, mostly small/medium, and yield direct TUI+Web parity:

1. In-file find (query + match list + next/prev) — `core::find`
2. Line numbers gutter — `core::view::gutter_width`
3. Diff / patch view mode (`.diff`/`.patch`) — `ViewMode::Diff` over existing `core::diff`
4. CSV table filtering (global + per-column) — wire existing `core::filter`/`session`
5. Hex search (byte/ASCII) — wire existing `hex::hex_search`
6. File-nav sort modes (name/modified/size) + dirs-first — `core::nav::sort_entries`
7. Hidden/dotfile toggle — `core::nav::should_show`
8. Go to line — `view::clamp_line`
9. Directory tree filter / quick file find (type-to-narrow) — `core::nav::filter_entries`
10. Document outline / markdown TOC — `core::outline::headings`
11. Open-as / forced view-mode override — extend `view::build` + relax web `parse_mode`
12. Image preview — web `/raw?path=` serve + TUI dimensions card

## Full ranked list

| # | Feature | Area | Value | Effort | Risk | Dep-gated |
|---|---------|------|-------|--------|------|-----------|
| 1 | In-file find (query + match list + next/prev) | search | high | M | low | no |
| 2 | Line numbers in text/source view (gutter) | view-mode | high | S | low | no |
| 3 | Diff / patch view mode (`.diff`/`.patch`) | diff | high | M | low | no |
| 4 | CSV table filtering (global + per-column) | view-mode | high | M | low | no |
| 5 | Hex search (byte/ASCII pattern) | search | high | M | low | no |
| 6 | File-nav sort modes + dirs-first | navigation | high | S | low | no |
| 7 | Hidden / dotfile toggle | navigation | high | S | low | no |
| 8 | Go to line / jump-to-line | navigation | high | S | low | no |
| 9 | Cross-file folder grep (search anywhere) | search | high | L | med | no (literal; regex gated) |
| 10 | Directory tree filter / quick file find | navigation | high | M | low | no (ascii; fuzzy gated) |
| 11 | JSON / XML pretty-print (Formatted mode) | view-mode | high | L | med | no (hand-rolled; serde_json gated upgrade) |
| 12 | Open-as / forced view-mode override | view-mode | medium | S | low | no |
| 13 | Status bar / file-metadata metrics | view-mode | medium | S | low | no |
| 14 | Encoding / line-ending detection badge | view-mode | medium | S | low | no |
| 15 | Image preview (web raw-serve, TUI dims card) | view-mode | high | M | med | no (pixel-decode gated) |
| 16 | Document outline / markdown TOC | navigation | high | M | low | no (symbol-outline gated) |
| 17 | Breadcrumb / clickable path navigation | navigation | medium | S | low | no |
| 18 | Word-wrap toggle | view-mode | medium | S | low | no |
| 19 | Recently-opened / history list | sessions | medium | S | low | no |
| 20 | Persistent front-end session state | sessions | medium | M | low | no |
| 21 | Table column-width parity + h-scroll | view-mode | medium | S | low | no |
| 22 | Reload current file from disk | navigation | medium | S | low | no |
| 23 | Show invisibles / whitespace markers | view-mode | low | S | low | no |
| 24 | Dark mode / theme tokens | view-mode | medium | S | low | no |
| 25 | Empty/error/too-large/binary states + truncation banner | view-mode | low | S | low | no |
| 26 | Keyboard help / shortcut overlay | navigation | low | S | low | no |
| 27 | Multi-file tabs/buffers (TUI) + back-forward (Web) | sessions | medium | M | med | no |
| 28 | Git status + working-tree diff integration | git | medium | L | med | no (shells out to git) |
| 29 | Find match minimap / scroll position indicator | search | low | S | low | no |
| 30 | **Markdown rendered view** | view-mode | high | L | high | **YES — comrak** |
| 31 | **Source syntax highlighting** (offsets-only token model) | view-mode | high | L | high | **YES — tree-sitter** |

## Dep-gated (need owner approval before implementing)

- **#30 Markdown rendered view** — `comrak` (markdown→HTML). A no-dep CommonMark subset is
  large surface to hand-roll. tree-sitter optional for fenced-code coloring. Mermaid OUT
  (2.5 MB JS runtime). Ties to existing slice #249.
- **#31 Source syntax highlighting** — `tree-sitter` + per-language grammars (large). A
  no-dep keyword/lexical highlighter is possible but low fidelity. Offsets-only
  `HighlightRun{line,col,len,class}` model (colors live per front-end via `core::theme`).
  Ties to existing slice #11/#249.

## FFI note

Almost all top features need **no FFI** — they're pure front-end rendering or sans-IO
core consumed by TUI/Web only (SwiftUI already has native equivalents). FFI is flagged as
*optional/later* only where SwiftUI should genuinely unify on the core: `format` (#11),
`markdown` (#30), `highlight` (#31) — each would let SwiftUI drop a Foundation/Swift-native
implementation for byte-identical cross-tier output, but only if the owner wants to
standardize there.

## Implementation approach (when the audit-fix branch lands)

Per-feature, in core→view→TUI→web order, validated headlessly:
- **Core:** add the module/fn, unit-test it (cargo).
- **view:** extend `core::view` where a new mode/body is needed (#3 Diff, #11 Formatted, #15 Image).
- **TUI:** ratatui render + a `--snapshot` TestBackend assertion.
- **Web:** std-only HTML + a socket/curl assertion.
- **Parity:** cross-check TUI count/output == Web == core on the same fixture (the structural-parity guarantee).

Batch the first wave (no-dep, low-risk) first; gate (`rust-core-gate.sh`) per commit.
