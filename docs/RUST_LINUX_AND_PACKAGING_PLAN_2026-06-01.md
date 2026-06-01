# Rust-Core: Linux Portability & macOS Packaging Plan

**Status:** Plan of record (owner-confirmed 2026-06-01). **Not** a call to start the migration — the Core is still left alone; CSV is the only thing integrated, behind `RustCSVGate` (a static arm64 `.a`). This document is the **map** for when the migration starts, and the **trigger** for two cheap-but-not-yet things: (1) standing the Linux leak-detector CI lanes up *early*, and (2) wrapping the arm64 `.a` as an `.xcframework` *whenever the real Rust workspace is created*.

Companion docs: [`docs/RUST_CORE_MIGRATION.md`](./RUST_CORE_MIGRATION.md) (the migration plan / risk register / front-end roadmap) and [`docs/RUST_CORE_TESTING.md`](./RUST_CORE_TESTING.md) (the test pyramid per front-end).

---

## 1. Target matrix

Two platforms, and the decision on each is now settled:

| Platform | Architectures | libc / distro floor | Status |
|---|---|---|---|
| **Apple (macOS)** | **arm64 ONLY — forever** | n/a (Mach-O) | The only Mac arch we will ever ship. **No x86 Mac, ever.** No `lipo`, no universal/fat binary, no `x86_64-apple-darwin` slice. |
| **Linux** | `x86_64` **and** `aarch64` | **glibc** (Debian / Amazon Linux) | First-class *wanted* target. **No musl** unless a fully-static run-anywhere binary is later wanted. |

Consequences that the rest of this doc builds on:

