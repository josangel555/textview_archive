# Rust at Mozilla: Shipping Rust Incrementally Inside a Huge C++ Codebase (Servo, Oxidation, Stylo, WebRender)

## Rust at Mozilla — the original case study in shipping Rust inside a C++ giant

Mozilla is where Rust was born and where it first survived contact with a multi-million-line production C++ codebase (Firefox/Gecko). The story splits cleanly into two arcs with opposite lessons:

1. **Servo** — the all-Rust research browser engine. *Architecturally ambitious, organizationally fragile.* It proved Rust could write a browser, but the full-rewrite never shipped as a browser and the team was laid off in 2020.
2. **Oxidation** — the *incremental* program that surgically replaced individual Gecko components with Rust. *This is the part that shipped to hundreds of millions of users and is the directly relevant playbook for your embedded core.*

The single most-cited meta-lesson, from multiple Mozilla engineers: **the technical hurdles were never the limiting factor.** Ralph Giles (first Rust in Firefox): *"Large organizations don't adopt new ideas quickly, and much of the work involved convincing others this was a worthwhile experiment."* For a solo/small project this inverts into a gift — you have no organization to convince, so the *integration mechanics* below become your whole job.

### The three shipped milestones — and what each taught

| Component | Shipped | Why chosen | Core lesson |
|---|---|---|---|
| **mp4parse** (MP4 demuxer) | FF48, 2016 | Small, revertible, parses *untrusted input*, suspected-buggy C++ | First Rust in prod. *Coding took 6 weeks; integration took ~a year.* |
| **Stylo / Quantum CSS** | FF57, 2017 | Servo's most mature subsystem; CSS is embarrassingly parallel | Rust delivered parallelism C++ failed at twice. But the *tight* FFI was the hardest integration Mozilla ever did. |
| **WebRender** (GPU compositor) | FF67, 2019 | Servo's GPU renderer | The Rust was the easy part. *Shipping was gated for years on GPU driver/shader bugs*, not language issues. |

**mp4parse — the "start tiny and revertible" template.** Giles deliberately picked something "small and easy to revert to minimize damage." Memory-safe parsing of untrusted input is the highest-ROI thing to put in Rust. The shock was the *ratio*: weeks of Rust, a year of build/CI/platform plumbing.

**Stylo — the parallelism win, and the FFI tax.** Stylo replaced ~160K lines of C++ with ~85K lines of Rust. Mozilla had attempted to parallelize the style system in C++ *twice* and failed both times; data races made it intractable. Rust's `Send`/`Sync` made it *statically* safe, turning style computation into a near-linear parallel speedup. Bobby Holley's candid framing — *"boiling the ocean, incrementally"* — is the strategy: don't swap the whole engine, find the one subsystem that's "fast and relatively mature" and bridge it. Started with **2-3 people**, 15 months from first pixels to shipping.

But Stylo is also the cautionary tale: because CSS is tightly coupled to DOM/layout, *there was no clean API to cut at*. The result was "really complicated FFI code" with constant cross-language callbacks, shared mutable structs, and an Arc that C++ could read directly (the `OffsetArc`/triomphe trick). Manish Goregaokar's explicit advice years later: **don't do what Stylo did unless you must.** Aim for a component "self-contained enough that you maintain ~ten FFI functions."

**WebRender — the language was never the risk.** The retrospective bugs are almost all *hardware reality*, not Rust: Adreno 505/506 driver crashes during shader compilation, 60-500ms/shader compile times on Windows (cut to 4-10ms only with binary caching), macOS shader-compile startup regressions, nested-switch shader bugs. Mozilla shipped via a *narrow rollout matrix* — NVIDIA-on-Win10 first — to avoid being flooded. Lesson for any core touching platform edges (GPU, filesystem, OS APIs): the safe-Rust core is cheap; the *I/O/platform edge is where the multi-year cost lives.* This validates your "async/threading/unsafe contained at the edges" architecture.

### The FFI mechanics Mozilla settled on (directly load-bearing for Swift↔Rust)

- **`cbindgen`** generates C headers *from* your Rust `extern "C"` API. This is your primary tool for a Rust-core-exposed-to-Swift design — it's exactly the WebRender pattern.
- **`bindgen`** does the reverse (Rust bindings from C/C++ headers); you'll need it only if the core calls *back* into host C APIs.
- **Check the generated bindings into source control** and add a **CI job that regenerates and diffs** — fail the build if they drift. This removes LLVM/bindgen from the build dependency of anyone not actively touching FFI, and catches ABI skew early. Mozilla moved Stylo *off* build-time bindgen for exactly this (bug 1560981).
- **Auto-generate struct-layout assertion tests** that verify field offsets/sizes match across the boundary (Mozilla ran these in CI, bug 1373878). This is the single highest-value FFI safety net.
- **Allocator discipline:** never transfer ownership of an allocation across the FFI if Rust and the host use different allocators — "disastrous consequences." Either provide Rust destructor FFI functions, or pin a shared `#[global_allocator]`.
- **Never pass non-POD types by value across FFI** (broken on MSVC; ABI-fragile everywhere). Marshal through `#[repr(C)]` POD structs.
- **Don't blanket-mark all host calls `unsafe`** — Manish argues that causes "alarm fatigue" and hides the genuinely dangerous spots. Wrap the boundary so safe-on-the-host-side calls are exposed as safe Rust.

