# Rust at Microsoft: Windows kernel rewrites, the windows-rs interop layer, formally-verified crypto, and what adoption-at-scale actually taught them

## Rust at Microsoft — learnings for a sans-IO core + FFI app

Microsoft is the most-cited "Rust in security-critical systems software" case study, and the useful part for *us* is not the press-release "rewrite Windows in Rust" narrative (which their own engineers keep walking back) but the **engineering learnings**: how they did C/C++ interop, why they split crates the way they did, what the ROI actually was, and where Rust's guarantees stopped short. The directly transferable lessons map almost 1:1 onto a sans-IO core embedded over FFI.

### The motivation and the ROI — verified, and it moved
The founding claim (MSRC, Jul & Nov 2019) is that **~70% of CVEs Microsoft assigned since 2006 were memory-safety issues**, *despite* code review, training, static analysis, and sanitizers. That last clause is the load-bearing one: their explicit position was that C++ tooling is structurally insufficient — only compiler-enforced guarantees are reliable. The 2025 follow-up data is the part most reports omit: of the ~33,000 CVEs published in 2025 with a CWE category, **memory-safety dropped to ~21%** — evidence that the industry-wide shift (Rust + hardening + safer C++ subsets) is actually working, not just a talking point.

### How it actually shipped (the "crawl, walk, run" reality)
David Weston (VP, OS & Enterprise Security) framed adoption at BlueHat IL 2023 as **"we are at the crawl stage"** and bluntly: *"rewriting Windows in Rust probably isn't going to happen anytime soon… we need a strategy that also includes securing more of our native code."* What concretely shipped:

| Component | Status / size | Note |
|---|---|---|
| **DWriteCore** (DirectWrite text/font) | ~152k LOC Rust + ~96k LOC C++ (coexisting) | first real target; **5–15% faster** glyph shaping. Font parsing = classic attacker-controlled-input surface |
| **Win32k GDI regions** | `win32kbase_rs.sys`, ~36k LOC Rust | shipped in **Windows 11 24H2**, behind a feature flag; boots, passes all GDI tests |
| **A kernel syscall** | implemented in Rust | proof that Rust can live in the NT kernel |
| **SymCrypt** (core crypto lib) | ML-KEM preview on `feature/verifiedcrypto` | see below — the most interesting one |

The 2030 "eliminate all C/C++" goal (Distinguished Engineer Galen Hunt, Dec 2025, *"1 engineer, 1 month, 1 million lines"* via AI agents) was immediately **clarified by Microsoft itself as a research project**, not a Windows rewrite plan. Treat the headline as aspiration; treat DWriteCore/GDI/SymCrypt as the real evidence.

### SymCrypt-in-Rust — the most relevant pattern for a safety-critical core
This (MS Research, Jun 2025) is the standout because it solves the *exact* problem we have — a portable core that must drop into hostile, heterogeneous host toolchains:

- **They compile Rust *back to C*** using **Eurydice** (Rust MIR → C) and check the generated C into the repo *alongside* the Rust source. Rationale: downstream consumers "rely on specific toolchains or compiler features that complicate adoption of Rust" — so the safe language is the *source of truth*, but the shipped artifact stays maximally portable. This is the inverse of the usual "Rust core + thin C shim" and worth knowing exists.
- Rust's aliasing guarantee is leveraged as a *proof obligation for free*: *"Rust's type system guarantees [non-overlapping] for any two mutably borrowed references"* — a property you must prove externally in C. The borrow checker pays dividends in verification, not just runtime safety.
- They explicitly note **memory safety is necessary but not sufficient**: side channels (timing, speculative execution) *"can leak private information even when the source code is provably correct."* Constant-time source isn't enough on modern CPUs, so they verify *compiled binaries* (Revizor) and prove functional correctness with **Aeneas → Lean** (MS Azure Research + Inria).

### windows-rs — the interop learnings that map to our FFI edge
`windows-rs` is the binding layer and its design history is a cheat-sheet for FFI ergonomics vs. compile cost:

- **Metadata-driven generation, not hand-written bindings.** Bindings are generated from the Windows API metadata (.winmd) via `windows-bindgen`, so they track every past/present/future API. Lesson: for any large FFI surface, generate from a machine-readable contract, don't hand-maintain.
- **The `windows` vs `windows-sys` split is a compile-time learning.** Kenny Kerr's stated finding: *"the most expensive aspect… is the cost of compiling function bodies."* So `windows-sys` ships **only externs/structs/constants** (zero wrappers) and compiles dramatically faster; `windows` adds the ergonomic safe layer at a build-time cost. The split itself is the lesson: **separate the raw `-sys` ABI layer from the safe/ergonomic layer**, so consumers who care about build time can opt out of the sugar.
- They later split into many narrow crates (`windows-core`, `windows-result`, `windows-strings`, `windows-link`, …) — granularity to avoid pulling the whole surface for a small need.
- The original 2019 FFI guidance still holds: **every FFI call goes through a wrapper that provides a safe abstraction; `unsafe` is confined and audited** — exactly the `forbid(unsafe_code)` core + audited-edge model we've chosen.