- Because there is no x86 Mac, **the Apple side never needs cross-compilation, fat binaries, or `lipo`.** The macOS FFI artifact is a *single* arm64 slice. Anything that talks about "universal Mac" or an `x86_64-apple-darwin` slice is stale (see [§8](#8-corrective-cross-links); the corrective edits to `RUST_CORE_MIGRATION.md` have been applied).
- The cross-platform engineering is **entirely Linux** (plus WASM later, out of scope here). Linux is where real portability work lives, and it is a **Rust cross-compile + CI** concern — orthogonal to anything Apple-toolchain.
- The glibc floor matters and is set by the *oldest target distro*, not the build host — see [§5](#5-glibc-floor--the-one-thing-thats-easy-to-get-silently-wrong).

---

## 2. The two-axis mental model

The single most important idea in this doc: **there are two completely independent build axes.** They share nothing. Conflating them is the mistake the older docs made (they treated "make it portable" as one axis and reached for `lipo`/universal — which is dead).

```
                       THE RUST CORE
        textview-core  +  textview-proto   (PURE: forbid(unsafe_code),
                 │                           sans-IO, ZERO Apple deps)
                 │
     ┌───────────┴────────────────────────────┐
     │                                         │
 AXIS 1 — macOS app packaging            AXIS 2 — Linux portability
 (Apple toolchain ergonomics)            (Rust cross-compile + CI)
 ───────────────────────────            ─────────────────────────────
 ONE arm64 .a  ──▶  link into            textview-ffi quarantines all
 the Swift app.                          Apple-isms; the PURE core is
                                         consumed on Linux either:
 Today:  unsafeFlags -L/-l hack            • in-proc  (a Linux TUI), or
 Hygiene: single-slice arm64               • over the wire: rmp-serde
          .xcframework binaryTarget           remote / UDS tier
          (drops the link path)               (rustls → no OpenSSL hell)

 NO lipo. NO universal. NO fat binary.   Targets:
 NO x86 Mac. EVER.                         x86_64-unknown-linux-gnu
                                           aarch64-unknown-linux-gnu
 .xcframework lives HERE ONLY ───────X    .xcframework is IRRELEVANT here
 (it is Apple's bundling format;          (Linux ships ELF .so/binaries;
  it cannot and does not carry             xcframework is a Mach-O
  a Linux slice)                           container — wrong universe)
```

Read off the diagram:

- **Axis 1 is Apple-only ergonomics.** Wrapping the `.a` as an `.xcframework` is *packaging hygiene* — it drops the hard-coded link path. It is **not** a cross-platform need. An `.xcframework` is Apple's multi-slice container format; even in the multi-platform case it would only ever carry Apple slices. It has nothing to do with Linux.
- **Axis 2 is a Rust + CI concern.** It is satisfied by keeping the core pure and cross-compiling/testing it for Linux. It never touches `xcodebuild`, `lipo`, or `Package.swift`.
- The two axes intersect at exactly one place: **the purity discipline of `textview-core`/`textview-proto`.** Keep those crates Apple-clean and sans-IO, and *both* axes work — Axis 1 links the same logic into Swift via `textview-ffi`; Axis 2 compiles the same logic for Linux because there's no Apple-ism to leak.

---

## 3. Axis 1 — macOS packaging hygiene (single-slice arm64 `.xcframework`)

### The choice: `unsafeFlags` link hack vs. single-slice `.xcframework` binaryTarget

This is a **packaging-hygiene** decision, not a portability one. Both produce the identical linked result on arm64 macOS; the difference is *how `Package.swift` finds the lib*.

| | What it does | Downsides |
|---|---|---|
| **Today: `unsafeFlags(["-L…","-l…"])`** | Hardcodes an absolute `-L` search path + `-l` lib name into the target. | Hardcoded absolute path; breaks `swift package` resolution when consumed from another package; no integrity/signing story; `unsafeFlags` itself bars the package from being a dependency of others. |
| **Hygiene: single-slice arm64 `.xcframework` `binaryTarget`** | SwiftPM resolves the lib + headers + modulemap as a first-class `binaryTarget`; carries platform/arch metadata so the toolchain selects it. | A one-time build step (`xcodebuild -create-xcframework`) to produce the artifact. That's the whole cost. |

**One slice only.** There is no `lipo`, no universal binary, no second arch. `lipo` would only enter if we combined arches *within* one slice (arm64+x86_64, or device+simulator) — which we explicitly never do.

### Concrete build steps (when we do it)

Layout — the `-headers` dir must contain the public header(s) **and** a `module.modulemap` so Swift can `import` it as a Clang module:

```
artifacts/
├── libtextview_ffi.a            ← the single arm64 macOS static lib
└── include/
    ├── textview_ffi.h
    └── module.modulemap
```

`include/module.modulemap`:

```
module TextViewFFI {
    header "textview_ffi.h"
    export *
}
```

Create the one-slice xcframework (exactly **one** `-library`/`-headers` pair = one slice):

```bash
xcodebuild -create-xcframework \
  -library artifacts/libtextview_ffi.a \
  -headers artifacts/include \
  -output TextViewFFI.xcframework
```

Reference it in `Package.swift` as a **local-path** binaryTarget (no checksum needed for an in-repo path — this is the direct, hermetic swap for `unsafeFlags`):

```swift
.binaryTarget(
    name: "TextViewFFI",
    path: "TextViewFFI.xcframework"
),
.target(name: "TextViewKit", dependencies: ["TextViewFFI"]),
```

Notes from the research:

- **No notarization / Gatekeeper step for the static slice.** A static-lib xcframework links *into* the consumer binary at build time; its code is not a separate signable Mach-O at runtime. The classic "No code signature found" SwiftPM `binaryTarget` failures are a *dynamic*-framework problem — not ours. The app gets signed as a whole by its existing local-signing flow.
- **Code-signing the xcframework is optional** and only worth it if we ever publish the zip via a URL `binaryTarget` (then `swift package compute-checksum` is mandatory and the signature should be applied *before* zipping). For a purely local in-repo `binaryTarget` it's unnecessary.
- **Header nesting** only matters if we ever ship multiple static-lib xcframeworks (nest headers under `include/TextViewFFI/…` to avoid `module.modulemap` collisions in the consumer). For a single framework it's a non-issue.

### Verdict — Axis 1

**Defer; fold into the workspace stand-up; low urgency.** The `unsafeFlags` hack works today and produces a byte-identical link. The xcframework wrap is pure `Package.swift` hygiene — do it as a small task *when the real Rust workspace stands up* (it pairs naturally with introducing `textview-ffi`), not on its own urgency clock. It is explicitly **not** the "biggest PoC→shippable gap" the old docs claimed — that framing assumed a universal-Mac gate that doesn't exist.

---

## 4. Axis 2 — Linux portability (Rust cross-compile + CI)

### 4.1 Keep `textview-core` / `textview-proto` PURE

This is the load-bearing discipline for *both* axes, but it's what *makes* Linux work at all:

- `forbid(unsafe_code)` on `textview-core` and `textview-proto`.
- **Sans-IO** — the core is pure transforms over data; effects come back as data (the "effects as data, not callbacks" decision), so the same core runs in-proc or over a wire with zero core changes.
- **ZERO Apple deps.** No `CoreFoundation`, no `objc`, no `#[cfg(target_os = "macos")]` logic in the core. Every Apple-ism is **quarantined in `textview-ffi`** (the only `unsafe` crate) and in the per-front-end shell.

If that discipline holds, the Linux build is free. The whole point of the next section is to make a *leak* of that discipline **loud and immediate**.

### 4.2 The CI leak-detector lanes (do EARLY)

Add two Linux build+test lanes the moment the real Rust workspace stands up:

```
x86_64-unknown-linux-gnu      cargo build + cargo test
aarch64-unknown-linux-gnu     cargo build + cargo test
```

Their job is **not** to ship a Linux binary. Their job is to be a **leak detector**: a red Linux build catches an accidental Apple-ism leak into the pure core *while it is still a one-line fix*, instead of months later when a Linux front-end is finally attempted and the core is shot through with `#[cfg]`s. This is cheap insurance — the lanes cost CI minutes, not engineering. **Do them early.**

Recommended CI shape (no emulation, full fidelity — this is the *authoritative* gate):

- A 2-entry matrix on GitHub-hosted **native** runners: `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64). Both are GA and available in private repos as of Jan 2026; arm64 runs on real silicon, no QEMU/Rosetta caveats.
- To prove the **actual** glibc floor (not "some Ubuntu glibc"), run the build *inside* a digest-pinned old-distro container on the runner (e.g. `debian:bullseye` / `amazonlinux:2` / a `manylinux` base). See [§5](#5-glibc-floor--the-one-thing-thats-easy-to-get-silently-wrong).

### 4.3 How Linux consumes the core

Two consumption modes, both already in the migration doc's transport-tier model:

1. **In-proc — a Linux TUI.** The TUI links the pure core directly (same as the macOS app links it via FFI, minus the Apple bits). No new core code; lowest latency.
2. **Over the wire — a headless Linux server.** The remote/UDS tier: length-prefixed **`rmp-serde`** (MessagePack) framing over a Unix domain socket (local) or WebSocket (remote). **`rustls` is already the chosen TLS stack → no system-OpenSSL version hell** across Debian/Amazon Linux. A static-ish Linux binary (+rustls ~1–3 MB) speaks the same wire format the Mac UI uses.

The wire format is identical across in-proc / UDS / remote — only the byte-pipe differs — so the Linux server tier is the *same* `rmp-serde` named-map protocol, not a new contract.

### 4.4 Verdict — the build/test ENVIRONMENT

**Preferred: Apple's `container` CLI** (already installed, `0.5.0`, macOS 26.2), for these reasons, empirically verified on this machine:

- **Zero idle footprint** — when no container runs, there is *no* resident Linux VM (only ~25 MB of helper processes). This is the decisive property for a Mac that's busy with a multi-day render: it doesn't tax the render when idle, unlike Docker Desktop/Colima which keep a multi-GB VM resident.
- **Ephemeral per-run micro-VMs** — each `container run --rm` spins its own hardware-isolated Linux VM (real kernel 6.12, real ELF execution, real `cargo`) and destroys it on exit. Nothing to reset.
- **Native aarch64 Linux at full speed** — this is the *authoritative local* arch (matches what we'll ship).
- **x86_64 works via Rosetta**, but is **~8–9× slower** (measured: trivial CPU loop arm64 3.96 s vs amd64 34.8 s) and is the least-baked corner (pre-1.0, Rosetta-for-Linux). Treat amd64 here as an **advisory smoke check**, and watch for the **AVX/AVX2/AVX512 cliff** (Rosetta doesn't implement them → `illegal hardware instruction` at runtime, no compile warning). The *authoritative* x86_64 verdict comes from CI native runners (§4.2).

**Constraints to respect on a busy box** (from the on-machine investigation): a VM's RSS ratchets to its peak and is **not** returned to the host until the container exits — so cap memory/CPU (`-m`, `-c`), keep every run `--rm`, never leave a detached container around, and keep `cargo`'s `target/` *inside* the VM (`CARGO_TARGET_DIR=/tmp/target`) so virtiofs doesn't choke on thousands of small artifacts.

**Fallback: UTM full VM.** Only wins if we want a persistent, hand-tuned Linux workstation to log into; for occasional, clean, disposable build/test it loses to `container` on setup, idle cost, and ephemerality.

**Alternatives (situational):**

- **`cargo-zigbuild`** — fastest *compile-only* inner loop, no Docker/VM, and the **cleanest glibc-floor control** (in-band `.2.NN` suffix on the triple). Great for "does it build for both arches?" but proves *nothing* about runtime — use it as a pre-flight, not the gate. Weak spot: C/FFI/`-sys` crates (zig's bundled sysroot ≠ the distro's). Caveat: invalid glibc suffix warnings are *swallowed* — always verify the floor afterward.
- **`cross test`** — only worth it if CI standardizes on `cross`; its QEMU-user default runs x86 *slower and serially* (thread-spawning tests can hang), so it's a weaker x86 path than Rosetta-in-`container`.
- **GitHub native-runner matrix** — the *authoritative* gate (§4.2); not a local tool.

**EXECUTION IS DEFERRED.** The owner's Mac is mid multi-day render and must not be overloaded; UTM/containers free up in a few days. **Plan now, execute when the Mac is free.**

---

## 5. glibc floor — the one thing that's easy to get silently wrong

glibc is **backward**-compatible but **not forward**-compatible: a binary linked against glibc 2.36 emits `GLIBC_2.36` symbol refs and **will not run** on an older host (`version 'GLIBC_2.xx' not found`). The build's floor must be **≤ the oldest target distro's glibc**, and it's baked in at link time — unfixable after the fact.

| Distro we care about | glibc |
|---|---|
| Amazon Linux 2 | **2.26** (practically: target 2.17 via a CentOS7/manylinux2014 base) |
| Amazon Linux 2023 | 2.34 |
| Debian 11 (bullseye) | 2.31 |
| Debian 12 (bookworm) | 2.36 |
| Ubuntu 24.04 (GH runner default) | 2.39 |

**The footgun:** building on a default `ubuntu-latest`/`ubuntu-24.04` runner pins you to glibc **2.39** and silently produces a binary that breaks on AL2 and older Debian. **Fix:** build *inside* a digest-pinned old-distro container (or `cargo zigbuild --target …gnu.2.17` / `.2.26` / `.2.31` to the chosen floor). **Verify every artifact** — symbol versions live in the dynsym table; assert in CI:

```bash
# Highest GLIBC_ symbol required must be ≤ the chosen floor. Don't strip first.
objdump -T ./binary | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail
```

Floor value is the same number across both arches for a given distro, and the low-floor base images exist for both `_x86_64` and `_aarch64`. **Decide the floor when the first Linux consumer is built** — for the leak-detector lanes, any glibc is fine (we're detecting Apple-isms, not certifying a floor yet).

> The `target-cpu` baseline note still applies here, scoped to **Linux x86_64**: don't use `target-cpu=native` for distributed binaries (SIGILLs on older CPUs); pick an explicit `x86-64-v2`/`v3` baseline. (This advice is dead for Mac — arm64-only — but live for the Linux x86 server tier.)

---

## 6. WHEN THE MAC IS FREE — checklist

First concrete steps to set up + verify the Linux env (a few days out, once the render finishes). Native aarch64 is the real gate; x86_64 is an advisory smoke check.

```bash
# 0. Service is already up; if not:
container system start

# 1. Sanity — native arm64 Linux round-trip (full speed):
container run --rm --arch arm64 debian:latest sh -c 'uname -a; nproc'

# 2. Rust toolchain image (arm64; rust:1-slim is multi-arch on Docker Hub):
container run --rm rust:1-slim cargo --version

# 3. Build + test the (future) Rust workspace, native aarch64, capped so the
#    render isn't starved; keep target/ INSIDE the VM (off virtiofs):
container run --rm -m 4g -c 4 \
  -v "$PWD":/src -w /src \
  -e CARGO_TARGET_DIR=/tmp/target \
  rust:1-slim \
  sh -c 'cargo build --locked && cargo test --locked'

# 4. (Advisory) x86_64 Linux smoke via Rosetta — expect ~8-9x slower; watch AVX:
container run --rm --platform linux/amd64 -m 4g -c 4 \
  -v "$PWD":/src -w /src -e CARGO_TARGET_DIR=/tmp/target \
  rust:1-slim \
  sh -c 'uname -m; cargo test --locked'

# 5. Nothing to tear down — --rm destroyed each VM. Confirm none linger:
container ls -a
```

Then, beyond the smoke run:

1. **Confirm the purity discipline holds** — both arch builds green = no Apple-ism leaked into `textview-core`/`textview-proto`. This *is* the leak detector running locally before CI.
2. **Wire the two CI lanes** (`{x86_64,aarch64}-unknown-linux-gnu`, native GH runners — §4.2) so the leak detector runs on every PR, not just by hand.
3. **(Only when a real Linux consumer exists)** pick the glibc floor (§5), switch CI to build inside a digest-pinned old-distro container, and add the `objdump -T` floor assertion.
4. **If `target/` round-trips matter** (snapshot updates from inside the container), the `-v` host mount already works read/write via virtiofs — but prefer keeping `target/` in-VM for build speed.

---

## 7. Deferral timing — do-early vs. defer-until-consumer

The real decision throughout is a **WHEN**, not an **IF**. The core itself stays untouched; these are scheduled, not started.

| Work item | Axis | Timing | Why |
|---|---|---|---|
| Keep `textview-core`/`textview-proto` Linux-clean (`forbid(unsafe_code)`, sans-IO, no Apple deps) | both | **DO EARLY** — at workspace stand-up | Free if done from day one; ruinous to retrofit. |
| `{x86_64,aarch64}-unknown-linux-gnu` build+test **CI leak-detector lanes** | 2 | **DO EARLY** — at workspace stand-up | Cheap insurance; a red Linux build catches an Apple-ism leak as a one-line fix. |
| Set up + verify the local Linux env (`container` CLI) | 2 | **PLAN now / EXECUTE when Mac is free** | Render in progress; don't overload the Mac. Few days out. |
| Single-slice arm64 `.xcframework` `binaryTarget` (drop `unsafeFlags`) | 1 | **DEFER** — fold into workspace stand-up, low urgency | Packaging hygiene only; the hack works today. No consumer waiting. |
| Pick glibc floor + container-pinned CI build + `objdump` floor assertion | 2 | **DEFER until there's a consumer** | Floor only matters once a real Linux binary ships. |
| Actual Linux front-end binaries (TUI / headless server) | 2 | **DEFER until there's a consumer** | No front-end planned yet; the lanes prove buildability in the meantime. |

---

## 8. Corrective cross-links

The older `docs/RUST_CORE_MIGRATION.md` framed the cross-platform gap as a **universal-Mac / `lipo` / `x86_64-apple-darwin`-slice** problem (§3 transport table, §5 risk row, §5 closing prose, §7 step 2). That framing is **stale** under the arm64-only-forever decision. The corrective edits (applied to `docs/RUST_CORE_MIGRATION.md` on 2026-06-01) supersede those passages; this plan doc is the canonical target-matrix + two-axis reference they point to.

`docs/RUST_CORE_MIGRATION.md` **§6** (the "one core, three projections" roadmap, including the `headless Linux server (later)` box and the `rmp-serde` transport tiers) is **already correct** and consistent with this plan — it is *extended*, not corrected, by Axis 2 here. `docs/RUST_CORE_TESTING.md` has **no** headless-Linux-server test tier today (its shared L1 `cargo test` base covers the server core's logic platform-agnostically); the §4.2 leak-detector lanes are the natural place that gap gets filled when a Linux consumer lands.