### What actually killed Servo-the-browser

Two failures, both worth internalizing:

1. **Organizational/funding, not technical.** The 2020 layoffs cut the *entire* Servo team — collateral damage of Mozilla's revenue crisis (≈90% of revenue from the Google search deal), not a verdict on the code. Servo limped to the Linux Foundation, went near-dormant 2021-22, then **Igalia revived it in 2023** with ~5 funded engineers under LF Europe + NLnet/Sovereign Tech Fund grants. The lesson: *an ambitious Rust rewrite needs a durable funding/ownership story or it rots.*

2. **Over-ambitious architecture.** Servo's original "Layout 2013" chased *fine-grained parallelism everywhere* via rigid separation of tree traversal from node ops. CSS floats "did not map well to this model" — "basically completely broken," "impossible to reason about." Igalia threw it out for "Layout 2020." The lesson cuts against naive parallel-everything: **parallelize where the domain is embarrassingly parallel (Stylo's style cascade), not where correctness fights you (layout/floats).** A synchronous functional core that adds parallelism surgically is the *correct* read of this history.


## Key takeaways
- Incremental beats rewrite: Mozilla's wins (mp4parse, Stylo, WebRender) all came from surgically replacing one Gecko subsystem at a time ('boiling the ocean incrementally'). The full-Servo rewrite never shipped as a browser. For your core, build it standalone and embed it component-by-component.
- Coding is cheap; integration is the real cost. mp4parse was ~6 weeks of Rust and ~a year of build/CI/platform plumbing. Budget accordingly — the FFI/build/CI machinery is the project, not the safe-Rust logic.
- Pick the first component to be small, revertible, and a parser of untrusted input. mp4parse was deliberately easy to back out. Memory-safe parsing of hostile input is Rust's highest-ROI target.
- Parallelize only where the domain is embarrassingly parallel. Stylo's parallel CSS cascade was a linear-speedup home run (C++ failed at it twice); Servo's parallel *layout* (floats) was 'completely broken' and got rewritten. A sync functional core with surgical parallelism is the historically-validated choice.
- Rust's static Send/Sync is the actual moat. The headline Stylo result is data-race-freedom *at compile time* enabling parallelism that two prior C++ attempts couldn't achieve safely.
- Keep FFI surfaces small and self-contained — aim for ~ten FFI functions per component. Stylo's tight, callback-heavy integration was Mozilla's hardest-ever and the engineer who built it says explicitly: don't copy it.
- Check generated FFI bindings (cbindgen output) into the repo and CI-diff them; auto-generate struct-layout assertion tests. These two practices catch ABI drift before it becomes a memory-safety bug at the boundary.
- The platform/IO edge is where multi-year cost hides, not the language. WebRender's Rust was fine; shipping was gated for years on GPU driver and shader-compilation bugs. Plan a narrow rollout matrix and heavy edge testing.
- First-time Rust contributors were ~70x less likely to introduce vulnerabilities than first-time C++ contributors (Mozilla-cited figure) — the safety dividend is real and measurable, but accrues at the cost of upfront integration investment.
- Sustainability is a first-class risk for ambitious Rust projects. Servo's near-death wasn't technical — it was funding/ownership. A solo project's analogue is scope discipline: don't build more engine than one person can maintain.

## Gotchas
- Never transfer ownership of an allocation across the FFI boundary when Rust and the host (Swift) use different allocators — 'disastrous consequences.' Provide Rust-side destructor FFI functions, or pin a shared #[global_allocator].
- Never pass non-POD types by value across FFI — works on some toolchains but broken on MSVC and ABI-fragile generally. Marshal through #[repr(C)] POD structs converted right at the boundary.
- C enums can legally hold invalid values; Rust enums cannot — a C-set out-of-range value read as a Rust enum is instant UB. For bitflag-style fields use integers, not enums, when type-replacing across FFI.
- Don't blanket-wrap every host call in `unsafe` — it causes alarm fatigue and hides the genuinely dangerous call sites. Expose host-safe operations as safe Rust; reserve `unsafe` for truly dangerous ops.
- cbindgen is a standalone Rust parser, NOT a rustc plugin — it can silently mis-handle newer Rust syntax/features as the language evolves. Treat its output as something to verify (CI diff + layout tests), not trust blindly.
- Regenerating FFI bindings at build time forces LLVM/bindgen onto every contributor and makes builds non-deterministic. Check bindings in and gate drift in CI instead.
- Adding a new compiled language explodes your CI/platform matrix. Mozilla took ~6 months to go from shipping on the first platform (x86_64-linux) to the last (armv7-android) purely on toolchain/target availability. Verify Rust+LLVM target support for every platform you intend to ship (incl. WASM and any TUI/Linux targets) before committing.
- Frequent Rust stable releases will churn your pinned toolchain and bootstrap scripts; pin the toolchain (rust-toolchain.toml) from day one and treat upgrades as deliberate events, not drift.
- Tight, callback-heavy FFI (the Stylo pattern) is exponentially harder than a clean boundary. If you find yourself doing constant cross-boundary callbacks and sharing mutable structs, that's a design smell — reshape the API to a small batch-style surface.
- A multi-year-abandoned Rust codebase rots hard: Servo's revival required massive dependency upgrades (SpiderMonkey, Stylo, WebRender all far behind) before any feature work. Keep dependencies current continuously; the catch-up cost compounds.

