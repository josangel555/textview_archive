# Rust at Large Shops: Documented ROI, Post-Mortems, and Adoption Lessons

## Rust at Other Large Shops — what the documented record actually says

The headline story across AWS, Google, Microsoft, Cloudflare, Discord, and Dropbox is consistent and now backed by *measured* data, not just vibes: Rust delivers C/C++-class performance with a near-elimination of memory-safety defects, and — the genuinely surprising 2025 finding — it does so while **increasing** development velocity rather than trading it away. The interesting material for a first Rust project is in the *how* and the *what-bit-them*, not the ROI numbers.

### The ROI scoreboard (primary sources)

| Shop | Project | Documented result |
|---|---|---|
| **Discord** | Read States (Go → Rust, 2020) | Killed GC-induced latency spikes every ~2 min; p99 dropped from milliseconds to **microseconds**; minimally-tuned Rust beat hand-tuned Go on latency, CPU, *and* memory |
| **Cloudflare** | Pingora (NGINX replacement) | **70% less CPU, 67% less memory** at equal load; ~1T req/day; "few hundred trillion requests, yet to crash due to our service code"; connection reuse 87.1% → 99.92% |
| **AWS** | Firecracker microVM | ~50k LOC VMM (96% smaller than QEMU), <125 ms boot, ~5 MiB/microVM; powers Lambda/Fargate |
| **Google** | Android | Memory-safety bugs **<20%** of total (2025) vs ~76% in 2019; Rust vuln density **~0.2/MLOC vs ~1000/MLOC** for C/C++ (1000× lower); **4× lower rollback rate**, **25% less time in code review**, 20% fewer revisions than C++ |
| **Microsoft** | Windows kernel / DirectWrite | 188k+ LOC rewritten; a researcher-found Rust bug produced a BSOD (crash) instead of the privilege escalation the same C++ bug would have enabled |
| **Dropbox** | Nucleus sync engine | 4-year rewrite; "betting on Rust was one of the best decisions we made" |

### The genuinely non-obvious lessons

**1. The safety/velocity tradeoff inverted.** Google's 2025 data is the strongest evidence yet that "the safer path is now also the faster one." The 4× lower rollback rate and 25% faster code review aren't security metrics — they're *throughput* metrics. The mechanism: defects the compiler catches never reach review or production, so reviewers reason about logic, not lifetimes-gone-wrong. This is the single most quotable finding for justifying Rust to skeptics.

**2. `unsafe` is not the escape hatch people fear.** Google measured ~4% of their Rust inside `unsafe {}` and found it *still* far safer than C/C++, for three concrete reasons: `unsafe` blocks don't disable *most* checks (borrow checking still runs), unsafe is *encapsulated* so you can reason about safety locally, and unsafe blocks attract heightened review scrutiny. Directly relevant to your `forbid(unsafe_code)` core + audited-FFI-edge model — that's exactly the encapsulation pattern Google validated.

**3. Defense-in-depth still matters — Rust is not a force field.** Google's near-miss (CVE-2025-48530, CrabbyAVIF) was a *linear buffer overflow in Rust code* that shipped to pre-release. It was rendered non-exploitable only by Scudo (Android's hardened allocator) guard pages. Lesson: even in safe-ish Rust, keep allocator hardening / fuzzing / OS mitigations. They also found crash reporting initially couldn't identify overflow causes — observability gaps bite even when the safety story is strong.

**4. "Designing away invalid states" is the force multiplier, not raw speed.** Dropbox's Nucleus is the canonical lesson for a *correctness-critical core* like yours. Their core architectural principle was using the type system to make invalid system states **unrepresentable**, and tying all control logic to a **single thread** with only I/O and hashing offloaded to background threads — for *deterministic, reproducible testing*. Their "Trinity" framework intercepts every future to inject failures via an adversarial scheduler. This is essentially your stated architecture (synchronous functional core, async at the edges) — and Dropbox is the strongest existence proof that it pays off, *specifically* because it makes the core testable.

**5. The big shops routinely reject the "standard" crate.** Cloudflare built their own HTTP library instead of using Hyper, because they needed to "survive the wilds of the Internet" — e.g. servers returning HTTP status codes in the 599–999 range that RFC-compliant parsers reject. The lesson isn't "always roll your own" (that contradicts minimal-deps); it's that at the boundary with hostile/noncompliant input, off-the-shelf strictness can be a liability. For a document *viewer*, your equivalent is malformed input (broken UTF-8, pathological markdown/CSV) — lenient, fuzzed parsing at the edge matters.

### What did NOT pan out / the friction (the honest column)

