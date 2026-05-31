# Rust in the Linux Kernel: Technical Constraints, Maintainer Friction, and Transferable Lessons

## Rust in the Linux Kernel (Rust-for-Linux)

Rust for Linux (RfL) is the most consequential real-world experiment in (a) operating Rust in a hard `no_std`/no-libstd environment and (b) introducing Rust into a ~30M-line C codebase with hostile-to-friendly maintainers. In **December 2025**, at the Tokyo Maintainers Summit, Miguel Ojeda posted a patch to "conclude the Rust experiment" — the `experimental` tag came off and Rust is now a permanent kernel fixture (merged originally in v6.1, 2022). Android already ships Rust kernel code (the binder driver) on millions of 6.12-based devices. ~20K+ lines of Rust have been upstreamed. Crucially, Ojeda tempered the milestone: *"this does not mean that everything works for every kernel configuration, architecture, toolchain"* — a lot of work remains. The lessons below are unusually relevant to a TextView core that targets WASM, FFI, and potentially `no_std` edges.

### Technical constraints (directly transferable to a sans-IO / FFI core)

| Constraint | How RfL handled it | Lesson for our core |
|---|---|---|
| No `std`, no default `alloc` | Custom kernel `alloc`; every allocating API is **fallible** (returns `Result`), never panics on OOM | Decide *early* whether the core must be `no_std`-able. Retrofitting `alloc`-free + fallible allocation onto a `std`-assuming core is expensive. |
| `panic=abort`, no unwinding | The kernel cannot unwind across the C ABI; panics are a hard error. RfL aims for a *panic-free subset*. | A panic that crosses an FFI boundary is UB. Plan for `panic=abort` at FFI/WASM edges from day one; keep panic-free invariants in the core. |
| Allocation flags (`GFP_KERNEL`, atomic context) | v6.10 added GFP flags to `Box`/`Vec`/`Arc` so allocation context is explicit | Generic, "context-aware" allocation is hard to bolt on later; if relevant, thread it through types early. |
| Self-referential / address-stable structs | The **pinned-initialization problem** — C structs (`list_head`, mutexes) embed self-pointers and must not move. Rust assumes values are movable. | `Pin` + in-place construction is a genuine paradigm clash with Rust's move semantics — see below. |
| Concurrency / memory model | LKMM (atomics, barriers, RCU, seqlocks) clashes with the borrow checker; RCU and seqlocks "cause about as much trouble for Rust ownership as for the C/C++ memory model" (paulmck) | Intrusive data structures and lock-free patterns fight the borrow checker; budget for `unsafe` cores wrapped in safe APIs. |

**The pinned-initialization problem** is the single most instructive technical gotcha. Ordinary Rust rarely hits it because userland code avoids self-referential structs; the kernel hits it everywhere (every mutex/synchronization primitive). The naive fix was a two-step `unsafe fn new()` + `unsafe fn init(self: Pin<&mut Self>)` — error-prone because safety relied entirely on the programmer remembering to call `init()`, and the requirement *propagated* up every containing struct. The solution, the **`pin-init`** crate, provides macro-based **in-place constructors** that make correct initialization structural rather than procedural, and supports *fallible* in-place init. `pin-init` has since been generalized for use outside the kernel — a reusable artifact born from this constraint. *Lesson: Rust's "initialize then move" model is fundamentally at odds with C-style in-place construction; if our FFI passes Rust structs to C that retain pointers, this bites.*

### The C ABI boundary

RfL generates Rust bindings from C headers via **bindgen**, then layers hand-written *safe abstractions* on top. Two pain points generalize: (1) C header changes can break bindgen output even when the C *compiles* fine (structural changes, layout), so the binding layer needs CI that fails loudly; (2) the impedance mismatch (ownership, lifetimes, nullability) must be absorbed *inside* the safe-abstraction layer — Hellwig's blunt framing: *"you write to C interfaces and deal with the impedance mismatch yourself."*

### Cultural / maintainer friction (the harder problem)

The technical work was largely tractable; the *social* integration was not. Two flashpoints:

