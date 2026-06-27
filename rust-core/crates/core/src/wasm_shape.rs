//! WASM-shape invariant guard (TSK-800).
//!
//! The feasibility recommendation in `docs/WASM_WEBUI_DUPLICATION_2026-06-19.md`
//! rests on ONE load-bearing technical premise: `mdvcore-core` is "wasm-shaped"
//! — pure, sans-IO, so it compiles to `wasm32-unknown-unknown` with no shim and
//! no new deps, and the same `dispatch::Method` registry the FFI/TUI/web tiers
//! call can be exposed to the in-app WebViews' JS. The 2026-06-09 rust-core
//! audit verified this by hand; this test makes the premise a REGRESSION GUARD
//! so it cannot silently rot.
//!
//! The canonical proof is `cargo check --target wasm32-unknown-unknown -p
//! mdvcore-core`, but that needs the `wasm32-unknown-unknown` toolchain
//! component installed (a CI/toolchain provisioning step, owner-gated, and not
//! present in every dev/sandbox environment). This guard is the dependency-free,
//! always-on host proxy: it source-scans the core crate for the std IO surface
//! that would break the wasm target (filesystem, network, threads, processes,
//! ambient env/time) and fails the normal `cargo test --workspace` lane the
//! moment any of it creeps into the pure core. It is deliberately conservative
//! (it pins the *property*, not the exact compile) and complements — does not
//! replace — the clippy `disallowed-methods` determinism lint already in
//! `clippy.toml`.
//!
//! If the core legitimately needs one of these (it should not — IO belongs in
//! the front-ends / a future `mdvcore-host` crate per the audit's target
//! architecture), the WASM tier-1 story changes; update the doc and this guard
//! together, deliberately.

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    /// Absolute path to this crate's `src/` directory.
    fn src_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
    }

    /// Every `.rs` file directly under `src/`, plus whether the tree stayed
    /// flat (no subdirectories — the scan is non-recursive, so a new module dir
    /// would silently escape it and must fail the test loudly instead).
    fn core_source_files() -> (Vec<PathBuf>, bool) {
        let mut files = Vec::new();
        let mut flat = true;
        for entry in fs::read_dir(src_dir()).expect("read core src dir") {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                flat = false;
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                files.push(path);
            }
        }
        (files, flat)
    }

    /// std paths whose presence in the PRODUCTION (non-test) core would break
    /// `wasm32-unknown-unknown`. Each entry: (needle, why). We scan textually
    /// rather than via the type system because the point is to catch a NEW
    /// import before it compiles into the wasm-breaking shape.
    const WASM_BREAKING: &[(&str, &str)] = &[
        ("std::fs", "filesystem IO — unavailable on wasm32-unknown-unknown"),
        ("std::net", "sockets — unavailable on wasm32-unknown-unknown"),
        ("std::thread", "OS threads — unavailable on wasm32-unknown-unknown"),
        ("std::process", "subprocess spawn — unavailable on wasm32-unknown-unknown"),
        ("std::env::", "ambient env — not sans-IO; inject as a parameter"),
        ("std::time::Instant", "monotonic clock — Instant::now panics on wasm32-unknown-unknown"),
        ("std::time::SystemTime", "wall clock — SystemTime::now unavailable on wasm32-unknown-unknown"),
    ];

    const TEST_ATTR: &[u8] = b"#[cfg(test)]";

    /// Strip every `#[cfg(test)]`-attributed `{ … }` block (brace-balanced, on
    /// raw bytes so no UTF-8 string slicing) so test-only IO — like THIS file's
    /// own `std::fs` scan — does not trip the guard. Only PRODUCTION core code
    /// must stay wasm-shaped. Byte-level: source is ASCII for these constructs;
    /// non-ASCII bytes (inside string literals/comments) are copied verbatim.
    fn strip_test_modules(source: &str) -> String {
        let bytes = source.as_bytes();
        let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
        let mut i = 0usize;
        while i < bytes.len() {
            if bytes[i..].starts_with(TEST_ATTR) {
                // Find the next opening brace after the attribute.
                let mut j = i + TEST_ATTR.len();
                while j < bytes.len() && bytes[j] != b'{' {
                    j += 1;
                }
                if j < bytes.len() {
                    // Balance braces from this opening one.
                    let mut depth = 1i32;
                    j += 1;
                    while j < bytes.len() && depth > 0 {
                        match bytes[j] {
                            b'{' => depth += 1,
                            b'}' => depth -= 1,
                            _ => {}
                        }
                        j += 1;
                    }
                    i = j;
                    continue;
                }
            }
            out.push(bytes[i]);
            i += 1;
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    #[test]
    fn core_stays_wasm_shaped_no_io_imports() {
        let (files, flat) = core_source_files();
        assert!(
            flat,
            "core/src grew a subdirectory — the wasm-shape scan is flat and \
             would miss it; recurse the scan or keep core flat"
        );
        assert!(!files.is_empty(), "found no core source files to scan");

        let mut violations: Vec<String> = Vec::new();
        for file in files {
            let name = file
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("<?>")
                .to_string();
            // This guard file itself uses std::fs in its TEST code — skip it
            // wholesale; it ships no production code.
            if name == "wasm_shape.rs" {
                continue;
            }
            let raw = fs::read_to_string(&file).expect("read core source file");
            let production = strip_test_modules(&raw);
            for (needle, why) in WASM_BREAKING {
                if production.contains(needle) {
                    violations.push(format!("{name}: contains `{needle}` ({why})"));
                }
            }
        }
        assert!(
            violations.is_empty(),
            "mdvcore-core gained wasm-breaking std IO in PRODUCTION code, which \
             breaks the WASM tier-1 path (docs/WASM_WEBUI_DUPLICATION_2026-06-19.md). \
             Move the IO to a front-end / mdvcore-host, or update the doc + this \
             guard deliberately:\n  {}",
            violations.join("\n  ")
        );
    }

    #[test]
    fn guard_detects_an_injected_violation() {
        // Teeth: prove the scan would actually catch a regression. A synthetic
        // production-code sample carrying `std::fs` must be flagged…
        let bad = "pub fn read() { let _ = std::fs::read(\"/etc/passwd\"); }";
        let hit = WASM_BREAKING.iter().any(|(n, _)| bad.contains(n));
        assert!(hit, "the WASM_BREAKING scan failed to flag an obvious IO call");

        // Time is wasm-breaking too — there is no clock on wasm32-unknown-unknown.
        let bad_time = "use std::time::Instant;\nfn f() { let _ = Instant::now(); }";
        assert!(
            WASM_BREAKING.iter().any(|(n, _)| bad_time.contains(n)),
            "the WASM_BREAKING scan failed to flag std::time clock usage"
        );

        // …and the test-module stripper must NOT let a test-only use hide a
        // real production violation that sits OUTSIDE the test module.
        let mixed = "use std::net::TcpStream;\n#[cfg(test)]\nmod tests { use std::fs; }\n";
        let stripped = strip_test_modules(mixed);
        assert!(
            stripped.contains("std::net"),
            "stripper wrongly removed production code"
        );
        assert!(
            !stripped.contains("std::fs"),
            "stripper failed to remove the test module"
        );
    }
}
