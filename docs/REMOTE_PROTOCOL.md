# Remote core protocol v1 — duplex frames, subscriptions, push (TSK-655)

Design for the `mdv-serve` machine API (TSK-653) and the Swift
`RemoteTransport` (TSK-652 stage 2). Extends the existing call-response frame
contract to a duplex channel with server push, without breaking the
in-process shape the FFI already speaks.

**Owner rulings baked in (2026-06-12):** carrier = length-prefixed frames over
an **ssh-forwarded local socket** (no TLS dependency; `mdv-serve` binds
loopback/unix-socket only and trusts the tunnel). Terminal is out of scope
(ssh/tmux). LSP rides this same channel as piped JSON-RPC (TSK-659).

---

## 1. Layering

```
ssh tunnel (confidentiality + auth)
  └─ byte stream
      └─ u32-LE length-prefixed frames        (§2, same prefix as wire.rs)
          └─ MessagePack ENVELOPE map          (§3)
              └─ body: the method's existing request/response map
                       (unchanged from the FFI contract)
```

The body maps are byte-identical to what `mdvcore_*` exports consume today —
`CoreTransport.call(method, requestBody)` already moves exactly these bytes.
The envelope is NEW and remote-only; `InProcessTransport` never builds one.

## 2. Stream framing

`u32`-LE length prefix + MessagePack envelope bytes. Same prefix rule as
`wire::encode_frame` / `MsgPackFraming.frame` — one framing convention
everywhere. Max frame size: 16 MiB (the existing `MDV_STATUS_TOO_LARGE`
ceiling); a server result exceeding it returns error `too_large`, mirroring
the FFI behavior (windowed APIs are the real fix, §6).

## 3. Envelope

A MessagePack **map** (named fields, forward-compatible — unknown keys are
ignored, matching the body convention):

| key | type | req | res | evt | meaning |
|-----|------|-----|-----|-----|---------|
| `t` | str  | "q" | "r" | "e" | frame type |
| `i` | u64  | ✓   | ✓   | —   | correlation id (client-assigned, monotonically increasing per connection) |
| `m` | str  | ✓   | —   | —   | method (`find_search`, `fs.read`, `fs.watch`, …) |
| `b` | bin  | ✓   | opt | opt | the body bytes (a nested MessagePack doc, opaque to the envelope) |
| `e` | map  | —   | opt | —   | error `{c: str, x: str}` — code + human text; mutually exclusive with `b` |
| `s` | u64  | —   | —   | ✓   | subscription id |
| `n` | u64  | —   | —   | ✓   | event sequence number, per subscription, starts 1, no gaps unless resync |
| `k` | str  | —   | —   | ✓   | event kind (`fs` family: `changed`/`created`/`deleted`/`renamed`/`resync`) |

- Concurrent in-flight requests are allowed; responses demux by `i`.
- Responses may arrive out of order (server parallelism is an implementation
  choice, the protocol permits it).
- Event frames are unsolicited but always belong to an established
  subscription (`s`); a client receiving an unknown `s` ignores it (late
  events after unsubscribe are benign).

Error codes (`e.c`): `null_arg`, `bad_utf8`, `busy`, `wire_error`,
`too_large`, `panic`, `internal`, `handle_dead`, `invalid_pattern` — the
MdvStatus/typed-error family verbatim — plus transport-level `unknown_method`,
`unauthorized` (root containment), `overloaded`.

## 4. Session establishment (hello)

First frame each direction, before anything else:

- client → `{t:"q", i:1, m:"hello", b:{wire_version, client:"mdv-swift/…"}}`
- server → `{t:"r", i:1, b:{wire_version, capabilities:u64, server:"mdv-serve/…", root:"/abs/served/root"}}`

Wire-version inequality = hard close (the ABI-skew rule, networked).
`capabilities` is the SAME u64 bitmap the FFI exports — remote families get
new bits: `fs` (1<<9), `git` (1<<10), `transcript_list` (1<<11), `lsp_pipe`
(1<<12), `search` (1<<13, added with TSK-656), `highlight` (1<<14, TSK-660 —
an ENGINE bit, present in both the in-process mask and hello) — pre-assigned
here, flipped per family landing (the reserved-bit test discipline applies on
both sides, same as the engine ports).

## 5. Subscriptions (the push half)

Subscribe/unsubscribe are ordinary requests:

```
→ {t:"q", i:7, m:"fs.watch",   b:{paths:["src/"], recursive:true}}
← {t:"r", i:7, b:{sub:3}}
← {t:"e", s:3, n:1, k:"changed", b:{path:"src/main.rs"}}
← {t:"e", s:3, n:2, k:"deleted", b:{path:"src/old.rs"}}
→ {t:"q", i:9, m:"fs.unwatch", b:{sub:3}}
← {t:"r", i:9}
```

**Portable event contract** (FSEvents/inotify/kqueue normalized):
- kinds: `created`, `changed`, `deleted`, `renamed` (`b` carries `path`,
  renames also `old_path` when the platform reports it; otherwise a rename
  degrades to deleted+created — consumers must tolerate both).
- **Server-side coalescing:** events per path are debounced (default 100 ms,
  per-subscription override in the watch request) and deduped within the
  window — at most one `changed` per path per window. Ordering is preserved
  per path, best-effort across paths.
- **Backpressure:** per-subscription bounded queue (default 256 events).
  Overflow drops the WHOLE queue and enqueues a single
  `{k:"resync", n:<next>}` — the client must re-stat what it watches.
  `n` stays monotonic (no gap), so resync is explicit, never inferred.
  This bounds server memory under event storms (build dirs, git checkouts).
- Subscriptions die with the connection. No server-side persistence —
  reconnect = re-subscribe + initial re-stat (the resync path again).
- **`transcript.follow` (TSK-663)** rides the same machinery:
  `{dir, name, from_start?, debounce_ms?}` → `{sub}`, where `dir`/`name`
  are EXACTLY the identifiers `transcript.list` returns (single path
  components; `name` is `*.jsonl` — the list family's zero-traversal
  posture). Events: `{k:"events", b:{events:[…]}}` — PARSED batches with
  redaction FORCED server-side (raw line tailing would bypass the
  TSK-658 wire guarantee, so it does not exist); `{k:"resync"}` on
  truncation/rotation/oversized torn lines (tail resets; client refetches
  via `transcript_parse` if it needs history). Torn trailing lines carry
  across ticks; per-tick read window 1 MiB. Unsubscribe via `fs.unwatch`
  or the `transcript.unfollow` alias. Rides the `transcript_list`
  capability bit.

## 6. Method namespaces (forward map)

- Engine methods keep their FFI names verbatim (`find_search`,
  `markdown_render`, `highlight_runs`, …) — `RemoteTransport` is a drop-in
  `CoreTransport`.
- New families are dotted: `fs.stat`, `fs.readdir`, `fs.read`
  (**windowed**: `{path, offset, len}` → `{total, data}` — the Phase-1
  windowed contract; a whole-file convenience is deliberately absent),
  `fs.tree`, `fs.watch`/`fs.unwatch`, `git.head`, `git.status`,
  `git.branches`, `git.log`, `transcript.list`, `transcript.follow`
  (a subscription, like fs.watch), `lsp.start`/`lsp.send` (+ an `lsp` event
  kind for server→client JSON-RPC), `ping`.
- Root containment: every path-taking method resolves inside the served
  root (the mdv-web out-of-root guard, mandatory here) → `unauthorized`.

## 7. Client shape (RemoteTransport, TSK-652 stage 2)

- One background reader demuxes: `t:"r"` → completes the pending call by
  `i`; `t:"e"` → dispatches to the subscription registry.
- `CoreTransport.call` stays SYNCHRONOUS for the engine methods (block on
  the demuxed response — the adapters are sync today); the subscription
  surface is a separate async API (`subscribe(method, body) ->
  AsyncStream<Event>` + cancel). Local mode satisfies it with FSEvents
  behind the same interface.
- Timeouts: per-call deadline (default 30 s) → `CoreError.wireError`-class
  failure → the adapters' Swift fallback fires exactly as for a local fault
  (fail-safe property preserved remotely).

## 8. What this deliberately defers

- Authentication beyond the tunnel (the tunnel IS the auth boundary, v1).
- Compression (frames are small; `fs.read` windows bound the big ones).
- Multi-client fan-out (one client per connection; N connections fine).
- Persistence/replay of missed events (resync covers it more simply).

## 9. Test plan (for the implementing tickets)

- Envelope codec round-trip + unknown-key tolerance (both sides).
- Demux under concurrent in-flight calls (out-of-order responses).
- Subscription: seq monotonicity, debounce window, overflow→resync (force a
  1-event queue in test), unknown-sub tolerance, unsubscribe races.
- Hello: version mismatch closes; capability bits gate families.
- Loopback A/B: every engine A/B suite green against RemoteTransport over a
  unix-socket mdv-serve (the TSK-652 acceptance).
