# TextView / MarkdownViewer — layer map (2026-06-12)

Color key: **green** = Rust engine validated **and** adapter+gate wired ·
**yellow** = Rust engine validated, adapter/gate **not yet wired** ·
**red** = Swift twin slated for deprecation · **blue** = stays Swift
(host-coupled) · **gray** = infrastructure.

> All `MDV_RUST_*` gates currently **default OFF** — the shipping app still
> routes every engine through Swift. Flipping defaults (after soak) and then
> deleting the red twins IS the deprecation path.

```mermaid
flowchart TB

subgraph UI["SwiftUI app - ViewerUI (stays Swift)"]
    CV["ContentView / DocumentModel<br/>TabCoordinator, StatusBar, Sidebar"]
    LENSES["View lenses:<br/>Rendered (WKWebView), Source, Editor (CM6),<br/>Hex, Table/CSV, Diff, Preview"]
    FEAT["Features: LSP, Plugins, Walkthrough,<br/>Image editor, Mermaid shim, Terminal, Monitor"]
end

subgraph TWINS["Swift engine twins - DEPRECATE (ports validated)"]
    S1["CSVParser / CSVFilter"]
    S2["Diff parse"]
    S3["HexDumpBuilder / HexSearchEngine"]
    S4["IndentDetector"]
    S5["CMEditApplier"]
    S6["FindEngine"]
    S7["FuzzyMatcher"]
    S8["HTMLRenderer / HTMLVisitor<br/>(structural part)"]
    S9["ClaudeLogParser"]
end

subgraph STAYS["Stays Swift (host-coupled)"]
    K1["TreeSitter highlight engine"]
    K2["HTMLSanitizer (security barrier)"]
    K3["MermaidSourceParser"]
    K4["GitClient, FileWatcher, Sessions,<br/>History, SQLite, LSP client"]
end

subgraph BRIDGE["Bridge - Sources/RustCore + CMdvCore"]
    GATES["RustCoreGates<br/>MDV_RUST_* env / defaults<br/>(ALL DEFAULT OFF today)"]
    CLIENT["CoreClient.swift<br/>mdvFrameCall, CoreCapabilities,<br/>typed CoreError + fallback channel"]
    MSGPACK["MessagePack.swift<br/>hand-rolled codec, no deps"]
    HDR["CMdvCore mdvcore.h<br/>cbindgen header, ABI skew pins"]
end

subgraph FFI["mdvcore-ffi - the only unsafe crate"]
    EXPORTS["extern C exports<br/>ffi_frame_body!, catch_unwind guard,<br/>misuse-matrix tests"]
    CAPS["Capability bitmap u64<br/>bits 0-8 ALL SHIPPED<br/>(no reserved bits left)"]
end

subgraph CORE["mdvcore-core - pure, sans-IO, forbid(unsafe)"]
    R1["Ported + adapter wired:<br/>csv+session, diff, hex, indent, cm_edit"]
    R2["Ported, adapter NOT wired yet:<br/>find_engine, fuzzy, json+transcript, markdown"]
    R3["Shared: wire (MessagePack frames),<br/>trace, filter, format, nav"]
end

subgraph FRONTS["Alt front-ends (rust-only consumers)"]
    TUI["mdv-tui (ratatui)"]
    WEB["mdv-web (std-only HTTP)<br/>the remote-core path"]
end

DEPS["Deps, features-off + pinned:<br/>serde, rmp-serde, regex-lite (0 transitive),<br/>pulldown-cmark (+unicase), cbindgen (build)"]

UI --> TWINS
UI --> STAYS
TWINS -.->|today: default route| UI
TWINS --> GATES
GATES -->|gate ON: Rust route| CLIENT
CLIENT --> MSGPACK
CLIENT --> HDR
HDR --> EXPORTS
EXPORTS --> CAPS
EXPORTS --> CORE
CORE --- DEPS
TUI --> CORE
WEB --> CORE
K2 -.->|raw_html chunks| CLIENT
K1 -.->|code chunks| CLIENT
K3 -.->|mermaid chunks| CLIENT

classDef green fill:#1a7f37,color:#ffffff
classDef yellow fill:#b08800,color:#ffffff
classDef red fill:#a40e26,color:#ffffff
classDef blue fill:#0969da,color:#ffffff
classDef gray fill:#57606a,color:#ffffff

class R1 green
class R2 yellow
class S1,S2,S3,S4,S5,S6,S7,S8,S9 red
class K1,K2,K3,K4,CV,LENSES,FEAT blue
class GATES,CLIENT,MSGPACK,HDR,EXPORTS,CAPS,DEPS,TUI,WEB gray
```

## Where each engine stands