### Where Microsoft hit friction (the gotchas worth front-loading)
From the 2019 MSRC posts and later reporting, the recurring pain:
- **C++ interop is the hard part, not C.** C ABI is straightforward; C++ (vtables, templates, name mangling, by-value structs) is where tooling breaks. A long-standing bindgen bug can **segfault when Rust/C++ structs share layout but differ in by-value ABI**.
- **Build-system impedance mismatch.** Microsoft's internal build system couldn't use Cargo's test harness; integrating Cargo into a large non-Cargo build (CMake/MSBuild) was real work. (Industry answer: Corrosion for CMake↔Cargo.)
- **`unsafe` governance at scale** — keeping `unsafe` confined and reviewed across thousands of engineers needed process, not just the keyword.
- **Leaky abstractions resist porting** — components with abstractions leaking across layers needed C++-side refactoring *before* Rust could be introduced. Clean interfaces port first.
- Russinovich's Sep 2022 "deprecate C/C++ for new projects" call carried a key caveat: **only where a non-GC language is required** — Rust is the systems-tier answer, not a universal one.


## Key takeaways
- The 70%-of-CVEs-are-memory-safety figure (MSRC 2019) was Microsoft's founding justification; their explicit position is that C++ static analysis/sanitizers are structurally insufficient and only compiler-enforced guarantees are reliable. 2025 data shows memory-safety CVEs fell to ~21% industry-wide, so the bet is paying off.
- Microsoft's own engineers temper the hype: Weston (BlueHat 2023) called it the 'crawl stage' and said rewriting Windows in Rust 'isn't going to happen anytime soon'; the Dec 2025 '2030, 1M LOC/engineer via AI' goal was clarified by Microsoft as a research project, not a Windows plan. Judge by shipped artifacts (DWriteCore, GDI, SymCrypt), not slogans.
- windows-rs's `windows` vs `windows-sys` split encodes a directly reusable lesson: the compiler's cost is dominated by compiling function BODIES, so isolate a raw zero-wrapper `-sys` ABI layer from the ergonomic safe layer and let build-time-sensitive consumers opt out of the sugar.
- windows-rs generates all bindings from machine-readable API metadata rather than hand-maintaining them — for any large FFI surface, generate from a contract.
- SymCrypt-in-Rust is the best template for a portable safety-critical core: keep Rust as the source of truth but compile it back to C (Eurydice) and ship that, so hostile/heterogeneous host toolchains aren't a blocker. Rust's mutable-aliasing guarantee doubles as a free proof obligation for formal verification.
- Memory safety is necessary but not sufficient: SymCrypt explicitly verifies compiled binaries for side channels (timing/speculative) because constant-time source code isn't enough on modern CPUs. Don't assume 'safe Rust' closes non-memory vulnerability classes.
- The 2019 FFI rule Microsoft still follows matches our chosen model exactly: confine `unsafe` to audited wrapper functions that expose a safe abstraction; keep the bulk of the core safe.