- **Wedson Almeida Filho's resignation (Sep 2024)** citing *"nontechnical nonsense"* — triggered by Ted Ts'o objecting on the mailing list: *"you're not going to force all of us to learn Rust,"* with the underlying fear that evolving C would silently break Rust bindings nobody on the C side wanted to own.
- **The DMA-mapping standoff (Jan–Feb 2025)**: maintainer Christoph Hellwig — *"No rust code in kernel/dma, please"* and elsewhere likening multi-language mixing to "cancer" — refused Rust abstractions even when RfL offered to maintain them entirely themselves. Hellwig later stepped down as a DMA maintainer.

The resolution is a **governance principle** worth internalizing. Torvalds (Feb 2025): *"You can't say 'I want to have nothing to do with Rust', and then in the very next sentence say 'And that means that the Rust code that I will ignore cannot use the C interfaces I maintain'... 'ignore the Rust side' automatically also means that you don't have any *say* on the Rust side."* I.e. binding maintenance is the Rust side's burden; C maintainers are not required to fix Rust callers, and in exchange get no veto over them. The internal Rust abstraction API is explicitly **not** stabilized — it can churn as the C side changes, exactly like in-tree C APIs.

### Tooling built because off-the-shelf wasn't enough

- **`klint`** — out-of-tree lints using rustc-as-a-library to inspect MIR; the flagship lint tracks **preemption count at compile time** to catch *sleep-in-atomic-context* violations that neither API design nor the type system can express. It finds real bugs but isn't lint-clean on the tree (false positives).
- **`pin-init`** — the pinned-init macro library (above).
- **`rustc_codegen_gcc`** / GCC front-end work to satisfy the kernel's broad architecture support, since LLVM doesn't cover every target.

### Broadly applicable takeaways

1. **Decide the `no_std`/fallible-alloc/panic posture before writing the core, not after.** RfL's hardest plumbing was making allocation fallible and the code panic-free — a property that must be designed in.
2. **The "safe abstraction over unsafe C/FFI" layering pattern works** and is the template for any Rust-over-C-ABI core: keep `unsafe` minimal, audited, and wrapped.
3. **The expensive part of introducing Rust into a C project is ownership and politics, not the compiler.** Pre-agree who maintains the binding layer and whether the internal API is stable.
4. **The type system can't express everything** (atomic context, sleep) — expect to build custom lints/static analysis for domain invariants.


