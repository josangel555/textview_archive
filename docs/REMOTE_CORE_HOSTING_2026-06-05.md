# Remote core hosting — testing front-ends against a core on a separate host (2026-06-05)

Owner ask: *"Use this VM to host the core to test the remote features as well — like SwiftUI/TUI running on a separate host."*

## TL;DR
- **Proven working today:** the **web** front-end (`mdv-web`) hosting the core on the UTM VM,
  reached from the Mac over an **SSH tunnel**. No code change, no security regression.
- **Not possible without new work:** SwiftUI and the TUI talk to the core via **in-process
  FFI** (they link `libmdvcore_ffi.a`) — there is **no network transport**, so they cannot
  run on a host separate from the core. That needs a new RPC server (spike filed).
- **Direct LAN access to `mdv-web` is deliberately blocked** (AUDIT-S1 hardening): it binds
  `127.0.0.1` only and 403s any non-loopback `Host` header (anti-DNS-rebinding). The SSH
  tunnel is the security-preserving way in; opening it to the LAN is an owner decision.

## What was demonstrated (repeatable)
The VM has **no Rust toolchain** (see memory `vm-no-rust-toolchain`), so build on the host and
ship the binary:
```bash
# host: build + ship the std-only web front-end (arm64 macOS)
cargo build -p mdvcore-web --release          # → rust-core/target/release/mdv-web
rsync -az rust-core/target/release/mdv-web macOS15:/tmp/mdv-web

# VM: run the core's web front-end on loopback, serving a tree
ssh macOS15 'cd ~/markdown_viewer && nohup /tmp/mdv-web --port 8791 . >/tmp/mdv-web.log 2>&1 &'

# Mac: tunnel to the VM-hosted core and use it (Host: 127.0.0.1 passes the guard)
ssh -fNL 18791:127.0.0.1:8791 macOS15
curl -s http://127.0.0.1:18791/                       # → index of the VM's filesystem
open  http://127.0.0.1:18791/                         # browse it in a Mac browser
```
Verified: index lists `/Users/vm-tester/markdown_viewer` (the VM's FS, not the host's), and
`/view?path=…` returns `200`. The request originates on the Mac; the core runs on the VM.

## Why the native front-ends can't go remote yet
```
        in-process (today)                     remote (needs work)
  ┌───────────────────────────┐        ┌────────── host A (VM) ───────────┐
  │ SwiftUI app  ── FFI ──┐    │        │  mdvcore-rpcd  ── owns core ──┐   │
  │ ratatui TUI  ── FFI ──┼─ libmdvcore │        ▲ compact binary RPC   │   │
  │ mdv-web (HTTP) ── core─┘    │        └────────┼──────────────────────┘   │
  └───────────────────────────┘                  │ TCP + auth
                                         ┌────────┴── host B (Mac) ─────────┐
                                         │ SwiftUI / TUI = thin RPC clients │
                                         └──────────────────────────────────┘
```
- `mdv-web` already speaks a network protocol (HTTP) → tunnelable now.
- SwiftUI/TUI hold the core in-process over the C ABI → no socket, no wire session.

## Options for true remote front-ends (owner decisions)
1. **SSH tunnel for `mdv-web`** *(recommended, zero-cost, done)* — trusted dev/test access,
   security preserved (loopback bind + SSH auth/encryption). Use this for remote *testing* now.
2. **`mdv-web --bind <addr>` + bearer-token auth** — relaxes the S1 localhost-only posture for
   LAN use; only behind an explicit flag + a shared secret + an allowlisted `Host`. Reverses
   part of the DNS-rebinding hardening → **owner sign-off required**.
3. **`mdvcore-rpcd` — a real RPC server for the native front-ends** — exposes the core over the
   owner's preferred **compact binary RPC (no JSON)** (memory `rust-core-decision`); the TUI and
   SwiftUI become thin clients selectable between in-process FFI and remote RPC. This is the
   actual "SwiftUI/TUI on a separate host" feature: needs transport + framing (reuse the
   existing `wire` codec), a session/handle model over the wire, backpressure, auth, and
   reconnection. **Spike first** — filed on the `tasked` board.

## Status
- Web-on-VM + Mac tunnel: **working**, left running on the VM at `127.0.0.1:8791` (PID noted in
  `/tmp/mdv-web.log` on `macOS15`); host tunnel on `127.0.0.1:18791`.
- A stale prior `mdv-web` (PID 1344) is also bound to `:8765` on the VM — pre-existing leak.
- Spike task filed for option 3 (the RPC server). Options 1/2 documented here for the owner.
