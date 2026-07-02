# Agent aa8b500596f995f84.output

## Prompt (first 300 chars)
Do FRESH web research (WebSearch + WebFetch of official docs, GitHub source, API docs) on the **Konva.js** 2D canvas library, focused on how a PROGRAM or AGENT (not a human with a mouse) would construct and edit documents. Do NOT rely on memory — fetch and cite real URLs.

Primary sources to priorit

## Final message

Research complete. Here is the structured report.

---

# Konva.js — Programmatic / Agent-Driven Authoring Research

Scope: how a *program or agent* (not a human dragging a mouse) builds and edits Konva documents. All findings from fresh fetches of `konvajs.org` docs/api and the `konvajs/konva` GitHub source; URLs cited per claim. Konva is an HTML5 Canvas 2D retained-mode scene-graph library.

---

## 1. Document / Data Model — the scene-graph tree

**Everything is a `Konva.Node`.** The tree is DOM-like: `Stage → Layer(s) → Group(s)/Shape(s)`, groups nesting arbitrarily. Node depth is fixed by role: Stage = 0, Layer = 1, Groups/Shapes ≥ 2.

**Class hierarchy** (all extend `Node`):
```
Node                     (abstract base — transforms, events, attrs)
├── Container            (add/children machinery)
│   ├── Stage            (owns the DOM container div)
│   ├── Layer            (owns its own <canvas> + hit canvas)
│   └── Group
└── Shape                (leaf; a draw function + hit function)
    ├── Rect, Circle, Ellipse, Wedge, Ring, Arc
    ├── Line  (also Polygon/Spline/Blob via config flags)
    ├── Path  (SVG path data)
    ├── Text, TextPath
    ├── Image
    ├── Star, RegularPolygon
    ├── Label, Tag
    ├── Sprite, Arrow
    └── Transformer  (the interactive resize/rotate handle group)
```
Container ← Node and Shape ← Node confirmed in the Container API page and the overview. Shape subclass list from the overview page. (`Container extends Node … Stage, Layer, and Group all inherit from Container`.)

**What a Node holds — the `attrs` object.** Every node has an instance property `this.attrs` (`attrs: any = {}`), the raw bag of all configured properties. It is populated from the constructor config object and mutated via `_setAttr(key, val)` (which also fires change events). Read the whole bag with `getAttrs()` → `Object`; single value with `getAttr(attr)`; `getAttrs()` returns the raw object literal. (Source: `src/Node.ts`.)

**Config object = the authoring surface.** You construct a node by passing a plain config to the constructor; those keys land in `attrs`. Common Node-level keys (from the Node API constructor list): `x, y, width, height, visible, listening, id, name, opacity, scale/scaleX/scaleY, rotation, offset/offsetX/offsetY, draggable, dragDistance, dragBoundFunc`, plus shape-specific keys like `fill, stroke, strokeWidth, radius`.

**Concrete node config objects:**
```js
const stage = new Konva.Stage({ container: 'container', width: 500, height: 500 });
const layer = new Konva.Layer();
const circle = new Konva.Circle({
  x: 250, y: 250,
  radius: 70,
  fill: 'red', stroke: 'black', strokeWidth: 4,
  id: 'my-circle',        // id() — string
  name: 'shape selectable' // name() — space-delimited string list
});
layer.add(circle);
stage.add(layer);
```
(Overview page.)

**ID / name scheme.** `id()` → `String` and `name()` → `String` are ordinary getter/setters added via `Factory.addGetterSetter(Node, 'id', '', ...)` — i.e. they are just attrs, not a typed handle. `name` is a **space-delimited list**; helper methods `hasName()`, `addName()`, `removeName()` operate on that string. Selectors: `#` = id, `.` = name (see §2). Class registration onto the global is separate: `_registerNode(NodeClass)` does `Konva[NodeClass.prototype.getClassName()] = NodeClass` so `Konva["Circle"]` resolves the class (used by deserialization).