## Gotchas
- C++ interop is the genuinely hard part, not C. The C ABI is straightforward; C++ vtables/templates/mangling/by-value structs break tooling. A long-standing bindgen bug can segfault when Rust and C++ structs share memory layout but differ in by-value calling ABI — keep your FFI boundary to a C ABI (extern "C", #[repr(C)]) and avoid passing complex structs by value.
- Build-system impedance: Microsoft's large internal builds couldn't use Cargo's test harness and integrating Cargo into a non-Cargo build is real work. If the macOS/SwiftPM/CMake side drives the build, plan the Cargo<->host build bridge early (e.g. Corrosion-style) rather than retrofitting.
- Leaky abstractions resist porting: components whose abstractions leak across layers needed refactoring on the C++ side BEFORE Rust could be introduced. Clean module boundaries are a prerequisite for a swappable core — a point in favor of the sans-IO design.
- Russinovich's 'deprecate C/C++' call was explicitly scoped to 'where a non-GC language is required.' Rust is the systems-tier answer, not a blanket recommendation; don't over-generalize the mandate.
- 'Microsoft is rewriting Windows in Rust' is largely press inflation. Real shipped scope as of 24H2 is targeted (GDI regions behind a flag, DWriteCore, one syscall, SymCrypt preview). The AI-mass-translation story was downgraded to research by Microsoft itself — don't anchor architecture decisions on the headline.
- windows-rs recommends version RANGES (e.g. >=0.59,<=0.61) over caret requirements to keep the resolver flexible across its many sub-crates — a maintenance quirk worth knowing if you ever depend on the Windows bindings for the native edge.

## Crates
- windows-sys — raw C-style Win32 bindings (externs/structs/constants only, no wrappers); the zero-overhead, best-compile-time tier. Microsoft-official (microsoft/windows-rs), dual MIT/Apache, ~135M downloads/month, only depends on windows-link. Verdict: gold-standard reference for how to structure a fast-compiling -sys layer; only directly relevant if the native edge calls Win32.
- windows — ergonomic/safe bindings over Win32 + COM + WinRT, generated from API metadata; adds traits/helpers at a build-time cost vs windows-sys. Microsoft-official, very widely used. Verdict: the 'safe ergonomic layer' half of the split pattern.
- windows-bindgen — generates the above crates from Windows .winmd metadata. Verdict: example of contract-driven binding generation; not a dependency for us, but the pattern (generate FFI from a machine-readable spec) is the takeaway.
- Eurydice — Microsoft Azure Research Rust(MIR)->C compiler used for SymCrypt; lets Rust be the source of truth while shipping portable C. Research-grade, not a general dependency. Verdict: know it exists if host-toolchain portability ever trumps shipping a Rust staticlib.
- Aeneas — MS Azure Research + Inria; translates Rust to a pure functional model for formal verification (connects to Lean). Research/verification tooling. Verdict: relevant only if any core invariant ever warrants machine-checked proof; otherwise just context for 'Rust's borrow checker aids verification.'

## Sources
- https://www.microsoft.com/en-us/msrc/blog/2019/07/why-rust-for-safe-systems-programming — 'Why Rust for safe systems programming' (MSRC, Jul 2019) — origin of the 70%-memory-safety-CVE argument and 'tooling is insufficient' position
- https://www.microsoft.com/en-us/msrc/blog/2019/11/using-rust-in-windows — 'Using Rust in Windows' (MSRC, Nov 2019) — FFI/unsafe wrapping guidance, build-system and C++ interop gotchas, developer ramp-up data
- https://www.theregister.com/2023/04/27/microsoft_windows_rust/ — 'Microsoft is rewriting core Windows libraries in Rust' (The Register, Apr 27 2023) — DWriteCore 152k/96k LOC, GDI 36k LOC, kernel syscall, Weston quotes
- https://www.theregister.com/2022/09/20/rust_microsoft_c/ — 'In Rust We Trust: Microsoft Azure CTO shuns C and C++' (The Register, Sep 20 2022) — Russinovich 'deprecate C/C++' with the non-GC caveat
- https://www.microsoft.com/en-us/research/blog/rewriting-symcrypt-in-rust-to-modernize-microsofts-cryptographic-library/ — 'Rewriting SymCrypt in Rust' (Microsoft Research, Jun 10 2025) — Eurydice Rust->C, Aeneas/Lean verification, side-channel/Revizor, constant-time caveats
- https://www.windowslatest.com/2025/12/24/microsoft-confirms-eliminate-c-and-c-plan-translate-code-to-rust-using-ai-as-windows-11-adopts-rust-and-webview2/ — Galen Hunt 2030 goal, '1 engineer/1 month/1M LOC', Microsoft's clarification that it's a research project (Dec 24 2025)
- https://github.com/microsoft/windows-rs — windows-rs repo — crate split rationale, metadata-driven generation, current state (Release 73, 2026)
- https://microsoft.github.io/windows-rs/book/rust-getting-started/windows-or-windows-sys.html — Kenny Kerr, 'Choosing between the windows and windows-sys crates' — 'cost of compiling function bodies' compile-time learning
- https://lib.rs/crates/windows-sys — windows-sys crate facts (v0.61.2, Oct 2025; ~135M downloads/month; depends only on windows-link)
- https://media.defense.gov/2025/Jun/23/2003742198/-1/-1/0/CSI_MEMORY_SAFE_LANGUAGES_REDUCING_VULNERABILITIES_IN_MODERN_SOFTWARE_DEVELOPMENT.PDF — NSA/CISA CSI on memory-safe languages (Jun 2025) — context for the ~21% 2025 memory-safety CVE figure