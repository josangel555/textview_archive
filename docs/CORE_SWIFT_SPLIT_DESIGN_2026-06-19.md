# Core / Swift split — where the boundary sits, and how local-only value-add layers on top (TSK-805)

**Status:** design spike (auto-approved per owner 2026-06-13). No owner decision
required; surfaced here as the durable design artifact. Companion executable
model: `Sources/ViewerCore/Architecture/FeatureLocality.swift` + tests
`Tests/ViewerCoreTests/FeatureLocalityTests.swift`.

## The question

The board has a large **remote-core track** (epic TSK-651; transport seam
TSK-652; protocol/fs.watch TSK-655/662; capability families TSK-653–664; app
attach TSK-665) all aimed at *moving the engine into Rust and exposing it over
the wire* so the core can run on another host. This spike is the **inverse,
undesigned angle**:

> Where should the core/Swift boundary sit so the Rust core stays cleanly
> separated (and remoteable), yet Swift/macOS-only value-added features (native
> UI affordances, system integration) can still be built on top — given those
> features explicitly will NOT be remote-supported (`[Remote not supported]`)?

The remote track answers "what goes *down* into the core." This answers "what
stays *up* in Swift, and how do we keep that from leaking back down."

## TL;DR — the answer

Use a **three-tier, one-way dependency lattice**. The split is not core-vs-UI;
it is **portability**:

```
                         depends downward ONLY ─────────────►
┌──────────────────────────────────────────────────────────────────────┐
│ Tier 3  LOCAL-ONLY SWIFT / macOS        [Remote not supported]         │
│   AppKit/SwiftUI/WindowServer · macOS frameworks (AVFoundation,        │
│   CoreMIDI, PDFKit, NSPasteboard, Quick Look) · local hardware ·       │
│   live pointer/keyboard. The value-add layer. Pinned to THIS Mac.      │
├──────────────────────────────────────────────────────────────────────┤
│ Tier 2  HOST-ORCHESTRATED               (symmetric local↔remote)       │
│   IO + process orchestration done WHERE THE FILES LIVE: fs.*, git.*,   │
│   transcript.*, lsp pipe, cross-file search. Local = Swift app;        │
│   remote = mdv-serve. Same transport-agnostic frame contract.          │
├──────────────────────────────────────────────────────────────────────┤
│ Tier 1  REMOTEABLE CORE                 (mdvcore-core, sans-IO)        │
│   Pure compute: parse, render-structure, diff, find, fuzzy, hex, csv,  │
│   indent, transcript-parse. Bytes in → bytes out. forbid(unsafe).      │
│   Reachable over FFI AND remote frames verbatim. Serves mdv-web today. │
└──────────────────────────────────────────────────────────────────────┘
```

**The invariant that makes the remote story hold: work flows downhill, never
up.** A Tier-1 engine must never reach for Tier-2 IO or Tier-3 system
frameworks, because the *same* engine code must run unchanged inside
`mdv-serve` on a headless box. One Tier-3 dependency pins a whole surface to
Tier 3 — i.e. `[Remote not supported]`.

This is not new architecture to *build* — it is the architecture the codebase
already has (`docs/ARCHITECTURE_LAYERS.md`, `docs/REMOTE_PROTOCOL.md`,
`mdvcore-core` is already `forbid(unsafe)` and sans-IO; `mdv-web`/`mdv-tui`
already consume it). What was missing is (a) the **boundary criteria written
down as a rule**, and (b) an **enforcement mechanism** so the boundary doesn't
silently erode as value-add features land. This spike supplies both.

## Boundary criteria — the decision rule

A feature surface's tier is **derived**, not chosen, from the host capabilities
it genuinely needs. `HostCapability.minimumTier` encodes the rule once:

| Capability a feature needs | Forces tier | Why |
|---|---|---|
| `pureCompute` (bytes/values in, out) | Tier 1 remoteable-core | no host dependency → runs anywhere the engine runs |
| `filesystemIO` (read/list bytes) | Tier 2 host-orchestrated | IO, but performable where files live (Swift locally / mdv-serve remotely) |
| `subprocess` (spawn git, LSP server) | Tier 2 host-orchestrated | process on the host; symmetric local/remote |
| `pushStream` (fs.watch, transcript.follow) | Tier 2 host-orchestrated | duplex push; the protocol already carries it (REMOTE_PROTOCOL §5) |
| `appKitUI` (AppKit/SwiftUI/WindowServer) | Tier 3 local-only | on-screen UI is meaningless to a remote engine |
| `macSystemFramework` (AVFoundation, CoreMIDI, PDFKit, NSPasteboard…) | Tier 3 local-only | macOS-only API, no remote equivalent |
| `localHardware` (audio device, MIDI port, GPU surface) | Tier 3 local-only | physical device attached to THIS machine |
| `interactivePointer` (live caret/mouse/drag tied to this window) | Tier 3 local-only | addresses on-screen state a remote engine doesn't have |

**Tier = max(minimumTier of every dependency).** A surface with no host
dependency is Tier 1; a single macOS-framework dependency makes it Tier 3.

A surface is **mis-tiered** (a real architecture violation) if its declared
tier ≠ its derived tier:

- Declared *more portable* than its dependencies allow ⇒ it would break the
  remote story (e.g. an audio editor declared as core). **Hard error.**