## Crates
- cbindgen — generates C headers from a Rust extern "C" API; this is the canonical tool for exposing a Rust core to a host language (used by WebRender in Firefox). Maintained by Mozilla, widely used, production-proven — the right default for your Swift↔Rust direction.
- bindgen — generates Rust bindings from C/C++ headers (the reverse direction); needed only if the core calls back into host C APIs. Mature, widely used, requires LLVM at generation time (so check output in).
- cxx — safer, more ergonomic C++↔Rust interop with automatic opaque-type and reference handling; Mozilla engineers retrospectively note it 'is probably a better tool' than raw bindgen for many cases. Relevant only if you bridge to C++ rather than C/Swift.
- triomphe (OffsetArc / Stylo's Arc) — a custom Arc variant letting C++ read the refcounted payload directly as *const T while Rust owns clone/drop; an example of the heroics tight FFI demands. Verdict: a pattern to *avoid needing*, not a dependency to adopt.

## Sources
- https://hacks.mozilla.org/2016/07/shipping-rust-in-firefox/ — 'Shipping Rust in Firefox', Mozilla Hacks (Jul 2016) — first Rust component (mp4parse) announcement
- https://medium.com/mozilla-tech/deploying-rust-in-a-large-codebase-7e50328074e8 — Ralph Giles, 'Deploying Rust in a large codebase', Mozilla Tech (Feb 22, 2017) — build/CI/platform integration cost firsthand
- https://bholley.net/blog/2017/stylo.html — Bobby Holley, 'Boiling the Ocean, Incrementally: How Stylo Brought Rust and Servo to Firefox' (Nov 28, 2017) — incremental strategy, team/timeline
- https://hacks.mozilla.org/2017/08/inside-a-super-fast-css-engine-quantum-css-aka-stylo/ — Lin Clark, 'Inside a super fast CSS engine: Quantum CSS (aka Stylo)', Mozilla Hacks (Aug 2017) — parallelism + LOC numbers
- https://blog.rust-lang.org/2017/11/14/Fearless-Concurrency-In-Firefox-Quantum/ — 'Fearless Concurrency in Firefox Quantum', Rust Blog (Nov 14, 2017) — two failed C++ parallelism attempts, Rust succeeded
- https://manishearth.github.io/blog/2021/02/22/integrating-rust-and-c-plus-plus-in-firefox/ — Manish Goregaokar, 'Integrating Rust and C++ in Firefox' (Feb 22, 2021; drafted 2018) — the definitive FFI gotchas/tooling reference
- https://wiki.mozilla.org/Oxidation — MozillaWiki 'Oxidation' (last updated Nov 17, 2020) — component selection criteria and the shipped-Rust-components list
- https://firefox-source-docs.mozilla.org/writing-rust-code/cpp-interop.html — Firefox Source Docs, 'Rust/C++ interop' — why both cbindgen and bindgen, checked-in bindings, layout tests
- https://github.com/servo/webrender/wiki/Driver-issues — Servo/WebRender wiki 'Driver issues' — concrete GPU driver/shader-compilation failures that gated WebRender shipping
- https://en.wikipedia.org/wiki/Servo_(software) — 'Servo (software)', Wikipedia — timeline incl. 2020 layoffs, LF handoff, WPT pass-rate recovery
- https://blogs.igalia.com/mrego/servo-revival-2023-2024/ — Manuel Rego, 'Servo Revival: 2023-2024' (Nov 15, 2024) — post-abandonment dependency rot, Layout 2020 consolidation, funding model
- https://www.igalia.com/2023/09/07/The-Servo-project-is-joining-Linux-Foundation-Europe.html — Igalia, 'The Servo project is joining Linux Foundation Europe' (Sep 7, 2023) — governance/funding handoff
- https://pcwalton.github.io/_posts/2014-02-25-revamped-parallel-layout-in-servo.html — Patrick Walton, 'Revamped Parallel Layout in Servo' (Feb 25, 2014) — fine-grained parallel layout design (later found too rigid for floats)
- https://servo.org/blog/2023/04/13/layout-2013-vs-2020/ — Servo blog, 'Layout 2013 and Layout 2020' (Apr 13, 2023) — why the original parallel layout was abandoned