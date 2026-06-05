//! Regression probe for AUDIT_BUGS [S2] "rust-core CI gate does NOT enforce the
//! no-panic policy on mdvcore-ffi" (`rust-core/crates/ffi/Cargo.toml:25`).
//!
//! ## What regressed and why a *manifest* assertion is the right probe
//!
//! `unwrap_used` / `expect_used` / `indexing_slicing` / `panic` are clippy
//! RESTRICTION lints — they are NOT members of the `all`/pedantic/correctness
//! groups, so `all = "deny"` does not pull them in. They fire only where
//! explicitly opted in. `mdvcore-core` opts in through the workspace
//! `[workspace.lints.clippy]` table, but `mdvcore-ffi` deliberately opts OUT of
//! workspace lint inheritance (cargo #13157 forbids mixing inherited +
//! package-local lints, and this crate must opt out of `unsafe_code = "forbid"`
//! since it IS the unsafe `extern "C"` edge). The net was a HOLE: a stray
//! `.unwrap()` / indexing panic in FFI marshaling compiled clean, and if it
//! unwound across the C ABI outside `ffi_guard!`/`catch_unwind` (e.g. in a
//! `Drop`) that is UB. The fix re-declares the four denies in this crate's
//! `Cargo.toml [lints.clippy]`.
//!
//! A pure-Rust `#[test]` cannot itself observe whether clippy would reject a
//! planted `.unwrap()`: lints are a compile-time concern resolved before this
//! test binary exists, and spawning `cargo clippy` from a test would race the
//! shared build tree (and pull in a `trybuild`-class dependency). So the probe
//! asserts the load-bearing INVARIANT directly: the four no-panic restriction
//! denies must be present in THIS crate's manifest. If anyone deletes them, the
//! enforcement hole reopens and this test (which the gate's `cargo test` runs)
//! goes red — exactly the "assert the gate goes red" the audit asked for.

/// This crate's own `Cargo.toml`, embedded at compile time. `CARGO_MANIFEST_DIR`
/// is `crates/ffi`, so this is precisely the manifest under audit.
const FFI_CARGO_TOML: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml"));

/// Extract the body of the `[lints.clippy]` table: everything from that header
/// up to (but not including) the next `[` section header at column 0.
fn lints_clippy_section(toml: &str) -> &str {
    let Some(start) = toml.find("[lints.clippy]") else {
        return "";
    };
    let after_header = &toml[start..];
    // Skip past the header line itself, then find the next top-level table.
    let body_start = after_header.find('\n').map_or(after_header.len(), |i| i + 1);
    let body = &after_header[body_start..];
    match body.find("\n[") {
        Some(end) => &body[..end],
        None => body,
    }
}

/// Returns true iff `name` is denied in the given lints body. Accepts either
/// the bare `name = "deny"` form or the table form
/// `name = { level = "deny", ... }`, ignoring whitespace, and ignores comments.
fn is_denied(section: &str, name: &str) -> bool {
    section.lines().any(|line| {
        let code = line.split('#').next().unwrap_or("").trim();
        let Some(rest) = code.strip_prefix(name) else {
            return false;
        };
        let rest = rest.trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            return false;
        };
        let rest = rest.trim_start();
        rest == "\"deny\"" || (rest.starts_with('{') && rest.contains("\"deny\""))
    })
}

#[test]
fn ffi_manifest_denies_the_four_no_panic_restriction_lints() {
    let section = lints_clippy_section(FFI_CARGO_TOML);
    assert!(
        !section.is_empty(),
        "ffi/Cargo.toml has no [lints.clippy] table — the local lint config (this \
         crate opts out of workspace inheritance) is gone"
    );

    for lint in ["unwrap_used", "expect_used", "indexing_slicing", "panic"] {
        assert!(
            is_denied(section, lint),
            "ffi/Cargo.toml [lints.clippy] no longer denies `{lint}`. These four \
             clippy RESTRICTION lints are NOT in the `all` group and this crate \
             opts out of workspace lint inheritance, so dropping the explicit \
             `deny` reopens the no-panic enforcement HOLE on the only unsafe \
             crate (a panic across the C ABI is UB). Re-add `{lint} = \"deny\"`."
        );
    }
}

#[test]
fn ffi_manifest_still_denies_the_unsafe_block_hygiene_lints() {
    // Guard the surrounding no-panic context the audit fix was added next to,
    // so a careless rewrite of the [lints.clippy] table can't silently drop the
    // pre-existing unsafe-block discipline either.
    let section = lints_clippy_section(FFI_CARGO_TOML);
    for lint in ["undocumented_unsafe_blocks", "multiple_unsafe_ops_per_block"] {
        assert!(
            is_denied(section, lint),
            "ffi/Cargo.toml [lints.clippy] no longer denies `{lint}` — unsafe-block \
             hygiene on the C ABI edge regressed."
        );
    }
}
