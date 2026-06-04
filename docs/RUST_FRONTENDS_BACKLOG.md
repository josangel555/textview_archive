# Rust-core front-ends — backlog (for later runs)

State after 2026-06-04: **three front-ends on one core** —
- `crates/ffi` → the SwiftUI macOS app (in-process FFI).
- `crates/tui` (`mdv-tui`) → ratatui terminal UI. File nav + text/HEX/CSV-table.
- `crates/web` (`mdv-web`) → std-only HTTP server, server-rendered HTML. Same
  feature set, localhost-only.

The TUI and Web are at **manual** feature parity. The items below make parity
*structural*, extend the front-ends, and open the next tiers. Ranked by value.

## High value — make parity structural (stop the drift before it starts)

1. **Shared front-end view-model in the core (`mdvcore-core`).**
   The TUI and Web each independently reimplement: capped file read, `.csv/.tsv`
   detection, the mode set + cycle, and the per-mode content build (text lines /
   `hex::render_all` / `csv::parse` table). Extract a sans-IO
   `core::view` that, given bytes + filename + mode, returns a view-agnostic
   model (e.g. `ViewModel::{Text(lines), Hex(lines), Table{header,rows}}` + an
   indent badge + the available modes). Front-ends become thin renderers. This
   is the real "feature parity" guarantee + DRY. *(The IO — reading the file —
   stays in each front-end; only the pure shaping moves to the core.)*

2. **Core `FileKind` classifier.** Each front-end hardcodes the `.csv/.tsv`
   check. Move a `core::file_kind(name, &bytes) -> {Text, Csv, Binary, Diff, …}`
   into the core so all three front-ends (incl. the Swift app) classify
   identically — content-sniff, not just extension.

3. **Parity test harness.** A test that feeds the same fixture files through the
   TUI's and Web's content paths (ideally both via item 1's shared view-model)
   and asserts equal data. Catches silent parity drift mechanically. Once item 1
   lands this is almost free (assert on the shared `ViewModel`).

## Extend the front-ends (TUI + Web both, keep parity)

4. **Diff view** (`mdvcore_core::diff::parse`) — a mode for `.diff`/`.patch`
   files (and later `git diff` output): colored +/- lines, hunks. TUI tracked as
   #257; do Web in lock-step.
5. **Content search box** — search within the open file (reuse `hex_search` for
   HEX; literal/regex text search once the `regex` slice lands) and across the
   directory listing (filename filter). TUI #257; Web parallel.
6. **Large-file paging** — both cap at 1 MiB read + 5000 table rows. Add
   windowed paging / virtual scroll so multi-MB files are fully browsable.
7. **Real Linux run** of `mdv-tui` + `mdv-web` once the box is provisioned —
   crossterm + std are portable; expect zero code change. Sanity-screenshot both.

## New tiers / options

8. **WASM browser-native tier.** Compile the core to WASM and run the viewer
   entirely in the browser via the File System Access API — no local server.
   Complements (doesn't replace) `mdv-web`; good for a hosted demo. Bigger spike.
9. **Web remote mode (opt-in).** `mdv-web` is localhost-only by design. If
   remote access is ever wanted: an explicit `--bind` + a token/`Authorization`
   gate + a path-jail to a served root (today it browses the whole FS, which is
   correct for a local single-user tool but unsafe to expose).
10. **Syntax highlighting** in both front-ends — depends on the markdown/
    highlight core slice (#11, owner dep: `comrak`+`tree-sitter`).
11. **Run scripts + README** — `scripts/run-tui.sh` / `scripts/run-web.sh`, and
    a short `rust-core/README.md` documenting the three front-ends + how to run
    each (so a fresh checkout / the Linux box is one command away).

## Notes
- The front-end bins stay out of the CI merge gate (`default-members` =
  core+ffi). When item 3 (parity tests) lands, decide whether to add a
  lightweight `cargo test -p mdvcore-tui -p mdvcore-web` lane (no external deps
  for web; ratatui for tui) — likely a separate non-blocking job.
- Validation pattern that works headlessly: ratatui `TestBackend` + `--snapshot`
  for the TUI; pure render-fn unit tests + a socket round-trip + `curl` smoke for
  the web.
