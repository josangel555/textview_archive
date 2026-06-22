# Tier D — long-lived interactive (PTY/socket) plugin contract

**Status:** DESIGN (TSK-1138). Owner-resolved option B on the TSK-779 plugin/core
boundary spike (2026-06-19). Terminal is the motivating case. Auto-approved design;
the **contract itself awaits owner ratification before implementation** — it opens a
new security surface (a persistent process with raw bidirectional I/O).

Builds on `docs/PLUGINS_DESIGN_v2.md` (Tiers A/B/C) and
`docs/research/lsp-and-plugin-boundary-2026-06-13/FINDINGS.md` (Part B, the
boundary principle + the per-subsystem classification that flagged the terminal as
the one subsystem no current tier fits).

---

## 1. Why a new tier (the gap)

The existing tiers serve **bounded** work:

| Tier | Shape | Lifecycle | Caps |
|------|-------|-----------|------|
| A | JSON config, no code | none | n/a |
| B | shell-out subprocess | **per-call**: spawn → stdin → stdout → exit | 5s SIGKILL, 1 MB stdout, env→HOME |
| C | sandboxed `WKWebView` | per-contribution hooks | WebKit sandbox |

A **terminal** (and any REPL / SSH / interactive-debugger surface) needs the exact
opposite of Tier B's one-shot/capped contract: a **long-lived** process, a **PTY**
(so the child sees a real tty), and **raw bidirectional streaming** with no 5s/1 MB
ceiling. It cannot be expressed as Tier B without breaking the interaction model.

**Key precedent — the app already runs this lifecycle.** `LSPPool` manages
long-lived external language-server processes today: lazy spawn keyed by
(language, workspaceRoot), idle-reap (5 min), crash-restart with [250 ms, 1 s, 5 s]
backoff, graceful shutdown → SIGTERM → SIGKILL, `F_SETNOSIGPIPE`, `didReap` guard.
Tier D **generalizes that proven runtime** into a capability-gated plugin contract.
It is not new risk territory for the host — it is the formalization of an existing,
tested pattern behind a grant + manifest.

## 2. The boundary stays intact (what is core vs plugin)

Per the TSK-779 principle (core owns determinism + identity + the security
perimeter; plugins own optional/IO-bound surfaces behind a grant + OS process
boundary), Tier D moves **only the PTY-owning runtime** outside core. For the
terminal specifically:

- **CORE (unchanged):** the ANSI parser + screen model (`ANSIParser.swift`,
  `TerminalScreen.swift`) — pure, sans-IO, deterministic. The doc/tab model. The
  security fences. These never become a plugin.
- **PLUGIN-ABLE (Tier D):** the long-lived PTY-owning process runtime (spawn the
  shell, stream bytes). This is the only piece the new tier introduces.

So the terminal is the *motivating example* that validates the contract, not a
mandate to extract it immediately (extraction is a later, separately-scoped step).

## 3. The Tier-D contract

### 3.1 Transport (two sub-modes)

- **`pty`** — host opens a PTY (`openpty`/`posix_openpt`), keeps the master, the
  plugin's child runs on the slave (so it sees a tty: job control, `isatty`, raw
  mode). Used by terminal-class plugins. Raw byte stream both ways; no framing on
  the data channel (the child speaks its own protocol, e.g. ANSI).
- **`socket`** — host creates a unix-domain socketpair (or a length-prefixed pipe
  pair). **Length-prefixed framed messages** both ways (reuse the Tier-B framing).
  Used by structured long-lived plugins (a persistent indexer, a watch server).

A small **control channel** (always framed, separate fd or a reserved frame type)
carries lifecycle messages (`hello`/capabilities handshake, `shutdown`, host→plugin
`resize` for PTY, `ping`/`pong` for liveness) independent of the data stream.

### 3.2 Lifecycle (mirror LSPPool)

1. **Lazy spawn** on first use of the contribution, keyed by (pluginId, context).
2. **Handshake** — plugin sends `hello` with its declared capabilities; host
   validates against the granted set; mismatch → kill + error.
3. **Stream** — long-lived bidirectional I/O until teardown.
4. **Idle-reap** — configurable idle timeout (default 5 min, like LSPPool); a PTY
   with an attached visible view is "busy" and exempt.
5. **Crash-restart** — same backoff ladder as LSPPool ([250 ms, 1 s, 5 s], N
   attempts, dead-cooldown), with a per-plugin crash callback surfaced to the UI.
6. **Teardown** — graceful `shutdown` control msg → wait → SIGTERM → SIGKILL.
   `F_SETNOSIGPIPE`, reap guard (no zombie/double-reap), reaped on app teardown.

### 3.3 Resource model (NOT the one-shot caps)

