//! Build script: run cbindgen to emit the C header from the `extern "C"`
//! surface, so the header can never drift from the source.
//!
//! Outputs TWO copies:
//!   - `$OUT_DIR/mdvcore.h` — canonical build artifact.
//!   - `<crate>/include/mdvcore.h` — committed-adjacent to `module.modulemap`
//!     so the SwiftPM systemLibrary target can `#include` it without knowing
//!     `OUT_DIR`.
//!
//! A cbindgen failure FAILS the build (audit TSK-539). The old warn-and-skip
//! tolerance meant an `#[repr(C)]` edit could rebuild the staticlib while the
//! header silently kept the OLD field offsets — cross-language memory
//! corruption with zero compile- or gate-time signal. A hard failure is the
//! only honest behavior for an artifact that IS the ABI contract.

use std::env;
use std::path::PathBuf;

fn main() {
    // `CARGO_MANIFEST_DIR` / `OUT_DIR` are set by cargo for every build-script
    // invocation, so a miss is effectively unreachable — but if it ever
    // happens the header cannot be generated, and a stale header is an ABI
    // hazard (TSK-539), so fail the build rather than warn-and-skip.
    // `exit(1)` (not `expect()`) keeps the workspace no-panic lint policy.
    let (Ok(crate_dir), Ok(out_dir)) = (env::var("CARGO_MANIFEST_DIR"), env::var("OUT_DIR")) else {
        eprintln!("cbindgen: CARGO_MANIFEST_DIR / OUT_DIR not set; cannot generate the ABI header");
        std::process::exit(1);
    };
    let crate_dir = PathBuf::from(crate_dir);
    let out_dir = PathBuf::from(out_dir);

    // Re-run if the FFI surface or config changes. The whole src/ DIRECTORY,
    // not just lib.rs (audit TSK-539): the #[repr(C)] ABI types live in
    // buf.rs and status.rs — with only lib.rs tracked, editing those rebuilt
    // the staticlib but left the header at the OLD layout.
    println!("cargo:rerun-if-changed=src");
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

            // Mirror into include/ for the SwiftPM systemLibrary target. This
            // copy IS the ABI contract Swift compiles against — failure to
            // stage it must fail the build, not warn (audit TSK-539).
            let include_dir = crate_dir.join("include");
            if let Err(e) = std::fs::create_dir_all(&include_dir) {
                eprintln!("cbindgen: could not create include dir: {e}");
                std::process::exit(1);
            }
            bindings.write_to_file(include_dir.join("mdvcore.h"));
            // No success-path cargo:warning — it spammed every build and
            // trained readers to ignore the warning channel.
        }
        Err(e) => {
            eprintln!("cbindgen failed to generate header: {e}");
            std::process::exit(1);
        }
    }
}
