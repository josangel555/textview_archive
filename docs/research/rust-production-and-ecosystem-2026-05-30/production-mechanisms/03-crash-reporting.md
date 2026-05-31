# Crash Reporting for a Rust Core (FFI-in-Swift, Headless Linux, WASM)

## Crash Reporting for a Rust Core

The hard truth up front: **there are two completely different failure classes, and they need two completely different mechanisms.** Conflating them is the single most common mistake.

| Class | Examples | Caught by | Stays inside the language runtime? |
|---|---|---|---|
| **Rust panics** | `unwrap()` on `None`, index OOB, explicit `panic!`, failed `assert!` | `std::panic::set_hook` + `catch_unwind` | Yes (if `panic=unwind`) |
| **Hard crashes** | `SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL`, `abort()`, stack overflow, faults from C deps / `unsafe` | OS signal/exception handlers + minidump writer | No — the process is already corrupt |

A panic hook will never see a `SIGSEGV`; a signal handler is the *only* thing that catches one. For a document viewer/editor with `forbid(unsafe_code)` in the core, panics will dominate — but the FFI edge, any C-backed dep (e.g. a syntax grammar, image/PDF decoder), and OS-level faults mean you cannot ignore the hard-crash path entirely.

### Panics: the synchronous, in-core path

`std::panic::set_hook` installs a global hook invoked *before* unwinding starts, while the **stack is still intact** — this is where you capture context. `PanicHookInfo` gives you the payload, `location` (file/line), `can_unwind`, and `force_no_backtrace`. The hook must capture the backtrace itself via `std::backtrace::Backtrace::capture()` (gated on the `RUST_BACKTRACE` / `RUST_LIB_BACKTRACE` env and on debuginfo being present). Because your core is sans-IO and synchronous, the clean design is: **hook serializes a structured panic record (message, location, backtrace, breadcrumbs) and hands it to the host via the FFI/callback edge** rather than doing I/O itself. The host (Swift, the TUI, the WASM glue, the server) owns transport.

`catch_unwind` is the second half — it stops a panic from unwinding *past* a boundary. It only works under `panic=unwind`; under `panic=abort` it is a no-op and the panic becomes an immediate `abort()`.

### The panic=abort vs unwind decision (decide this on day one)

This choice ripples everywhere and is expensive to retrofit because it changes ABI obligations at every FFI function.

- **`unwind`** (default on most targets): lets you `catch_unwind` at the FFI edge, runs destructors (RAII cleanup, file locks released), and lets the host recover and keep running. Cost: larger binaries, slightly slower compiles (Cargo-as-lib was cited at ~13% larger / ~11% slower compile with unwind), and landing-pad code.
- **`abort`**: smaller/faster, "cleaner" single crash event, but **no recovery and no destructor cleanup** — a panic in one document tab takes down the whole app.

For an interactive editor where one bad document should not kill the session, **`panic=unwind` + `catch_unwind` at the boundary is the right call.** Reserve `abort` for the truly-headless server only if you front it with a supervisor that captures the core/minidump and restarts.

### Crossing the FFI boundary into Swift (the part most guides get wrong)

**A panic unwinding across a plain `extern "C"` boundary is undefined behavior.** Historically the rule was "wrap every exported function body in `catch_unwind` and convert the panic into an error return / out-param." That is still the safe baseline.

The modern refinement is **RFC 2945 `extern "C-unwind"`** (stabilized in Rust 1.71, July 2023). Declaring an FFI fn `extern "C-unwind"` makes cross-boundary unwinding *defined*: under `panic=unwind` it unwinds through the foreign frame, and under `panic=abort` (or a "forced" unwind) it is caught and the process aborts deterministically instead of being UB. **This does not mean you should let panics unwind into Swift** — Swift's runtime won't run Rust destructors and the behavior across the Rust↔Swift frames is fragile. The production pattern remains:

```rust
#[no_mangle]
pub extern "C" fn tv_render(doc: *const Doc, out: *mut Result) -> i32 {
    let r = std::panic::catch_unwind(|| { /* sans-IO core call */ });
    match r {
        Ok(v) => { /* write v into out */ 0 }
        Err(_) => { /* panic already logged by the hook; return error code */ -1 }
    }
}
```

The panic hook does the *reporting*; `catch_unwind` does the *containment*; the i32 return code is the *contract with Swift*. Use `C-unwind` mainly as a correctness backstop against UB, not as a license to unwind into ObjC/Swift.

