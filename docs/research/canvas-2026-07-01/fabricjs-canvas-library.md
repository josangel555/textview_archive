# Agent a3104db6697c96211.output

## Prompt (first 300 chars)
Do FRESH web research (WebSearch + WebFetch of official docs, GitHub source, API docs) on the **Fabric.js** canvas library (current v6), focused on how a PROGRAM or AGENT (not a human with a mouse) would construct and edit documents. Do NOT rely on memory — fetch and cite real URLs.

Primary sources

## Final message

I have verified everything across the 6 dimensions from primary sources (official docs + raw GitHub v6 source). Here is the report.

---

# Fabric.js v6 — Programmatic / Agent Authoring Reference

Scope note: v6 is a full TypeScript rewrite with ES named exports (`import { Canvas, Rect } from 'fabric'`) and Promise-based async APIs. Classes were renamed to avoid JS keyword collisions: `fabric.Object` → `FabricObject`, `fabric.Text` → `FabricText`, `fabric.Image` → `FabricImage`. If you carried `@types/fabric`, remove it — types now ship in-package. Source: [Upgrading to Fabric 6.0](https://fabricjs.com/docs/upgrading/upgrading-to-fabric-60/).

---

## 1. Document / Data Model

**Retained-mode scene graph, flat array.** The `Canvas`/`StaticCanvas` holds an ordered array of objects accessed via `canvas.getObjects()` (returns `FabricObject[]`), plus `canvas.item(index)` for index access. `Canvas` (interactive) extends `StaticCanvas` (headless/render-only). Ref: [Canvas API](https://fabricjs.com/api/classes/canvas/), [StaticCanvas API](https://fabricjs.com/api/classes/staticcanvas/).

**Class hierarchy.** `BaseFabricObject` → `FabricObject` (base) → concrete shapes: `Rect`, `Circle`, `Ellipse`, `Triangle`, `Line`, `Polygon`, `Polyline`, `Path`, `FabricText`, `IText`, `Textbox`, `FabricImage`, `Group`, `ActiveSelection`. Refs: [FabricObject API](https://fabricjs.com/api/classes/fabricobject/), [BaseFabricObject API](https://fabricjs.com/api/classes/basefabricobject/).

**Base properties + verified defaults** (from [FabricObject API](https://fabricjs.com/api/classes/fabricobject/) and `src/shapes/Object/Object.ts`):

| Property | Type | Default |
|---|---|---|
| `type` | string | class-derived (e.g. `"rect"`) |
| `left` / `top` | number | 0 |
| `width` / `height` | number | 0 |
| `angle` | TDegree | 0 |
| `scaleX` / `scaleY` | number | 1 |
| `fill` | string \| TFiller \| null | `rgb(0,0,0)` |
| `stroke` | string \| TFiller \| null | null |
| `strokeWidth` | number | 1 |
| `opacity` | number | 1 |
| `originX` / `originY` | TOriginX/Y | `'left'` / `'top'` |
| `flipX` / `flipY` | boolean | false |
| `skewX` / `skewY` | number | 0 |
| `visible` | boolean | true |
| `selectable` | boolean | true |
| `objectCaching` | boolean | true |
| `dirty` | boolean | true |

The `type` field in serialization is `(this.constructor as typeof FabricObject).type` — a class-static string, not per-instance (verified in `toObject`, `src/shapes/Object/Object.ts`).

**ID scheme — NO built-in id.** This is the single most important fact for programmatic authoring. Objects have no identity field by default; the docs state it explicitly and recommend against treating objects as data stores. Ref: [Objects and custom properties](https://fabricjs.com/docs/using-custom-properties/). You opt in via the static `customProperties` array (see §4):

```typescript
static customProperties: string[] = [];   // src/shapes/Object/Object.ts (default empty)
```

**Concrete object config** (constructor takes an options bag; custom props can be passed too):

```typescript
import { Rect, FabricObject } from 'fabric';
FabricObject.customProperties = ['id', 'name'];   // register once, globally

const rect = new Rect({
  left: 100, top: 80, width: 200, height: 120,
  fill: '#3b82f6', stroke: '#1e40af', strokeWidth: 2,
  angle: 15, scaleX: 1, scaleY: 1,
  originX: 'left', originY: 'top', opacity: 0.9,
  id: 'node-42', name: 'title-box',   // custom, only survives because registered
});
canvas.add(rect);
```

---

## 2. Layout Representation

**Absolute positioning, no auto-layout at the object level.** Each object carries absolute `left`/`top` in canvas coordinates, anchored by `originX`/`originY` (`'left'|'center'|'right'` and `'top'|'center'|'bottom'`) — origin changes where left/top *mean*, so an agent moving an object must account for the anchor. Transform is `angle` (degrees) + `scaleX`/`scaleY` + `skewX`/`skewY` + `flipX`/`flipY`.

**Groups nest with relative coordinates.** Inside a `Group`, children store `left`/`top` relative to the group's local coordinate system, not the canvas. Absolute canvas position is the composition of transforms up the parent chain — use `object.calcTransformMatrix()` / `getTotalObjectScaling()` to resolve. Ref: [Group API](https://fabricjs.com/api/classes/group/). Groups have a `layoutManager` (the v6 `LayoutManager`/`FitContentLayout` system) that governs how the group's bbox tracks children — this is the closest thing to "layout," but it is group-bbox management, not flexbox-style child layout. `subTargetCheck: true` (+ historically `interactive`) enables hit-testing into children.

**Stacking order = array index.** Z-order is literally the position in the objects array (index 0 = bottom). In v6 the stacking API moved from the object onto the owning `Collection` (Canvas or Group) and was renamed to disambiguate which stack you mean:

- `canvas.bringObjectForward(obj)`, `canvas.sendObjectBackwards(obj)`
- `canvas.bringObjectToFront(obj)`, `canvas.sendObjectToBack(obj)`
- `canvas.moveObjectTo(obj, index)`

The old instance methods (`obj.bringForward()`, `obj.sendToBack()`, `obj.moveTo(n)`) were **removed** from `FabricObject` — v6 stopped guessing which stack to operate on. Stack operations on an active multi-selection are also gone. Ref: [Breaking changes for fabric 6.0 (#8299)](https://github.com/fabricjs/fabric.js/issues/8299).

---

## 3. Mutation API

**Create / attach / detach:**
- `new fabric.Rect({...})` etc. (or `new Rect({...})` with named imports)
- `canvas.add(obj, ...)`, `canvas.insertAt(index, obj)`, `canvas.remove(obj, ...)`, `canvas.clear()`

**Mutate:** `obj.set({ fill: 'red', left: 20 })` (or `obj.set(key, value)`), `obj.get(key)`. Note: **method chaining was removed** in v6 — `obj.set({...}).rotate(90)` no longer returns `this`; issue calls separately. Ref: [Upgrading to Fabric 6.0](https://fabricjs.com/docs/upgrading/upgrading-to-fabric-60/).

**Recompute + repaint:**
- `obj.setCoords()` — recomputes the object's corner/control coords; call after programmatic transforms if you rely on hit-testing/bounds before the next render.
- `canvas.renderAll()` — synchronous immediate repaint.
- `canvas.requestRenderAll()` — coalesced repaint on next animation frame (preferred for batches). Verified in `src/canvas/StaticCanvas.ts`:
  ```typescript
  requestRenderAll() {
    if (!this.nextRenderHandle && !this.disposed && !this.destroyed) {
      this.nextRenderHandle = requestAnimFrame(() => this.renderAndReset());
    }
  }
  ```

**Observability — events.** `canvas.on(eventName, handler)`, `off`, and objects also fire (`obj.on(...)`, `obj.fire(...)`). Event families (typed via the `CanvasEvents` interface — [CanvasEvents API](https://fabricjs.com/api/interfaces/canvasevents/)):
- Object lifecycle/transform: `object:added`, `object:removed`, `object:modified` (fires once at end of an interaction), `object:moving`/`object:scaling`/`object:rotating`/`object:skewing` (fire continuously during interaction).
- Selection: `selection:created`, `selection:updated`, `selection:cleared`.
- Mouse: `mouse:down`, `mouse:up`, `mouse:move`, `mouse:over`, `mouse:out`, `mouse:dblclick`, etc.

Handler shape: `canvas.on('object:modified', (e) => { const obj = e.target; })`. Ref: [Working with events](https://fabricjs.com/docs/events/). Caveat for agents: **transforms you apply programmatically via `set()` do NOT fire `object:modified`** — those events are driven by the interaction pipeline, not by `set()`. If your history/observability hangs off events, programmatic edits are invisible to it.

**Undo — NOT built in.** There is no undo/redo stack in core. The standard pattern is DIY: snapshot `canvas.toJSON()` (or per-object `toObject()`) onto a stack and `loadFromJSON()` to restore, or use a community history plugin. (No official history API in the v6 docs/source.) *Flagged as verified-absent rather than a cited feature.*

---

## 4. Persistence

**Serialization.**
- `obj.toObject(propertiesToInclude?)` → plain object. `obj.toJSON()` just delegates to `toObject()` (verified: `toJSON() { return this.toObject(); }`).
- `canvas.toObject(propertiesToInclude?)` / `canvas.toJSON()` → `{ version, objects: [...], background, ... }`.
- `canvas.toDatalessJSON()` — replaces heavy `Path` data with an SVG `sourcePath` link (smaller payloads).
- `canvas.toSVG()` / `obj.toSVG()` — SVG export. `canvas.toDataURL()` — raster export.

**Custom props survive only if registered.** Two mechanisms, both verified in `src/shapes/Object/Object.ts`:

```typescript
// toObject merges caller-passed props + class-static customProperties:
const propertiesToSerialize = propertiesToInclude.concat(
  FabricObject.customProperties,
  (this.constructor as typeof FabricObject).customProperties || [],
);
// ... returned object spreads them:
const object = { ...pick(this, propertiesToSerialize), type, version: VERSION, ... };
```

So either pass ad-hoc `obj.toObject(['id','name'])`, or (better for round-trips) set the static once: `FabricObject.customProperties = ['id','name']`. For TS you must also augment the interfaces so the props type-check and are recognized on the serialized side:

```typescript
declare module "fabric" {
  interface FabricObject { id?: string; name?: string; }
  interface SerializedObjectProps { id?: string; name?: string; }
}
FabricObject.customProperties = ['name', 'id'];
```

Subclass override pattern (verified in docs):
```typescript
export class PathPlus extends Path {
  declare id?: string;
  toObject(propertiesToInclude = []) {
    return super.toObject([...propertiesToInclude, 'id', 'name']);
  }
}
```
Refs: [Objects and custom properties](https://fabricjs.com/docs/using-custom-properties/), [Discussion #10176](https://github.com/fabricjs/fabric.js/discussions/10176).

**Version field — present, no migrations.** Both the canvas-level and every object-level `toObject` stamp `version: VERSION` (verified in `src/canvas/StaticCanvas.ts` and `src/shapes/Object/Object.ts`; `VERSION` is imported from `src/constants.ts` — best guess: equals the package.json version string). It is a provenance stamp only — I found **no migration/upgrade logic keyed on it** in the deserialize path; `loadFromJSON` does not transform old schemas. Treat cross-version JSON as best-effort. *Flagged: absence-of-migrations is a verified-negative from source reading, not a documented guarantee.*

**Deserialization is async and reconstructs real instances.** Verified signature (`src/canvas/StaticCanvas.ts`):
```typescript
loadFromJSON(
  json: string | Record<string, any>,
  reviver?: EnlivenObjectOptions['reviver'],
  { signal }: Abortable = {},
): Promise<this>
```
It returns a `Promise<this>` (v6 dropped the old callback form) and internally uses `enlivenObjects` to turn each serialized `{type, ...}` blob back into a live class instance. This is the "enlivening" step — the JSON is data, but after load you get real `Rect`/`Group`/`FabricImage` objects with methods.

**Default-value stripping affects round-trip fidelity.** `toObject` ends with:
```typescript
return this.includeDefaultValues ? object : this._removeDefaultValues(object);
```
By default `includeDefaultValues` is true, so full objects are emitted; but if an object/canvas has `includeDefaultValues = false`, properties equal to defaults are dropped from JSON (smaller, but the JSON no longer literally lists every field). Numeric fields are also rounded to `config.NUM_FRACTION_DIGITS` via `toFixed` — a lossy round-trip on sub-pixel precision. Both verified in `src/shapes/Object/Object.ts`.

---

## 5. Rendering

**HTML5 Canvas 2D, retained-mode over immediate-mode.** Fabric keeps a persistent object model (the array) and paints it onto an immediate-mode `<canvas>` 2D context on each `renderAll`. Verified render path:
```typescript
renderAll() {
  this.cancelRequestedRender();
  if (this.destroyed) return;
  this.renderCanvas(this.getContext(), this._objects);
}
```

**Two canvas elements (interactive `Canvas` only).** The interactive `Canvas` maintains a **lower** canvas (committed objects) and an **upper** canvas (interaction layer: selection box, controls, hover). `StaticCanvas` has only the lower canvas — which is what you want for headless/agent authoring and server-side rendering (Node via `import { ... } from 'fabric/node'`), no interaction overhead.

**Dirty flags + per-object caching.** `objectCaching` defaults `true`: each object renders to its own offscreen cache canvas and is blitted unless `dirty` is set. `dirty` defaults `true` (first render) and is re-flagged when cacheable state changes, forcing a re-cache. For agents doing bulk `set()` mutations, this means many objects can go dirty; batch with `requestRenderAll()` to collapse to one frame. Refs: [FabricObject API](https://fabricjs.com/api/classes/fabricobject/) (objectCaching/dirty), source `StaticCanvas.ts`.

---

## 6. Programmatic-Authoring Friction

Concrete assessment for a program/agent constructing and editing documents:

**LOW friction (good for agents):**
- **`StaticCanvas` is headless-friendly** and Node has a first-class entry (`fabric/node`) — you can author/serialize/render without interactive plumbing.
- **Clean options-bag constructors + `set()`** map naturally to declarative generation; you build the whole scene as data and `add()` it.
- **Full serialize/deserialize** (`toObject`/`toJSON` ↔ `loadFromJSON`) with `Promise`-based async that composes with `await`.
- **Typed everything** (v6 TS) — `CanvasEvents`, `SerializedObjectProps`, etc. give an agent a real contract to target.

**HIGH friction (the traps):**
1. **No stable identity by default.** You *must* opt in (`FabricObject.customProperties = ['id']` + TS interface augmentation) or objects are anonymous and un-referenceable across a round-trip. An agent that assigns ids but forgets to register them will silently lose them on `toJSON`. Refs: [custom-properties docs](https://fabricjs.com/docs/using-custom-properties/), [#10176](https://github.com/fabricjs/fabric.js/discussions/10176).
2. **`loadFromJSON` is async and rebuilds real instances** — you cannot treat the JSON as a live document; you must `await` enlivening before querying/mutating. Any code that reads `canvas.getObjects()` synchronously after a load gets an empty/partial scene.
3. **Custom props need explicit `propertiesToInclude`/`customProperties`** — persistence is opt-in, per the merge logic in `toObject`. Easy to lose app metadata.
4. **A DOM `<canvas>` is required.** Even `StaticCanvas` needs a canvas element/context (browser, or a canvas polyfill under `fabric/node`) — you can't operate purely on plain data with zero environment.
5. **No undo, no migrations.** History is DIY (snapshot/restore); cross-version JSON has no automatic upgrade path (`version` is a stamp, not a migration key) — verified-absent in source.
6. **Round-trip is not bit-exact.** Numbers are `toFixed`-rounded to `NUM_FRACTION_DIGITS`, and `includeDefaultValues=false` strips default-valued fields — so serialized JSON may omit properties and lose sub-pixel precision. Verified in `Object.ts` (`toFixedBound`, `_removeDefaultValues`).
7. **Image (and filter) reload on deserialize is async and network-bound.** `FabricImage.fromObject` re-fetches the source and re-enlivens filters (verified `src/shapes/Image.ts`):
   ```typescript
   return Promise.all([
     loadImage(src!, { ...options, crossOrigin }),
     f && enlivenObjects(f, options),
     rf ? enlivenObjects([rf], options) : [],
     enlivenObjectEnlivables(object, options),
   ]).then(([el, filters = [], [resizeFilter], hydratedProps = {}]) => new this(el, {...}));
   ```
   `toObject` stores `src: this.getSrc()` + `crossOrigin` + serialized `filters` — so a document with images will hit the network on every load, can fail on CORS/`crossOrigin`, and is not self-contained unless you embed data-URIs.
8. **Programmatic `set()` doesn't emit interaction events** (`object:modified` etc. are interaction-driven) — event-based history/observability won't see agent edits without manual `canvas.fire(...)`.
9. **Stacking API moved to the collection** — code written against v5 `obj.bringForward()` breaks; z-order edits must go through `canvas.bringObjectForward(obj)` / `moveObjectTo(obj, i)`.

---

## Sources

- [Objects and custom properties (docs)](https://fabricjs.com/docs/using-custom-properties/)
- [Upgrading to Fabric.js 6.0 (docs)](https://fabricjs.com/docs/upgrading/upgrading-to-fabric-60/)
- [FabricObject API](https://fabricjs.com/api/classes/fabricobject/) · [BaseFabricObject API](https://fabricjs.com/api/classes/basefabricobject/) · [Canvas API](https://fabricjs.com/api/classes/canvas/) · [StaticCanvas API](https://fabricjs.com/api/classes/staticcanvas/) · [Group API](https://fabricjs.com/api/classes/group/) · [CanvasEvents interface](https://fabricjs.com/api/interfaces/canvasevents/)
- [Working with events (docs)](https://fabricjs.com/docs/events/)
- [Custom props in serialized JSON — Discussion #10176](https://github.com/fabricjs/fabric.js/discussions/10176)
- [Breaking changes for fabric 6.0 — Issue #8299](https://github.com/fabricjs/fabric.js/issues/8299) · [Group Rewrite — Issue #7670](https://github.com/fabricjs/fabric.js/issues/7670)
- Raw v6 source (master): `src/canvas/StaticCanvas.ts` (toObject/version, toJSON, loadFromJSON, renderAll/requestRenderAll), `src/shapes/Object/Object.ts` (customProperties, toObject, defaults), `src/shapes/Image.ts` (fromObject/toObject) — fetched from `raw.githubusercontent.com/fabricjs/fabric.js/master/...`

**Unverified / flagged:** (a) `VERSION` equals the package.json version — inferred from the `import { VERSION } from '../constants'` usage, not separately confirmed against `constants.ts`. (b) Absence of schema migrations and absence of a built-in undo stack are verified-negatives from reading the source/docs, not documented guarantees. (c) Exact default of `originX/originY` (`'left'`/`'top'`) is from convention/API docs; a couple of numeric defaults (`scaleX/scaleY=1`, `strokeWidth=1`) come from the API table rather than a line-quote of `fabricObjectDefaultValues`.
