//! Shared golden corpus + differential parity test for the `diff` engine
//! (TSK-586, slice 1 of 2 — `markdown` is the sibling `golden_corpus_markdown.rs`).
//!
//! # Why a corpus, and why the WIRE seam
//!
//! The diff parser has THREE consumers that must agree byte-for-byte:
//!   * the Swift FFI (`mdvcore_diff_parse`, via `diff::parse_wire`),
//!   * the TUI / serve remote path (`mdvcore-serve` dispatches `"diff_parse"`
//!     to the SAME `diff::parse_wire`),
//!   * any future web serve path.
//!
//! They all funnel through ONE function — `diff::parse_wire` — which decodes a
//! length-prefixed MessagePack request frame, parses, and encodes the response
//! frame. That wire seam is therefore the single source of truth: if it drifts,
//! every consumer drifts together (or, worse, the in-process `diff::parse` and
//! the wire encoding diverge silently). This corpus pins it.
//!
//! For each input under `tests/golden/diff/inputs/*.diff` we:
//!   1. build the request frame EXACTLY as the FFI/serve callers do
//!      (`wire::encode_frame(&{text})`),
//!   2. call `diff::parse_wire` (the shared entry point),
//!   3. decode the response frame and render it to a deterministic,
//!      human-reviewable canonical text form,
//!   4. assert it equals the recorded golden under `tests/golden/diff/expected/`.
//!
//! We ALSO assert the in-process `diff::parse` agrees with the wire-decoded
//! structure (the FFI-vs-serve "ONE source of truth" guarantee — a divergence
//! here means the positional wire records drifted from the owned types).
//!
//! # Regen mode
//!
//! `MDV_REGEN_GOLDEN=1 cargo test -p mdvcore-core --test golden_corpus_diff`
//! REWRITES every expected file from the current engine output. Without the env
//! var (i.e. in the gate) any drift FAILS the test with a unified-ish diff. So
//! goldens are trivially updatable, but CI catches an unreviewed change.

// The whole module is gated `#[cfg(test)]` so clippy recognizes the free
// helpers (not just the `#[test]` fn) as test code and applies the workspace
// `allow-{expect,unwrap,panic}-in-tests` exemptions (clippy.toml). An
// integration-test crate is always built in test mode, so the gate is always
// active here — it is purely the marker clippy keys off.
#![cfg(test)]

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use mdvcore_core::{diff, wire};

/// Request frame shape mirrored from `diff::ParseRequest` (the private wire
/// request type): a named map `{text}`. Building it here, with the public
/// `wire::encode_frame`, reproduces the EXACT bytes the FFI/serve callers send.
#[derive(serde::Serialize)]
struct ParseRequest<'a> {
    text: &'a str,
}

/// Response shape mirrored from `diff`'s positional wire records (TSK-563): the
/// envelope is a named map `{files}`, each file/hunk/line a positional ARRAY.
/// Decoding here proves the recorded golden is what a consumer ACTUALLY sees.
#[derive(serde::Deserialize)]
struct ParseResponse {
    files: Vec<FileView>,
}
/// `[old_path, new_path, is_new, is_deleted, is_binary, is_rename, hunks]`.
#[allow(
    clippy::struct_excessive_bools,
    reason = "positional mirror of the diff wire record's four independent flag fields (matches diff::FileView 1:1)"
)]
#[derive(serde::Deserialize)]
struct FileView(String, String, bool, bool, bool, bool, Vec<HunkView>);
/// `[old_start, old_count, new_start, new_count, header, lines]`.
#[derive(serde::Deserialize)]
struct HunkView(i64, i64, i64, i64, String, Vec<LineView>);
/// `[kind, old_line_no, new_line_no, content]`.
#[derive(serde::Deserialize)]
struct LineView(String, Option<i64>, Option<i64>, String);

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/diff")
}

// ---------------------------------------------------------------------------
// IO helpers. The workspace clippy gate DENIES both `panic` (no
// `allow-panic-in-tests` knob) and `expect_fun_call` (a `clippy::all` perf
// lint that fires on `expect(&format!(..))`), while `expect_used` IS allowed
// in tests. So we pre-build the message into a `let` and pass `&msg` — a plain
// variable, not a call inside `expect` — which satisfies every lint.
// ---------------------------------------------------------------------------

fn read_input_files(dir: &Path, ext: &str) -> Vec<PathBuf> {
    let msg = format!("read corpus inputs {}", dir.display());
    std::fs::read_dir(dir)
        .expect(&msg)
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == ext))
        .collect()
}

fn read_text(path: &Path) -> String {
    let msg = format!("read {}", path.display());
    std::fs::read_to_string(path).expect(&msg)
}

