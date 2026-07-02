# Agent a4f9686920425afb5.output

## Prompt (first 300 chars)
You are a web-research agent. Research how visual/design/canvas editing tools model their DOCUMENT as an in-memory data structure — the "scene graph" or "document IR" (intermediate representation) — as opposed to raw HTML/CSS/JS.

Context: someone is building a visual/canvas editor whose document wi

## Final message

Research complete. Here are the cited findings.

# How visual/canvas editors model their document (scene graph / document IR)

The single most important axis: **flat map of records with parent pointers** vs. **nested tree**. Collaborative/agent-friendly tools converge on the flat model; file-format-first tools tend toward nested trees. Below, per-tool concrete detail, then the cross-cutting themes (IDs, z-order, schemas) and pitfalls.

---

## The two architectures at a glance

```
FLAT (records keyed by id, hierarchy via parentId)      NESTED (tree of children[] arrays)
┌─────────────────────────────────────────┐            ┌──────────────────────────────┐
 tldraw   store: Map<id, Record>            │            │ Sketch   page.json layers[]  │
 Excalidraw  elements: [ {..}, {..} ]       │            │ Penpot   ShapeTree (+ objects│
 Figma    Map<ObjectID, Map<Prop,Value>>    │            │          map, hybrid)        │
                                            │            │ Konva    Stage>Layer>Group   │
 parent = a PROPERTY on the child           │            │ Lottie   comp > layers[]     │
 z-order = fractional index string          │            │ z-order = array position     │
└─────────────────────────────────────────┘            └──────────────────────────────┘
```

The flat model wins for programmatic/collab mutation: reparenting is a single property write, no array splicing, IDs never move. The nested model is more human-readable on disk but makes "move node X under Y" a structural tree surgery and makes stable addressing harder.

---

## tldraw — flat reactive record store (open source, best-documented)