**Registry caveat (important, non-obvious).** Konva historically maintained global `ids`/`names` index objects populated by `_addId`/`_removeId`/`_addName`/`_removeName`. **`find`/`findOne` no longer use that index** — they do a live tree walk (`_descendants` + `_isMatch`); the index was kept only to reduce breaking changes and has been proposed for removal. **IDs are global across ALL stages**, not per-stage — a real collision hazard for programmatic authoring of multiple documents. (GitHub issues #77, #1073.) *Flag: I could not get the WebFetch small-model to quote the current `ids: {}`/`names: {}` lines out of `Global.ts` (the excerpt truncated before them), so the exact present-day field names are **best-guess/UNVERIFIED**; the behavioral claim — find() doesn't use an index, ids are global — is corroborated by the issues.*

---

## 2. Layout Representation — absolute only

**No layout engine. Everything is absolute/manual.** Position is `x`/`y` in the node's own coordinate space; there is no flexbox/grid/anchoring. Extra transform attrs: `rotation` (degrees), `scaleX`/`scaleY`, `offsetX`/`offsetY` (moves the transform origin, e.g. to rotate about center), `skewX`/`skewY`. (Node API.)

**Parent/child tree = the only structure.**
- `container.add(...children)` → `Container` — attaches one or more nodes.
- `container.getChildren(filterFunc?)` → `Array` — direct descendants.
- `node.getParent()`, `node.getLayer()`, `node.getStage()` — walk upward.
- Selectors: `container.find(selector)` → `Array`, `container.findOne(selector)` → `Konva.Node | undefined`. Selector is `'#id'`, `'.name'`, a className string (`'Circle'`), or a predicate function. Resolution is a tree walk via `_generalFind` → `_descendants((node)=>node._isMatch(selector))` (Container source), **not** an index lookup.

**Coordinate math is on you, but helpers exist.** Child coords are relative to parent; to get world coords use `getAbsolutePosition(ancestor?)` / `absolutePosition(pos?)` and `getAbsoluteTransform()` → `Konva.Transform`. **Non-obvious gotcha for programmatic editing:** moving a parent changes a child's absolute position **without firing the child's `xChange`/`yChange`** — attr-change events are local to the mutated node only (GitHub issue #188). So you cannot rely on child change-events to observe layout shifts caused by ancestor moves.

---

## 3. Mutation API

**You must hold real `Konva.Node` instances to mutate.** There is no "edit the plain data and re-render" path in core — attrs live inside live objects. Operations:

| Intent | API |
|---|---|
| Create | `new Konva.Rect({...})` etc. |
| Attach | `layer.add(node)` / `group.add(node)` (returns the container) |
| Set many attrs | `node.setAttrs({ x: 100, fill: 'blue' })` → `Node` |
| Set one attr | `node.setAttr('x', 100)` or the getter/setter `node.x(100)` |
| Read | `node.getAttr('x')` / `node.x()` |
| Detach (reusable) | `node.remove()` → `Node` (keeps it alive, off-tree) |
| Delete (permanent) | `node.destroy()` (also `container.destroyChildren()`) |
| Clone | `node.clone(overrides?)` → `Node` |

Getter/setters are overloaded: `node.x()` reads, `node.x(100)` writes. `remove()` vs `destroy()` is a real distinction — `removeChildren()` preserves for reuse, `destroyChildren()` frees. (Node/Container APIs.)

**Redraw / batching.** Retained scene graph over immediate-mode canvas, so mutations need a draw:
- `layer.draw()` (inherited) — draws scene + hit graphs immediately.
- `layer.batchDraw()` → `Layer` — schedules a draw on the next `requestAnimationFrame` (coalesces many mutations into one frame; the right call for programmatic bulk edits).
- **`Konva.autoDrawEnabled` (default `true`)** — Konva auto-updates the canvas on attr changes, so an explicit draw is often unnecessary; set it `false` for full manual control (`Global.ts`).

**Observability / reactivity.** No reactive data-binding, but a rich event system via `node.on(evtStr, handler)` / `off` / `fire`:
- **Attribute-change events**: `'xChange'`, `'fillChange'`, `'scaleXChange'`, … — handler gets `evt.oldVal` / `evt.newVal`. This is the built-in hook for observing programmatic edits — but only for the node actually mutated (see §2 parent-move caveat).
- Interaction events: `click, dblclick, mouseover/out/move, wheel, contextmenu, dragstart/dragmove/dragend`, touch/tap variants.
- Space-delimited multi-bind (`'mousedown mouseup'`) and namespaces (`'click.foo'`). Event object exposes `target`, `currentTarget`, `evt`. (Binding-Events + Drag-Events docs.)

**Undo/redo: NONE built in.** Konva provides no history model. You roll your own — the docs' own pattern is snapshot `stage.toJSON()` after each action onto a stack, or (recommended for real apps) keep your own state model separate from Konva and diff/replay it. The React/Angular undo docs explicitly say undo/redo "should be independent of rendering." (Best_Practices; react/Undo-Redo; GitHub discussion #1232.)

---

## 4. Persistence — serialize / deserialize

**`node.toObject()` → plain object; `node.toJSON()` → `JSON.stringify(toObject())`.** Structure per node: `{ className: <getClassName()>, attrs: {...}, children: [...] }` (Container adds recursive `children`). (`src/Node.ts`.)

**What `toObject` includes / drops (from the source logic):**
- Only attrs whose value **differs from the class default** are written (it temporarily deletes the key, calls the getter to obtain the default, compares, restores) — so JSON is sparse, defaults are omitted.
- **Skipped:** non-plain objects / class instances, functions. Consequently **images, filters, custom `sceneFunc` draw functions, and event handlers/listeners are NOT serialized** — the docs state event handlers and images "are not serializable"; `toJSON` "can't save filters, images and event listeners." (Serialize_a_Stage; Complex_Load.)

**Deserialize: `Konva.Node.create(json, container?)`.**
- Accepts a JSON string or an already-parsed object; if a string, `JSON.parse` first.
- Internally `_createNode(obj, container)` looks up the class by className (`Konva[className]`), does `new Class(obj.attrs)`, then recurses over `obj.children` with `node.add(...)`. `container` (a DOM id / element) is injected for the Stage. (`src/Node.ts`.)
- **After loading you must manually re-attach everything that didn't serialize**: find the nodes (`stage.findOne('RegularPolygon')`), re-bind `.on(...)`, re-set images (`imageNode.image(imgEl)` / cache), re-apply `.filters([...])` + `.cache()`. Docs example:
```js
const stage = Konva.Node.create(json, 'container');
const hexagon = stage.findOne('RegularPolygon');
hexagon.on('click', () => hexagon.fill(Konva.Util.getRandomColor()));
```
(Complex_Load.)

**Schema versioning: NONE.** No version field, no migrations. `className` is the only type discriminator. The docs actively steer larger apps *away* from `toJSON` round-tripping: "those methods are useful only in very small apps… In bigger apps it is VERY hard" — keep your own serializable app-state and rebuild the canvas from it (`create(state)` / `update(state)` functions). (Best_Practices.)

*Flag / UNVERIFIED discrepancy:* one WebFetch of `Node.ts` reported `toObject` writing `className` at the object root **and** `_createNode` reading `obj.attrs.className`. Those two are inconsistent; the small-model likely misread one. Best-guess from the canonical structure: `className` sits at the **root** of each node object (sibling of `attrs`), and `_createNode` reads it from the root. Treat the exact storage location of `className` as UNVERIFIED pending a direct source read.

---

## 5. Rendering

- **Backend: HTML5 Canvas 2D.** Konva is a retained-mode scene graph layered on top of immediate-mode `<canvas>`.
- **Each `Layer` owns its own `<canvas>` DOM element** — plus a **second hidden hit-graph canvas** for event/hit detection. `getCanvas()` (wrapper), `getNativeCanvasElement()` (raw DOM canvas), `getContext()` (2D context), `getHitCanvas()`. The Stage owns the container `<div>`; layers stack inside it. (Layer API; how_it_works.)
- **Hit detection** renders every shape a second time to the hit canvas in a unique `colorKey` color; a pixel read maps back to the shape — cheap O(1) hit-testing instead of geometric math. (how_it_works / overview.)
- **Redraw model:** `draw()` = immediate scene + hit redraw (drawing the Stage clears+redraws all layers); `batchDraw()` = rAF-coalesced; `clearBeforeDraw` (default `true`) controls per-frame clearing; global `Konva.autoDrawEnabled` triggers redraws on attr changes automatically. Perf guidance: split content across multiple layers so a mutation only redraws its layer, not the whole stage. (Layer API; Best_Practices.)

---

## 6. Programmatic-Authoring Friction — concrete assessment

**HIGH-friction aspects (for a program/agent):**
1. **Live objects, not data.** To mutate you must hold an actual `Konva.Node` instance and call setters — there is no "patch this plain JSON and it re-renders." An agent editing serialized state must `Konva.Node.create(...)`, `findOne`/`find` the target, mutate, re-serialize. The docs themselves warn `toJSON`/`create` round-tripping is "VERY hard" beyond tiny apps.
2. **Lossy serialization.** `toObject`/`toJSON` silently drop **images, filters, `sceneFunc` custom draws, event handlers/listeners**, and anything non-plain-object/function. Round-trip fidelity is **partial by design** — every load needs a manual re-attach pass (`on`, `image`, `filters`+`cache`). An agent that reasons purely over the JSON is blind to those aspects.
3. **Requires a DOM container / Stage.** A Stage needs a real `container` DOM node; core Konva assumes a browser DOM (headless use needs `konva-node`/canvas shims). Pure server-side authoring is not first-class.
4. **No undo, no history.** Every edit-history feature is DIY (snapshot stack or external state model).
5. **No schema / no versioning / no migrations.** Only `className` discriminates types; nothing guards format drift across versions.
6. **Global id namespace.** IDs are shared across all stages and the id/name index is no longer used by `find` — so ids aren't a reliable primary key, and cross-document authoring risks collisions.
7. **Local-only change events.** `xChange`/`fillChange` fire only on the directly-mutated node; ancestor transforms don't propagate change events — observing derived layout programmatically is unreliable.
8. **No auto-layout.** Every position is absolute; an agent must compute all geometry itself (alignment, flow, wrapping beyond `Text` internals).

**LOW-friction aspects:**
1. **Uniform, discoverable API.** Everything is a Node with a consistent config-object constructor and overloaded getter/setters (`node.x()`/`node.x(100)`), `setAttrs({...})` for bulk — easy to generate mechanically.
2. **Sparse, human-legible JSON.** `toObject` omits defaults, so serialized nodes are compact `{className, attrs, children}` trees — easy for an agent to read and template.
3. **Simple deterministic tree.** `add`/`remove`/`destroy` + `find('#id' | '.name' | 'ClassName' | fn)` give clean CRUD/navigation.
4. **Explicit render control.** `batchDraw()` + `autoDrawEnabled` mean bulk programmatic edits coalesce cleanly.
5. **Rich event hooks** (`on`, attr-change events with `oldVal`/`newVal`) give an observability seam if you stay within a single node's mutations.

---

## Sources
- https://konvajs.org/docs/overview.html
- https://github.com/konvajs/site/blob/master/source/docs/how_it_works.md
- https://konvajs.org/api/Konva.Node.html
- https://konvajs.org/api/Konva.Container.html
- https://konvajs.org/api/Konva.Layer.html
- https://konvajs.org/api/Konva.Group.html
- https://konvajs.org/api/Konva.Stage.html
- https://github.com/konvajs/konva/blob/master/src/Node.ts (raw: `raw.githubusercontent.com/konvajs/konva/master/src/Node.ts`)
- `raw.githubusercontent.com/konvajs/konva/master/src/Global.ts`
- `raw.githubusercontent.com/konvajs/konva/master/src/Container.ts`
- https://konvajs.org/docs/data_and_serialization/Serialize_a_Stage.html
- https://konvajs.org/docs/data_and_serialization/Complex_Load.html
- https://konvajs.org/docs/data_and_serialization/Simple_Load.html
- https://konvajs.org/docs/data_and_serialization/Best_Practices.html
- https://konvajs.org/docs/react/Undo-Redo.html
- https://github.com/konvajs/konva/discussions/1232
- https://konvajs.org/docs/events/Binding_Events.html
- https://konvajs.org/docs/drag_and_drop/Drag_Events.html
- https://github.com/konvajs/konva/issues/188 (ancestor move doesn't fire child xChange)
- https://github.com/konvajs/konva/issues/77 (find by id across multiple stages — global namespace)
- https://github.com/konvajs/konva/issues/1073 (name/id index; find no longer uses the index)

**Two items flagged UNVERIFIED** (WebFetch small-model truncation/inconsistency, not confirmable without a direct source read): (a) exact present-day field names of the global id/name registry in `Global.ts` (`ids`/`names`/`_addId`…) — behavior is corroborated by issues, field names are best-guess; (b) whether `className` is stored at the node-object root vs inside `attrs` in `toObject`/`_createNode` — the two fetched excerpts disagreed; best-guess is root-level.
