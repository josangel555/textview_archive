//! Regression probe for the build/test-speed lever landed under TSK-786
//! (`rust-core/Cargo.toml [profile.test]`).
//!
//! ## What this pins and why a *manifest* assertion is the right probe
//!
//! `cargo test` compiles with the `test` profile, which by default inherits
//! `dev` → `debug = true` (FULL DWARF). The rust-core gate
//! (`scripts/rust-core-gate.sh`) cold-compiles ~14 crate test binaries on every
//! run; full debuginfo is the single heaviest compile cost, and the gate never
//! needs variable/type info — only a file:line backtrace on a panic, which
//! `debug = "line-tables-only"` preserves. Measured A/B (cargo 1.92, cold
//! `CARGO_TARGET_DIR`, `cargo test --locked --workspace --no-run`):
//!   `debug = true`            : 12.72 s wall, 1.1 GB target
//!   `debug = "line-tables-only"`: 12.04 s wall, 997 MB target
//! ⇒ ~5% off the cold test-compile + ~100 MB less disk, zero behaviour risk.
//!
//! A pure-Rust `#[test]` cannot time the compiler (the profile is resolved
//! before this binary exists), so — exactly like the no-panic-lints manifest
//! probe in `crates/ffi/tests/` — it asserts the load-bearing INVARIANT
//! directly: the workspace manifest must declare `[profile.test]` with
//! `debug = "line-tables-only"`. If someone deletes the table (reverting to the
//! `dev`-inherited full-debug default) or weakens it back to `debug = true`,
//! the gate's `cargo test` runs this and it goes red — flagging the silent
//! re-bloat of every test-compile.
//!
//! The probe is deliberately *narrow*: it only guards the debuginfo lever it
//! was added for. It does NOT assert anything about `dev`/`dist`/`release`, so
//! it won't fight an unrelated future profile change.

/// The workspace-root `Cargo.toml`, embedded at compile time. `CARGO_MANIFEST_DIR`
/// is `crates/core`; `../../Cargo.toml` is the workspace root (verified: the
/// `[workspace]` table with `members = [...]` lives there).
const WORKSPACE_CARGO_TOML: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml"));

/// Extract the body of a top-level `[section]` table: everything from that
/// header up to (but not including) the next `[` section header at column 0.
/// Mirrors the helper in `crates/ffi/tests/no_panic_lints_gate_*` so the two
/// manifest probes parse tables the same way.
fn section_body<'a>(toml: &'a str, header: &str) -> Option<&'a str> {
    let start = toml.find(header)?;
    let after_header = toml.get(start..)?;
    let body_start = after_header.find('\n').map_or(after_header.len(), |i| i + 1);
    let body = after_header.get(body_start..)?;
    Some(match body.find("\n[") {
        Some(end) => body.get(..end).unwrap_or(body),
        None => body,
    })
}

/// True iff `key` is set to the exact string value `value` in the given table
/// body (`key = "value"`), ignoring whitespace and `#` comments.
fn key_equals_str(body: &str, key: &str, value: &str) -> bool {
    let want = format!("\"{value}\"");
    body.lines().any(|line| {
        let code = line.split('#').next().unwrap_or("").trim();
        let Some(rest) = code.strip_prefix(key) else {
            return false;
        };
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            return false;
        };
        rest.trim() == want
    })
}

#[test]
fn workspace_root_is_the_manifest_under_test() {
    // Guard the include path: if the workspace is ever restructured so this file
    // no longer points at the root manifest, fail loudly here rather than let
    // the real assertions silently pass against the wrong file.
    assert!(
        WORKSPACE_CARGO_TOML.contains("[workspace]")
            && WORKSPACE_CARGO_TOML.contains("members ="),
        "../../Cargo.toml from crates/core no longer looks like the workspace \
         root manifest (no [workspace]/members table). Fix the include path in \
         this test."
    );
}

#[test]
fn test_profile_trims_debuginfo_to_line_tables_only() {
    let body = section_body(WORKSPACE_CARGO_TOML, "[profile.test]").expect(
        "workspace Cargo.toml has no [profile.test] table. The test profile \
         inherits `dev` → `debug = true` (full DWARF) without it, re-bloating \
         every `cargo test` compile by ~5% wall + ~100 MB disk (TSK-786). \
         Re-add:\n    [profile.test]\n    debug = \"line-tables-only\"",
    );
    assert!(
        key_equals_str(body, "debug", "line-tables-only"),
        "[profile.test] no longer sets `debug = \"line-tables-only\"`. Reverting \
         to the `dev`-inherited `debug = true` makes every gate test-compile \
         emit full DWARF for no benefit (the gate only needs panic file:line, \
         which line-tables preserve). Restore `debug = \"line-tables-only\"`."
    );
}
