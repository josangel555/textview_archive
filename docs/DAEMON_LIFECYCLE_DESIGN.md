# Daemon vs instances — mdv-serve lifecycle design (TSK-1537)

**Status:** designed 2026-07-07 · slices filed (see §8) · owner question 2026-07-04
**Scope:** how the rust core runs on a machine — one daemon, N shells — and how it
starts, stops, survives updates, and refuses to lose data. The stateful-session half
builds on S1–S8 (TSK-1516…1523); the lifecycle half stands alone.

## 1. Where we are (recorded so the delta is honest)

```
TODAY                                   TARGET
─────                                   ──────
App ──(launch-time dial, TSK-665)──►    App ──(reconnect loop)──►┐
        mdv-serve (manual foreground)                            │
                                                                 ▼
mdv-web: own HTTP server,               launchd-activated mdv-serve daemon
         core IN-PROCESS                (ONE per user; owns EditorSessions)
                                                                 ▲
mdv-tui: core IN-PROCESS,               mdv-web ──(thin client)──┤
         no remote mode                 mdv-tui ──(CoreTransport)┘
```

Three independent embeddings of the same core; no shared sessions; the App's remote
mode dials only at launch and silently reverts on loss. That is the gap.

## 2. Decisions (the short version)

| # | Question | Decision |
|---|----------|----------|
| D1 | Process model | ONE per-user daemon (`mdv-serve`), N attached shells (App/TUI/WUI). Never per-project daemons — the session registry (TSK-1517) is already multi-doc with an eviction budget. |
| D2 | Start | launchd agent with **socket activation**: launchd owns the unix socket; first client connect spawns the daemon (`launch_activate_socket`). Manual `mdv-serve <socket>` stays for dev/Linux. |
| D3 | Stop | **Idle-exit with a dirty guard**: zero connections for 15 min AND zero dirty sessions → flush + exit 0 (launchd re-arms the socket). A dirty session pins the process alive, same law as the eviction budget (dirty ⇒ pinned, TSK-1517). |
| D4 | Updates / skew | Hello already carries `abi_version` + capability mask. A NEWER client meeting an OLDER daemon sends `daemon.retire`; the daemon flushes, closes the listener, exits; the retry connect spawns the updated binary (the plist points into the app bundle, so the binary updates with the app). An older client meeting a newer daemon keeps the existing hard-close rule. |
| D5 | Who owns state | EditorSessions live IN THE DAEMON (doc_registry). Shells are views: one writer, N viewers, change fan-out over the TSK-662 subscription infra. Until S8 lands, shells attach stateless methods only — the lifecycle work does not wait for it. |
| D6 | WUI | `mdv-web` remains the HTTP/WS face (s1/s2 shipped there) but becomes a THIN CLIENT of the daemon socket — its in-process core calls swap for socket calls behind one seam. Not a rewrite; a transport swap. |
| D7 | TUI | Same seam as the App: a rust `CoreTransport` trait — `InProcess` (today) \| `Socket(path)` — selected by `MDV_REMOTE_SOCKET`, mirroring the Swift pattern byte-for-byte on the wire. |
| D8 | App resilience | Replace the launch-time-only dial with the TSK-1552 self-healing pattern (capped backoff, forever until app quit; requests queue while down). Reverting to in-process core remains the degrade path AFTER the backoff window — observable, never silent. |

## 3. Lifecycle mechanics

### launchd agent (macOS)
- `~/Library/LaunchAgents/com.markdownviewer.mdv-serve.plist`, installed/updated by
  `install-app.sh` (opt-in flag first, default later once proven).
- `Sockets` key: launchd creates `~/Library/Application Support/MarkdownViewer/mdv-serve.sock`
  (0600, per-user) and holds it. `ProgramArguments` → the app-bundle-embedded binary.