The 5s/1 MB Tier-B ceilings are wrong for a long-lived process. Instead:

- **Memory:** per-process `RLIMIT_AS`/`RLIMIT_DATA` cap (default e.g. 512 MiB,
  manifest-overridable up to a host hard-max), enforced by the OS.
- **Process count:** a max-concurrent-Tier-D cap across all plugins (default e.g.
  8) to bound fork-bomb / resource exhaustion.
- **CPU watchdog:** a soft wall/CPU budget with a warn → kill escalation for a
  runaway (background, not on the data hot path).
- **Output:** no total cap, but **backpressure** — bounded in-flight buffers; if
  the plugin outruns the consumer, the host stops reading (the OS pipe blocks the
  writer) rather than buffering unboundedly.
- **The host kill-switch:** the host can SIGKILL any Tier-D process at any time
  (user "stop", resource breach, app teardown). Non-negotiable.

### 3.4 Security

The new surface is *a persistent process with raw I/O*. Mitigations:

- **New capability `process.longlived`** — explicit, declared in the manifest,
  user-granted on install + re-prompted on capability bump (same `JSONFileStore`
  grant model as Tier B/C). A Tier-D plugin without it cannot spawn.
- **Env scrub** — same as Tier B: env reduced to `HOME` only; no inherited secrets.
  Network only if `network.egress` is *also* granted (and even then, OS-level only —
  the host doesn't proxy).
- **No extra FS** — the child sees only what the plugin's granted `file.read`/
  `file.write` capabilities allow (the existing grant model); the PTY/socket does
  not widen FS access.
- **Audit log** — every spawn/teardown to the existing byte-free `0o600` audit log
  (no payload bytes, just lifecycle + pluginId + grant set).
- **PTY caveat** — a tty grants the child terminal control sequences; the host must
  treat the data stream as untrusted bytes (the terminal's existing ANSI parser
  already does — it is the CORE-class consumer, hardened separately).

### 3.5 Manifest declaration

```json
{
  "tier": "D",
  "contract": "pty",            // or "socket"
  "entry": { "command": "…", "args": ["…"] },
  "capabilities": ["process.longlived", "file.read:$workspace"],
  "resources": { "memoryMiB": 256, "idleReapSeconds": 300 }
}
```

## 4. Implementation breakdown (slices)

1. **`TierDHost` runtime** (host-testable core): the long-lived-process manager —
   spawn/handshake/idle-reap/crash-restart/teardown, modeled on `LSPPool` (much of
   the logic is liftable). Pure lifecycle state machine + a fake-process seam for
   host tests (mirror `LSPPoolFakeServerTests`). **Most of the value, host-testable.**
2. **Socket transport** — framed control + data over a socketpair; reuse Tier-B
   framing. Host-testable with a fake plugin echo process.
3. **PTY transport** — `openpty`, raw stream, `resize` control msg. (The raw-tty
   part is integration; the framing/lifecycle is host-testable.)
4. **Manifest + grant** — extend the manifest schema (`tier: "D"`, `contract`,
   `resources`) + the `process.longlived` capability + grant-prompt copy.
   Host-testable (schema decode + grant gating).
5. **Resource enforcement** — RLIMIT wiring + the concurrent-process cap + the
   watchdog. (RLIMIT is integration; the cap/decision logic is host-testable.)
6. **Terminal-as-Tier-D PoC** (LATER, render/VM) — re-host the terminal's PTY
   runtime as a Tier-D plugin to validate the contract end-to-end. Deferred; the
   ANSI parser/screen stay core.

Slices 1, 2, 4, 5 (the runtime + socket + manifest + cap logic) are largely
host-testable; the PTY raw-tty path (3) and the terminal PoC (6) are
integration/VM.

## 5. Open questions for owner ratification

1. **Ship `socket` only first, or `pty` too?** Socket covers structured long-lived
   plugins with less risk; PTY is needed for the terminal but is the bigger surface.
   Recommendation: design both, **implement socket first**, PTY with the terminal PoC.
2. **Resource defaults** — memory cap (512 MiB?), max-concurrent (8?), idle-reap
   (5 min?) — confirm or set.
3. **Does Tier D ship at all before the plugin-expansion epics (TSK-754/772/773/777)
   land?** It is independent of them (they're Tiers A/B/C); Tier D can be sequenced
   after, since the terminal works fine as host-owned core today (no regression if
   Tier D waits).

**Recommendation:** ratify the contract (§3) as the long-lived-plugin standard;
implement slice 1 (`TierDHost`, host-testable, lifted from `LSPPool`) + slice 2
(socket) first; defer the PTY transport + terminal PoC until there is a concrete
second consumer or an explicit terminal-extraction decision.
