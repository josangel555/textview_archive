# Agent a7c30306e8c25a253.output

## Prompt (first 300 chars)
Do FRESH web research (WebSearch + WebFetch of official docs, GitHub source, TypeScript type definitions) on the **tldraw** infinite-canvas library, focused on how a PROGRAM or AGENT (not a human with a mouse) would construct and edit documents. Do NOT rely on memory — fetch and cite real URLs.

Pri

## Final message

Research complete across all six dimensions with verified type/field/method names from tldraw.dev docs, the GitHub monorepo source, and package definitions. Report follows.

---

# tldraw — Programmatic / Agent Authoring Model

Scope note: findings reflect tldraw SDK **main branch (v3/v4/v5-era, mid-2026)**. Where a name changed across versions I flag it. All non-obvious claims cite a URL. `[UNVERIFIED]` marks anything I could not confirm from a primary source this session.

---

## 1. Document / Data model — flat records in a reactive store

**It's a flat list of records, not a tree.** The store (`@tldraw/store`, class `Store`) is a reactive in-memory key-value database keyed by branded record IDs. Every entity — shapes, pages, bindings, assets, the document, the per-user instance/camera state — is a `TLRecord` (a `UnknownRecord`-shaped object). Tree structure (parenting) is expressed *only* by a `parentId` field on records, not by nesting. ([Store reference](https://tldraw.dev/reference/store/Store), [@tldraw/store npm](https://www.npmjs.com/package/@tldraw/store))

