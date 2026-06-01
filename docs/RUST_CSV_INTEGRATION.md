# Rust-core CSV integration — the shipping beachhead

> **Status: landed behind a feature flag, default OFF.** This is the first
> migration step from `docs/RUST_CORE_MIGRATION.md` §7 — the PoC's validated CSV
> core, brought into the shipping app, A/B-able against the incumbent Swift
> `CSVParser`. The shipping default is unchanged (Swift); the Rust path runs
> only when the operator opts in. Branch: `rust-csv-integration`.

## 1. Build pipeline (the migration's foundation — read this first)

```
  rust-core/                         cargo virtual workspace (the PoC crate, renamed)
    crates/core   (mdvcore-core)     #![forbid(unsafe_code)] CSV parse + session + wire
    crates/ffi    (mdvcore-ffi)      the ONLY unsafe crate: extern "C" + cbindgen
        build.rs                     runs cbindgen → mdvcore.h (header can't drift)
    link/         (gitignored)       staged libmdvcore_ffi.a + mdvcore.h

  scripts/build-rust-core.sh         cargo build --profile dist → stage .a + header
        │  (invoked first by build-app.sh, and required before any swift build)
        ▼
  Sources/CMdvCore/                  .systemLibrary target: module.modulemap + mdvcore.h (gitignored)
  Sources/RustCore/                  Swift bridge (CoreClient.swift + MessagePack.swift)
        │  static-links -L <pkg>/rust-core/link -lmdvcore_ffi  (unsafeFlags, leaf target)
        ▼
  Sources/ViewerCore/RustCSVGate.swift     the feature flag
  Sources/ViewerCore/RustCSVAdapter.swift  Rust Table → CSVParser.Result, fail-safe
        ▼
  Sources/ViewerUI/CSVTableView.swift      reparse() calls RustCSVAdapter.parse(text)
```

**Link mechanism — static-link the `.a` into the executable.** SwiftPM
static-links the Rust **staticlib** (`libmdvcore_ffi.a`) into the
`MarkdownViewer` executable via a `.systemLibrary` target (`CMdvCore`, holding
the cbindgen header + module map) and the `RustCore` target's
`linkerSettings: .unsafeFlags(["-L", <pkg>/rust-core/link, "-lmdvcore_ffi"])`.
The linker dead-strips the 16 MB `.a` to the live symbols. There is **no
separate dylib** in `Contents/Frameworks/`.

**Why static, NOT a dylib in `Contents/Frameworks/`** (a measured, deliberate
call — I built and tested *both*):

> A separate dylib is smaller in isolation (~344 KB), BUT under the **hardened
> runtime** (`codesign --options runtime`) + this project's **self-signed local
> cert** (`TeamIdentifier` "not set"), **dyld refuses to load** a non-platform
> dylib that is a *load-time dependency* of the signed executable:
> `mapping process and mapped file (non-platform) have different Team IDs`.
> Confirmed empirically: the app failed to launch with the dylib even after a
> clean `codesign --deep --strict` pass. (The lazy TreeSitter grammars dodge
> this only because they are `dlopen`'d at runtime — dyld is lenient for those,
> strict for load-time deps.)
>
> Static-linking the `.a` sidesteps the team-ID problem entirely (no separate
> Mach-O to load): the app launches clean and `codesign --deep --strict`
> passes. And the size cost is far smaller than feared — see §5: the Rust core
> adds only **~0.36 MB** to the executable, not the ~2.9 MB an early
> wrong-baseline estimate suggested.

**Why `unsafeFlags`, not an xcframework `binaryTarget` (yet).** The end-state
(migration doc §7 step 2) is a universal `lipo`'d xcframework `binaryTarget`.
That requires the `x86_64-apple-darwin` slice, which is **not installed** under
the no-install rule — so it is deferred. The `unsafeFlags` link is acceptable
because `RustCore` is a leaf bridge consumed only inside this package (never
exported for downstream package use). **The biggest item the owner should weigh
before merge** (see §6).

**Determinism / hygiene.** `build-rust-core.sh` builds with
`CARGO_TARGET_DIR` pointing outside the worktree (`/private/tmp/.../mdv-rust-csv-target`)
and stages the `.a` + header into the in-repo `rust-core/link/` and
`Sources/CMdvCore/` — both **gitignored**. The committed tree is the Rust source
+ the 4-line module map only; the 17 MB binary and the generated header are never
committed (no repo bloat, no arm64-only binary pinned into history, no header
drift). `scripts/build-app.sh` invokes `build-rust-core.sh` before `swift build`
so the `.a`/header always exist at link time.

