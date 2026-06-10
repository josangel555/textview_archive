# Performance profiling — signposts + Instruments

This app emits `os_signpost` intervals around the file open → render hot
path via `ViewerCore/Perf/PerfSignpost.swift`. Capture them with Instruments
(`xctrace`) to see exactly where the time goes for a source / editor / db /
csv / markdown open, on a *release* build of the real app — no `Date()`
probes, no test-target stand-ins.

## TL;DR

```bash
# 1. Build the signed app bundle (release).
bash scripts/build-rust-core.sh
bash scripts/build-app.sh                       # -> dist/TextView.app

# 2. Record a trace with signposts enabled. MDV_SIGNPOSTS=1 turns the
#    PerfSignpost facility on (it is a no-op otherwise).
# NOTE the explicit --instrument 'os_signpost': the stock Time Profiler
# template records ONLY Apple's PointsOfInterest signpost lane — without
# this flag your com.markdownviewer.* intervals are silently absent from
# the trace (verified 2026-06-10, TSK-598). Also: OSSignposter intervals
# are NOT persisted to the unified log store by default, so `log show`
# is NOT a fallback — the trace is the only record.
xcrun xctrace record \
  --template 'Time Profiler' \
  --instrument 'os_signpost' \
  --env MDV_SIGNPOSTS=1 \
  --launch -- dist/TextView.app/Contents/MacOS/MarkdownViewer \
  /path/to/file/to/open.swift

# 3. Open the resulting .trace in Instruments and read the
#    "os_signpost" / "Points of Interest" lane (see below).
open *.trace
```

Stop the recording from the Instruments UI (or Ctrl-C the `xctrace`
process) once you've reproduced the slow open.

## The master switch: `MDV_SIGNPOSTS=1`

`PerfSignpost` reads `MDV_SIGNPOSTS` **once** at first touch and caches it.

- **Unset (normal/release):** every `begin` / `end` / `withInterval` /
  `event` is a single branch-and-return. No `OSSignposter` is constructed,
  no signpost ID is minted, no Instruments lane appears. Zero overhead and
  zero surprise signpost spew for users who never asked for profiling.
- **`MDV_SIGNPOSTS=1`:** the facility lazily builds one `OSSignposter` per
  stage (category) and emits real intervals/events.

There is no Debug/Release `#if` — the gate is purely runtime env, so you can
profile a fully optimised release bundle (which is the build whose timings
actually matter).

## What's instrumented and where to read it

Signposts are grouped by **stage** — each stage is one `OSLog` *category*
under subsystem `com.markdownviewer.MarkdownViewer`, so Instruments lanes
them separately. In the "os_signpost" instrument, set the lane to the
subsystem and you'll see one row per category.

| Stage (category) | Interval / event name            | Where (file)                          | What it measures |
|------------------|----------------------------------|---------------------------------------|------------------|
| `open`           | `DocumentModel.openResolved`     | `ViewerUI/DocumentModel.swift`        | Whole user-facing open span (click → tab mounted). UI thread. |
| `categorize`     | `FileTypeDetector.category`      | `ViewerCore/DocumentController.swift` | Extension/UTI routing decision. |
| `load`           | `DocumentController.open`        | `ViewerCore/DocumentController.swift` | Loader read + `TextDecoder` decode (or the native-preview / binary routing that skips the read). |
| `load`           | event `route:native-preview`     | "                                     | Marks an image/audio/video/pdf/**sqlite** routed to a native viewer with **no** byte read. |
| `load`           | event `route:text-decode`        | "                                     | Marks entry into the text decode path. |
| `materialize`    | `materializeIfNeeded`            | `ViewerUI/DocumentModel.swift`        | Off-main lazy-tab read. Begins on the main actor, **ends in the detached read completion** — so the interval length is the background read latency. |
| `materialize`    | `openLargeFileOffMain`           | "                                     | Off-main read for files above the loader soft watermark. Same begin/end-across-Task shape. |
| `highlight`      | `TreeSitterEngine.tokenize`      | `ViewerCore/Highlight/TreeSitterEngine.swift` | Full tokenize (off the main thread via `HighlightCacheActor`). |
| `highlight`      | `ts.query-compile`               | "                                     | The **one-time per-language** `Query(language:data:)` compile — the bulk of cold-start tokenize cost. Present only on a cold (first-touch) tokenize. |
| `highlight`      | `ts.parse`                       | "                                     | TreeSitter parse. |
| `highlight`      | `ts.query-iterate`               | "                                     | Query execute + capture-collect loop. |
| `highlight`      | `ts.paintOver`                   | "                                     | Sweep-line overlap resolution (O(K log K) in run count). |
| `render`         | `SourceTextController.apply`     | `ViewerUI/TextDisplayView.swift`      | NSTextView attributed-string set + layout (the source-view paint). UI thread. |
| `render`         | `HTMLRenderer.render`            | `ViewerCore/HTMLRenderer.swift`       | Markdown → HTML visit (incl. per-code-fence tokenize). |
| `render`         | `WKWebView.loadToFinish`         | `ViewerUI/MarkdownRenderedView.swift` | The WebKit half of a rendered-MD open: `loadHTMLString` hand-off → WebContent parse/layout → `didFinish`. Spans processes; stitched by signpost ID. |
| `interact`       | `navSweep.tabSwitch` / `navSweep.sidebarToggle` / `navSweep.viewToggle` | `ViewerUI/Perf/NavSweep.swift` | Scripted navigation interactions (TSK-603; `nav-sweep` verb / `vm-profile.sh … nav`). The interval bounds the synchronous model call only — it is an ANCHOR; the SwiftUI re-render it triggers lands in the Time Profiler samples immediately after the interval. |