- Declared *less portable* than necessary ⇒ a missed-portability smell (a pure
  parser needlessly pinned local), kept honest by the same check.

Both are caught by `FeatureLocalityCatalog.inconsistencies` and the
`test_catalogIsInternallyConsistent` test — the **teeth**.

## How Swift/macOS value-add layers on top WITHOUT polluting the core

The whole point of value-add is that it's *allowed to be local-only*. The rules
that keep it from leaking down:

1. **Value-add lives in Tier 3 (ViewerUI / the macOS-framework slices of
   ViewerCore) and consumes lower tiers, never the reverse.** An image editor
   may call `fs.read` (Tier 2) and a Rust engine (Tier 1); neither may call the
   image editor.

2. **Anything a value-add feature needs from the core must be expressed as a
   lower-tier capability first.** Example: a macros feature (TSK-957) that wants
   to "replay a text transform" must route through a *replayable command*
   (`CommandReplayability` already exists) whose effect is a pure model
   mutation — the transform is Tier 1/2, the record/replay UI is Tier 3. The
   value-add does not push UI concepts down into the engine.

3. **The frame contract is the firewall.** Tier 1↔2 only ever exchange the
   MessagePack body maps (`CoreTransport.call(method, body)`); Tier 3 talks to
   Tier 2 through the same seam locally (`InProcessTransport`) that a remote
   client uses (`RemoteTransport`). Because the contract is transport-agnostic
   (REMOTE_PROTOCOL §1), a value-add feature written against it works against a
   remote core for free *for the parts that are Tier ≤ 2* — only its Tier-3
   shell is local.

4. **Capability bits gate, softly.** The engine exports a `u64` capability
   bitmap (`CoreCapabilities`); the remote `hello` re-uses the same bits plus
   remote-family bits (REMOTE_PROTOCOL §4). A value-add feature checks the bit
   and degrades — it never assumes a capability is present. Local-only features
   simply have no bit (they are not core capabilities at all).

## Candidate feature classification

Encoded in `FeatureLocalityCatalog.surfaces` (the test pins it). Summary:

### Tier 1 — Remoteable core (`mdvcore-core`)
markdown structural render · diff parse · csv parse/filter/sort · hex
dump+search · in-buffer find · fuzzy match · transcript parse · indent detect.
*(Sanitizer / TreeSitter highlight / Mermaid parse stay Swift-side chunks by
design — see ARCHITECTURE_LAYERS — but the surrounding render is Tier 1.)*

### Tier 2 — Host-orchestrated (Swift app locally / `mdv-serve` remotely)
windowed file read (`fs.read`, TSK-654) · file tree (`fs.tree`) · file watch
(`fs.watch`, TSK-655) · cross-file search (TSK-656) · git (`git.*`, TSK-657) ·
transcript discovery+tail (`transcript.list/follow`, TSK-658/663) · LSP session
pipe (`lsp.*`, TSK-659).

### Tier 3 — Local-only Swift / macOS value-add (`[Remote not supported]`)
view lenses (WKWebView/CM6/native chrome) · in-document native find bars (search
what's on screen) · image editor · audio editor/playback · AudioUnit+CoreMIDI
(TSK-956) · Universal Paste (TSK-958) · embedded PTY terminal (remote terminal =
ssh/tmux, deliberately *not* in mdv-serve per REMOTE_PROTOCOL §7.5) · Quick
Look / media preview · editor macros (TSK-957).

> Edge calls worth noting:
> - **Native find bars are Tier 3, not Tier 1**, even though the find *engine*
>   is Tier 1: the bar searches the on-screen WKWebView/NSTextView, which is
>   pointer/render state. The portable part (the matcher) is already Tier 1;
>   the bar is its local shell.
> - **Terminal is Tier 3 by owner ruling**, not by capability necessity — a PTY
>   *could* be host-orchestrated, but the owner scoped remote terminal to
>   ssh/tmux (REMOTE_PROTOCOL §7.5), so we classify it local-only to match the
>   product decision. The model lets us change this by editing one dependency
>   set if that ruling ever changes.

## What this changes operationally

- **New value-add feature?** Add a `FeatureSurface` to the catalog with its real
  dependency set. The test tells you its tier. If you *wanted* it remoteable but
  the catalog forces Tier 3, that's the architecture telling you it has a
  macOS dependency to shed first.
- **Refactor moves an engine?** If someone gives a Tier-1 surface a host
  dependency, `test_remoteableCoreSurfacesHaveNoHostDependency` /
  `test_catalogIsInternallyConsistent` go red — the remote story is protected by
  CI's headless gate, not by reviewer vigilance.
- **Doc and code can't drift.** The classification table above and the catalog
  are the same data; the test is the contract between them.

## Non-goals / deferred

- This spike does **not** move any engine or wire any adapter — that's the
  TSK-645–649 / TSK-651 track, unchanged and still the critical path.
- It does not introduce a runtime feature-gating system; the catalog is a
  *design + enforcement* artifact, not a flag store (the real flag store is
  `RustCoreGates` / capability bits, which already exist).
- No new dependencies. Pure Foundation; the model is host-testable.

## Open items for the owner (none blocking)

- The terminal Tier-3 classification follows the existing owner ruling; revisit
  only if remote terminal is ever brought into `mdv-serve`.
- If the owner wants the catalog *rendered* into the in-app diagnostics window
  (it is `Codable`), that's a small Tier-3 follow-up — file separately.
