//! Shared golden corpus + differential parity test for the `markdown` engine
//! (TSK-586, slice 2 of 2 — `diff` is the sibling `golden_corpus_diff.rs`).
//!
//! Same rationale as the diff corpus: the markdown→HTML renderer has three
//! consumers (Swift FFI `mdvcore_markdown_render`, the TUI/serve remote path
//! dispatching `"markdown_render"`, and a future web path) that ALL funnel
//! through ONE function — `markdown::render_wire` — which is the single source
//! of truth. This corpus pins its output so a drift fails the rust-core gate
//! for every consumer at once.
//!
//! For each `tests/golden/markdown/inputs/*.md` we build the `{text}` request
//! frame exactly as the FFI/serve callers do, call `markdown::render_wire`,
//! decode `{html, chunks}`, render canonical text, and compare to the golden
//! under `tests/golden/markdown/expected/`. We also cross-check that the
//! in-process `markdown::render` produces the SAME html + chunks the wire
//! decoded (the FFI-vs-serve agreement guarantee).
//!
//! Regen: `MDV_REGEN_GOLDEN=1 cargo test -p mdvcore-core --test golden_corpus_markdown`
//! rewrites every expected file. Without it the gate FAILS on drift.

// The whole module is gated `#[cfg(test)]` so clippy recognizes the free
// helpers (not just the `#[test]` fn) as test code and applies the workspace
// `allow-{expect,unwrap,panic}-in-tests` exemptions (clippy.toml). An
// integration-test crate is always built in test mode, so the gate is always
// active here — it is purely the marker clippy keys off.
#![cfg(test)]

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use mdvcore_core::{markdown, wire};

/// `{text}` request map — mirrors `markdown::RenderRequest`; `wire::encode_frame`
/// reproduces the EXACT bytes the FFI/serve callers send.
#[derive(serde::Serialize)]
struct RenderRequest<'a> {
    text: &'a str,
}

/// `{html, chunks:[{kind,lang,payload}]}` — mirrors `markdown::RenderResponse`.
#[derive(serde::Deserialize)]
struct RenderResponse {
    html: String,
    chunks: Vec<Chunk>,
}
#[derive(serde::Deserialize)]
struct Chunk {
    kind: String,
    lang: String,
    payload: String,
}

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/markdown")
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

/// Deterministic text form of a decoded wire response. The html is emitted
/// verbatim (it is the primary contract) with the chunk table appended; the
/// `<!--mdv-chunk-N-->` sentinels in the html cross-reference the chunk rows.
fn canonical(resp: &RenderResponse) -> String {
    let mut out = String::new();
    out.push_str("=== html ===\n");
    out.push_str(&resp.html);
    if !resp.html.ends_with('\n') {
        out.push('\n');
    }
    let _ = writeln!(out, "=== chunks: {} ===", resp.chunks.len());
    for (i, c) in resp.chunks.iter().enumerate() {
        let _ = writeln!(out, "chunk[{i}] kind={} lang={:?}", c.kind, c.lang);
        let _ = writeln!(out, "  payload: {:?}", c.payload);
    }
    out
}

/// Run the renderer over one input via the SHARED wire seam, cross-check the
/// in-process API, and return canonical text.
fn run_engine(input: &str) -> String {
    let frame = wire::encode_frame(&RenderRequest { text: input })
        .expect("encode request frame");
    let resp_frame = markdown::render_wire(&frame).expect("markdown::render_wire");
    let resp: RenderResponse =
        wire::decode_frame(&resp_frame).expect("decode response frame");

    // Cross-check: the in-process owned API must agree with the wire path.
    let direct = markdown::render(input);
    assert_eq!(
        direct.html, resp.html,
        "wire html must match in-process markdown::render"
    );
    assert_eq!(
        direct.chunks.len(),
        resp.chunks.len(),
        "wire chunk count must match in-process markdown::render"
    );
    for (d, w) in direct.chunks.iter().zip(resp.chunks.iter()) {
        assert_eq!(d.kind.as_str(), w.kind, "chunk kind: wire vs in-process");
        assert_eq!(d.lang, w.lang, "chunk lang: wire vs in-process");
        assert_eq!(d.payload, w.payload, "chunk payload: wire vs in-process");
    }

    canonical(&resp)
}

#[test]
fn markdown_corpus_matches_goldens() {
    let dir = corpus_dir();
    let inputs = dir.join("inputs");
    let expected_dir = dir.join("expected");

    let mut entries: Vec<PathBuf> = read_input_files(&inputs, "md");
    entries.sort();
    assert!(
        !entries.is_empty(),
        "markdown corpus is empty — expected fixtures under {}",
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
        "markdown golden corpus drift ({} case(s)). Re-run with MDV_REGEN_GOLDEN=1 \
         after confirming the change is intended:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}