- **Async Rust is the consistently-cited pain point.** The Rust Foundation's 2026 "what we heard" report flags async as the thing "many people had issues with." Runtime fragmentation (libraries pinned to tokio vs others), the `'static` requirement on spawned tasks fighting the borrow checker, and "function coloring" all recur. The widely-cited maintainer consensus (corrode, WyeWorks) lands exactly where you've already landed: **synchronous functional core, async only as a thin I/O wrapper.** Cloudflare *did* go all-in on tokio and praise its work-stealing scheduler — but that's a network proxy that is fundamentally I/O-bound, the opposite of a viewer core.
- **Compile times are a slow-burn, not an acute blocker.** Across all cohorts it's the #1 cited productivity drag, *yet* the 2026 report notes nobody said it currently *blocks* them — the worry is scaling ("if we keep writing more Rust… we may eventually get to a point that compile times are an issue"). GUI/visual devs feel 10s+ iteration loops most. Mitigation is cheap *if done early*: workspace splitting, `cargo nextest`, fast linker, keeping the dep tree small (your minimal-deps stance directly helps here).
- **The borrow checker is a beginner tax that amortizes away.** "Rust experts don't really complain about the borrow checker anymore." Budget for it as a one-time onboarding cost (~4 months to comfort, per corrode), not a permanent drag.
- **Style-debate churn is a real org cost.** Multiple sources flag that Rust offers many valid ways to do the same thing, generating low-value code-review debates (clone vs lifetimes, generics depth, macro use). The fix is a short written style guide *from day one*.

### Adoption playbook the shops converge on

- **A "Rust champion" with bus-factor > 1.** corrode's strongest warning: never let one person own the Rust knowledge.
- **Non-negotiable CI from commit #1:** `cargo fmt --check`, `cargo clippy`, `cargo audit`, doc-coverage lint. "There should be no exceptions."
- **Pick a meaningful-but-not-mission-critical first target.** Notably, corrode warns *against* WebAssembly as a *first* project (tooling complexity, deferred payoff) — worth weighing given your WASM target is one of four backends. Land the native/FFI path first; treat WASM as backend #2.
- **AWS's structural bet:** they didn't just *use* Rust, they hired the tokio maintainers (Lerche, McArthur, Gjengset, Franco) and fund the Rust Foundation — a signal that betting a platform on Rust means investing in the ecosystem's sustainability, not just consuming it.


## Key takeaways
- The 2025/2026 data inverts the classic tradeoff: Rust is now measurably BOTH safer AND faster to ship. Google Android: ~0.2 vs ~1000 memory-safety vulns/MLOC (1000x), 4x lower rollback rate, 25% less code-review time, 20% fewer revisions than C++.
- Discord and Cloudflare validate the perf story for two different workloads: Discord killed GC tail-latency spikes (ms -> microseconds p99) with minimally-tuned Rust beating hand-tuned Go; Cloudflare's Pingora runs at 70% less CPU / 67% less memory and 'has yet to crash due to service code' across hundreds of trillions of requests.
- Dropbox's Nucleus is the direct precedent for your architecture: type-system-enforced 'design away invalid states' + single-threaded control logic with I/O/hashing offloaded to background threads, purpose-built for deterministic, reproducible testing (adversarial future-injecting scheduler). They call the Rust bet one of their best decisions.
- Your forbid(unsafe_code)-core + audited-FFI-edge model is exactly what Google validated: ~4% unsafe Rust is still vastly safer than C/C++ because unsafe doesn't disable most checks, is locally encapsulated, and draws extra review scrutiny.
- Async is the ecosystem's most-cited pain point; the convergent advice (corrode, WyeWorks, Rust Foundation) matches your plan: synchronous functional core, async strictly as a thin I/O wrapper. Cloudflare went all-in on tokio only because Pingora is purely I/O-bound.
- Adopt the shops' day-one hygiene: a Rust champion with bus-factor > 1, mandatory CI (fmt/clippy/audit/doc-lint, no exceptions), a short written style guide to kill clone-vs-lifetime review churn, and ~4 months budgeted to team fluency.

## Gotchas
- Rust is NOT a force field: Google's first near-miss (CVE-2025-48530, CrabbyAVIF) was a linear buffer overflow IN safe-ish Rust that shipped to pre-release and was only saved by Scudo allocator guard pages. Keep allocator hardening, fuzzing, and OS mitigations even with a safe core. Crash reporting also initially failed to identify the overflow cause -- observability gaps bite regardless of language.
- Off-the-shelf strictness can be a liability at hostile boundaries: Cloudflare rejected Hyper and built their own HTTP parser to tolerate noncompliant servers (e.g. status codes 599-999). For a viewer, the analog is malformed/pathological input (broken UTF-8, adversarial markdown/CSV) -- prefer lenient, fuzzed edge parsing over RFC-strict rejection.
- Compile times are a slow-burn scaling risk, not an acute blocker today -- but mitigations (workspace splitting, nextest, fast linker, small dep tree) are far cheaper to bake in early than to retrofit. GUI/visual iteration loops (10s+) feel it worst, relevant to your editor UI.
- Tokio's GC-free / work-stealing wins (Cloudflare) apply to I/O-bound network services, the OPPOSITE of a CPU-bound document core -- don't cargo-cult 'just use tokio everywhere' from proxy case studies into your sync core.
- Async Rust's '\''static-on-spawned-tasks requirement fights the borrow checker and forces runtime-specific code; runtime fragmentation means libraries get pinned to one executor. Keep async out of the core entirely to avoid leaking this into the reusable library.
- Multi-valid-ways-to-do-things generates low-value style-debate churn in code review (clone vs lifetimes, generics depth, macros). Without a written style guide from day one this becomes a recurring team-friction tax, per multiple primary sources.

## Sources
- https://discord.com/blog/why-discord-is-switching-from-go-to-rust — 'Why Discord is switching from Go to Rust' (Discord Engineering, 2020; primary)
- https://blog.cloudflare.com/how-we-built-pingora-the-proxy-that-connects-cloudflare-to-the-internet/ — 'How we built Pingora, the proxy that connects Cloudflare to the Internet' (Cloudflare, Sep 2022; primary)
- https://blog.cloudflare.com/20-percent-internet-upgrade/ — 'Cloudflare just got faster and more secure, powered by Rust / Pingora' (Cloudflare; primary)
- https://blog.google/security/rust-in-android-move-fast-fix-things/ — 'Rust in Android: move fast and fix things' (Google Security Blog, Nov 2025; primary, contains the 1000x density, <20%, 4x rollback, 25% review figures and CVE-2025-48530)
- https://source.android.com/docs/security/test/memory-safety — 'Memory safety' (Android Open Source Project docs; primary)
- https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine — 'Rewriting the heart of our sync engine' (Dropbox, Nucleus; primary)
- https://dropbox.tech/infrastructure/-testing-our-new-sync-engine — 'Testing sync at Dropbox' (Dropbox, Trinity adversarial scheduler; primary)
- https://aws.amazon.com/blogs/opensource/firecracker-open-source-secure-fast-microvm-serverless/ — 'Announcing the Firecracker Open Source Technology' (AWS, Nov 2018; primary)
- https://www.amazon.science/blog/how-awss-firecracker-virtual-machines-work — 'How AWS's Firecracker virtual machines work' (Amazon Science; primary; references NSDI '20 Agache et al. paper)
- https://aws.amazon.com/blogs/opensource/why-aws-loves-rust-and-how-wed-like-to-help/ — 'Why AWS loves Rust, and how we'd like to help' (AWS; primary; tokio team hiring, Carl Lerche)
- https://aws.amazon.com/blogs/opensource/sustainability-with-rust/ — 'Sustainability with Rust' (AWS; primary)
- https://blog.rust-lang.org/2026/03/20/rust-challenges/ — 'What we heard about Rust's challenges' (Rust Blog / Rust Foundation, Mar 2026; primary; async + compile-time + ecosystem findings from ~70 interviews)
- https://corrode.dev/blog/successful-rust-business-adoption-checklist/ — 'Making Your First Real-World Rust Project a Success' (corrode Rust Consulting; secondary-expert; day-one checklist, champion/bus-factor, CI, style guide)
- https://corrode.dev/podcast/s05e03-cloudflare/ — 'Cloudflare with Edward Wang & Kevin Guthrie' (corrode Rust in Production podcast; primary interview)
- https://corrode.dev/blog/async/ — 'The State of Async Rust: Runtimes' (corrode; secondary-expert)
- https://www.wyeworks.com/blog/2025/02/25/async-rust-when-to-use-it-when-to-avoid-it/ — 'Async Rust: When to Use It and When to Avoid It' (WyeWorks, Feb 2025; secondary-expert)
- https://thenewstack.io/microsofts-rust-bet-from-blue-screens-to-safer-code/ — 'Microsoft's Rust Bet: From Blue Screens to Safer Code' (The New Stack; secondary; 188k LOC, ~70% memory-safety since 2006)
- https://techcommunity.microsoft.com/blog/windowsdriverdev/towards-rust-in-windows-drivers/4449718 — 'Towards Rust in Windows Drivers' (Microsoft Community Hub; primary)
- https://thenewstack.io/rust-enterprise-developers/ — 'Nearly half of all companies now use Rust in production' (The New Stack, on State of Rust 2025 survey; secondary)