- Daemon start: `launch_activate_socket("mdv-serve")` hands over the listening fd; the
  existing accept loop takes it verbatim. Fallback: no launchd env (dev, Linux) → bind
  the path itself, exactly as today.
- **Single-instance is free**: launchd owns the socket; two daemons cannot bind it.

### Idle-exit
- Tick every minute: `connections == 0 && dirty_sessions == 0 && idle >= 15min` → flush
  snapshots → exit 0. launchd re-arms; next client connect restarts. Cheap cold-start is
  a design budget: attach p50 must stay < 150 ms (hello + session restore from the store).
- A dirty session NEVER idles out (data-loss wall). If a shell crashed leaving dirt, the
  daemon holds it until a shell reattaches or the OS reboots (snapshots also persist on
  every mutation batch — crash loses ≤ one debounce window).

### Update handover (D4 flow)
```
new App v2 ── hello ──► daemon v1
        ◄── hello{abi:v1} ──
  abi mismatch, client newer:
        ── daemon.retire ──►    flush all sessions → close listener → exit
        (connect, retry w/ backoff) ──► launchd spawns v2 binary → hello{abi:v2} ✓
```
`daemon.retire` refuses (error, no exit) if ANY other client is attached with a
DIFFERENT abi expectation — first-writer-wins; the stragglers see the connection close
and re-dial (their reconnect loops handle it).

## 4. Security
- Socket 0600 + `SO_PEERCRED`-equivalent check (uid match) on accept — same-user only,
  no TCP listener. The WUI's HTTP face keeps its own loopback + Host anti-rebind walls.
- The wire-boundary redaction rule (TSK-658) stays: forced redaction on anything that
  leaves the process, regardless of transport.

## 5. Observability
- `daemon.status` method: uptime, connections, session count/dirty count, memory
  (phys_footprint), abi, binary path. Surfaced in the App's diagnostics pane and
  `mdv --status` later.
- Structured stderr log (launchd captures to `~/Library/Logs/MarkdownViewer/mdv-serve.log`).

## 6. Failure modes
| Failure | Behavior |
|---|---|
| Daemon crash | launchd re-arms socket; clients' reconnect loops re-attach; sessions restore from persisted snapshots (≤ one debounce window lost). |
| Daemon wedge | Client request deadline → reconnect loop's dial fails → shell degrades to in-process core, banner "remote core unavailable"; a `daemon.retire`-style kill is manual (`launchctl kickstart -k`). |
| Socket path clobbered | launchd owns the node; a stale manual node is superseded by `launchctl bootstrap`. Dev fallback keeps today's stale-node replacement. |
| Disk full on flush | Idle-exit ABORTS (stays alive, logs); dirty guard already prevents data-dropping exits. |

## 7. What this deliberately does NOT do
- No system-wide (root) daemon; no multi-user sharing. One user, one daemon.
- No network transport in this design — the socket is local. Remote-over-SSH rides the
  same wire later (the envelope is already transport-agnostic, TSK-651).
- No LSP/terminal remoting (parked, TSK-659).

## 8. Slices (filed on the board, in dependency order)
1. **Socket activation + launchd plist** — `launch_activate_socket` fallback-first;
   `install-app.sh --with-daemon` installs the plist. [independent]
2. **Idle-exit with the dirty guard** — the 15-min tick + flush + exit; attach-latency
   budget test. [independent]
3. **`daemon.retire` + skew handover** — the D4 flow + refuse rule. [after 1]
4. **App reconnect loop** — TSK-1552 pattern on the TSK-665 dial; observable degrade.
   [independent; supersedes the 665 follow-up note]
5. **TUI `CoreTransport` seam** — rust trait, `InProcess`/`Socket`; env-selected. [independent]
6. **mdv-web thin-client mode** — swap in-process core calls for socket calls behind one
   seam; keeps its HTTP walls. [after 5's trait lands core-side]

Stateful one-writer-N-viewers attach rides S5–S8 (TSK-1516…1523), not re-designed here.