fn read_golden(path: &Path) -> String {
    let msg = format!(
        "missing golden {} — run with MDV_REGEN_GOLDEN=1 to create it",
        path.display()
    );
    std::fs::read_to_string(path).expect(&msg)
}

fn write_text(path: &Path, body: &str) {
    let msg = format!("regen write {}", path.display());
    std::fs::write(path, body).expect(&msg);
}

/// Render a decoded wire response to deterministic, line-oriented text. The
/// format is purely for golden review/diff legibility — every field that the
/// wire carries is present, so a drift in ANY field changes the text.
fn canonical(resp: &ParseResponse) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "files: {}", resp.files.len());
    for (fi, f) in resp.files.iter().enumerate() {
        let _ = writeln!(out, "  file[{fi}]");
        let _ = writeln!(out, "    old_path: {:?}", f.0);
        let _ = writeln!(out, "    new_path: {:?}", f.1);
        let _ = writeln!(
            out,
            "    flags: new={} deleted={} binary={} rename={}",
            f.2, f.3, f.4, f.5
        );
        let _ = writeln!(out, "    hunks: {}", f.6.len());
        for (hi, h) in f.6.iter().enumerate() {
            let _ = writeln!(
                out,
                "      hunk[{hi}] @@ -{},{} +{},{} @@ header={:?}",
                h.0, h.1, h.2, h.3, h.4
            );
            for l in &h.5 {
                let old = l.1.map_or_else(|| "·".to_string(), |n| n.to_string());
                let new = l.2.map_or_else(|| "·".to_string(), |n| n.to_string());
                let _ = writeln!(out, "        [{:<8}] {:>4} {:>4} | {:?}", l.0, old, new, l.3);
            }
        }
    }
    out
}

/// Run the engine over one input via the SHARED wire seam and return the
/// canonical text. Also asserts the in-process API agrees with the wire output.
fn run_engine(input: &str) -> String {
    // 1. Build the request frame exactly as the FFI/serve callers do.
    let frame = wire::encode_frame(&ParseRequest { text: input })
        .expect("encode request frame");
    // 2. Call the shared entry point — the ONE function every consumer hits.
    let resp_frame = diff::parse_wire(&frame).expect("diff::parse_wire");
    // 3. Decode the response the way a consumer would.
    let resp: ParseResponse =
        wire::decode_frame(&resp_frame).expect("decode response frame");

    // 4. Cross-check: the in-process owned API must agree with the wire path.
    //    A mismatch means the positional wire records drifted from the typed
    //    `diff::File`/`Hunk`/`Line` — the exact silent-divergence this corpus
    //    exists to catch.
    let direct = diff::parse(input);
    assert_eq!(
        direct.len(),
        resp.files.len(),
        "wire file count must match in-process diff::parse"
    );
    for (d, w) in direct.iter().zip(resp.files.iter()) {
        assert_eq!(d.old_path, w.0, "old_path: wire vs in-process");
        assert_eq!(d.new_path, w.1, "new_path: wire vs in-process");
        assert_eq!(
            (d.is_new, d.is_deleted, d.is_binary, d.is_rename),
            (w.2, w.3, w.4, w.5),
            "flags: wire vs in-process for {:?}",
            d.new_path
        );
        assert_eq!(
            d.hunks.len(),
            w.6.len(),
            "hunk count: wire vs in-process for {:?}",
            d.new_path
        );
    }

    canonical(&resp)
}

#[test]
fn diff_corpus_matches_goldens() {
    let dir = corpus_dir();
    let inputs = dir.join("inputs");
    let expected_dir = dir.join("expected");

    let mut entries: Vec<PathBuf> =
        read_input_files(&inputs, "diff");
    entries.sort();
    assert!(
        !entries.is_empty(),
        "diff corpus is empty — expected fixtures under {}",
        inputs.display()
    );

    let regen = std::env::var_os("MDV_REGEN_GOLDEN").is_some();
    let mut failures: Vec<String> = Vec::new();

    for input_path in &entries {
        let stem = input_path
            .file_stem()
            .and_then(|s| s.to_str())
            .expect("utf8 stem");
        let input = read_text(input_path);
        let got = run_engine(&input);
        let golden_path = expected_dir.join(format!("{stem}.txt"));

        if regen {
            write_text(&golden_path, &got);
            continue;
        }

        let want = read_golden(&golden_path);
        if got != want {
            failures.push(format!(
                "DRIFT in {stem}:\n--- expected ---\n{want}\n--- got ---\n{got}"
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "diff golden corpus drift ({} case(s)). Re-run with MDV_REGEN_GOLDEN=1 \
         after confirming the change is intended:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}