**Symbolication on Apple platforms is its own minefield.** Rust panics in a static lib linked into an `aarch64-apple-ios`/macOS app frequently produce unsymbolicated traces; `RUST_BACKTRACE=1` has historically *segfaulted* on macOS (rust-lang/rust#71397), and a dSYM sitting next to the binary has triggered libbacktrace crashes. Strategy: build with `split-debuginfo=packed` to get a `.dSYM`, archive it per release, and symbolicate **offline** server-side (Sentry/`symbolic`, or `atos -o …dSYM/Contents/Resources/DWARF/<bin> -l <load> <addr>`) rather than trusting in-process backtrace formatting on device.

### Hard crashes: minidumps and out-of-process capture

When the fault is a real signal, **doing work in-process is unreliable** — the heap/allocator may be corrupt, and on Windows in-process dumping is "notoriously buggy" (Mozilla's words). The state of the art is **out-of-process**: a separate monitor process writes the dump from the *outside*.

The **EmbarkStudios `crash-handling`** family is the pure-Rust toolkit here:

- `crash-handler` — installs platform handlers (Linux signals + `sigaltstack`, Windows vectored exception handling, **macOS Mach exception ports**) behind one `CrashEvent` trait.
- `minidumper` — client/server IPC; the crashing client requests a dump, the server process writes it (UDS on Linux, AF_UNIX on Windows 10.17063+, Mach IPC + UDS hybrid on macOS).
- `minidump-writer` — inspects the crashed process and emits a Breakpad-format minidump.

**macOS gotcha that directly bites a Swift `.app`:** Mach exception ports are consulted thread→task→host, and *Apple's own crash reporter uses Mach exceptions*. If your Rust crash handler claims the task exception port, you can shadow or fight Apple's reporter; if you only register a `SIGSEGV` signal handler, Mach-exception-based reporters preempt it and your handler never fires. You must decide deliberately who owns the exception port, and chain to the previous handler.

### Sentry

The official **`sentry`** crate's `sentry-panic` integration hooks `set_hook` and ships panics as events — but the docs are explicit that it **cannot capture hard native crashes**. Options: `sentry-rust-minidump` (timfish) wires `minidumper-child` to relaunch your exe in reporter mode and upload minidumps as attachments (small project, ~11 stars — vet before depending), or Sentry's official **Native SDK** built on Crashpad. Server-side, Sentry uses `symbolic` to symbolicate.

### What the big shops do, and the WASM case

**Firefox/Mozilla** replaced Breakpad's *processor* with pure-Rust **rust-minidump** (`minidump-stackwalk`), in production since ~Dec 2021, running in half the time and more reliably. Note: they kept Breakpad for *in-process* writing because the Rust writers only do out-of-process — and a later fuzzing campaign still found bugs the heavy test suite missed. Symbols come from `dump_syms`.

**WASM:** `wasm32-unknown-unknown` is `panic=abort` by default — a panic emits an `unreachable` trap surfacing as a JS `WebAssembly.RuntimeError`, **poisoning the whole instance** (sibling state lost, destructors skipped). `console_error_panic_hook` only improves the console message. The 2026 development: wasm-bindgen 0.2.x (Cloudflare, Apr 22 2026) added **`panic=unwind` for WASM** via the WebAssembly Exception Handling proposal (`-Cpanic=unwind -Zbuild-std`, `--panic-unwind` flag), so destructors run and the instance survives. For now this needs nightly `build-std`; on stable WASM, treat every panic as fatal-to-instance and have the JS host reload.

**Headless Linux:** simplest case — `panic=unwind` with a hook that logs structured JSON to stderr/journald, plus either a `minidumper` monitor or a process supervisor that captures the core dump and the `RUST_BACKTRACE` output, then symbolicate offline.


## Key takeaways
- Panics and hard crashes are two disjoint problems: set_hook/catch_unwind catch panics; only OS signal/Mach-exception handlers + a minidump writer catch SIGSEGV/SIGABRT/SIGFPE. A panic hook will never see a segfault.
- Decide panic=abort vs panic=unwind on day one — it changes ABI obligations at every FFI function and is expensive to retrofit. For an interactive editor, panic=unwind + catch_unwind at the boundary is right so one bad document doesn't kill the whole app and destructors still run.
- Set the panic hook to capture (message, location, backtrace via std::backtrace::Backtrace::capture()) while the stack is intact, but keep the sans-IO core out of the I/O business: hand the structured record to the host (Swift/TUI/JS/server) which owns transport.
- FFI baseline: wrap every exported extern "C" fn body in catch_unwind and return an error code; never let a panic unwind into Swift. extern "C-unwind" (stable since Rust 1.71, 2023) makes cross-boundary unwinding defined (abort instead of UB under panic=abort) — use it as a correctness backstop, not as permission to unwind into Swift/ObjC.
- Real native-crash capture should be out-of-process: a separate monitor writes the minidump from outside the corrupted process. EmbarkStudios crash-handler + minidumper + minidump-writer is the pure-Rust toolkit; Mozilla uses rust-minidump (minidump-stackwalk) for processing in Firefox since ~Dec 2021.
- WASM (wasm32-unknown-unknown) is panic=abort by default — a panic traps and poisons the whole instance (sibling state lost, no destructors). console_error_panic_hook only fixes the console message. As of wasm-bindgen ~0.2.x (Apr 2026) panic=unwind is possible via WebAssembly Exception Handling but still needs nightly -Zbuild-std.
- Symbolicate offline, server-side (Sentry/symbolic, dump_syms, or atos with an archived dSYM) — do not rely on in-process backtrace formatting, especially on Apple platforms where it is fragile.

## Gotchas
- catch_unwind is a silent no-op under panic=abort and on default wasm32-unknown-unknown — code that relies on it for FFI safety will not protect you there.
- Letting a Rust panic unwind across a plain extern "C" boundary into Swift/C is undefined behavior. extern "C-unwind" makes it defined but the safe pattern is still to catch_unwind inside the export and return an error code.
- macOS Mach exception ports are consulted thread→task→host and Apple's own crash reporter uses them. A Rust crash handler that claims the task exception port can shadow Apple's reporter; conversely a plain SIGSEGV signal handler never fires because Mach-exception reporters preempt it. Decide port ownership deliberately and chain the previous handler.
- RUST_BACKTRACE=1 has historically segfaulted on macOS (rust-lang/rust#71397), and a dSYM next to the binary has triggered libbacktrace crashes — don't assume in-process backtraces work on Apple targets.
- Rust panics from a static lib linked into an iOS/macOS app often come out unsymbolicated; you must archive the per-release dSYM and symbolicate offline (atos / Sentry / symbolic).
- In-process minidump writing is unreliable (heap/allocator may be corrupt; 'notoriously buggy on Windows' per Mozilla). Out-of-process is the production answer — but the pure-Rust minidump-writer only supports out-of-process, which is why Mozilla still uses Breakpad for in-process writing.
- Do as little as possible inside a signal/crash handler — it runs in async-signal-unsafe context. The minidumper design exists precisely so the crashing process only signals a monitor and the monitor does symbolication/upload.
- On WASM stable, a single panic traps and poisons the entire instance, silently affecting unrelated work in the same instance; the JS host must detect the RuntimeError and recreate/reload the instance.
- The official sentry crate's panic integration cannot capture hard native crashes — it only sees panics. You need sentry-rust-minidump or Sentry's Crashpad-based Native SDK for real crashes, and the third-party crate is small (~11 stars) so vet it.
- Stack overflow crashes on the crashing stack by default — without an installed sigaltstack the handler itself can't run. crash-handler installs an alternate signal stack; a hand-rolled handler must too.

## Crates
- std::panic (set_hook / catch_unwind) — stdlib panic hook + boundary containment; the in-core panic path. Stable, zero-dep, use everywhere.
- std::backtrace::Backtrace — stdlib backtrace capture inside the hook; gated on debuginfo + RUST_BACKTRACE. Stable.
- crash-handler (EmbarkStudios) — installs platform crash handlers (Linux signals+sigaltstack, Windows VEH, macOS Mach exception ports) behind one CrashEvent trait. Actively maintained, the de-facto pure-Rust choice for native crashes.
- minidumper (EmbarkStudios) — out-of-process client/server IPC so a monitor process writes the dump from outside the crashed process. Maintained; pairs with crash-handler.
- minidump-writer (EmbarkStudios/rust-minidump) — inspects a crashed process and writes a Breakpad-format minidump. Out-of-process only. Maintained.
- rust-minidump / minidump-stackwalk (Mozilla) — server-side minidump parsing + stackwalking; in Firefox production since ~Dec 2021, ~2x faster than Breakpad. Mature, well-tested (and fuzzed).
- dump_syms (Mozilla) — turns native build artifacts (PDB/DWARF/dSYM) into Breakpad symbol files for offline symbolication. Mature.
- symbolic (getsentry) — symbolication library (dSYM/DWARF/PDB) used by Sentry server-side. Mature, widely used.
- sentry + sentry-panic (getsentry) — official Rust SDK; hooks set_hook to report panics. Mature, but explicitly does NOT capture hard native crashes.
- sentry-rust-minidump (timfish) — relaunches the exe in reporter mode (via minidumper-child) and uploads minidumps to Sentry as attachments. Small project (~11 stars) — vet before depending.
- sentry-contrib-native / Sentry Native SDK — Crashpad-based native crash capture linkable into Rust; covers the hard-crash gap the official Rust SDK leaves. Maintained by Sentry/community.
- console_error_panic_hook (rustwasm) — routes WASM panics to console.error for readable messages/stack traces. Maintained; debugging aid only, not crash recovery.
- backtrace — backtrace capture/resolution crate underlying older tooling; mostly superseded by std::backtrace for capture. Maintained.

## Sources
- https://doc.rust-lang.org/std/panic/fn.set_hook.html — std::panic::set_hook (Rust std docs, current)
- https://doc.rust-lang.org/std/panic/fn.catch_unwind.html — catch_unwind in std::panic (Rust std docs, current)
- https://doc.rust-lang.org/stable/reference/panic.html — Panic (The Rust Reference, current) — panic hooks, abort vs unwind, FFI UB
- https://doc.rust-lang.org/nomicon/unwinding.html — Unwinding (The Rustonomicon, current)
- https://doc.rust-lang.org/nomicon/ffi.html — FFI (The Rustonomicon, current) — catching panics at FFI boundary
- https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html — RFC 2945 'C-unwind' ABI (FFI-unwind project group; stabilized Rust 1.71, Jul 2023)
- https://github.com/rust-lang/rust/issues/74990 — Tracking Issue for 'C-unwind ABI', RFC 2945 (rust-lang/rust)
- https://rust-lang.github.io/rfcs/1513-less-unwinding.html — RFC 1513 (panic strategy: abort vs unwind)
- https://jake-shadle.github.io/crash-reporting/ — 'Crash reporting in Rust', Jake Shadle / EmbarkStudios (deep dive: in-process vs out-of-process, signals, Mach ports, crash-handler/minidumper/minidump-writer)
- https://github.com/EmbarkStudios/crash-handling — EmbarkStudios crash-handling (crash-handler, minidumper, minidump-writer, crash-context, sadness-generator)
- https://hacks.mozilla.org/2022/06/everything-is-broken-shipping-rust-minidump-at-mozilla/ — 'Everything Is Broken: Shipping rust-minidump at Mozilla', Mozilla Hacks, Jun 2022
- https://firefox-source-docs.mozilla.org/contributing/debugging/debugging_a_minidump.html — Debugging A Minidump (Firefox Source Docs, current)
- https://bugzilla.mozilla.org/show_bug.cgi?id=1588742 — Replace breakpad's client code with a Rust implementation (Mozilla Bugzilla)
- https://docs.rs/sentry — sentry crate docs (panic integration; current)
- https://blog.sentry.io/debugging-a-segfault-in-rust/ — 'Debugging a Rust Segfault with Sentry' (Sentry blog)
- https://docs.sentry.io/platforms/native/usage/crashes/ — Application Crashes, Sentry for Native (Crashpad/minidump)
- https://github.com/timfish/sentry-rust-minidump — sentry-rust-minidump (out-of-process minidump capture to Sentry)
- https://github.com/getsentry/symbolic — symbolic (Sentry symbolication library)
- https://blog.sentry.io/ios-symbolication-troubles/ — 'The Troubles With iOS Symbolication' (Sentry blog)
- https://github.com/rust-lang/rust/issues/71397 — RUST_BACKTRACE on macOS can trigger crashes (rust-lang/rust)
- https://github.com/rust-lang/rust/issues/46796 — Issues with crash handling for iOS (rust-lang/rust)
- https://github.com/rustwasm/console_error_panic_hook — console_error_panic_hook (rustwasm)
- https://blog.cloudflare.com/making-rust-workers-reliable/ — 'Making Rust Workers reliable: panic and abort recovery in wasm-bindgen', Cloudflare, Apr 22 2026 (panic=unwind for WASM via Exception Handling)
- https://doc.rust-lang.org/beta/rustc/platform-support/wasm32-unknown-unknown.html — wasm32-unknown-unknown platform support (panic=abort default)
- https://developer.apple.com/forums/thread/113742 — 'Implementing Your Own Crash Reporter' (Apple Developer Forums; Mach exceptions vs signals)