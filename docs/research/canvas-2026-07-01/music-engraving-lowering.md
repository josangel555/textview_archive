# Agent abdaeb8ba1c11536f.output

## Prompt (first 300 chars)
I'm doing open-ended design research for a system where a PROGRAM authors visual artifacts against a high-level SEMANTIC/INTENT model, which is then "lowered"/rendered to a final publication-quality visual form. I want to learn how the MUSIC NOTATION ENGRAVING world does this.

Do GENUINE FRESH web 

## Final message

Research complete across all systems plus two high-value adjacents I surfaced (Verovio as a concrete lowering engine; Gould's *Behind Bars* as the codified rulebook). Findings below, URLs inline. Not writing any files.

---

# Music notation engraving as a semantic→visual "lowering" pipeline

**The cross-cutting pattern you're after:** every mature system in this world enforces a hard split between *what the music IS* (pitches, durations, structure, editorial intent) and *how it looks on the page* (x/y positions, stem lengths, spacing). The visual form is **computed** from the semantic form by an engine that encodes centuries of hand-engraving craft as machine rules. The formats deliberately **under-specify** layout so the engine owns it. That is exactly the "author against intent, lower to publication-quality visual" architecture you're designing — and this domain has 25+ years of hard-won detail on where it works and where it breaks.

---

## 1. LilyPond — the reference implementation of "describe the music, engrave automatically"

**(1) What it is.** A text-input music engraver: you write a domain-specific language describing pitches/durations/structure, and it produces publication-quality PDFs/SVGs by applying an internal library of engraving rules. Its explicit design goal is to match hand-engraved plates from historic European publishers (Bärenreiter, Durand, Peters, Schott) ([lilypond.org essay/automated-engraving](https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving)).

**(2) How it models the artifact — this is the important part.** LilyPond runs a multi-phase pipeline that is a textbook lowering architecture ([extending-lilypond.gitlab.io/en/extending/translation.html](https://extending-lilypond.gitlab.io/en/extending/translation.html); [lilypond.org contributor/overview-of-lilypond-architecture](http://lilypond.org/doc/v2.18/Documentation/contributor/overview-of-lilypond-architecture)):

```
input (.ly text)
  → PARSE → music expression tree  (internal Scheme representation of music objects)
  → ITERATORS advance through the tree in time, broadcasting STREAM EVENTS
  → CONTEXTS (Score ▸ StaffGroup ▸ Staff ▸ Voice) receive events; hold state
  → ENGRAVERS listen to events, create GROBS (GRaphical OBjects)
  → BACKEND / "paper" phase: line-breaking, page-breaking, stencils → PDF/SVG
```

- The **music model is pure semantics**: a Scheme list of music objects (pitch, duration, structure), with *no coordinates* ([lilypond.org search: internal representation is a Scheme music-object set](https://lilypond.org/doc/v2.23/Documentation/internals/grob_002dinterface)).
- **Iterators** own timing; they "broadcast their contents as stream events." **Engravers** are the lowering rules — there is literally one engraver per notation concept: `Note_heads_engraver`, `Stem_engraver`, `Beam_engraver`, `Staff_symbol_engraver`, etc. They "react to the stream events… create grobs, read and set context properties, and process the grobs created by other engravers" ([extending-lilypond translation](https://extending-lilypond.gitlab.io/en/extending/translation.html)).
- A **grob** is the graphical object. Its visual properties live in an **alist chain** searched in order (per-grob override → context default → …), so styling is layered/cascading rather than baked in ([lilypond.org internals/grob-interface](https://lilypond.org/doc/v2.23/Documentation/internals/grob_002dinterface)).
- **Spacing = a physics model of springs and rods.** A single `SpacingSpanner` grob sets all horizontal spacing for the score; the `springs-and-rods` property triggers `ly:spacing-spanner::set-springs` ([lilypond.org internals/spacingspanner](https://lilypond.org/doc/v2.23/Documentation/internals/spacingspanner)). Concrete parameters: `spacing-increment` default **1.2 staff-spaces** ("typically the width of a note head"); `base-shortest-duration` default **3/16** (the assumed shortest note even if none appears); `shortest-duration-space` default **2.0**; `common-shortest-duration` computed from the actual notes. Spacing is driven off the *shortest duration present*, not raw note count ([spacingspanner](https://lilypond.org/doc/v2.23/Documentation/internals/spacingspanner)).

**(3) Transferable idea — the non-obvious one:** LilyPond does **not** hard-code layout rules as imperative "if X then place at Y" logic. Instead it defines an **objective/ugliness cost function** per decision and picks the least-ugly configuration by search. Direct quote: *"we only have to describe the objectives well enough that LilyPond can judge the attractiveness of several alternatives. Then, for each possible configuration we compute an ugliness score and we choose the least ugly configuration."* It gives real numbers — a slur grazing a notehead scored 15.39 penalty points; another candidate 13.08 total ([lilypond.org essay/automated-engraving](https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving)). This cost-minimization approach is applied uniformly to *beaming, ties, dots-in-chords, line breaks, and page breaks* — one paradigm, many decisions. **The steal:** when lowering intent→visual, model aesthetic quality as a scored optimization over candidate layouts, not a pile of hand-coded special cases. The essay explicitly contrasts this against the traditional-engraving-manual approach of "simple rules of thumb… leading to algorithms with lots of hand-coded exceptions."

A second steal: **spacing as a constraint solver** (springs = stretchable ideal distances, rods = hard minimums), not additive widths. This is why the same content reflows beautifully at different page widths.

A third: **measure everything in a document-relative unit** (the *staff-space*), never absolute points. Optical scaling then falls out — at small sizes LilyPond uses "proportionally heavier lines so the music will still read well," mirroring how hand-engravers cut a separate punch per size ([lilypond.org essay/engraving-details](https://lilypond.org/doc/v2.24/Documentation/essay/engraving-details)).

**(4) What breaks / honest limits.** LilyPond's own essay concedes the ceiling: *"typography relies on human judgment of appearance, so people cannot be replaced completely. However, much of the dull work can be automated."* ([automated-engraving](https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving)). In practice: the fully-declarative model means fine visual control requires dropping into Scheme `\override` on grob properties — powerful but a steep cliff, and overrides are brittle across versions. Complex contemporary/avant-garde notation, dense collision scenarios, and cross-staff beaming still need manual nudging. The optimizer can also be slow, and "least ugly by our cost function" occasionally disagrees with a human engraver's eye. UNVERIFIED-from-fetch (widely reported, not confirmed on a fetched page this session): its horizontal-spacing default can look loose vs. commercial engravers, and manual `\override`/`\tweak` is routine for professional output.

---

## 2. MusicXML — the *interchange* format (presentation-tolerant semantics)

**(1) What it is.** The de-facto lingua franca for exchanging scores between notation programs (Finale, Sibelius, MuseScore, Dorico all import/export it). Born from the **sheet-music publishing industry's** need to move engraved scores between tools ([musescore.org/en/node/24208](https://musescore.org/en/node/24208)).

**(2) How it models music.** XML, in two isomorphic orderings — **partwise** (parts contain measures) or **timewise** (measures contain parts). Rhythm uses an integer `<divisions>` grid per measure; each `<note>` carries an explicit `<duration>` in those divisions plus `<pitch>`(step/octave/alter). Design rule, stated by author Michael Good: *"Musical data is represented using elements, while metadata such as formatting and performance information is represented using attributes"* — and MusicXML deliberately chose verbose **elements over attributes**: *"MusicXML files are longer than the corresponding MEI files, but they are more structured, complete, easier to understand… and easier for music application developers to work with"* ([musicxml.com/publications/…/prefer-clarity-over-concision](https://www.musicxml.com/publications/makemusic-recordare/xml-2006/prefer-clarity-over-concision/)). It explicitly invokes the XML spec's "terseness is of minimal importance."

**The key semantic/visual boundary:** MusicXML *can* carry precise layout via **advisory positioning attributes** — `default-x`/`default-y` (absolute-ish origin) and `relative-x`/`relative-y` (offsets), measured in **tenths of interline space** (staff-relative, like LilyPond's staff-space). But these are **optional layout suggestions**, and handling *"varies across different music notation applications"* — importers routinely ignore them ([usermanuals.musicxml.com default-x](https://usermanuals.musicxml.com/MusicXML/Content/AT-MusicXML-default-x.htm); [musescore.org/en/node/278534: "x position specs ignored on import"](https://musescore.org/en/node/278534)).

**(3) Transferable idea.** MusicXML's design is the pragmatic middle: **semantics are mandatory and structural; presentation is present-but-advisory and lives in a syntactically separable channel (attributes).** A consumer can honor the layout hints for high-fidelity round-trips *or* discard them and re-engrave from scratch. For your system: separate "the layout the author *suggests*" from "the content the author *means*" into different, ignorable channels — so a downstream renderer can choose fidelity-to-source vs. re-lowering. Also note the **relative units** discipline (tenths of interline space) even in the "presentation" format — nobody in this domain uses absolute pixels/points as the primary unit.

**(4) What breaks.** MusicXML is verbose and semantically *shallower* than MEI — it is oriented to "what a notation program needs to redraw this," so scholarly/analytical meaning (why a note is bracketed, which source a reading comes from) is lost or degraded to presentation ("draw brackets") rather than intent ("editorially supplied"). Round-tripping through it is famously lossy: the advisory layout attributes are inconsistently honored, so a score exported and re-imported often re-flows. It is an *interchange* format, not an *authoring model* or an engraving spec — it says almost nothing normative about *how* to space or shape anything.

---

## 3. MEI (Music Encoding Initiative) — the *scholarly/semantic* model

**(1) What it is.** An XML framework for encoding musical *documents* (not just playable notes) in a machine-readable, semantically rich structure, built by music scholars, librarians, and theorists. It consciously mirrors the **TEI** (Text Encoding Initiative) philosophy for scholarly text ([music-encoding.org/about](https://music-encoding.org/about/)).

**(2) How it models music.** A logical hierarchy — `mdiv` → `score`/`parts` → `section` → `measure` → `staff` → `layer` → `note`/`chord`/`rest` — with musical facts as attributes: `pname` (A–G), `oct`, `dur` (`4`=quarter, `8`=eighth), `dots` ([music-encoding.org guidelines/v5/shared](https://music-encoding.org/guidelines/v5/content/shared.html)). Crucially, **visual/layout markers are optional annotations, never structural**: `pb` (page break) and `sb` (system break) can be present but are not required, and the guidelines state *"it is not always possible or desirable to automatically derive one view from the other"* — which is why `score` and `parts` can be *separately encoded* rather than one generated from the other ([guidelines/v5/shared](https://music-encoding.org/guidelines/v5/content/shared.html)).

What sets MEI apart is that it models **editorial and scholarly intent as first-class semantics**, not as visual marks:
- **Critical apparatus** (`app`/`rdg`/`lem`): multiple *variant readings* of the same passage from different sources, encoded as alternatives — not "draw two versions" ([music-encoding.org guidelines search: Ch.9 Critical Apparatus](https://music-encoding.org/guidelines/v4/content/facsimilesrecordings.html)).
- **Editorial markup** (`choice`, `corr`/`sic`, `orig`/`reg`, `supplied`, `unclear`): the classic MusicXML-vs-MEI contrast — MusicXML says *"place two square brackets around this note"*; MEI says the note is `supplied` (editor-provided), and the brackets are a *rendering* of that fact ([musescore.org/en/node/24208](https://musescore.org/en/node/24208)).
- **Facsimile module**: links the encoding to source-image coordinates — defines a writing `surface` as a rectangular coordinate space with `zone`s of interest, so an encoded note can point at its pixel region on a scanned manuscript ([music-encoding.org guidelines/v4/facsimiles](https://music-encoding.org/guidelines/v4/content/facsimilesrecordings.html)).
- It also natively encodes **mensural and neume** notations *structurally* (preserving their logic), not by visually faking them ([music-encoding.org/about](https://music-encoding.org/about/)).

**(3) Transferable idea — the strongest one for your design.** MEI separates **three** layers, not two: *intellectual intent* (this note is editorial, uncertain, or a variant reading) / *logical structure* (pitch, duration, hierarchy) / *presentation* (breaks, coordinates). The intent layer is the non-obvious steal: encode **why** something is the way it is (provenance, certainty, alternative interpretations, source linkage) as queryable semantics — *above* the logical content — so the same document can render differently for different audiences (a performance edition hides the apparatus; a scholarly edition shows it) **from one source of truth**. And the facsimile/zone mechanism is a clean pattern for *bidirectional* linkage between an authored artifact and its source/rendered pixels. MEI even acknowledges the two-way-derivation problem explicitly — a mature admission that automatic lowering *and* lifting between views is sometimes impossible, so it stores both.

**(4) What breaks.** MEI is verbose, complex, and has a steep learning curve; its very flexibility (multiple valid ways to encode the same thing) hurts interoperability. It has **no single canonical renderer** — because it deliberately declines to specify layout, you *need* an external engine (Verovio, below) to see it, and different renderers disagree. In the ecosystem it is not natively supported by the major commercial notation programs (which speak MusicXML) — MEI usually must be *transformed to/from MusicXML*, losing scholarly semantics in the process ([musescore.org/en/node/24208](https://musescore.org/en/node/24208)). So the richest layer (intent) is precisely the layer that doesn't survive the trip to production tools.

---

## 4. SMuFL (Standard Music Font Layout) — decoupling glyph *identity* from glyph *design*

**(1) What it is.** An open standard mapping the ~2,440+ symbols of music notation to stable **Unicode Private Use Area** code points (starting **U+E000**) in a single format-independent font, so any SMuFL font is interchangeable. Originally developed by Daniel Spreadbury at Steinberg for Dorico; now maintained by the **W3C Music Notation Community Group** ([smufl.org](https://www.smufl.org/); [w3.org/2019/03/smufl13 how-smufl-is-organised](https://www.w3.org/2019/03/smufl13/about/how-smufl-is-organised.html)) (Spreadbury/Dorico origin per Wikipedia search snippet — not deep-fetched this session, treat as UNVERIFIED provenance).

**The problem it solves:** before SMuFL, "the code point for the G clef in one font may be the code point used for a quarter rest in another" — every music font had an ad-hoc, incompatible layout, so a score was locked to its font ([search: SMuFL background](https://en.wikipedia.org/wiki/SMuFL)).

**(2) How it models glyphs.** Two parts: (a) a **fixed codepoint registry** — 118 named groups ordered "least to most idiomatic," with intentional gaps for future expansion, split into *recommended* vs *optional* glyphs, plus ligatures and stylistic alternates ([how-smufl-is-organised](https://www.w3.org/2019/03/smufl13/about/how-smufl-is-organised.html)); and (b) a **companion JSON metadata file per font** carrying the geometry a layout engine needs. That metadata is where the semantic/visual decoupling actually happens ([how-smufl-is-organised](https://www.w3.org/2019/03/smufl13/about/how-smufl-is-organised.html)):
- `engravingDefaults` — recommended line thicknesses (stems, barlines, beams, etc.).
- `glyphBBoxes` — precise bounding boxes.
- `glyphsWithAnchors` — **the killer feature**: named attachment points *per glyph*, e.g. `stemUpSE` ("the exact position at which the bottom-right corner of an upward stem rectangle should start"), `stemDownNW`, `stemUpNW`/`stemDownSW` (stem-lengthening for a clean flag connection), `splitStemUpSE`/…, `nominalWidth` (for leger-line width), `cutOutNW/NE/SW/SE` (corner cut-outs enabling *tighter kerning* of accidentals against noteheads), `opticalCenter` (align dynamics under noteheads), `noteheadOrigin` (align asymmetric noteheads), `numeralTop/Bottom` ([w3.org/2019/03/smufl13 glyphswithanchors](https://www.w3.org/2019/03/smufl13/specification/glyphswithanchors.html)).

**(3) Transferable idea.** This is the sleeper insight for any lowering system. SMuFL says: **the primitive visual assets carry their own machine-readable connection semantics.** A notehead glyph doesn't just draw pixels — it *declares where a stem attaches, where its optical center is, and where its corners cut in for kerning*. The engine composes glyphs by reading anchors, so it stays **font-agnostic**: swap the font, the engraving still connects correctly. For your program-authored visual documents: give your rendering primitives *typed attachment/anchor/cut-out metadata* so the layout engine composes them geometrically without hard-coded per-asset offsets. It's the difference between "place the stem at x+3.2" (brittle) and "attach the stem to the notehead's `stemUpSE` anchor" (portable). The stable-codepoint-registry idea (with reserved gaps) is also a clean pattern for a **versioned, extensible symbol vocabulary** shared across independent producers/consumers.

**(4) What breaks.** SMuFL standardizes *glyph identity and per-glyph geometry* — it does **not** specify the layout/spacing/collision engine itself (that's still each application's job, or Behind Bars' rules). Coverage of fringe/contemporary/ethnic notations is incomplete (hence the optional-glyph tail and the reserved gaps). Font designers must correctly populate the metadata JSON; if anchors are missing or wrong, the engine falls back to guesses. And it lives in the PUA, so SMuFL text isn't portable *as text* outside SMuFL-aware software.

---

## 5. Verovio — a concrete MEI→SVG lowering engine (the "renderer" made real)

**(1) What it is.** A lightweight, dependency-free music-engraving *library* "designed for the Music Encoding Initiative" that turns semantic encodings into engraved notation ([book.verovio.org/introduction](https://book.verovio.org/introduction/)).

**(2)/(3) Model + transferable idea.** It ingests **MEI and MusicXML** (among others) and renders directly to **SVG**, using **SMuFL fonts** for glyphs ([book.verovio.org/advanced-topics/smufl](https://book.verovio.org/advanced-topics/smufl.html)). It's the working proof of the whole stack: *semantic model (MEI) + font-geometry standard (SMuFL) + engraving engine (Verovio) → vector output (SVG)*. Notably its SVG output retains the MEI `@xml:id`s, so **every rendered glyph is traceable back to the semantic element that produced it** — bidirectional intent↔pixel linkage, the same idea as MEI's facsimile zones but on the *output* side. The steal: emit your lowered visual output with **stable back-references to the semantic source elements**, so selection/editing/analysis on the rendered artifact maps back to intent.

**(4) What breaks.** It's an engraver, so it inherits the same ceiling — it makes automatic layout decisions that a professional may want to override, and complex/rare notation is weaker. (Detailed limitation pages not fetched this session — treat specifics as UNVERIFIED.)

---

## 6. "Engraving rules" as codified domain knowledge — *Behind Bars* and the craft-as-algorithm thesis

**(1) What it is.** The recognition that music engraving is a **body of expert craft knowledge** — centuries of hand-engraving convention — that a layout engine must encode. The canonical modern reference is **Elaine Gould, *Behind Bars: The Definitive Guide to Music Notation* (Faber Music)**, cited directly in LilyPond's own literature list ([lilypond.org essay/short-literature-list](https://lilypond.org/doc/v2.24/Documentation/essay/short-literature-list)). LilyPond describes the historical craft it's automating: sheet music was cut/stamped by hand into zinc/pewter plates, "requiring nearly perfect execution in one go," a skill needing ~5 years to master and ~5 more to excel ([essay/automated-engraving](https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving)).

**(2) How the knowledge is modeled — concrete rules from LilyPond's essay** ([essay/engraving-details](https://lilypond.org/doc/v2.24/Documentation/essay/engraving-details)):
- **Optical spacing depends on stem direction, not just noteheads.** "The eye notices the distance between note heads" *and* "the distance between consecutive stems." So an **up-stem/down-stem** pair must be spaced *farther apart*, and a **down-stem/up-stem** pair *closer together* — even though the notehead-to-notehead distance is nominally identical. A final up-stem gets extra room before a barline "to keep it from looking crowded"; a down-stem doesn't.
- **Line weights aren't uniform:** leger lines are drawn *thicker* than staff lines; an expert engraver *shortens* a leger line to let an accidental sit closer.
- **Optical size scaling:** smaller staves use proportionally heavier lines so the music stays legible — a per-size design decision, not a uniform scale.

**(3) Transferable idea.** The whole domain is a case study in **turning tacit expert aesthetic judgment into explicit, parameterized machine rules** — and in *where you draw the line*. The deep lesson: the rules are frequently **perceptual and contextual, not geometric** (space is a function of *what the eye perceives crowded*, not literal ink distance). If you're lowering intent→visual, the highest-value rules encode *human perception of the composition*, and the cleanest implementation expresses them as an **objective function over the whole layout** (LilyPond's ugliness score) rather than local placement formulas — because these rules interact (stem direction × barline proximity × accidental collision) in ways local rules can't reconcile.

**(4) What breaks.** Even with the craft fully codified, LilyPond's authors state flatly that "people cannot be replaced completely" ([essay/automated-engraving](https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving)) — final aesthetic judgment resists full automation, and *Behind Bars* itself is full of "it depends" cases where competent engravers disagree. The rules also conflict (satisfying spacing may worsen collision), which is exactly why the optimization-over-candidates framing beats a rule cascade, and why every one of these systems still exposes a manual-override escape hatch.

---

## Synthesis — the seven patterns worth stealing

1. **Hard semantic/visual split with the visual computed, not stored** (LilyPond, MEI): author against intent; layout is a *derived* artifact.
2. **Lowering as a phased pipeline** (LilyPond: parse → events → contexts → engravers → grobs → backend). Each phase has one job; the semantic side never holds coordinates.
3. **Layout by constrained optimization / cost minimization**, not imperative placement (LilyPond's "ugliness score"; springs-and-rods spacing) — because engraving rules interact and conflict.
4. **A three-layer model beats two:** intent (MEI editorial/variant) *above* logical content *above* presentation — one source, many audience-specific renderings.
5. **Presentation as an optional, ignorable channel** (MusicXML advisory `default-x/y`) so consumers choose fidelity-to-source vs. re-lowering.
6. **Primitives carry their own composition metadata** (SMuFL anchors/cut-outs) → the engine is asset/font-agnostic; no hard-coded offsets.
7. **Bidirectional intent↔pixel linkage** (MEI facsimile `zone`s in; Verovio `@xml:id` in the SVG out) so the rendered artifact maps back to meaning.

**Honest overall limit shared by all of them:** the last mile of aesthetic quality resists full automation, so every system ships a manual-override mechanism — and the richer the semantic/intent layer, the less of it survives the trip into mainstream production tooling.

**One sourcing caveat:** the seminal Nienhuys/Nieuwenhuizen LilyPond paper PDF wouldn't parse this session, so the architecture claims above are cited to LilyPond's official contributor/internals docs and the *Extending LilyPond* project docs (near-primary), not the paper itself. The SMuFL Spreadbury/Dorico provenance is from a Wikipedia search snippet, not a deep-fetched page — flagged UNVERIFIED.