**Profile.** The linked profile is `dist` (size-opt + `panic = "unwind"`), NOT
`release` (size-opt + `panic = "abort"`). Under `panic=abort` a core panic
SIGABRTs the host before `catch_unwind` can convert it to an error — so the GUI
app must link `unwind`. This is the playbook's easy-to-get-wrong call; the
script hard-codes `dist`.

**Dependencies — pre-approved set only.** The Rust runtime crate surface is
exactly `serde + rmp-serde + rmp + byteorder` (4 crates); `cbindgen` is a
build-dependency only (does not ship). No new crates were added. The PoC's
`deny.toml` (config-only; `cargo-deny` not installed) and `clippy.toml`
(determinism lints) came across unchanged.

## 2. The feature flag + default

`RustCSVGate` (in `ViewerCore`, mirrors `DiagnosticGate`):

| Opt-in | Mechanism | Scope |
|---|---|---|
| **none (default)** | — | **OFF → Swift `CSVParser` (today's behavior, byte-identical)** |
| Settings toggle | `UserDefaults` key `MarkdownViewer.experimental.rustCSV == true` | persisted, survives relaunch |
| Env override | `MDV_RUST_CSV=1` (or `true`) | per-run; A/B / CI / `swift run` |
| Env pin-off | `MDV_RUST_CSV=0` | forces Swift even if the toggle is on |

Precedence: the env var, if present, is a hard override (so an A/B run pins
either side regardless of the persisted pref); absent it, the UserDefaults
toggle decides; absent both, **OFF**. The shipping default is the safe Swift
path. *(A Settings-pane checkbox bound to the UserDefaults key is the obvious
follow-up — not wired in this step; the flag is fully functional via the key +
env today.)*

**Fail-safe routing.** `RustCSVAdapter.parse(_:)` consults the gate. When ON, it
drives the Rust core and maps the returned `Table` onto a `CSVParser.Result`;
**if the Rust bridge throws for any reason** (decode error, a panic caught at the
FFI boundary, an unknown status), it falls back to the Swift `CSVParser`. A CSV
view can never go blank because the experimental engine hiccuped — the worst case
degrades to today's behavior.

## 3. A/B + size delta

**Correctness parity** — asserted against the *real shipping* `CSVParser` /
`CSVFilter` (not a vendored copy) across 14 shared inputs (comma/tab/semi/pipe,
quoted delimiters + newlines, escaped quotes, quote-aware detection, ragged
rows, CRLF, bare-CR, Unicode, header-only, empty), through both the direct
bridge and the production adapter. All green.

**Performance** (`RustCoreTests.ABTests.testPerformanceAB`, 20k-row CSV, 5-iter
avg, host arm64):

| Path | Time | Ratio |
|---|---|---|
| Swift `CSVParser.parse` — parse only | 115.1 ms | 1.00x |
| Rust core — FULL pipeline (FFI open + parse + MessagePack encode + Swift decode) | 91.1 ms | **0.79x** |

Rust wins end-to-end *including every byte of crossing/wire/decode overhead*,
against the incumbent. Caveat (unchanged from the PoC): the A/B compares Rust
full-pipeline vs Swift *parse-only*, not parse+filter+project — a deliberately
pessimistic framing, so the real ceiling is better.

**Size delta** (release, arm64, stripped like `build-app.sh`):

| Artifact | `main` baseline (no Rust) | with Rust core | delta |
|---|---|---|---|
| executable | **18.60 MB** | ~18.96 MB | **+~0.36 MB** |
| total bundle | ~38.7 MB | ~39.0 MB | **+~0.3 MB** |

The Rust static-link adds only **~0.36 MB** to the exec. **A surprise the
measurement surfaced:** the `main` exec *already* measured 18.60 MB — i.e. it
already breached the old 18 MB exec sub-cap *before this change*. The cap was
stale (pre-existing drift from recent `main` work), so it was bumped to 20 MB
exec / 40 MB total (`scripts/check-bundle-size.sh`), covering the real baseline
+ the Rust core + headroom. (The dylib is `libmdvcore_ffi.dylib` ~344 KB and the
staticlib ~16 MB on disk, but the linker dead-strips the `.a` — what lands in
the exec is ~0.36 MB.)

## 4. What works flag-on vs flag-off

| | Flag OFF (default, Swift) | Flag ON (Rust) |
|---|---|---|
| CSV/TSV parse | Swift `CSVParser` (unchanged) | Rust `mdvcore-core` parse over FFI |
| Delimiter detection | Swift, quote-aware | Rust, quote-aware (parity-asserted) |
| Filtering | Swift `CSVFilter` (global + per-column ops) | **Swift `CSVFilter`** — unchanged |
| Truncation caps | Swift `Limits` | Rust `Limits` (same defaults) |

**Important scope note:** only the **parse** is routed through Rust. The CSV
*view's* filtering (`CSVFilter`, including per-column `>`/`<`/`=` expressions and
the lowercased-row cache) stays Swift on both sides — the Rust adapter returns a
`CSVParser.Result` and the existing `CSVTableView` filter pipeline runs on top
unchanged. The Rust core *has* a stateful filtered-session path
(`CsvSession.setFilter`/`snapshot`, global-substring only) and it is fully tested
at the bridge level, but the UI does **not** route filtering through it yet — that
is Phase B (convert `DocumentModel`/the CSV view to project a core snapshot).
Wiring the session path would also require porting the per-column operator
expressions into the Rust filter (mechanical; doesn't change the FFI shape).

## 5. Verification summary

- `swift build` (whole package) — clean; Rust staticlib links into the exec.
- `RustCoreTests` (20 tests) — green host-headless: cross-language round-trips,
  panic→error (proves `dist`/unwind is linked), handle lifecycle (500 opens),
  bad-UTF8, level-triggered snapshot, correctness + filter parity, gate
  default-OFF / env / toggle, adapter fail-safe + faithful mapping.
- `ViewerCoreTests` (1808 tests, incl. `CSVParserTests` + `CSVFilterTests`) —
  green; the Swift A-side is untouched.
- Rust `cargo test` — 37 core + 17 FFI green; `clippy -D warnings` + `fmt
  --check` clean.
- `scripts/build-app.sh release` — valid signed `.app`, `codesign -v` passes,
  within size caps (numbers in the branch's final report).

## 6. For the owner — review BEFORE merge

1. **`unsafeFlags` link, arm64-only.** The link mechanism is the PoC's
   `-L/-l unsafeFlags` (now to a deterministic in-repo path instead of `/tmp`).
   It is correct for a single-host arm64 build but is **not** the cross-platform
   shipping setup. The xcframework `binaryTarget` (universal `lipo` slice +
   `x86_64-apple-darwin`) is the documented end-state and needs the x86_64
   target installed (no-install rule). **Decision: accept arm64-only behind the
   flag for now, or block on the xcframework first?**
2. **Static link forced by the self-signed cert (a real finding).** I tried to
   ship the core as a smaller dylib in `Contents/Frameworks/` and **dyld refused
   to load it** under the hardened runtime + self-signed cert (Team-ID
   mismatch; §1). So the core is static-linked. This is fine for local dev, but
   when a **Developer ID / real Team ID** is in play (public shipping), the
   dylib path *would* work and may be preferable (relocatable, plugin/remote
   tier). **Decision: confirm static-link-for-now is acceptable; revisit the
   dylib at the Developer-ID milestone.** (LESSONS.md candidate — the team-ID
   load rule for load-time vs `dlopen`'d dylibs under a self-signed cert.)
3. **Caps bumped (already partly stale).** Exec 18→20 MB, total 37→40 MB. The
   exec bump is mostly *not* this change — `main`'s own exec was already 18.60
   MB, over the old 18 MB cap. Worth an independent look at why `main` drifted.
4. **Build prerequisite ordering.** A bare `swift build` (without first running
   `build-rust-core.sh`) fails to link if `rust-core/link/libmdvcore_ffi.a` is
   absent. `build-app.sh` handles this; CI / a fresh checkout must run
   `scripts/build-rust-core.sh` first. Consider a SwiftPM plugin or a Makefile
   target to make this automatic.
5. **`deny.toml` is unenforced** (cargo-deny not installed) and **the trace-sink
   callback FFI is not wired** — both carried over as-is from the PoC's noted
   gaps. Neither blocks this step.
6. **Filtering still Swift-side** (§4) — the perf win measured is parse-only;
   the stateful session path is tested but not yet driving the UI.