- **Storage is a flat map of records, not a tree.** The store is "a reactive collection of records" keyed by id; changes are expressed as a `RecordsDiff`. Every record has a `typeName` (e.g. `'shape'`, `'page'`) and an `id`. Source: [tldraw Store/Schema (DeepWiki)](https://deepwiki.com/tldraw/tldraw/2.3-tools-system), [Store reference](https://tldraw.dev/reference/store/Store).
- **`TLBaseShape` fields:** `id: TLShapeId`, `type`, `x`, `y`, `rotation`, `index: IndexKey`, `parentId: TLParentId`, `isLocked`, `opacity`, `meta` (arbitrary user metadata), and `props` (shape-type-specific). Base defaults: `{ x:0, y:0, rotation:0, isLocked:false, opacity:1, meta:{} }`. Source: [TLShape.ts](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts), [Shapes docs](https://tldraw.dev/docs/shapes).
- **Hierarchy = parent pointer.** `type TLParentId = TLPageId | TLShapeId` — a shape is parented to either a page or another shape (group/frame). No `children[]` array; children are found by querying records whose `parentId` matches. Source: [TLShape.ts](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts).
- **IDs = branded, prefixed, opaque.** `createShapeId()` returns `` `shape:${uniqueId()}` `` cast to the branded type `TLShapeId = RecordId<TLShape>`. Pages are `page:xxx`, etc. IDs are stable across edits/reload; the prefix makes them type-safe and greppable. Source: [TLShape.ts](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts).
- **Z-order = fractional index string, scoped to siblings.** `index: IndexKey` is a lexicographically-sortable string like `'a1'`, `'a2'`, `'a1V'` (first char = base-62 integer part, rest = fractional part). Higher sorts in front. Ordering is **relative to siblings under the same `parentId`**. Helpers: `getIndexBetween`, `getIndexAbove/Below`, `getIndicesBetween`, `sortByIndex`, `validateIndexKey`. As of [PR #6646](https://github.com/tldraw/tldraw/pull/6646) they use the `jittered-fractional-indexing` package (jitter prevents two clients minting identical indices). Trade-off: reorder touches only the moved shape (O(1) write, no sibling renumber), at the cost of index strings slowly growing and needing occasional rebalancing. Source: [Shape indexing](https://tldraw.dev/sdk-features/shape-indexing).
- **Schema/migrations are first-class.** `StoreSchema` coordinates record types, validates records, and runs migration sequences; any change to persisted shape requires up/down migrations (`createCustomRecordMigrationSequence`). `TLStoreSnapshot` carries schema-version info so old files upgrade on load. Trade-off: robust forward/back-compat, but every schema edit is a mandatory migration chore. Source: [StoreSchema](https://tldraw.dev/reference/store/StoreSchema), [DeepWiki](https://deepwiki.com/tldraw/tldraw/2.3-tools-system).

## Excalidraw — flat elements array (open source)

- **Document = flat array, zero nesting.** File JSON top level: `{ type:"excalidraw", version, source, elements:[…], appState, files }`. `elements` is a flat array of element objects; `files` is a separate id→binary map for images. Source: [JSON Schema docs](https://docs.excalidraw.com/docs/codebase/json-schema), [scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema).
- **Base element fields** (shared by every type): identity `id`, `type` (`"rectangle"|"text"|"arrow"|"image"|…`); geometry `x`, `y`, `width`, `height`, `angle` (radians); style `strokeColor`, `backgroundColor`, `fillStyle`, `strokeWidth`, `strokeStyle`, `roundness`, `roughness`, `opacity`; reconciliation/order `seed`, `version`, `versionNonce`, `index`, `updated`; lifecycle `isDeleted`, `locked`; relations `groupIds`, `frameId`, `boundElements`, `containerId`; extension `customData`. Elements keep **absolute scene coordinates** (frame membership does not offset children). Source: [scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema).
- **IDs** are opaque persisted strings (e.g. `"pologsyG-tAraPgiN9xP9b"`), generated by `randomId()` at creation; treat as stable identity, not a name. Source: [scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema).
- **Change tracking for collab:** `version` monotonically increments per change; `versionNonce` is a fresh random int per change used as the **tiebreaker for deterministic reconciliation** when two clients land the same `version`. `updated` is epoch-ms. This is a lightweight LWW-ish scheme, not a full CRDT. Source: [scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema), [discussion #2672](https://github.com/excalidraw/excalidraw/discussions/2672).
- **Z-order = `index` fractional string** ("either a fractional ordering string or null for newly created / not-yet-indexed elements") — same fractional-indexing idea as tldraw/Figma, enabling insert without renumbering siblings. Before `index` existed, pure array order was the z-order. Source: [scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema).
- **Grouping/parenting via references, not tree:** `groupIds` (array, ordered deepest→shallowest for nested groups), `frameId` (frame membership), `boundElements` (reverse refs to bound arrows/labels), `containerId` (a text element's parent container). Trade-off: flat array is trivial to iterate/diff and IDs never move, but "all descendants of this group" requires a scan/index over `groupIds`. Source: [Element Types (DeepWiki)](https://deepwiki.com/excalidraw/excalidraw/3.1-element-binding-and-geometry).

## Figma — tree of nodes over a property CRDT (internal model documented; file format closed)

- **Internal model is a tree, stored as a flat property map.** "Every Figma document is a tree of objects, similar to the HTML DOM," but physically stored as `Map<ObjectID, Map<Property, Value>>` — equivalently tuples `(ObjectID, Property, Value)`. So: **logically a tree, physically a flat two-level map** — the best of both for collab. Source: [How Figma's multiplayer technology works](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/).
- **IDs are composite + client-generated.** Each client gets a unique client ID, embedded into every object ID it creates, guaranteeing global uniqueness without a central allocator. Stable across the session/document. Source: [multiplayer blog](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/).
- **Parent + position stored atomically as one property.** The parent link is a property on the child (survives reparenting, preserves identity); child order is a **fractional index between 0 and 1**. Crucially, "parent and position must both be stored as a single property so they update atomically" — otherwise a concurrent move could orphan or duplicate a node. Source: [multiplayer blog](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/).
- **Conflict resolution = per-property last-writer-wins** (not OT, not a text-CRDT): the latest value any client sent for a given (object, property) wins. Source: [multiplayer blog](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/).
- **Fractional indexing deep-dive** (primary source, the canonical reference for this whole technique): indices are fractions in (0,1) exclusive; insert = average the two neighbors; stored as **strings with arbitrary precision** (not 64-bit doubles, which would exhaust precision after enough inserts); the leading `0.` is dropped and they use the full ASCII range (**base-95**) for compactness. Figma deliberately chose the simple algorithm over fancier CRDTs for implementability. Source: [Realtime Editing of Ordered Sequences](https://www.figma.com/blog/realtime-editing-of-ordered-sequences/) (Evan Wallace).
- **Node types (from the Plugin API)** — a large closed enum: `DOCUMENT`, `PAGE`, `FRAME`, `GROUP`, `SECTION`, `COMPONENT`, `COMPONENT_SET`, `INSTANCE`, `RECTANGLE`, `ELLIPSE`, `POLYGON`, `STAR`, `LINE`, `VECTOR`, `TEXT`, `TEXT_PATH`, `BOOLEAN_OPERATION`, `SLICE`, `STICKY`, `CONNECTOR`, `TABLE`/`TABLE_CELL`, `SLIDE`/`SLIDE_ROW`/`SLIDE_GRID`, `WIDGET`, etc. `DocumentNode` is the single root; its children are `PageNode`s; each page has a `children` array = layers. Source: [Node Types](https://www.figma.com/plugin-docs/api/nodes/), [DocumentNode](https://www.figma.com/plugin-docs/api/DocumentNode/).
- **The API deliberately hides fractional indexing.** `children` is a read-only array; you cannot splice it — you must call `appendChild`/`insertChild`, and "the reason … is because the internal representation for the layer tree uses fractional indexing and `insertChild` performs that conversion." `parent` is likewise read-only; reparent via `appendChild`. **Design lesson for an agent-facing API:** expose intent-level ops (`insertChild(node, i)`), not raw index strings. Source: [children](https://www.figma.com/plugin-docs/api/properties/nodes-children/), [parent](https://www.figma.com/plugin-docs/api/properties/nodes-parent/).
- **File format (`.fig`) is proprietary/closed** — a binary Kiwi (Evan Wallace's protobuf-like schema) blob, magic header `fig-kiwi`/`fig-jam.`/`fig-deck`, compressed (deflate/zstd). No official schema is published; the community reverse-engineers it (fig-kiwi npm, Grida's parser, Evan Wallace's own toy parser). **Verifiable via reverse-engineering, not documented.** Sources: [fig-kiwi npm](https://www.npmjs.com/package/fig-kiwi), [Kiwi format](https://github.com/evanw/kiwi), [Grida .fig parser](https://grida.co/tools/fig), [reverse-engineering write-up](https://albertsikkema.com/ai/development/tools/reverse-engineering/2026/01/23/reverse-engineering-figma-make-files.html).

## Penpot — hybrid: container tree of shapes, shape = augmented SVG node (open source)

- **Hierarchy:** `Project > File > (Page | Component)`; both Page and Component are unified under a `Container` abstraction, each holding a **tree of shapes** (`ShapeTree`): a top frame → top-level shapes; frames/groups may contain any non-frame shape. Source: [Penpot Data model](https://help.penpot.app/technical-guide/developer/data-model/).
- **A Shape corresponds to one SVG node** "augmented with Penpot special features." Each shape holds a **reference to its parent and to all its children** (bidirectional). In practice Penpot keeps an `objects` map (id→shape) per page plus the parent/children refs — a hybrid of flat-map storage and tree links, so the "actual representation slightly differs depending on environment (frontend app, backend RPC, SQL DB)." Source: [Penpot Data model](https://help.penpot.app/technical-guide/developer/data-model/).
- **Shape attributes:** `selrect` + geometry (`x`,`y`,`width`,`height`), `transform` (2D matrix for rotate/skew), `constraints` (responsive resize behavior), `fill`/`stroke`/`shadow`/`blur`, `font`/`content` (text), `interactions` (prototype behavior), `exports`. Source: [Penpot Data model](https://help.penpot.app/technical-guide/developer/data-model/), [Shape plugin type](https://penpot-plugins-api-doc.pages.dev/types/Shape).
- IDs are UUIDs (the model is Clojure maps keyed by shape uuid). Note: the doc is conceptual; field-level types are best read from source. Trade-off: SVG-node-per-shape gives a clean export/rendering story, but the augmentation means it's not pure SVG.

## Sketch — ZIP of nested JSON layer trees (open, published JSON Schema)

- **On-disk = ZIP archive of JSON** (since Sketch 43). Layout: `meta.json` (pages/artboards list, version, fonts), `document.json` (shared styles + links to page files), `user.json` (per-page viewport/zoom), `pages/<uuid>.json` (one file per page, the actual layer content), `images/`, `previews/`. Source: [Sketch file format](https://developer.sketch.com/file-format/).
- **Nested tree:** each page JSON is a recursive structure where container layers hold a `layers` array of child layers; **z-order = array order**. Source: [Sketch file format](https://developer.sketch.com/file-format/), [spec](https://developer.sketch.com/file-format/spec).
- **Identity:** every layer has a `do_objectID` (a **UUID**); the `_class` string is the type discriminator (`"rectangle"`, `"text"`, `"group"`, `"artboard"`, …). Custom data goes in a per-layer/document `userInfo` object. Source: [Sketch file format](https://developer.sketch.com/file-format/), [Data docs](https://www.sketch.com/docs/designing/data/).
- **Published, versioned JSON Schema** (Draft-07) + TypeScript types, split into reusable sub-schemas and combined at build; usable to validate/generate documents programmatically. This is the gold standard for "a documented, machine-checkable design IR." Source: [sketch-hq/sketch-file-format](https://github.com/sketch-hq/sketch-file-format), [npm @sketch-hq/sketch-file-format](https://www.npmjs.com/package/@sketch-hq/sketch-file-format). Trade-off: array-order z-order means reordering/reparenting is array splicing (harder to merge concurrently than fractional indices).

## Konva & Fabric.js — canvas scene-graph libraries (open source)

- **Konva: nested scene graph.** `Stage > Layer > Group > Shape`; each node inherits transforms from its parent (children coords are relative). `toJSON()` serializes to nested JSON of node attributes; hierarchy via `children` arrays, type via `className`, props via `attrs`. Caveat: `toObject()`/`toJSON()` lose class info and drop event handlers/images — you re-hydrate with `Node.create(json)` and type assertions. Source: [Konva Serialize a Stage](https://konvajs.org/docs/data_and_serialization/Serialize_a_Stage.html), [Konva best-canvas-library](https://konvajs.org/docs/guides/best-canvas-library.html).
- **Fabric.js: object model over canvas, richest serialization.** `canvas.toObject()`/`toJSON()` emit a serializable list of objects with props/transforms/filters; SVG import/export built in. Flatter than Konva (objects on a canvas rather than a deep transform tree). Source: [Fabric.js intro pt.3](https://fabricjs.com/docs/old-docs/fabric-intro-part-3/), [Fabric serialization](https://riptutorial.com/fabricjs/topic/8274/fabricjs-canvas-serialization). Trade-off: great round-trip fidelity, but serialization loses class identity → needs re-hydration logic.

## Lottie — nested animation JSON (open, published JSON Schema)

- Top-level `Animation` object → `assets` (precomps/images) + `layers[]`; compositions nest layers; everything is keyframe-animatable properties. Machine-readable JSON Schema published. It's uncompressed and can be bloated vs. binary formats. Source: [Lottie JSON Schema](https://lottiefiles.github.io/lottie-docs/schema/), [Lottie Specs schema](https://lottie.github.io/lottie-spec/1.0.1/specs/schema/). (Rive is the binary counterpart — compact but no open document schema; format is effectively proprietary. Source: [Rive as a Lottie alternative](https://rive.app/blog/rive-as-a-lottie-alternative).)

## Framer — tree IR expressly re-shaped for AI agents (directly on-point)

This is the most relevant source for your exact use case (agent authoring a document, can't see pixels):

- **Document = verbose tree, "a lot like HTML"** (Project Structure API exposes an XML/tree of pages/components). "Modifications to a design might require updating just a single property on hundreds of nodes at varying depths." Source: [Framer developers](https://www.framer.com/developers/plugins-introduction), [Building Framer agents](https://www.framer.com/blog/building-framer-agents/).
- **They chose canvas/tree over emitting code** because "a giant pile of code is hard to edit, hard to understand, and hard to own" — the agent edits structured nodes so humans can adjust/debug visually. Source: [Building Framer agents](https://www.framer.com/blog/building-framer-agents/).
- **Agents mutate via streamed patch commands** (deltas), not full-node rewrites — "every token spent is directly used, instead of 50% being spent expressing the 'replaced' values." For heavier/multi-file ops the agent "queries and updates the tree with snippets of JavaScript in the background."
- **They compressed the IR specifically for token cost:** shortened property names (`backgroundColor` → `bg`), dropped any value equal to its default, and invented "our own language to express the tree and its edits, stripping every character it can." Source: [Building Framer agents](https://www.framer.com/blog/building-framer-agents/).

---

## Cross-cutting: stable IDs

| Tool | ID scheme | Stable across edit/reload/collab? |
|---|---|---|
| tldraw | `shape:<uniqueId>` branded string, prefix per record type | Yes; assigned once, never changes |
| Excalidraw | opaque `randomId()` string | Yes; treat as identity not name |
| Figma | client-ID + counter composite, client-generated | Yes; unique without central allocator |
| Sketch | `do_objectID` UUID per layer | Yes |
| Penpot | UUID per shape | Yes |
| Konva/Fabric | optional `id` attr (you set it) | Only if you assign one |

**Takeaway for an agent-authored doc:** every tool that supports collab/programmatic editing assigns an **opaque, stable, unique id at creation** and never derives identity from position or name. Client-side generation (Figma's composite id, random ids) avoids a round-trip to a server for id allocation — important if the agent creates many nodes offline/batched.

## Cross-cutting: z-order / ordering

- **Fractional indexing (string keys)** is the dominant modern choice for collab + cheap reorder: Figma (base-95 arbitrary-precision), tldraw (`IndexKey`, jittered), Excalidraw (`index`). Insert-between and move are single-record writes; no sibling renumbering. Canonical references: [Figma: Realtime Editing of Ordered Sequences](https://www.figma.com/blog/realtime-editing-of-ordered-sequences/), [tldraw shape-indexing](https://tldraw.dev/sdk-features/shape-indexing), [David Greenspan: Implementing Fractional Indexing](https://observablehq.com/@dgreensp/implementing-fractional-indexing), [Steve Ruiz: Reordering with fractional indices](https://www.steveruiz.me/posts/reordering-fractional-indices).
- **Array position** is the simpler alternative (Sketch layers[], Konva children[], Lottie layers[], pre-index Excalidraw) — human-readable but concurrent reorders conflict and every insert shifts siblings.

## Pitfalls / trade-offs to weigh

1. **Nested tree vs flat map is the load-bearing decision.** Flat map + `parentId` (tldraw/Figma) makes reparent/reorder O(1) single-property writes and IDs positionally stable — ideal for an agent issuing surgical patches. Nested `children[]` (Sketch/Konva/Lottie) reads better as a file but turns "move node" into array splicing that's painful to merge and to address stably.
2. **Parent + order must be atomic.** Figma's explicit warning: store the parent link and the position as *one* property, or concurrent moves orphan/duplicate nodes. Applies to any batched/agent mutation, not just multiplayer. ([multiplayer blog](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/))
3. **Fractional index string growth + collisions.** Repeated inserts at the same spot grow index strings unboundedly and, without jitter, two writers mint identical keys — hence tldraw's jittered algorithm and occasional rebalancing. ([PR #6646](https://github.com/tldraw/tldraw/pull/6646))
4. **Schema migrations are unavoidable and easy to under-invest in.** tldraw makes up/down migrations mandatory per persisted-shape change; Sketch versions its JSON Schema. If your agent writes documents that outlive a schema version, budget for migrations from day one. ([StoreSchema](https://tldraw.dev/reference/store/StoreSchema))
5. **Serialization that loses type identity** (Konva/Fabric `toObject`) forces re-hydration guesswork — prefer an explicit `type`/`_class`/`typeName` discriminator on every record (tldraw, Excalidraw, Sketch all have one).
6. **Absolute vs relative coordinates.** Excalidraw keeps absolute scene coords even for framed elements; Konva/Figma inherit parent transforms. For an agent that can't see pixels, **absolute coords are easier to reason about** (no transform-stack math), at the cost of manual updates when a container moves.
7. **Token cost of verbose trees for agents** is real (Framer): prefer short/defaulted property names, omit defaults, and let the agent emit *patches/deltas* against stable ids rather than whole-node or whole-document rewrites.
8. **Proprietary vs verifiable:** Figma `.fig` (Kiwi binary) and Rive are closed — only reverse-engineered. **Sketch (JSON Schema), Lottie (JSON Schema), tldraw, Excalidraw, and Penpot are open and documented** and are your best primary references for designing an IR.

### Most useful primary sources to read next
- [tldraw TLShape.ts source](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts) + [shape-indexing](https://tldraw.dev/sdk-features/shape-indexing) — cleanest open flat-record model.
- [Excalidraw scene-content-schema](https://plus.excalidraw.com/docs/api/scene-content-schema) — minimal flat-array element model with field-level detail.
- [Figma: How multiplayer works](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/) + [Realtime Editing of Ordered Sequences](https://www.figma.com/blog/realtime-editing-of-ordered-sequences/) — the definitive tree-as-property-map + fractional-index design.
- [Sketch file format](https://developer.sketch.com/file-format/) + [sketch-hq/sketch-file-format JSON Schema](https://github.com/sketch-hq/sketch-file-format) — the model for a documented, validatable nested IR.
- [Framer: Building agents](https://www.framer.com/blog/building-framer-agents/) — the only source directly on "AI agent authors a design tree it can't see."
