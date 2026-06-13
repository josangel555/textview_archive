# Editor perf — TSK-791 "Was CM6 a mistake? Why is the editor so slow?"

Spike, 2026-06-13. Owner #1-priority complaint (user-felt editor slowness) + a
strategic question. Grounded in prior measurements + a fresh read of the
cm_apply FFI wire seam (`rust-core/crates/core/src/cm_edit.rs:95-143`).

## Answer: CM6 is not the architectural mistake. The slowness is three separable causes.

### 1. Typing latency — cm_apply ships the FULL doc across FFI per edit batch (TSK-543, S3) — the big one
- **What:** `mdvcore_cm_apply` is STATELESS. The Swift editor buffer is kept in
  sync by sending `{base: <whole doc>, edits:[…]}` to rust per ~200ms debounce
  batch and getting `{text: <whole doc>}` back (`apply_wire`). So the document
  bytes cross the FFI boundary **both ways, every batch**, scaling with doc size.
- TSK-561 already removed the rust-side *owned* copy (borrowed `Cow<str>`), but
  the bytes still cross. ~2× doc-size FFI traffic per keystroke-batch.
- **Fix (architectural, not a tweak):** a STATEFUL rust editor session (like the
  CSV session) — rust owns the doc mirror; Swift sends only the keystroke-sized
  edits and queries the text only when a consumer needs it, not every batch.
  This is the highest-leverage typing-latency win but a real redesign that
  touches the migration contract (the CMEditApplier twin + the sync model).

### 2. First-open latency — TreeSitter grammar query-compile (TSK-619)
- ~400ms on MAIN, one-time per grammar, measured. Felt as a stall when first
  opening a source file. Separable, smaller, already ticketed.

### 3. WebView mount cost — inherent to a WKWebView editor
- CM6 runs in a WKWebView; the mount/first-paint cost is structural. The
  pane-retention work (TSK-108/621) already mitigates *re*-mounts. Not a defect.

## Recommendation
Keep CM6 (it provides the rich editing surface; the slowness is addressable, not
inherent to the choice). Fix priority: **543 (typing) > 619 (first-open)**. Before
committing to 543's stateful redesign, run a fresh VM xctrace (`scripts/vm-profile.sh`,
editor-open + sustained-typing, `os_signpost`) to QUANTIFY the split (e.g. per-keystroke
ms and the cm_apply-FFI share in a large doc) — "measure don't guess" before a redesign.

## Owner decision (parked)
Whether to invest in 543's stateful-editor-session redesign now (the real typing-
latency fix) vs. accept current perf / reconsider the editor. Framed on TSK-791.
