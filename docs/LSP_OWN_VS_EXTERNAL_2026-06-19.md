# Spike/Decision: LSP — own implementation vs external server (TSK-781) — 2026-06-19

**Question (owner):** Build our own LSP intelligence, or use external LSP servers? Which is robust/fast?

**Recommendation: External servers (confirm the current architecture) + invest in lifecycle ROBUSTNESS, not in re-implementing language intelligence.** Add a TreeSitter-based **zero-server fallback** for *trivial* in-file completion so the editor is never dead when no server is installed. Do **not** build an "own LSP."

---

## The homework (what exists today)

The app **already implements the external-server approach** — a substantial, working LSP *client*:

- `Sources/ViewerCore/LSP/`: `LSPClient`, `LSPProtocol`, `LSPFraming`, `LSPService`, `LSPDiscovery`, `LSPConfiguration`, `LSPPositionConverter`, `LSPLanguage`, `LSPNavigationStore`, `LSPWorkspaceOverrides`.
- Feature surface: `completion`, `hover`, `definition`, `references`, `documentSymbol`(s) — i.e. real LSP requests over the wire.
- UI: Problems panel, Navigation panel, Diagnostics view, Outline, Hover attachment, Rename prompt.
- `MDVFakeLSPServer` — an in-repo fake server for deterministic host tests (no external dep in CI).
- `jdtls-data/` under Application Support (Java server working dir) — confirms real external servers are spawned.

So the question is really: **keep investing in the client+external-server path, or pivot to building intelligence ourselves?**

## Why "own implementation" is the wrong path

- **You cannot out-build clangd / rust-analyzer / jdtls / pyright / sourcekit-lsp.** Real LSP value is *deep, cross-file, type-aware* intelligence — years of per-language compiler work. Re-implementing even one language to that depth is a multi-year effort and a permanent maintenance black hole; doing it for N languages is infeasible.
- **The protocol is not the hard part** — the client already speaks it. Re-implementing servers buys nothing the protocol doesn't already give us via best-in-class servers.
- An "own" engine would inevitably be *shallower* than the servers, i.e. a downgrade in the exact dimension (intelligence depth) that justifies LSP at all.

## Why external is right — and where the real work is

External servers give best-in-class intelligence per language for free over a standard protocol. The genuine engineering challenge is **robustness of the client↔server lifecycle**, which is where effort should go:

1. **Discovery & config** (`LSPDiscovery`/`LSPConfiguration`/`LSPWorkspaceOverrides`) — find installed servers (PATH, common locations, overrides), degrade gracefully when absent (like the ffmpeg-locator pattern). Never hard-fail.
2. **Process lifecycle** — spawn, initialize handshake, **crash detection + bounded restart**, shutdown on workspace close, resource caps (servers are heavy: memory, CPU on index). This is the robustness backbone.
3. **Latency hiding** — servers are slow to start + index; show progress, debounce completion/diagnostics requests, cancel superseded requests (LSP `$/cancelRequest`), don't block the UI.
4. **Fast path / zero-server fallback** — when no server is installed for a language, fall back to **TreeSitter-symbol completion** (in-file identifiers/symbols from the already-resident TreeSitter tree — we have the Rust highlight engine + grammars). Trivial but instant, in-process, offline; keeps the editor useful. This is the *only* "own" piece worth building, and it's cheap.

## Robust vs fast

- **Robust** = external + disciplined lifecycle (crash-restart, graceful-absent, request cancellation). The current client is the right foundation; harden #2/#3.
- **Fast** = (a) the zero-server TreeSitter fallback for instant in-file completion, (b) request debounce/cancel so the deep server work never janks the UI, (c) keep diagnostics async/off the keystroke path.

## Decision options

1. **(Recommended) External + robustness + TreeSitter fallback** — keep the client, invest in lifecycle hardening + a zero-server trivial-completion fallback. No "own LSP."
2. **External only** (no fallback) — simplest; editor is inert for languages without an installed server.
3. **Own implementation** — not recommended (infeasible depth, maintenance black hole, strictly shallower than the servers).

**Why option 1 is "the right thing":** it leans on the best-in-class servers for the hard part (intelligence), spends our effort where we can actually add value (robust lifecycle + an instant offline fallback), and is future-proof + frugal — no doomed attempt to out-engineer compiler teams.
