//! Build script: run cbindgen to emit the C header from the `extern "C"`
//! surface, so the header can never drift from the source.
//!
//! Outputs TWO copies:
//!   - `$OUT_DIR/mdvcore.h` — canonical build artifact.
//!   - `<crate>/include/mdvcore.h` — committed-adjacent to `module.modulemap`
//!     so the SwiftPM systemLibrary target can `#include` it without knowing
//!     `OUT_DIR`.
//!
//! We tolerate a cbindgen failure (warn, don't fail the build) so a plain
//! `cargo build`/`cargo test` of the Rust side still works even if the header
//! generation hits an edge case — the header is only needed for the Swift link
//! step, which `poc/build.sh` drives explicitly.

use std::env;
use std::path::PathBuf;

fn main() {
    // `CARGO_MANIFEST_DIR` / `OUT_DIR` are set by cargo for every build-script
    // invocation, so a miss is effectively unreachable — but we degrade
    // gracefully (warn + skip header gen, which is non-essential per the module
    // doc) rather than `expect()`-panic, satisfying the workspace no-panic lint
    // policy that `cargo clippy --all-targets` now enforces on build scripts too.
    let (Ok(crate_dir), Ok(out_dir)) = (env::var("CARGO_MANIFEST_DIR"), env::var("OUT_DIR")) else {
        println!("cargo:warning=cbindgen skipped: CARGO_MANIFEST_DIR / OUT_DIR not set");
        return;
    };
    let crate_dir = PathBuf::from(crate_dir);
    let out_dir = PathBuf::from(out_dir);

    // Re-run if the FFI surface or config changes.
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=build.rs");

    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen.toml"))
        .unwrap_or_else(|_| cbindgen::Config::default());

    match cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
    {
        Ok(bindings) => {
            let out_header = out_dir.join("mdvcore.h");
            bindings.write_to_file(&out_header);

            // Mirror into include/ for the SwiftPM systemLibrary target.
            let include_dir = crate_dir.join("include");
            if let Err(e) = std::fs::create_dir_all(&include_dir) {
                println!("cargo:warning=could not create include dir: {e}");
            } else {
                bindings.write_to_file(include_dir.join("mdvcore.h"));
            }
            // Surface where the canonical header landed.
            println!(
                "cargo:warning=cbindgen wrote header to {}",
                out_header.display()
            );
        }
        Err(e) => {
            // Don't fail the Rust build on header-gen issues.
            println!("cargo:warning=cbindgen failed to generate header: {e}");
        }
    }
}