## Key takeaways
- Rust in the Linux kernel was declared 'no longer experimental' at the Dec 2025 Tokyo Maintainers Summit (merged v6.1 in 2022, ~20K+ lines upstreamed, binder shipping on millions of Android 6.12 devices) — but Ojeda explicitly noted much remains unfinished.
- The kernel runs Rust in no_std with a custom alloc where every allocating API is fallible (returns Result) and panic=abort with no unwinding — these posture decisions must be designed in from day one, not retrofitted.
- The pinned-initialization problem (self-referential, address-stable C structs vs Rust's move semantics) is the standout technical clash; it was solved with the reusable pin-init crate's macro-based in-place constructors.
- The pattern that works is a thin, audited unsafe FFI layer wrapped by hand-written safe abstractions over bindgen-generated bindings — minimize unsafe, push impedance-mismatch handling into the abstraction layer.
- The hard part of introducing Rust into a large C codebase was cultural/governance, not technical: Filho resigned over 'nontechnical nonsense' (Sep 2024) and Hellwig blocked Rust DMA abstractions (early 2025).
- Torvalds' governance ruling: a C maintainer who refuses to touch Rust also gets no veto over Rust callers of their C API; the Rust side owns its own binding maintenance and the internal Rust API is deliberately NOT stabilized.
- Some domain invariants (sleep-in-atomic-context) can't be expressed in the type system, so RfL built custom rustc-MIR-based lints (klint) — expect to write project-specific static analysis.

## Gotchas
- A panic unwinding across an FFI/C-ABI (or WASM) boundary is undefined behavior — the kernel uses panic=abort. Any Rust core called over FFI must treat panics as fatal and ideally maintain a panic-free invariant at the boundary.
- Rust's 'initialize-then-move' model fundamentally conflicts with C-style in-place construction of address-stable structs; if Rust structs are handed to C and have pointers retained into them, you hit the Pin/self-reference trap that took RfL years and a dedicated crate to tame.
- Making allocation fallible (Result on OOM) and stripping libstd is far cheaper to bake in from the start than to retrofit — std and the default alloc crate assume infallible, panicking allocation.
- C header changes can silently break bindgen-generated Rust bindings even when the C side still compiles cleanly (layout/structural changes) — CI must compile-check the binding layer, not just the C.
- Intrusive data structures, RCU, seqlocks, and lock-free patterns fight the borrow checker; expect to wrap an unsafe core in a safe API rather than expressing them in safe Rust directly.
- Don't assume the type system catches everything: context-sensitive rules like 'must not sleep here' require custom lints, and even klint isn't lint-clean (false positives) on the real tree.
- The internal Rust abstraction API is intentionally unstable in-tree — out-of-tree consumers that pin to it will break across releases, mirroring the kernel's no-stable-internal-API policy for C.

## Crates
- pin-init (formerly pinned-init) — macro-based safe, fallible, in-place initialization of pinned/self-referential structs; born in RfL, now generalized for general no_std/embedded Rust — actively maintained, the canonical answer to the Pin-init problem
- klint — out-of-tree rustc-as-a-library lints (MIR-level) enforcing kernel invariants like atomic-context/preemption-count rules that the type system can't express — RfL-maintained, demonstrates the 'build your own static analysis' pattern; not yet lint-clean (false positives)
- bindgen — generates Rust FFI bindings from C headers; the workhorse of RfL's C-ABI boundary — widely used and well-maintained, but binding stability across C header changes must be CI-guarded
- rustc_codegen_gcc — GCC-backed Rust codegen used to reach kernel targets LLVM doesn't cover — relevant only if broad/exotic target support is needed; still maturing

## Sources
- https://lwn.net/Articles/1049831/ — The (successful) end of the kernel Rust experiment, LWN, 2025-12-10
- https://lwn.net/Articles/1006805/ — Resistance to Rust abstractions for DMA mapping, LWN, 2025-01-30
- https://lwn.net/Articles/1011197/ — Linus on Rust and the kernel's DMA layer, LWN, 2025-02-21
- https://rust-for-linux.com/the-safe-pinned-initialization-problem — The Safe Pinned Initialization Problem, Rust for Linux project docs
- https://rust-for-linux.com/pin-init — pin-init, Rust for Linux project docs
- https://www.memorysafety.org/blog/gary-guo-klint-rust-tools/ — Klint: Compile-time Detection of Atomic Context Violations for Kernel Rust Code, ISRG Prossimo / Gary Guo
- https://lwn.net/Articles/951550/ — Preventing atomic-context violations in Rust code with klint, LWN
- https://lwn.net/Articles/1038750/ — Linting Rust code in the kernel, LWN
- https://paulmck.livejournal.com/62436.html — So You Want to Rust the Linux Kernel?, Paul McKenney, 2021-09 (with later updates)
- https://www.theregister.com/2024/09/02/rust_for_linux_maintainer_steps_down/ — Rust for Linux maintainer steps down in frustration, The Register, 2024-09-02
- https://www.theregister.com/2025/02/05/mixing_rust_and_c_linux/ — Mixing Rust and C in Linux likened to cancer by maintainer, The Register, 2025-02-05
- https://www.theregister.com/2025/03/10/rust_drivers_expected_to_become/ — Strap in, get ready for more Rust drivers in Linux kernel, The Register, 2025-03-10
- https://lpc.events/event/18/contributions/1912/attachments/1619/3351/2024-09-19%20-%20LPC%202024%20-%20Rust%20for%20Linux.pdf — Rust for Linux (LPC 2024 talk slides), Miguel Ojeda, 2024-09-19
- https://www.phoronix.com/news/Rust-To-Stay-Linux-Kernel — New Linux Patch Confirms: Rust Experiment Is Done, Phoronix, 2025-12
- https://en.wikipedia.org/wiki/Rust_for_Linux — Rust for Linux, Wikipedia (overview/timeline)
- https://arxiv.org/html/2407.18431v1 — Rusty Linux: Advances in Rust for Linux Kernel Development, arXiv, 2024-07