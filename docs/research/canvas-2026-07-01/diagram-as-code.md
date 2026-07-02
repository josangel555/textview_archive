# Agent a79da7df70986d6a3.output

## Prompt (first 300 chars)
Do FRESH web research (use web search + fetching the actual documentation/source pages) on two diagram-as-code systems: **Mermaid** and **Graphviz / the DOT language**. Prefer PRIMARY sources (official docs, GitHub, papers). Cite every claim with a full URL.

For EACH, capture concretely these 6 dim

## Final message

I have thorough primary-source coverage across both systems and all six dimensions. Here is the structured writeup.

---

# Mermaid

## 1. Document / Data Model
- **Text DSL, one dialect per diagram type.** Every diagram begins with a keyword declaring its type, which tells the parser which grammar to use: `flowchart`/`graph`, `sequenceDiagram`, `classDiagram`, `stateDiagram-v2`, `erDiagram`, `journey`, `gantt`, `pie`, `quadrantChart`, `requirementDiagram`, `gitGraph`, `C4Context`, `mindmap`, `timeline`, `zenuml`, `sankey-beta`, `xychart-beta`, `block-beta`, `packet-beta`, `kanban`, `architecture-beta`, `radar`, and newer ones (`treemap`, Venn, Ishikawa, Wardley, Cynefin, Event Modeling, TreeView). "All diagram definitions begin with a declaration of the diagram type… This declaration notifies the parser which kind of diagram the code is supposed to generate." ([mermaid.js.org/intro/syntax-reference.html](https://mermaid.js.org/intro/syntax-reference.html))
- **Parsing: historically Jison, migrating to Langium; some ANTLR.** Each diagram type has its own grammar. The classic engine used **Jison** (LALR/LR grammars, one per diagram). Mermaid is actively **reimplementing parsers in Langium** (typed AST, strict validation, better errors); *"JISON grammars are deprecated… new diagrams with JISON grammars will not be accepted."* ([GitHub issue #4401](https://github.com/mermaid-js/mermaid/issues/4401), [docs.mermaidchart.com new-diagram-jison](https://docs.mermaidchart.com/mermaid-oss/community/new-diagram.html))
- **No single unified AST.** Each diagram type is a triple: *grammar/parser → a per-type "db" (the internal model that stores parsed nodes/edges/state) → a per-type renderer*. There is **no cross-type AST**; the model is diagram-specific. Note: the Jison parsers **discard comments during lexing**, so they aren't in the parsed model. ([jsr.io/@emily/mermaid-ast](https://jsr.io/@emily/mermaid-ast))
- **Node identification.** In flowcharts a node is an **id** with an optional label: `A[Start]`, `B{Choice}`; edges reference ids: `A --> B`. The id is the stable handle you re-reference. Historically there was **no public "parse to AST/JSON" API** exposed to users — `mermaid.parse()` validates but did not return a reusable tree ([GitHub issue #2523](https://github.com/mermaid-js/mermaid/issues/2523)).

## 2. Layout Representation — automatic, author specifies NO coordinates
- **Default engine = dagre** (a JS Sugiyama-style layered-DAG layout), used for flowchart, state, class, ER, etc. *"Dagre is the default layout engine… the classic layout algorithm… used in Mermaid for a long time."* ([mermaid.ai/open-source/config/layouts.html](https://mermaid.ai/open-source/config/layouts.html), [deepwiki mermaid layout-engines](https://deepwiki.com/mermaid-js/mermaid/2.3-layout-engines)) — **VERIFIED as current (v11)**.
- **How dagre works (Sugiyama layered):** (1) **cycle removal** — `acyclicer: greedy` computes a feedback arc set to make the graph acyclic; (2) **rank assignment** — nodes assigned to layers, default ranker **network-simplex** (also `tight-tree`, `longest-path`); (3) **ordering within ranks** to minimize edge crossings; (4) **coordinate assignment**. Config knobs: `rankdir` (TB/BT/LR/RL, default TB), `ranksep` (50), `nodesep` (50), `edgesep` (10). ([github.com/dagrejs/dagre wiki](https://github.com/dagrejs/dagre/wiki), [Medium: dagre network-simplex](https://medium.com/@angeloarcillas64/understanding-how-dagre-js-layout-works-ranker-network-simplex-5a4459b011c2)) — **dagre itself is unmaintained (dev stopped ~2018)** ([github.com/dagrejs/dagre](https://github.com/dagrejs/dagre)).
- **ELK is opt-in.** In **Mermaid v11, ELK (Eclipse Layout Kernel) was moved out of core into a separate package `@mermaid-js/layout-elk`** to shrink the bundle; **if not registered, Mermaid falls back to dagre.** ELK gives better handling of large/complex graphs; configured via `layout: elk` with strategies like `BRANDES_KOEPF`, `LINEAR_SEGMENTS`, `INTERACTIVE`, `SIMPLE`. ([npmjs.com/@mermaid-js/layout-elk](https://www.npmjs.com/package/@mermaid-js/layout-elk), [mintlify.wiki mermaid layouts](https://mintlify.wiki/mermaid-js/mermaid/configuration/layouts)) — **VERIFIED**.
- **Other registered layouts.** The layout registry also lists **`tidy-tree`** (hierarchical) and **`cose-bilkent`** (force-directed) ([mermaid.js.org/config/layouts.html](https://mermaid.js.org/config/layouts.html)) — I could only confirm these two in one docs source and could **NOT verify which diagram types use them**; treat as **UNVERIFIED** for scope. Architecture diagrams use a **cytoscape/fcose** force layout (see determinism below).
- **Determinism — mixed:**
  - dagre is **largely deterministic** given the same input (it orders by node ID) — *medium confidence*, from secondary sources ([deepwiki dagrejs/dagre](https://deepwiki.com/dagrejs/dagre)).
  - **Known non-determinism:** the **architecture diagram renders differently on each reload** because its underlying **fcose layout calls `Math.random()`**; you need `randomize: false` **plus a `seed`** to lock it ([GitHub issue #6166](https://github.com/mermaid-js/mermaid/issues/6166)). Separately, **SVG element IDs are generated from the current date by default**, so raw SVG output isn't byte-reproducible unless `deterministicIds` is enabled ([GitHub issue #727](https://github.com/mermaid-js/mermaid/issues/727)).
- **The author never gives coordinates** — dagre/ELK compute all positions and edge routes.

## 3. Mutation / Authoring API
- **You edit the text.** Programmatic surface (high-level `mermaid` API; the lower-level `mermaidAPI` is deprecated):
  - `mermaid.initialize(config)` — global config (theme, `securityLevel`, `startOnLoad`, layout).
  - `mermaid.render(id, text)` → `{ svg, bindFunctions }` (async; uses an internal serial queue).
  - `mermaid.parse(text)` → validate only (throws, or returns boolean with `suppressErrors`). ([mermaid.ai/open-source/config/usage.html](https://mermaid.ai/open-source/config/usage.html), [Snyk: mermaid.render](https://snyk.io/advisor/npm-package/mermaid/functions/mermaid.render))
- **Re-editability is excellent:** ids are stable handles, so *adding a node = adding a line* (`A --> C`); removing = deleting the line. No coordinate bookkeeping to maintain.

## 4. Persistence
- Plain-text **`.mmd` / `.mermaid`** files. **The source contains no coordinates**, so source round-trip is trivial — but the **rendered positions are recomputed on every render**. There is **no mechanism to freeze computed layout back into the source** (contrast Graphviz's `-Tdot`). This makes source diffs clean but means visual output is only as stable as the layout engine's determinism (§2).

## 5. Rendering
- **Output is SVG.** In-browser via `mermaid.js`; headless via **`@mermaid-js/mermaid-cli` (`mmdc`)**, which drives **Puppeteer/headless Chromium** to emit **SVG / PNG / PDF**. Server-side rendering = `mmdc` (it still needs a Chromium). ([mermaid.js.org/intro/getting-started.html](https://mermaid.js.org/intro/getting-started.html))
- **Theming:** built-in themes `default`, `base`, `dark`, `forest`, `neutral`; **only `base` is customizable** via **`themeVariables`**. Per-diagram overrides use the **`%%{init: {...}}%%`** directive; global via `initialize()` or YAML frontmatter config. Variables **auto-derive** (e.g. `primaryBorderColor` from `primaryColor`), and **colors must be hex, not CSS names** ('#ff0000' works, 'red' doesn't). Directives can be blocked by `securityLevel`. ([mermaid.ai/open-source/config/theming.html](https://mermaid.ai/open-source/config/theming.html))
- **Reproducibility caveats:** date-based IDs and fcose randomness (§2) — otherwise deterministic per version.

## 6. Programmatic-Authoring Friction (LLM/agent view)
- **Why it's ideal:** the agent writes **pure semantics** (`A --> B`), no pixel math, no coordinate model to keep consistent; adding/removing a node is a **one-line edit**; the engine handles all positioning and edge routing.
- **The limits (be concrete):**
  - **No pixel control** — you cannot place a node at an exact (x,y); dagre/ELK decide.
  - **Hard to force a specific arrangement** — your only levers are coarse (`rankdir`, subgraphs, ELK strategy, node/edge order); you can't say "put C to the right of B."
  - **Edge routing and overlaps are the engine's call** — you can't hand-route an edge.
  - **Layout instability:** a small input change (one added node/edge) can **reflow the entire diagram** — positions of unrelated nodes shift, so visual diffs are large and unpredictable.
  - **Non-determinism** for architecture/fcose diagrams and date-based SVG IDs undermines byte-stable regeneration unless explicitly seeded.

---

# Graphviz / DOT

## 1. Document / Data Model
- **DOT language grammar** (from the official spec, [graphviz.org/doc/info/lang.html](https://graphviz.org/doc/info/lang.html)):
  ```
  graph      : [ strict ] (graph | digraph) [ ID ] '{' stmt_list '}'
  stmt       : node_stmt | edge_stmt | attr_stmt | ID '=' ID | subgraph
  edge_stmt  : (node_id | subgraph) edgeRHS [ attr_list ]
  edgeRHS    : edgeop (node_id | subgraph) [ edgeRHS ]
  node_stmt  : node_id [ attr_list ]
  node_id    : ID [ port ]
  port       : ':' ID [ ':' compass_pt ] | ':' compass_pt
  attr_stmt  : (graph | node | edge) attr_list
  subgraph   : [ subgraph [ ID ] ] '{' stmt_list '}'
  ```
- **Directedness:** a `digraph` uses the `->` edge operator; an undirected `graph` uses `--`. `strict` forbids duplicate/multi-edges.
- **Nodes identified BY NAME.** A node exists the moment its ID is first referenced (in an edge or node statement); attributes attach by re-naming the same ID: `a [color=red, label="Node A"]`. Edge chains: `a -> b -> c`. **ID types:** alphanumeric+underscore, numerals, double-quoted strings (with escapes), or **HTML strings** `<...>`.
- **Attributes & defaults:** `graph [...]`, `node [...]`, `edge [...]` set defaults for subsequent statements (scoped/inherited within subgraphs); `attr_list` is `'[' a_list ']'`.
- **Subgraphs / clusters / ports:** `subgraph {...}`; **if the subgraph name begins with `cluster`, the engine draws its nodes inside a bounding rectangle** — this is a naming *convention*, not separate syntax. **Ports + compass points** attach edges to specific node sides: `a:port1:n -> b:port2:s`; compass points are `n ne e se s sw w nw c _`. Keywords (`node edge graph digraph subgraph strict`) are **case-independent**.
- **Internal model:** an attributed graph of nodes/edges/subgraphs (implemented in Graphviz's `libcgraph`).

## 2. Layout Representation — automatic, author specifies NO coordinates
Graphviz ships **multiple distinct engines** (select with `-K` or by invoking the named binary); each computes coordinates and edge splines ([paulgorman graphviz notes](https://paulgorman.org/technical/graphviz.txt.html), engine docs below):

| Engine | Model | Use |
|---|---|---|
| **dot** | Sugiyama-style **hierarchical/layered ranked** | directed/DAG "flow" graphs (default for directed) |
| **neato** | **stress minimization / MDS** (stress majorization default) | undirected, ≲100 nodes |
| **fdp** | **force-directed spring** model | undirected |
| **sfdp** | **multiscale** force-directed | large undirected graphs |
| **twopi** | **radial** — concentric circles by BFS distance from a root | tree-ish/radial |
| **circo** | **circular** | cycles/ring topologies |
| **osage** | **cluster/array packing** — lays out each cluster, then packs | clustered graphs |
| **patchwork** | **squarified treemap** | hierarchical area maps |

- **`dot` algorithm** — the four passes (Gansner, Koutsofios, North, Vo, *"A Technique for Drawing Directed Graphs,"* IEEE TSE 1993; summarized in *"Drawing graphs with Graphviz"* [graphviz.org/pdf/oldlibguide.pdf](https://www.graphviz.org/pdf/oldlibguide.pdf), [graphviz.org/docs/layouts/dot](https://graphviz.org/docs/layouts/dot/)): (1) **rank assignment** — assign each node an integer rank minimizing total weighted edge length (solved via network-simplex/integer program); (2) **ordering** — reorder nodes within ranks to reduce edge crossings; (3) **coordinate assignment** — a second optimization to compact the drawing and straighten edges; (4) **edge routing** as splines. Controls: `rankdir` (TB/LR/…), `ranksep`, `minlen`, `constraint`, `rank=same`.
- **`neato` model** — *"neato attempts to minimize a global energy function, which is equivalent to statistical multi-dimensional scaling,"* with the **default being stress majorization** (Gansner, Koren, North 2005, [graphviz.org/documentation/GKN04.pdf](https://graphviz.org/documentation/GKN04.pdf)); `mode` switches to **Kamada-Kawai** (steepest descent, K&K 1989). It's a stress/MDS model, not a naïve spring embedder. ([graphviz.org/docs/layouts/neato](https://graphviz.org/docs/layouts/neato/))
- **Author does not give coordinates** — the engine computes them. (Exception: `neato -n` accepts pre-set `pos` and skips layout, and `pin=true` pins specific nodes — these deliberately *bypass* auto-layout.)

## 3. Mutation / Authoring API
- **You edit the text.** CLI: `dot -Tsvg in.gv -o out.svg`; pick engine with `-Kneato` (or call `neato`, `fdp`, …).
- **Bindings & tooling:** C libraries `libcgraph`/`libgvc`; SWIG-generated bindings; Python via `pygraphviz` / the `graphviz` package; **`gvpr`** (a graph-stream processing language); **`xdot`** output for programs that need the computed layout. ([mankier.com/1/dot](https://www.mankier.com/1/dot))
- **Re-editability:** nodes are **auto-created by naming**, so *adding a node/edge = adding a line*; no coordinate bookkeeping.

## 4. Persistence
- Plain-text **`.dot` / `.gv`** files. **Source has no coordinates → trivial source round-trip.**
- **Crucially, Graphviz CAN persist computed layout:** `dot -Tdot` (a.k.a. `-Tcanon`) and **`-Txdot`** emit a **DOT file with the computed geometry embedded** — node `pos`, `width`, `height`, graph `bb`, and edge spline control points. This laid-out DOT can be **re-fed and rendered with `-n`** to preserve positions. So unlike Mermaid, Graphviz has a first-class "freeze the layout back into the source format" path. Positions in the `canon/dot/xdot/plain` formats are interpreted with the **origin at lower-left**. ([graphviz.org/docs/outputs](https://graphviz.org/docs/outputs/), [DOT lang spec](https://graphviz.org/doc/info/lang.html))

## 5. Rendering
- **Output via `-T<lang>`** (native CLI/server-side, **no browser needed**): **SVG** (`svg`, `svgz`, `svg_inline`), **PNG**, **PDF**, **PostScript/EPS**, **`xdot`** (+ `xdot1.2/1.4`), **DOT-with-coords** (`dot`/`gv`/`canon`), **JSON** (`json`, `json0`, `dot_json`, `xdot_json`), **plain/plain-ext**, plus GIF/JPEG/WebP/BMP/VML, image maps, and terminal formats. `dot -T?` lists what your build supports. ([graphviz.org/docs/outputs](https://graphviz.org/docs/outputs/))
- **Styling = attributes, not themes:** `color`, `fillcolor`, `style` (filled/dashed/rounded), `shape`, `fontname`, `penwidth`, `bgcolor`, `rankdir`, etc., with graph/node/edge default statements for cascading. There is **no theme-variable system** — it's pure attributes + defaults. ([graphviz.org/doc/info/attrs.html](https://graphviz.org/doc/info/attrs.html))
- **Determinism:** output is deterministic for a **fixed Graphviz version + fixed input ordering**, but **element enumeration order can affect layout** — a common nondeterminism source is a front-end (e.g. NetworkX) emitting nodes/edges in **unstable order**; sorting them first restores reproducibility. Cross-version output can also differ. ([groups.google.com networkx graphviz_layout reproducible](https://groups.google.com/g/networkx-discuss/c/hdXSeyyUXNo))

## 6. Programmatic-Authoring Friction (LLM/agent view)
- **Why it's ideal:** identical to Mermaid's strength — write **semantic relationships** (`a -> b`), nodes **auto-create on naming**, engine positions everything and routes edges as splines; add/remove is a one-line edit.
- **The limits — but with more levers than Mermaid:**
  - **No exact pixel placement** by design (unless you drop to `pos` + `-n`/`pin`, which turns *off* auto-layout).
  - **More control knobs to *bias* layout than Mermaid:** `rank=same`/`rankdir`, edge `weight` and `constraint`, `minlen`, **ports + compass points**, `cluster` subgraphs, invisible edges — you can *nudge* strongly, but the engine still makes the final call.
  - **Edge routing/overlaps are the engine's decision** (splines), not hand-routable in source.
  - **Layout instability:** adding one node/edge can change rank assignment and **reflow the whole drawing** — same trade-off as Mermaid, so byte-stable diffs of *rendered* output aren't guaranteed across edits even when the source diff is one line.

---

## Cross-cutting notes & UNVERIFIED flags
- **Mermaid default layout = dagre — VERIFIED** (multiple sources incl. v11 docs).
- **ELK is opt-in via `@mermaid-js/layout-elk`, moved out of core in v11, falls back to dagre — VERIFIED.**
- **`tidy-tree` and `cose-bilkent` as additional registered Mermaid layouts — UNVERIFIED** which diagram types actually use them (found in one docs page only).
- **dagre determinism (ID-ordered, deterministic) — MEDIUM confidence** (secondary sources); **Mermaid architecture-diagram non-determinism (fcose `Math.random`) and date-based SVG IDs — VERIFIED** via GitHub issues #6166 / #727.
- The **exact IEEE TSE 1993 dot paper PDF URL** I did not fetch directly; the algorithm is corroborated by the official `oldlibguide.pdf` and the `docs/layouts/dot` page cited above.
- The biggest structural contrast: **Graphviz can persist computed coordinates back into its own source format (`-Tdot`/`-Txdot`) and re-render them with `-n`; Mermaid cannot** — Mermaid source is always coordinate-free and re-laid-out every render.

## Sources
- Mermaid parser/Langium migration: https://github.com/mermaid-js/mermaid/issues/4401 · https://docs.mermaidchart.com/mermaid-oss/community/new-diagram.html · https://jsr.io/@emily/mermaid-ast · https://github.com/mermaid-js/mermaid/issues/2523
- Mermaid diagram types / syntax: https://mermaid.js.org/intro/syntax-reference.html · https://mermaid.js.org/intro/getting-started.html
- Mermaid layout engines: https://mermaid.ai/open-source/config/layouts.html · https://mermaid.js.org/config/layouts.html · https://mintlify.wiki/mermaid-js/mermaid/configuration/layouts · https://deepwiki.com/mermaid-js/mermaid/2.3-layout-engines · https://www.npmjs.com/package/@mermaid-js/layout-elk
- dagre: https://github.com/dagrejs/dagre · https://github.com/dagrejs/dagre/wiki · https://deepwiki.com/dagrejs/dagre · https://medium.com/@angeloarcillas64/understanding-how-dagre-js-layout-works-ranker-network-simplex-5a4459b011c2 · https://blog.disy.net/sugiyama-method/
- Mermaid API: https://mermaid.ai/open-source/config/usage.html · https://snyk.io/advisor/npm-package/mermaid/functions/mermaid.render
- Mermaid theming: https://mermaid.ai/open-source/config/theming.html
- Mermaid determinism: https://github.com/mermaid-js/mermaid/issues/6166 · https://github.com/mermaid-js/mermaid/issues/727
- DOT language grammar: https://graphviz.org/doc/info/lang.html · https://graphviz.org/doc/info/attrs.html
- Graphviz engines: https://paulgorman.org/technical/graphviz.txt.html · https://graphviz.org/docs/layouts/dot/ · https://graphviz.org/docs/layouts/neato/ · https://www.mankier.com/1/dot
- Graphviz layout papers: https://www.graphviz.org/pdf/oldlibguide.pdf · https://graphviz.org/documentation/GKN04.pdf
- Graphviz outputs / xdot / dot-with-coords: https://graphviz.org/docs/outputs/
- Graphviz determinism: https://groups.google.com/g/networkx-discuss/c/hdXSeyyUXNo