| Engine | Rust module | Capability bit | Adapter | Gate (`MDV_RUST_*`) | Default |
|---|---|---|---|---|---|
| CSV session | `csv`+`session` | 1<<0 | `RustCSVAdapter` | `MDV_RUST_CSV` | OFF |
| Diff | `diff` | 1<<1 | `RustDiffAdapter` | `MDV_RUST_DIFF` | OFF |
| Hex render | `hex` | 1<<2 | `RustHexAdapter` | `MDV_RUST_HEX` | OFF |
| Hex search | `hex` | 1<<2 | `RustHexSearchAdapter` | `MDV_RUST_HEXSEARCH` | OFF |
| Indent | `indent` | 1<<3 | `RustIndentAdapter` | `MDV_RUST_INDENT` | OFF |
| CM edit apply | `cm_edit` | 1<<4 | wrapper only | `MDV_RUST_CMEDIT` (case exists) | OFF |
| Find | `find_engine` | 1<<5 | **none yet** (TSK-645) | **no gate case yet** | — |
| Markdown | `markdown` | 1<<6 | **none yet** (TSK-648) | **no gate case yet** | — |
| Transcript | `json`+`transcript` | 1<<7 | **none yet** (TSK-647) | **no gate case yet** | — |
| Fuzzy | `fuzzy` | 1<<8 | **none yet** (TSK-646) | `MDV_RUST_FUZZY` (case exists) | OFF |

## Deprecation path (Swift core → Rust core)

1. **Wire the four new adapters** — TSK-645 (find), TSK-646 (fuzzy),
   TSK-647 (transcript), TSK-648 (markdown incl. chunk splice; sanitizer /
   mermaid / TreeSitter stay Swift-side by design). Fallback-on-`CoreError`
   like the CSV beachhead.
2. **Flip gate defaults ON per engine and soak** (TSK-649 stage A) — env
   override still pins either side for A/B; the parity suites are the
   regression net.
3. **Bake in** (TSK-649 stage B, owner-gated per engine): remove the gates,
   delete the red twins, retarget twin-coupled tests. Swift core shrinks to
   the blue host-coupled set; `mdvcore-core` becomes the single engine layer —
   the same one `mdv-web` serves remotely.

> Mermaid rendering glitch in this doc is tracked as TSK-650 (parked by owner
> directive).

---

# Remote operation (owner target 2026-06-12): Rust-only server, thin Swift UI

**What the Swift app calls "core" today is ONLY the engine families above.**
Everything else is Swift-local — and that's the real gap for remote:

| Surface | Today (Swift-local) | Remote requirement | Ticket |
|---|---|---|---|
| File read | `TextFileLoader` / `BinaryFileLoader` | `fs.read` **windowed** (offset+len; a 500 MB file never ships whole) | TSK-654 |
| File tree / sidebar | `FileTreeService` | `fs.tree` / `fs.readdir` with listing caps + root containment | TSK-654 |
| File watching | `FileWatcher` (FSEvents) | `fs.watch` **server-push** events — needs a duplex channel, not request/response | TSK-655 |
| Cross-file search | `CrossFileSearch` | host-layer orchestration over `find_engine`, streamed results | TSK-656 |
| Git | `GitClient` (spawns local git) | `git.*` family server-side (spawn server's git; no libgit2 dep) | TSK-657 |
| Transcript discovery + tail | `FileManager` + Swift tail | `transcript.list/follow` on the server; redaction enforced at the WIRE | TSK-658 |
| LSP / Terminal | local processes | server-side LSP proxy / remote PTY — hardest, spiked separately | TSK-659 |
| In-document find bars | WKWebView / NSTextView / CM6 native search | stays client-side (it searches what's on screen) | — |

The engine layer (`mdvcore-core`) is deliberately **sans-IO** — that stays.
IO lives in a Rust **host layer**: locally that's the Swift app feeding bytes
through FFI; remotely it's **`mdv-serve`** (TSK-653) doing its own IO where
the files live. `mdv-web` already proves the shape (it browses/reads/searches
in pure Rust) — but it serves HTML to humans; `mdv-serve` speaks the SAME
MessagePack frames the FFI speaks, to the Swift thin client over a socket.

```mermaid
flowchart LR

subgraph MAC["Mac (thin client)"]
    UI2["SwiftUI app<br/>lenses, chrome, caret,<br/>native find bars"]
    TRANS["CoreTransport seam (TSK-652)<br/>same frames, two carriers"]
end

subgraph LOCALMODE["Local mode (today)"]
    FFI2["in-process FFI<br/>libmdvcore_ffi.a"]
end

subgraph SERVER["Remote server (Rust ONLY)"]
    SERVE["mdv-serve (TSK-653)<br/>fs.*, git.*, transcript.*,<br/>watch push, DocId registry,<br/>audit log"]
    CORE2["mdvcore-core<br/>all 9 engine families"]
    FILES["files, git repos,<br/>~/.claude transcripts"]
end

UI2 --> TRANS
TRANS -->|local| FFI2
FFI2 --> CORE2
TRANS -->|"socket (frames)"| SERVE
SERVE --> CORE2
SERVE --> FILES
SERVE -.->|push: watch events,<br/>search/tail streams| TRANS
```

**Why the adapter-flip wave (TSK-645–649) is still the critical path:** the
transport seam only helps if every consumer already routes through the
adapters. Flip order: adapters → `CoreTransport` → `mdv-serve` + `fs` family →
watch/push → git/transcript → LSP/terminal spike. Epic: **TSK-651**.