**`TLBaseShape`** — the shape record shape, verbatim from [`packages/tlschema/src/shapes/TLBaseShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/shapes/TLBaseShape.ts):

```typescript
export interface TLBaseShape<Type extends string, Props extends object> {
	readonly id: TLShapeId
	readonly typeName: 'shape'
	type: Type
	x: number
	y: number
	rotation: number
	index: IndexKey
	parentId: TLParentId
	isLocked: boolean
	opacity: TLOpacityType
	props: Props
	meta: JsonObject
}
```

- `typeName: 'shape'` is the **record-kind discriminator** (records also have `typeName: 'page' | 'binding' | 'asset' | 'document' | 'instance' | ...`). `type` is the **shape-kind** discriminator (`'geo'`, `'text'`, `'arrow'`, `'frame'`, `'draw'`, `'image'`, …).
- **`props` vs `meta`:** `props` are schema-validated, migratable, shape-type-specific fields; `meta` is a free-form `JsonObject` escape hatch for your own data (not validated, but still persisted/migratable). ([tlschema README](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/README.md))

**ID scheme** — from [`TLShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts) and [createShapeId reference](https://tldraw.dev/reference/tlschema/createShapeId):
- `type TLShapeId = RecordId<TLShape>` — a **branded string** with prefix `"shape:"` (e.g. `"shape:abc123"`).
- `type TLParentId = TLPageId | TLShapeId` — parent is either a page (`"page:..."`) or another shape (`"shape:..."`).
- `createShapeId(customId?)` generates the ID: returns `"shape:" + <customId or a generated uniqueId>`. Passing your own suffix gives **stable, deterministic IDs** — key for agents (`createShapeId('my-node-1')` → `"shape:my-node-1"`). Exported from `@tldraw/tlschema` and re-exported from `tldraw`. There's a matching `createBindingId` / `createPageId`.

**Concrete geo record** (assembled from the [Editor docs](https://tldraw.dev/docs/editor) `createShapes` example + `TLBaseShape` defaults). A stored `geo` rectangle looks like:

```jsonc
{
  "id": "shape:abc123",
  "typeName": "shape",
  "type": "geo",
  "x": 0, "y": 0,
  "rotation": 0,
  "index": "a1",
  "parentId": "page:page1",
  "isLocked": false,
  "opacity": 1,
  "props": {
    "geo": "rectangle",
    "w": 100, "h": 100,
    "color": "blue", "fill": "none", "dash": "draw",
    "size": "m", "font": "draw",
    "align": "middle", "verticalAlign": "middle",
    "growY": 0, "scale": 1, "labelColor": "black",
    "url": "",
    "richText": { /* rich text doc */ }
  },
  "meta": {}
}
```

`geoShapeProps` field list + `GeoShapeGeoStyle` enum from [`TLGeoShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/shapes/TLGeoShape.ts): geo styles are `rectangle, ellipse, triangle, diamond, pentagon, hexagon, octagon, star, rhombus, rhombus-2, oval, trapezoid, cloud, arrow-right/left/up/down, x-box, check-box, heart`.

> **Flag for agents:** in current `main`, the geo/text label is **`richText`** (a ProseMirror-style rich-text doc via `richTextValidator`), **not** a plain `text: string`. Older tldraw (v2.x) used `props.text`; it was migrated to `richText` (~v3). If you author `props.text` against a current SDK it will be dropped/invalid. This is the single most likely programmatic-authoring footgun. `[Version-sensitive]`

---

## 2. Layout representation — absolute coords + fractional index; no auto-layout

- **Coordinates:** `x`, `y` are the shape's top-left in **its parent's coordinate space** (page space if parented to a page; frame-local space if parented to a frame). `rotation` is radians. There is no width/height on the base — size lives in `props` (e.g. geo's `w`/`h`), varying by shape type.
- **Parenting:** `parentId` points at a page (`page:...`) or a container shape. **Frames** (`TLFrameShape`) and **groups** (`TLGroupShape`) are just shapes that other shapes set as their `parentId`; a frame additionally clips. There is no separate "children" array — the parent/child relation is derived by scanning records for matching `parentId`.
- **Z-order — fractional indexing.** `index: IndexKey` is a lexicographically-sortable base-62 string (`'a1'`, `'a2'`, `'a1V'` …). Higher sorts in front; **indices are sibling-relative within the same parent**. Reordering = pick a new string between neighbors, so no bulk renumber and it's collab-safe. Helpers in `@tldraw/utils`: `getIndexAbove`, `getIndexBelow`, `getIndexBetween`, `getIndicesAbove/Below/Between`, `sortByIndex`, `validateIndexKey`. `IndexKey` is branded — you can't pass an arbitrary string. ([Shape indexing docs](https://tldraw.dev/sdk-features/shape-indexing))
- **Bindings** (`@tldraw/tlschema`, [`TLBaseBinding.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/bindings/TLBaseBinding.ts)) — a **separate record type**, not a shape field:

```typescript
export interface TLBaseBinding<Type extends string, Props extends object> {
	readonly id: TLBindingId
	readonly typeName: 'binding'
	type: Type
	fromId: TLShapeId
	toId: TLShapeId
	props: Props
	meta: JsonObject
}
```

  The built-in `arrow` binding ([`TLArrowBinding.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/bindings/TLArrowBinding.ts)) is `TLBaseBinding<'arrow', TLArrowBindingProps>` with props `{ terminal: 'start'|'end', normalizedAnchor: VecModel (0–1 relative point on target), isExact: boolean, isPrecise: boolean, snap: 'center'|'edge-point'|'edge'|'none' }`. So an arrow that connects two boxes is: one arrow **shape** + up to two **binding** records (`fromId` = arrow, `toId` = target box, one per terminal). Authoring a connected diagram means emitting both. Managed via `BindingUtil`, `createBindingId`, `editor.createBindings`.
- **Auto-layout:** **None built in.** tldraw is absolute-position. Any tree/graph/flow layout must be computed by you (positions + indices), then written. (Layout-via-bindings is a demonstrated *pattern*, not a feature — see the [Layout constraints example](https://tldraw.dev/examples/layout-bindings), which wires a custom binding to reposition children.)

---

## 3. Mutation API — Editor high-level + Store low-level; reactive; mark-based history

Two tiers:

**Editor tier** (validates, fills defaults, runs side effects, participates in history) — [Editor docs](https://tldraw.dev/docs/editor):
- `editor.createShape(partial)` / `editor.createShapes(partials[])` — take `TLShapePartial` (only `type` required; `id` auto-created via `createShapeId` if omitted; missing props filled from the `ShapeUtil`'s `getDefaultProps()`).
- `editor.updateShape(partial)` / `editor.updateShapes(partials[])` — partial where `id` + `type` required, everything else optional.
- `editor.deleteShape(id)` / `editor.deleteShapes(ids|shapes)`.
- `editor.createBindings(...)`, plus ordering helpers `sendToBack`, `bringToFront`, etc.

**Batching / transactions:** `editor.run(fn, opts?)` batches all mutations into one transaction. Options: `{ history: 'ignore' }` (mutations don't touch undo/redo — the standard way an agent makes changes it doesn't want the user to be able to undo into) and `{ ignoreShapeLock: true }`. ([Editor docs](https://tldraw.dev/docs/editor), [designdebt.club writeup](https://designdebt.club/programmatic-changes-in-tldraw-without-affecting-undo-redo-stack/))

```ts
editor.run(() => {
  editor.createShapes(myShapes)
  editor.sendToBack(myShapes)
  editor.selectNone()
}, { history: 'ignore' })
```

**Undo/redo — mark-based, not per-op** ([History docs](https://tldraw.dev/sdk-features/history)):
- `editor.markHistoryStoppingPoint()` → returns a mark id; sets an undo stopping point and **clears the redo stack**.
- `editor.undo()`, `editor.redo()`.
- `editor.bailToMark(id)` — revert to a mark, discarding those changes (not redoable).
- `editor.squashToMark(id)` — collapse everything since a mark into one undo step.

**Store tier** (raw, no validation-of-partials, no defaults, low-level) — [Store reference](https://tldraw.dev/reference/store/Store):
- `store.put(records[])`, `store.remove(ids[])`, `store.get(id)`, `store.has(id)`, `store.update(id, updater)`, `store.allRecords()`, `store.clear()`, `store.applyDiff(RecordsDiff)`.
- **Records go in fully-formed** at this tier (no default-filling like `createShapes`), and are validated against the schema on `put`.

**Reactivity — yes, signals-based.** Built on `@tldraw/state` (the open-sourced *Signia* library): `atom` (mutable), `computed` (derived, lazy), `react` (effect); React bindings `useValue`/`useAtom`/`useComputed` in `@tldraw/state-react`. The store itself is reactive — every record/query is an atom/computed. Subscribe programmatically with `store.listen(onHistory, filters?)` (returns an unsubscribe fn; filters by `source: 'user'|'remote'` and `scope`), and collab-merge via `store.mergeRemoteChanges(fn)`. ([@tldraw/state](https://www.npmjs.com/package/@tldraw/state), [Signals docs](https://tldraw.dev/sdk-features/signals), [Store reference](https://tldraw.dev/reference/store/Store))

---

## 4. Persistence — JSON snapshots (store map + schema), `.tldr` = wrapped JSON, auto-migrate on load

**Snapshot API** ([Persistence docs](https://tldraw.dev/docs/persistence), [SDK persistence](https://tldraw.dev/sdk-features/persistence)):
- `getSnapshot(editor.store)` → `TLEditorSnapshot` = `{ document, session }`:
  - `document` — shapes, pages, bindings, assets (the shareable/serverside part).
  - `session` — camera, current page, selection, UI state (per-user, keep local).
- `loadSnapshot(editor.store, { document, session? })` — restores; **migrates automatically** if the snapshot's schema is older.
- Store-level: `store.getStoreSnapshot(scope?)` → `StoreSnapshot<R>` = `{ store: SerializedStore, schema: SerializedSchema }`; `store.loadStoreSnapshot(snapshot)`; `store.serialize(scope)` → `SerializedStore` (bare record map, no schema); `store.migrateSnapshot(snapshot)`.

**`.tldr` file format** — [`packages/tldraw/src/lib/utils/tldr/file.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/utils/tldr/file.ts):

```typescript
export interface TldrawFile {
  tldrawFileFormatVersion: number   // LATEST_TLDRAW_FILE_FORMAT_VERSION = 1
  schema: SerializedSchema
  records: UnknownRecord[]
}
```

- MIME `application/vnd.tldraw+json`, extension `.tldr` — it's **just JSON**: the flat `records` array + the serialized `schema`.
- `serializeTldrawJson()` / `serializeTldrawJsonBlob()` to write; `parseTldrawJsonFile({schema, json})` → `Result<TLStore, TldrawFileParseError>` to read. Parse errors are a discriminated union: `v1File`, `notATldrawFile`, `fileFormatVersionTooNew`, `migrationFailed`, `invalidRecords`.

**Schema versioning + migrations** ([SDK persistence](https://tldraw.dev/sdk-features/persistence)):
- `SerializedSchema` carries version info. **V2 schema** = `{ schemaVersion: 2, sequences: Record<string, positiveInteger> }` (sequence-id → version). Older **V1** = `{ schemaVersion: 1, storeVersion, recordVersions }`.
- Migrations run **automatically on load** (`loadSnapshot`/`parseTldrawJsonFile`), walking each migration sequence to current.
- Author custom-shape migrations with `createShapePropsMigrationIds`, `createShapePropsMigrationSequence` (each step has `up()`/`down()`); general data uses `createMigrationIds` / `createMigrationSequence`. Scopes: `record` and `store`. Sequences are passed to `createTLStore()` / the `<Tldraw>` component. The whole schema is assembled by `createTLSchema` / `StoreSchema`. ([createTLSchema](https://tldraw.dev/reference/tlschema/createTLSchema))

**Round-trip:** yes — a full scene serializes to a single JSON blob (`records` + `schema`) and restores losslessly, including forward-migration of old files.

---

## 5. Rendering — React + HTML/DOM (not canvas, not primarily SVG), retained

- Each shape kind has a **`ShapeUtil`** subclass ([Shapes docs](https://tldraw.dev/docs/shapes)). Key members: `getDefaultProps()`, `getGeometry(shape)` (returns geometry primitives like `Rectangle2d` for hit-testing/bounds), **`component(shape)`** (the React render), and `indicator(shape)` / `getIndicatorPath` (selection outline).
- **`component()` returns React JSX wrapped in `<HTMLContainer>`** — shapes are **DOM elements** positioned on an infinite-canvas transform, **not** drawn to a `<canvas>`. It's **retained-mode**: shapes persist as reactive React components that re-render on signal change, rather than being repainted each frame.

```jsx
component(shape) {
  return <HTMLContainer>Hello</HTMLContainer>
}
```

- SVG is used *within* shapes where appropriate (e.g. draw/geo strokes) and for **export** (SVG/PNG), but the compositing model is DOM/CSS-transform, not a canvas scene graph. ([Shapes docs](https://tldraw.dev/docs/shapes))

Implication for agents: the visual only exists when an `Editor` is mounted in a browser DOM. Headless (Node) work manipulates the **store/records**, which is fully decoupled from rendering.

---

## 6. Programmatic-authoring friction — mostly LOW, a few real HIGH edges

**LOW friction (favorable):**
- **Stable, deterministic IDs** via `createShapeId('my-id')` — reference shapes across create/update/bind without a round-trip. Ideal for agents building a scene incrementally.
- **Flat records, no nesting** — the whole scene is a `records[]` array you can generate, diff, and patch positionally. Parent/child and connections are plain ID references (`parentId`, binding `fromId`/`toId`), not nested structure.
- **Full JSON round-trip** — author or emit a `TldrawFile` / snapshot as pure JSON offline; load it later; it forward-migrates.
- **Headless store** — `createTLStore({ shapeUtils, bindingUtils, schema, initialData })` gives a working, validated, reactive store **with no DOM and no Editor** ([createTLStore](https://tldraw.dev/reference/editor/createTLStore)). You can `put`/`remove`/`serialize`/`loadStoreSnapshot`/`listen` server-side (Node) — the docs explicitly support server/collab usage (`TLSocketRoom`). This is the recommended path for pure data generation.
- **Batching + `{history:'ignore'}`** — agent edits can be applied atomically and kept out of the user's undo stack.
- **Validation is real and typed** — props are validated at runtime by `@tldraw/validate` (`T.*` validators like `T.nonZeroNumber`, `T.literalEnum(...)`, `T.linkUrl`) declared as `RecordProps<...>`. Bad records are rejected on `put`/load, so malformed agent output fails loudly rather than corrupting silently.

**HIGH / watch-out friction:**
1. **Two write tiers with different contracts.** `editor.createShapes` fills defaults from `getDefaultProps()` and accepts *partials*; `store.put` does **not** — it needs a **complete, valid record** (every base field incl. a valid `IndexKey` `index` and `parentId`, plus all `props`). Hand-building full records for `store.put` is where agents most often produce invalid data. Prefer `createShapes` when an Editor exists.
2. **`index` is mandatory and branded.** You can't invent `"1"`, `"2"`. You must produce valid `IndexKey`s (`getIndexAbove` / `getIndexBetween`) or `validateIndexKey` rejects them. Sibling-relative ordering adds bookkeeping when generating many shapes.
3. **Connections are multi-record.** A bound arrow = 1 arrow shape + up to 2 binding records with correct `terminal`/`normalizedAnchor`. Miss a binding and the arrow renders unattached. More moving parts than a single "edge" object.
4. **Version-sensitive props schema.** The `text` → `richText` change (dim. 1) means an agent must target the SDK version actually in use; there's no lenient string fallback in current `main`. Authoring rich text requires the ProseMirror-style doc structure, which is heavier than a plain string.
5. **Migrations on load are automatic but one-directional in practice.** Loading a *newer*-schema file into an *older* SDK fails (`fileFormatVersionTooNew`). Agents emitting `.tldr` should pin/emit against a known schema.
6. **Rendering requires a browser Editor.** `[Partially UNVERIFIED]` — the *store* is confirmed headless; I did not fully verify whether an `Editor` instance can be constructed with no DOM at all (historically the `Editor`/`TldrawEditor` expects a container/DOM environment). Best guess: **for pure data authoring use `createTLStore` headless; reserve the `Editor` for when you need layout math / geometry / measured bounds**, which the store alone doesn't compute. Confirm against your target version if you need Editor-in-Node.

---

## Key sources

- Shape record: [`TLBaseShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/shapes/TLBaseShape.ts) · [`TLShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/records/TLShape.ts) · [`TLGeoShape.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/shapes/TLGeoShape.ts)
- Bindings: [`TLBaseBinding.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/bindings/TLBaseBinding.ts) · [`TLArrowBinding.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tlschema/src/bindings/TLArrowBinding.ts)
- Store/mutation: [Store reference](https://tldraw.dev/reference/store/Store) · [Editor docs](https://tldraw.dev/docs/editor) · [createTLStore](https://tldraw.dev/reference/editor/createTLStore) · [History docs](https://tldraw.dev/sdk-features/history)
- Reactivity: [@tldraw/state](https://www.npmjs.com/package/@tldraw/state) · [Signals docs](https://tldraw.dev/sdk-features/signals)
- Persistence: [Persistence docs](https://tldraw.dev/docs/persistence) · [SDK persistence](https://tldraw.dev/sdk-features/persistence) · [`.tldr file.ts`](https://github.com/tldraw/tldraw/blob/main/packages/tldraw/src/lib/utils/tldr/file.ts)
- Indexing / IDs: [Shape indexing](https://tldraw.dev/sdk-features/shape-indexing) · [createShapeId](https://tldraw.dev/reference/tlschema/createShapeId)
- Rendering: [Shapes docs](https://tldraw.dev/docs/shapes)
