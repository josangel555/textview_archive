# Agent a4ea2031e58c3446e.output

## Prompt (first 300 chars)
I need deep, freshly-researched findings on cross-domain systems that hold a SEMANTIC / abstract representation which then renders/engraves/compiles to a rich VISUAL artifact. Use web search and actually fetch primary sources (specs, papers, project docs, source). Do NOT rely on memory or listicles.

## Final message

Research complete — 13 primary sources fetched directly, plus search-surfaced material (flagged where I couldn't independently fetch). Findings below.

---

# Semantic model → visual artifact: cross-domain findings

A note on citation rigor up front: URLs marked **[fetched]** I retrieved in full and quoted from. Claims marked **[search-surfaced]** came only through the search tool's page synthesis (I did not independently fetch the page, or the fetch was blocked) — treat those as lower-confidence. Two sources I *tried* to fetch returned `403`/Anubis blocks and are **not** cited as fetched: the Ondsel blog and the live `wiki.freecad.org` mirror.

---

## 1. MusicXML (semantic interchange) vs LilyPond (engraving DSL)

### MusicXML — an interchange/semantic model

**What it is.** MusicXML explicitly frames itself as interchange: *"sheet music desperately needs a comprehensive, Internet-friendly interchange format"* — [musicxml.com "Elements of MusicXML Design"](https://www.musicxml.com/publications/makemusic-recordare/xml-2001/elements-of-musicxml-design/) [fetched]. It deliberately encodes *musical meaning* over *graphical appearance*. The same source contrasts it with NIFF, a graphical format: MusicXML's pitch is `step` + `octave`, *"well-suited for both notation and performance applications,"* whereas NIFF's graphical staff-step approach *"requires computational inference to determine actual pitch."* That is the semantic-vs-graphical axis in one sentence.

**Concrete data structure.** Two isomorphic tree shapes, chosen by root element ([W3C MusicXML 4.0 tutorial](https://www.w3.org/2021/06/musicxml40/tutorial/structure-of-musicxml-files/) [fetched]):

```
<score-partwise>            <score-timewise>
  part                        measure
    measure                     part
      note ...                    note ...
```

- `<score-partwise>` → part is primary, measures nested inside each part. `<score-timewise>` → measure is primary, parts nested inside. *"MusicXML can represent scores either partwise (measures within parts) or timewise (parts within measures), with XSLT stylesheets to go back and forth between the two"* — because *"musical scores are inherently two-dimensional"* ([Elements of MusicXML Design](https://www.musicxml.com/publications/makemusic-recordare/xml-2001/elements-of-musicxml-design/) [fetched]). Most tools use partwise ([W3C tutorial](https://www.w3.org/2021/06/musicxml40/tutorial/structure-of-musicxml-files/) [fetched]).
- A `<note>` is the atom ([W3C MusicXML 4.0 `<note>` reference](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/note/) [fetched]): exactly one of `<pitch>` (`<step>`/`<octave>`/optional `<alter>`), `<unpitched>`, or `<rest>`; plus `<duration>`, `<type>`, `<dot>`, `<voice>`, `<chord>`, `<tie>`, `<stem>`, `<beam>`, `<notations>`, `<lyric>`.

**The tell — it carries BOTH semantics and optional layout, in the same node.** The `<note>` element also carries `default-x`/`default-y` (which *"Changes the computation of the default horizontal/vertical position"*), `relative-x`/`relative-y`, and formatting attributes `color`, `font-family`, `font-size`, `print-object`, `print-spacing`, etc. ([W3C `<note>` reference](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/note/) [fetched]). So MusicXML is *semantic-first but layout-optional* — it can hint at appearance, but that layer is advisory, not authoritative.

### LilyPond — an engraving model

**What it is.** A compiler. *"LilyPond is a compiled system: it is run on a text file describing the music"*; you *"write music by typing text. This text is interpreted (or 'compiled') by LilyPond, which produces beautifully engraved sheet music"* — it is *"more similar to a programming language than graphical score editing software"* ([lilypond.org text-input](https://lilypond.org/text-input.html) [fetched]). Philosophy is WYSIWYM/LaTeX-like: input is content, output is typeset.

**Concrete data structure — and the non-obvious part.** LilyPond *inverts* the modeling question. From the engraving essay ([Music representation, LilyPond essay](https://lilypond.org/doc/v2.25/Documentation/essay/music-representation) [fetched]): rather than defining what music "really is," the authors *"write a program capable of producing sheet music, and adjust the format to be as lean as possible."* Input is **recursive music expressions** — sequential `{ }`, simultaneous `<< >>` — defined by a context-free grammar from which the parser is generated. Critically: *"parsing and representation take up less than 10% of the source code"* — the other 90% is the formatting/layout algorithms. The abstract model is cheap; the engraving is the hard part.

Internally the typeset output is a graph of **grobs** (graphical objects) ([LilyPond Internals: grob-interface](https://lilypond.org/doc/v2.25/Documentation/internals/grob_002dinterface) [fetched]):
- *"A grob represents a piece of music notation."*
- *"All grobs have an X and Y position on the page … stored in a relative format,"* so they compose by stacking/hanging/coupling — a staccato dot's X reference point *is* its note head, so *"When the note head is moved, the staccato dot moves along automatically."* (Relative positioning = a constraint-like layout graph, not absolute coordinates.)
- Grobs have **immutable** (shared default style, changed via `\override`/`\revert`) and **mutable** (per-grob) Scheme properties. Some grobs print nothing and only group.
- **Engravers** turn music events into grobs; a grob's **stencil** produces the final marks.

So the pipeline is: *music expression → engravers → grob graph (relative-positioned, property-carrying) → stencils → pages*.

### The gap between "what the music IS" and "how it sits on the page"

- **Round-trip is lossy by construction.** Per MuseScore's own handbook [search-surfaced, fetch was `403`-blocked]: MusicXML *"faithfully reproduces the notes and instrumentation, but … it is usually necessary to do some clean-up work,"* and *"the exact layout of systems and pages will not be the same at first, since due to differences in spacing settings and fonts (etc.) it might not be possible to fit the same number of bars in a system"* ([MuseScore handbook — working with MusicXML files](https://musescore.org/en/handbook/4/working-musicxml-files)). The semantic layer transfers; the engraving layer is *recomputed by each program's own layout engine* and won't match.
- **Adjacent lead — MEI + Verovio confirm the two-model split as an architecture, not an accident.** Verovio uses **MEI as its native internal model** and, *"When loading a MusicXML file into Verovio, it converts this internally into MEI"*, then engraves the MEI to SVG via `renderToSVG()` ([Verovio book — encoding formats](https://book.verovio.org/interactive-notation/encoding-formats.html) [fetched]). So even a modern engraver treats MusicXML as an *import interchange format* and converts it into a *richer internal representation* before laying out. [search-surfaced, not independently fetched] one comparison frames the axis as MEI capturing musical *semantics/relationships* better while MusicXML leans toward *notation layout* ([music-encoding.org / DLFTeach intro to MEI](https://music-encoding.org/about/)) — note this cuts against the naive "MusicXML = pure semantics" framing, so I flag it as **contested / lower-confidence**.

### Why it matters for your model→HTML/CSS/JS + WYSIWYG-canvas system

- Keep **two explicit layers**: a semantic/interchange model (the "what") and an engraving/layout projection (the "how"). MusicXML's mistake-to-avoid is *bleeding advisory layout attributes (`default-x`) into the semantic node* — it makes the format ambiguous about who owns layout. Decide, per property, whether the *model* owns it or the *renderer* owns it, and don't duplicate.
- LilyPond's 90/10 split is the load-bearing lesson: **the parser/model is the easy 10%; the layout engine is the 90%.** Budget accordingly.
- LilyPond grobs' **relative positioning** ("dot's X reference is the note head") is exactly a WYSIWYG-friendly design: edits to a parent reflow children for free. If your canvas projects an abstract model, prefer relative/anchored geometry over baked absolute coordinates so edits don't require global recompute.
- Expect **no clean round-trip** between your export/interchange format and the pixel-exact layout. If exact visual fidelity must survive export, you must serialize the layout decisions too — and even then a different renderer will diverge.

---

## 2. Parametric CAD: feature history + constraint sketches, and the topological-naming failure

### What it is

Parametric/feature-based CAD models a part as an **ordered history of features** (pad, cut, fillet, chamfer, union…), each built on geometry produced by earlier features, plus **2D constraint sketches** solved by a constraint solver (design *intent*, not fixed coordinates). Later features reference earlier geometry *by topological identity* — "the top face of pad 2," "edge #47."

### Concrete data structure

A **feature tree / DAG**: nodes are parametric operations; edges are dependencies where a downstream feature names a face/edge/vertex of an upstream result. The geometry kernel (e.g. OCCT in FreeCAD) re-evaluates this tree on every edit, regenerating the boundary representation (B-rep) and the IDs of its faces/edges/vertices.

### What breaks — the topological naming problem (the famous failure mode)

FreeCAD's own docs define it precisely ([FreeCAD-documentation — Topological_naming_problem.md](https://github.com/FreeCAD/FreeCAD-documentation/blob/main/wiki/Topological_naming_problem.md) [fetched]):
- *"a shape changing its internal name after a modelling operation (pad, cut, union, chamfer, fillet, etc.) is performed."*
- *"This will result in other parametric features that depend on that shape to break or be incorrectly computed."*
- Concrete failure, verbatim: *"the top face of the second pad was renamed from `Face13` to `Face14`. The third sketch is attached to `Face13` as it originally was, but since this face is now on the side (not at the top), the sketch follows its orientation and now is incorrectly positioned."*

This is *inherent* to feature-based parametrics, not a FreeCAD bug per se — the academic literature has chased it for decades. The persistent-naming problem is *"the problem of identifying entities in an initial parametric model and matching them in the re-evaluated model"*; Kripac proposed a **Topological ID system** assigning stable IDs to entities based on inherent characteristics rather than evaluation order ([cad-journal.net — "A Feature-Based Solution to the Persistent Naming Problem" (2005 PDF)](https://www.cad-journal.net/files/vol_2/CAD_2(1-4)_2005_517-526.pdf) [fetched]). [search-surfaced] follow-on surveys note *"there is no single standard method for persistent identification"* and that Kripac's algorithm *"is difficult to implement because details … for name matching among faces … were not addressed"* ([ScienceDirect — "Mechanisms of Persistent Identification of Topological Entities in CAD Systems: A Review"](https://www.sciencedirect.com/science/article/pii/S1110016818300814); [KAIST/IJCC "Identification of Topological Entities and Naming Mapping"](https://koasas.kaist.ac.kr/bitstream/10203/6600/1/Identification%20of%20Topological%20Entities%20and%20Naming.pdf)).

### Honest maturity

FreeCAD's fix (shipped in 1.0) is **not a total solve** — it's a mitigation with three jobs ([FreeCAD-documentation — Topological_naming_problem.md](https://github.com/FreeCAD/FreeCAD-documentation/blob/main/wiki/Topological_naming_problem.md) [fetched]): identify broken references and show errors; present likely fixes for user acceptance; auto-resolve references — but *"only with high confidence in the correctness of the repair, because an incorrect automatic repair may re-introduce the problem."* So even the "fixed" state is *conservative auto-repair*, not guaranteed persistence. [search-surfaced, blocked-fetch] the Ondsel commentary frames it as "significantly improved, most rebuilds now succeed" rather than eliminated ([ondsel.com — toponaming is history](https://www.ondsel.com/blog/toponaming-problem-is-history/) — could NOT be fetched, `403`; do not treat as verified).

### Why it matters for your model→HTML/CSS/JS + WYSIWYG-canvas system

This is the single most important cautionary tale for you if your abstract model uses **references/intent** ("this callout points at *that* heading," "align to the element created in step 3," "style the 3rd column"):
- **Capturing intent (constraints/relations) is powerful but fragile**: any edit that regenerates the entity set can silently re-point a reference at the wrong target — the *exact* `Face13→Face14` failure, translated to your DOM/model nodes.
- **Do not name things by ordinal/positional identity** (index, generation order, "nth child"). That is the volatile ID that shifts. Assign **stable durable IDs** at creation and keep them across edits — the persistent-naming lesson, decades old and still unsolved cleanly.
- When you *can't* resolve a reference confidently, **fail loud + offer a repair**, don't auto-guess — FreeCAD's hard-won rule ("only repair at high confidence, a wrong repair reintroduces the bug").

---

## 3. SVG — declarative retained-mode scene graph vs Canvas immediate mode

### What it is

*"SVG is a language for describing two-dimensional graphics in XML"* ([W3C SVG 1.1 — Introduction](https://www.w3.org/TR/SVG11/intro.html) [fetched]). Every shape is a real document element (like a `<div>`), addressable and stylable.

### Concrete data structure

A **DOM tree of graphics elements** — a retained scene graph. Per the spec ([W3C SVG 1.1 intro](https://www.w3.org/TR/SVG11/intro.html) [fetched]): *"Graphical objects can be grouped, styled, transformed and composited"*; SVG provides *"a complete Document Object Model (DOM)"* with *"complete access to all elements, attributes and properties,"* and content *"can be styled by … CSS … or XSLT"* with declarative or scripted animation. The browser retains this model and repaints it; when a few nodes change it can repaint incrementally.

### Contrast with Canvas (immediate mode)

[search-surfaced] the crisp framing: *"SVG gives you a built-in retained-mode scene graph (DOM), while Canvas and WebGL are immediate-mode and you manage the data + picking yourself"*; with Canvas, *"once your drawing is on the canvas, the canvas stops keeping track of it"* — you own the model, the redraw, and hit-testing ([kirupa — DOM vs Canvas](https://www.kirupa.com/html5/dom_vs_canvas.htm); [dev.to — SVG vs Canvas vs WebGL](https://dev.to/vitalf/svg-vs-canvas-vs-webgl-for-diagram-viewers-tradeoffs-bottlenecks-and-how-to-measure-34n7)). These I did not fetch directly.

### What breaks / maturity

SVG's retained tree is mature and battle-tested but **scales poorly to very large node counts** — thousands of live DOM nodes carry per-element cost (layout, style, event listeners); Canvas wins on raw draw throughput precisely because it retains nothing [search-surfaced, same sources above]. That's the classic tradeoff, unverified beyond search synthesis.

### Why it matters for your model→HTML/CSS/JS + WYSIWYG-canvas system

- SVG **is your architecture in miniature**: an abstract, declarative, addressable model that the runtime projects to pixels and re-projects on change. If your model → HTML/CSS/JS, you are already in **retained mode** — lean into it (diff the model, patch the DOM, let CSS handle reflow) rather than reimplementing immediate-mode repaint.
- **Hit-testing/selection is free in retained mode** (each node is a real element with events) and *manual* in immediate mode. A WYSIWYG canvas needs precise "what did the user click?" → the retained model gives you that; a Canvas-based editor must maintain a parallel scene model just to do picking.
- The scaling caveat is real: if your projected artifact can reach thousands of nodes, plan virtualization/immediate-mode escape hatches for hot regions.

---

## 4. PostScript (imaging *program*) vs PDF (static page-description *model*)

### PostScript — a Turing-complete imaging program

*"PostScript (PS) is a page description language and dynamically typed, stack-based programming language"*; it uses reverse Polish notation, is **Turing complete**, and *"When the PostScript program is interpreted, the interpreter converts these instructions into the dots needed to form the output"* (rasterization). It is device-independent because *"the document-program is the same regardless of its destination"* ([Wikipedia — PostScript](https://en.wikipedia.org/wiki/PostScript) [fetched]). A `.ps` file is *executed*, not merely parsed — with loops, conditionals, procedures, dictionaries.

### PDF — a static, resolution-independent page-description model

PDF keeps PostScript's *imaging model* but drops the *programming*: *"The imaging model for PDF was originally based on the PostScript page description language, used to render complex text, images, and graphics in a device-independent and resolution-independent manner"*, and PDF represents *"'final form' formatted documents"* ([RFC 8118 — the application/pdf Media Type](https://www.rfc-editor.org/rfc/rfc8118.html) [fetched]). Wikipedia puts the contrast bluntly: PDF is *"a static data structure made for efficient access"* that lacks PostScript's *"general-purpose programming language framework"* ([Wikipedia — PostScript](https://en.wikipedia.org/wiki/PostScript) [fetched]). (PDF standardized as ISO 32000; JavaScript can be embedded but PDF itself is a document format, not a language — [RFC 8118](https://www.rfc-editor.org/rfc/rfc8118.html) [fetched].)

```
PostScript:  program  --(interpret/execute: loops, procs)-->  rasterized page   [dynamic]
PDF:         static object graph (fixed page tree + content streams) --(render)--> page   [final-form]
```

### What breaks / maturity

- PostScript's Turing-completeness is its curse for viewers: you cannot know a page's content without *running* the program (halting-problem territory) — slow, non-random-access, and a security surface. That is *why* PDF exists: a *"more structured format … to improve performance for interactive viewing"* ([search-surfaced, ISO 32000 framing surfaced in search]; the core claim is corroborated by [Wikipedia — PostScript](https://en.wikipedia.org/wiki/PostScript) [fetched]).
- PDF's "final form" is its own limitation: it pins layout, so content **doesn't reflow** — the opposite failure from a semantic model.

### Why it matters for your model→HTML/CSS/JS + WYSIWYG-canvas system

- This is the **"program vs data" axis** of your abstract model. If your model is *executable* (arbitrary JS/logic that computes the artifact), you get PostScript's power *and* its problems: you can't statically analyze/diff/incrementally-render it, and you inherit a security/perf surface. If your model is *declarative data* (PDF-like object graph), you get random access, cheap diffing, incremental render, and safety — at the cost of expressiveness.
- For a WYSIWYG editor, **strongly prefer the declarative-data end**: you can select, diff, patch, and re-project a static model node-by-node. An "execute to see the page" model fights every one of those. (This is the same lesson as retained-vs-immediate, viewed through document formats.)

---

## 5. Retained mode vs immediate mode (the general lens)

### The authoritative definitions

From Microsoft's Win32 docs ([learn.microsoft.com — Retained Mode Versus Immediate Mode](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode) [fetched], verbatim):

- **Retained mode is declarative.** *"The application constructs a scene from graphics primitives … The graphics library stores a model of the scene in memory. To draw a frame, the graphics library transforms the scene into a set of drawing commands. Between frames, the graphics library keeps the scene in memory. To change what is rendered, the application issues a command to update the scene … The library is then responsible for redrawing the scene."*
- **Immediate mode is procedural.** *"Each time a new frame is drawn, the application directly issues the drawing commands. The graphics library does not store a scene model between frames. Instead, the application keeps track of the scene."*
- **Examples:** *"Direct2D is an immediate-mode API. Windows Presentation Foundation (WPF) is an example of a retained-mode API."*

### The core tradeoff (verbatim)

*"Retained-mode APIs can be simpler to use, because the API does more of the work for you, such as initialization, state maintenance, and cleanup. On the other hand, they are often less flexible, because the API imposes its own scene model. Also, a retained-mode API can have higher memory requirements … With an immediate-mode API, you can implement targeted optimizations."* ([learn.microsoft.com](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode) [fetched]).

### Why it matters for your model→HTML/CSS/JS + WYSIWYG-canvas system

This is the meta-lens over all four cases above:

| Axis | Retained (declarative model) | Immediate (procedural draw) |
|---|---|---|
| Who holds the scene | the library/framework | your app, every frame |
| Editing | update the model, framework re-renders | you recompute + redraw |
| Hit-test/selection | free (nodes exist) | manual |
| Flexibility / perf ceiling | lower (imposed model) | higher (hand-tuned) |
| Domain instances above | SVG/DOM, WPF, PDF object graph, MusicXML tree, LilyPond grob graph | Canvas, Direct2D, PostScript execution |

- A **WYSIWYG canvas that projects an abstract model is retained mode almost by definition** — the model *is* the retained scene; the framework re-renders on edit. Embrace it: your edits mutate the model, a differ patches the DOM. Don't hand-roll immediate-mode "clear and repaint the world" unless a hot subview demands it.
- Microsoft's honest caveat maps directly onto your risk: *"the API imposes its own scene model."* If your projection layer (HTML/CSS) imposes constraints the abstract model can't express, you'll fight it — the same "you need both a semantic model and a layout model, and they don't perfectly agree" tension from MusicXML/LilyPond.

---

## The three non-obvious cross-cutting lessons (what to actually take away)

1. **Interchange/semantic ≠ layout/engraving, and they don't round-trip cleanly — plan for two models, not one.** MusicXML transfers notes but each program *recomputes* the page (MuseScore: expect cleanup) [search-surfaced]; Verovio converts MusicXML into its *own* internal MEI before engraving to SVG ([Verovio book](https://book.verovio.org/interactive-notation/encoding-formats.html) [fetched]); LilyPond spends 90% of its code on layout, only 10% on the model ([LilyPond essay](https://lilypond.org/doc/v2.25/Documentation/essay/music-representation) [fetched]). If exact visual fidelity must survive a save/load, you must serialize layout decisions *alongside* the semantic model — and even then a different renderer diverges. Decide explicitly, per property, whether the model or the renderer owns it (MusicXML's leaky `default-x` on `<note>` is the anti-pattern — [W3C `<note>`](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/note/) [fetched]).

2. **Capturing intent (references/constraints/parameters) is powerful but fragile — the topological-naming trap generalizes to any model with references.** The `Face13→Face14` failure ([FreeCAD docs](https://github.com/FreeCAD/FreeCAD-documentation/blob/main/wiki/Topological_naming_problem.md) [fetched]) is *exactly* what happens if your model nodes reference each other by ordinal/positional identity and an edit regenerates the node set. Decades of CAD research (Kripac's Topological IDs onward) have *mitigated but not solved* this ([cad-journal 2005](https://www.cad-journal.net/files/vol_2/CAD_2(1-4)_2005_517-526.pdf) [fetched]; [ScienceDirect review](https://www.sciencedirect.com/science/article/pii/S1110016818300814) [search-surfaced]). Practical rules: assign **stable durable IDs at creation**, never name by index/generation-order, and on an unresolvable reference **fail loud + offer a repair** rather than silently re-pointing (FreeCAD only auto-repairs at high confidence because a wrong repair reintroduces the bug).

3. **Retained vs immediate is the right lens for WYSIWYG-canvas architecture — you're almost certainly retained, so commit to it.** SVG/DOM, WPF, and a PDF object graph are retained; Canvas, Direct2D, and PostScript *execution* are immediate ([Microsoft](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode) [fetched]; [Wikipedia PostScript](https://en.wikipedia.org/wiki/PostScript) [fetched]; [RFC 8118](https://www.rfc-editor.org/rfc/rfc8118.html) [fetched]). A model-projecting WYSIWYG editor gets free selection/hit-testing, incremental repaint, and diff-and-patch editing from retained mode — and pays for it in a framework-imposed scene model and memory. Prefer a **declarative-data model over an executable one** (the PDF-over-PostScript choice): declarative data is diffable, randomly accessible, incrementally renderable, and safe; executable models buy expressiveness at the cost of every one of those.

---

## Sources

**Fetched directly (quoted):**
- MusicXML: [W3C 4.0 tutorial — structure](https://www.w3.org/2021/06/musicxml40/tutorial/structure-of-musicxml-files/) · [W3C 4.0 `<note>` reference](https://www.w3.org/2021/06/musicxml40/musicxml-reference/elements/note/) · [musicxml.com — Elements of MusicXML Design](https://www.musicxml.com/publications/makemusic-recordare/xml-2001/elements-of-musicxml-design/)
- LilyPond: [Music representation essay](https://lilypond.org/doc/v2.25/Documentation/essay/music-representation) · [Text input](https://lilypond.org/text-input.html) · [Internals — grob-interface](https://lilypond.org/doc/v2.25/Documentation/internals/grob_002dinterface)
- CAD: [FreeCAD-documentation — Topological_naming_problem.md](https://github.com/FreeCAD/FreeCAD-documentation/blob/main/wiki/Topological_naming_problem.md) · [cad-journal.net — A Feature-Based Solution to the Persistent Naming Problem (2005)](https://www.cad-journal.net/files/vol_2/CAD_2(1-4)_2005_517-526.pdf)
- SVG: [W3C SVG 1.1 — Introduction](https://www.w3.org/TR/SVG11/intro.html)
- PostScript/PDF: [Wikipedia — PostScript](https://en.wikipedia.org/wiki/PostScript) · [RFC 8118 — application/pdf Media Type](https://www.rfc-editor.org/rfc/rfc8118.html)
- Retained/immediate: [Microsoft Learn — Retained Mode Versus Immediate Mode](https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode)
- MEI/Verovio: [Verovio book — encoding formats](https://book.verovio.org/interactive-notation/encoding-formats.html)

**Search-surfaced only (NOT independently fetched — lower confidence):**
- [MuseScore handbook — working with MusicXML files](https://musescore.org/en/handbook/4/working-musicxml-files) (fetch returned `403`; round-trip quotes are from search synthesis)
- [music-encoding.org — About MEI](https://music-encoding.org/about/) (the "MusicXML leans layout / MEI leans semantics" framing is contested — flagged)
- [ScienceDirect — Mechanisms of Persistent Identification review](https://www.sciencedirect.com/science/article/pii/S1110016818300814) · [KAIST — Identification of Topological Entities and Naming Mapping](https://koasas.kaist.ac.kr/bitstream/10203/6600/1/Identification%20of%20Topological%20Entities%20and%20Naming.pdf)
- SVG/Canvas tradeoff synthesis: [kirupa — DOM vs Canvas](https://www.kirupa.com/html5/dom_vs_canvas.htm) · [dev.to — SVG vs Canvas vs WebGL](https://dev.to/vitalf/svg-vs-canvas-vs-webgl-for-diagram-viewers-tradeoffs-bottlenecks-and-how-to-measure-34n7)

**UNVERIFIED — could not retrieve (blocked; cited by no claim):** [ondsel.com — toponaming is history](https://www.ondsel.com/blog/toponaming-problem-is-history/) and [wiki.freecad.org — Topological_naming_problem](https://wiki.freecad.org/Topological_naming_problem) both returned `403`/Anubis blocks. The FreeCAD *maturity* claims rest instead on the [FreeCAD-documentation GitHub markdown](https://github.com/FreeCAD/FreeCAD-documentation/blob/main/wiki/Topological_naming_problem.md), which I did fetch.