### Reading a source-file open

A typical cold source open shows, in time order:

```
open  | DocumentModel.openResolved  [=================================]
load  |   DocumentController.open    [==]                                (decode is cheap)
      |   event route:text-decode     |
highlight |        TreeSitterEngine.tokenize    [============]          (OFF main; overlaps)
          |          ts.query-compile  [=========]                       (cold only)
          |          ts.parse                    [=]
          |          ts.query-iterate             [==]
          |          ts.paintOver                   []
render |  SourceTextController.apply  [=]  ...then a SECOND apply [====]  (highlight arrived)
```

The two `render | SourceTextController.apply` intervals per open are the
plain-text first paint and the highlighted second paint. If the second one
is large (hundreds of ms on a few-hundred-KB file), that's the NSTextView
full-document layout — the dominant source-view cost. (The optimisation in
`applyAttributedString` keeps the plain→highlight transition to an
in-place attribute re-fix instead of a full `setAttributedString` rebuild,
so the second apply should be cheap when the text is byte-identical.)

### Reading an 8 KB `.db` open

`load | event route:native-preview` fires immediately and the `load`
interval is sub-millisecond — the `.db` goes straight to the SQLite browser
with **no** text read / decode / highlight. If you instead see
`route:text-decode` for a `.db`, the file was mis-routed (it should never
be decoded as text on a default open).

## Allocations / memory

To profile transient allocations (e.g. the markdown render pipeline's
multi-multiple-of-input spike, or a tokenize's run array):

```bash
xcrun xctrace record \
  --template 'Allocations' \
  --env MDV_SIGNPOSTS=1 \
  --launch -- dist/TextView.app/Contents/MacOS/MarkdownViewer \
  /path/to/file
```

The signpost intervals still record alongside the allocations track, so you
can correlate an allocation spike with the `highlight` / `render` interval
that caused it. For a combined view, add the "os_signpost" instrument to an
Allocations template (Instruments → add instrument) before recording.

## Custom template

The two stock templates above (`Time Profiler`, `Allocations`) already pull
in the points-of-interest / signpost track. If you want a focused template:

1. Instruments → File → New → blank.
2. Add **os_signpost** + **Time Profiler**.
3. In the os_signpost instrument's inspector, set Subsystem to
   `com.markdownviewer.MarkdownViewer`. Leave Category as "All" to see every
   stage, or pick one (`open` / `highlight` / `render` / …) to focus.
4. Save as `MDV-Hotpath.tracetemplate`; reuse via
   `xctrace record --template MDV-Hotpath …`.

## Notes

- The interval/event/category names above are an Instruments-facing
  contract. Renaming one is a doc-coupled change — update this table too.
- `materialize` intervals legitimately span a Task boundary (begin on the
  main actor, end in the detached completion). Instruments stitches them by
  signpost ID, so the displayed length is the real background latency, not
  main-thread time.
- The facility lives in **ViewerCore** (it's `os.signpost`, not SwiftUI), so
  both ViewerCore and the ViewerUI/app layers emit through the same API.
- This profiles the **built app** on a real WindowServer session — the
  honest target. Headless test-target timing probes measure logic-path cost
  but not the live AppKit layout / compositor cost; for the latter, profile
  `dist/TextView.app` as above (or use the VM lane).
