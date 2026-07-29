# AUTONOMOUS_PROGRESS Ledger Learnings — Batch 3 (Lines 10001–14933)

**File:** archive/AUTONOMOUS_PROGRESS_2026-06-04_to_2026-07-02.md  
**Status:** Completed work ledger, archived post-2026-07-02 (9 days old; recent)  
**Content span:** Lines 10001–14933 (4,933 lines)  
**Work period:** 2026-06-10 through 2026-07-02 (~3+ weeks, drain waves 9–final + Canvas M3/M4)

---

## Quantitative Snapshot

| Metric | Count | Note |
|--------|-------|------|
| **Distinct work sessions (LOG entries)** | 275 | Roughly 1 per business day |
| **Items validated** | 260 | Hard evidence + gate green required |
| **Items held (honest gaps named)** | 37 | VM render / interaction / pixel / owner-eye |
| **Items bounced (mislabels)** | 9 | Primarily TSK-NNN vs built-in #NNN trap |
| **Items PARKED to owner** | 13 | Owner decisions or blocked gates |
| **Headless gate mentions** | 55 | Primary validation artifact |
| **Rust gate mentions** | 10 | Rust-core validation |
| **VM-lane mentions** | 414 | Heavy reliance on VM for final validation |

**Top recurring tickets (rework-arc indicators):**
- **TSK-649** (28×) — Soak testing; flipping engines default-ON post-Port (csv, indent, diff, hex, hexSearch)
- **TSK-580** (27×) — Thin-waist FFI envelope (`mdvcore_call`); universal production dispatch path
- **TSK-660** (26×) — TreeSitter grammar integration; Rust highlighter capability + stage-2 adapter
- **TSK-640** (21×) — LSP Code Actions (rename + picker); PARITY feature  
- **TSK-492** (20×) — Long-running (multi-tick), tied to engine ports / validation gates

These recurrences **are not failures — they are large, multi-stage features naturally tracked in daily ledgers.**

---

## Key Learnings from This Batch

### 1. **Validation-Ladder Discipline as Standard Practice**

Every commit (or group per ticket) runs through:
1. **Headless gate** — `swift test --filter` + `bash scripts/test-headless-gate.sh` (host-safe)
2. **Rust gate** — `bash scripts/rust-core-gate.sh` (Rust FFI boundary)
3. **VM full-suite** — `ssh macOS15 && bash scripts/test-in-vm.sh all` (T4 LiveAppTestCase, T5 PixelTestCase, WebView tiers)
4. **Honest gap registry** — If a gap exists (render pixel / interaction / owner-eye), it is **explicitly named and parked, not silenced.**

**Observation:** This creates tight feedback. When TSK-443 hit the bundle-size cap (63→48 MB limit on the 12 grammar C parsers), the team **immediately escalated to the owner with three carry options** rather than shipping blind or silently bumping. This is customer-obsession at work: never hide a constraint from the customer.

### 2. **The #NNN ↔ TSK-NNN Mislabel Trap (Systemic Pattern)**

Three mislabels surfaced in the fixed-lane drain (TSK-276, 279, 326):
- **Built-in TaskList numbering (#NNN)** collided with **board tickets (TSK-###).**
- An agent closed a ticket as "fixed" under work that was *actually* on the built-in item.
- **Symptom:** "Fixed, but the actual problem is still open."

**Cure:** Before validating any `fixed` item, **match the recorded work description against the board title.** A topic mismatch = `task_record → progress` + correction note.

**Port this:** In the greenfield build, establish **canonical ticket naming early** (board first; disable colliding alternate numbering schemes). The trap is a process failure, not a data bug.

### 3. **Honest Holds as Load-Bearing Gates**

The ledger tracks 37 held items, all with **named, actionable gaps:**
- **VM render gaps** (261, 268, 331, 324): "SwiftUI Button doesn't realize as NSView → headless test is a lie → VM pixel/owner-eye required"
- **Interaction gaps** (456, 457): "No automated drag-select test surface → VM T4 UAT or owner interaction test required"
- **Live validation** (619, 468): "Warmup mechanism host-pinned; improvement must be measured live on real load"
- **Owner decision** (270, 306, 322, 372): "Symptom reproduced; fix confirmed; owner one-glance on installed bundle to close"

**Key insight:** Holding at a gap is **not a failure — it's integrity.** The trap is holding silently (claiming "done" without evidence). This project **surfaced every gap, filed it, and moved on.**

### 4. **The ImageRenderer / Headless False-Green Class**

A recurring hazard:
- **`ImageRenderer` rasterizes SwiftUI in isolation** and draws a placeholder for `NSViewRepresentable` surfaces.
- **Result:** An occluded SwiftUI view (hidden behind a layer-backed AppKit surface) renders perfectly under `ImageRenderer` but is black on screen.
- **Lesson:** "Renders green in `ImageRenderer`" ≠ "Visible on screen." The only authority is WindowServer pixels (T5 / `screencapture`).

**Corollary (TSK-488):** The terminal-tab-strip miss was caught FOUR TIMES because the symptom (no tabs) looked like a compositor occlusion bug, but the evidence changed each time (`ImageRenderer` false-green kept papering over it until the real pixel test ran).

**Port this:** Document this trap in the greenfield's TEST_PYRAMID.md. Flag it in code review whenever a SwiftUI+AppKit layout test goes green headlessly. The remedy: **run the pixel test; if you can't, hold and name the gap.**

### 5. **VM Validation is the DEFAULT, Not Optional**

414 VM-lane mentions across this ledger. The pattern:
- Host-testable work (model, logic, FFI) validates headless.
- **Rendered/interactive work (CM6 pixels, button tap, tree expand, picker UX) REQUIRES the VM.**
- VM is not "owner's lane" — it's part of **the standard validation contract.**

A telling quote: **"Held at review (not validated) — the picker VIEW render (panel/loading/rows) is SwiftUI → VM/T5 pixel tail."** This is not a handoff to the owner; it's a **named gap in the agent's scope (pixels)** that the agent acknowledges before moving on.

**Port this:** In the greenfield build, **treat VM runs as the default for UI work.** The gate script (`test-in-vm.sh`) is already battle-tested. Bake it into the ticket acceptance criteria: "render changes need T4/T5 on the VM."

### 6. **Thin-Waist FFI (TSK-580) as the Production Dispatch Contract**

Over 27 entries, TSK-580 progressively consolidated **all Rust methods into a single `mdvcore_call()` envelope:**
```
mdvcore_call(METHOD_ID, req_frame, aux_buffer, out_buffer)
```

**Benefits realized:**
- One symbol to maintain across language boundaries.
- **Auxiliary input (`aux`) and output (`out`) side-channels** for bulk data (filesearch buffer, grammar output).
- **Remote-core ready:** ABI is stable and wire-transportable (the endpoint for the next greenfield's "remote core" goal).

**Pattern observed:** The team didn't ship the envelope all at once. Instead:
- Slice 1: Stateless methods → envelope route
- Slice 2: Add aux input (hex_search)
- Slice 3: Add output channel (raw_output methods deferred)

**Port this:** Design the FFI contract as a **future wire protocol, not just a C bridge.** Envelope early; batch conversions into slices (one method class per slice). This unblocks remote execution without a flag-day refactor.

### 7. **Stage Gates and Owner-Gated Pauses as Execution Pattern**

The canvas work (M1–M4) and the Rust-port soak (TSK-649) both used **explicit stage gates:**

**Soak example (TSK-649):**
- Stage A: All engines on the Rust side, Swift fallbacks in place
- Stage B: Flip engines default-ON one per ticket (csv, indent, diff, hex)
- **Gate between:** Wait for soak data + owner sign-off before next cohort

**Result:** Each flip was independent, tested, and had explicit undo semantics. If an engine misbehaved, only that flip regressed — the others stayed solid.

**Canvas example (TSK-1372–1385, M0–M6):**
- M0–M2: Local WYSIWYG, controller, selection overlay ✅
- **Owner review gate** (M3 green, M4 design)
- M4–M6: Claude-Design surface (MCP abstraction), remaining pieces

**Port this:** Use **explicit stage gates in the greenfield planning.** Don't ship features as "finished"; ship them as "stage N complete, stage N+1 paused at owner review." This lets the owner see progress without forcing a "done/not done" binary.

### 8. **Rust Migration Policy: Bugfix-Only on Swift Twins**

Entries repeatedly note:
- **Ports completed:** Hex, HexSearch, Find, Fuzzy, Transcript, Indent, Diff, Highlight (Rust side stable)
- **Swift twins:** Explicitly treated as "bugfix-only" — no perf work, refactors, or new features.
- **Reason:** Every change to the Swift engine would need to be **shadow-ported to Rust**, doubling effort.

**Observation:** This discipline stuck. No "let me optimize the Swift hex render while we wait for Rust" tangents. The team drained user-facing bugs from the Swift side, then **moved the entire lane to Rust.**

**Port this:** When porting an engine to Rust, cut the Swift version off from forward work **on day one.** Explicitly park new features on the Rust side. This prevents the "both codebases drift" trap.

---

## Decision Records Found

### **D1: Bundle Size Threshold for Grammar Parsers (TSK-660 stage 2, parked to owner)**

**Context:** The first 12 tree-sitter grammar C parsers, when statically linked, grew the exec from 26→43 MB (within the 65 MB cap), but the bundle swelled to 63 MB (vs 48 MB limit).

**Options recorded:**
1. **Transient bump** — Raise the 48 MB bundle cap (precedent: 25→48 already; owner bumped exec to 65).
2. **Dlopen dylib** — Link grammars as separate dylibs, loaded on-demand.
3. **Feature-off-in-app** — Ship without grammar support in the shipped app (support behind a debug flag).

**Status:** PARKED to owner. Stage 3 (10 more grammars) and stage 4 (Swift deletion, reclaims double-carry) queued behind the decision.

**Port this:** **Codify bundle budgets early** (main-exec, total bundle, per-framework). Make the tradeoff explicit before work blocks: static-link = speed but size; dylib = slower load but shipping flexibility.

---

### **D2: Zoom Preference: Unified or Split by Surface? (TSK-322, parked to owner)**

**Finding:** The drain caught TSK-322 and TSK-321 **falsely sitting at fixed.** They contained an agent "resolved by design" close that contradicted the **owner's intent.**

**Background:** The owner has **UserDefaults.zoom** (unified). The agent "resolved" the split-per-surface option in code but never filed the decision.

**Parked with options:**
1. Keep unified (status quo)
2. Full split (zoom per surface type)
3. Hybrid (persist unified, allow per-session override)

**Port this:** Don't resolve design ambiguities "by design" in code without an explicit ticket decision. If a ticket sits at "fixed" with work that contradicts a prior owner directive, **bounce it back with the contradiction named.**

---

### **D3: LSP-Driven Code-Action Execution Model (TSK-640 stage 2, validated but with noted scope)**

**Decision made (implicit):** The team builds an **interactive Code-Action picker** but does NOT execute server commands:
- **Edit-bearing actions** are applied locally to the buffer.
- **Command-only actions** are listed but disabled (user cannot execute arbitrary commands via LSP).

**Rationale:** The viewer is for reading + local editing. Server commands (format, refactor on server, etc.) are out of scope.

**Evidence:** 7 host tests pinned the state machine; `canRequestCodeActions` gates on LSP-language + cursor. VM pixel tail noted as the render gap.

**Port this:** Document the server-command boundary early. Make it **an explicit product decision, not a silent omission.** Future work (agent co-editing, walkthroughs) might revise this.

---

### **D4: Preview Tab Restoration: Isolation vs Memory (TSK-743/744 pair resolution)**

**Problem:** Two tickets pairing a feature request (TSK-743: "remember my scroll position per file in the preview tab") with a bug fix (TSK-744: "don't inherit the prior file's position").

**False "ambiguity":** The drain found 744 fixed but 743 untouched, with the closing note claiming "ambiguous." It wasn't.

**Resolution (TSK-743, self-implemented):** Built the **FIFO-bounded (64-entry) per-URL preview state store:**
- On file swap: stash(prior-url) → reset(isolation) → restore(current-url if seen before)
- Never-previewed = stays reset (isolation preserved). Re-visited = position restored (memory preserved).

**Result:** Both properties (isolation + memory) coexist. The feature request was implemented; the bug fix stayed fixed.

**Port this:** If a ticket sits with "ambiguous next step," **investigate before parking.** Ambiguity often hides a coherent solution; the prior decision just wasn't made explicit.

---

## Portable-Artifact Candidates

### **1. Validation-Gate Template (HIGHEST PRIORITY)**

**What:** The three-gate ladder (headless + rust + VM full-suite) as a **reusable shell script and CI gate definition.**

**Current state:** Scattered across:
- `scripts/test-headless-gate.sh` (host-safe, primary gate)
- `scripts/rust-core-gate.sh` (Rust boundary)
- `scripts/test-in-vm.sh` (VM heavy-tier orchestration)
- `.github/workflows/pr.yml` + `nightly-vm.yml` (CI pipeline)

**Portable value:** This is the **production validation pattern** that kept the project safe through 8 weeks of intense work. The greenfield can adopt it verbatim.

**Carry forward as:** PORT — Copy the gate scripts, the `TierGateObserver` sentinel pattern, and the `.github` workflow structure.

---

### **2. Honest-Gap Registry (Test Evidence Template)**

**What:** The structured holds in the ledger encode a **test-gap classification:**

| Gap Type | Example | Evidence Required |
|----------|---------|-------------------|
| Render (pixel) | TSK-261 tab-strip divider visibility | T5 screencapture on VM |
| Interaction | TSK-456 drag-select on HexView | VM T4 real-event test |
| Live-validation | TSK-619 TreeSitter warmup time | `Signpost` measurements on live app |
| Owner-eye | TSK-270 "file open feels slow" | Owner installed-bundle one-glance |

**Portable value:** This codifies the **when to hold vs. when to fake** decision. Future agents can reference it.

**Carry forward as:** PORT — Document as `TEST_PYRAMID.md` §Gap Classification; link to per-surface test-matrix.

---

### **3. Thin-Waist FFI Contract (Architecture Template)**

**What:** The `mdvcore_call` envelope design and its stage-wise rollout.

**Current form:**
```c
int mdvcore_call(
  MDV_MethodID method,
  const uint8_t* req,    // Request frame (max 16 MiB)
  const uint8_t* aux,    // Auxiliary input (zero-copy, unbounded)
  uint8_t* out           // Output buffer (allocated by caller)
);
```

**Staged conversions:**
- Slice 1: Stateless methods
- Slice 2: Methods with aux input (e.g., hex_search)
- Slice 3: Methods with raw output (e.g., hex_render, deferred)

**Portable value:** This is the **blueprint for the next greenfield's "remote core" goal.** The envelope is ABI-stable and already handles wire transport.

**Carry forward as:** DISTILL — Document the design rationale and slice-wise conversion strategy in `docs/FFI_ARCHITECTURE.md`. Include the aux/out side-channel pattern and the symbol-consolidation benefits.

---

### **4. VM Validation Harness (CI/Test Infrastructure)**

**What:** The `test-in-vm.sh` script and its supporting infrastructure.

**Current features:**
- SSH to UTM VM (`macOS15`)
- `rsync` with excludes (`.build/`, `dist/`, `.git/objects/pack/`)
- Toolchain selection (Swift 6.3 for tests, 6.1.2 for app)
- GUI lane setup (`MDV_VM_GUI_SESSION=1`, `MDV_VM_SUDO_PASS=<vm-sudo-password>`)
- Full-suite orchestration (build + test + JUnit output)

**Portable value:** Saves the greenfield team ~2–3 weeks of "how do we run UI tests headlessly?" infrastructure work.

**Carry forward as:** PORT — Copy the script, the rsync patterns, and the `.github/workflows/nightly-vm.yml` setup. Adapt for the greenfield's project name.

---

### **5. Stage-Gated Feature Rollout (Planning Template)**

**What:** The explicit stage gates (Stage A → owner review → Stage B → ...) used for soak testing (TSK-649) and canvas (M0–M6).

**Pattern:** Each stage is:
- **Independent:** Can be shipped, tested, and reviewed in isolation.
- **Undoable:** No forward dependency on the next stage's completion.
- **Owner-visible:** Progress is clear without "finished/not finished" binary.

**Example (Soak):**
- **A:** All engines ported, Swift fallbacks in place ✅
- **B:** Flip default-ON per engine (csv, indent, diff, hex, hexSearch), one per change
- **Owner gate:** Soak data + feedback before B is live

**Portable value:** Reduces feature-review friction and lets agents make progress without blocking on owner decisions.

**Carry forward as:** DISTILL — Document as `FEATURE_STAGING_PATTERN.md` with examples (soak, canvas, future features). Include the "stage independence" rule and the owner-review gate placement.

---

### **6. Mislabel-Trap Prevention (Process Doc)**

**What:** The #NNN ↔ TSK-NNN collision pattern and the fix.

**Current form:**
- Problem: Agent closes a ticket as "fixed" for work that was actually on a built-in item.
- Cure: Before validating any `fixed`, match the recorded work against the board title.
- Test: `ContextBudgetTests` (if implemented) could flag title/work mismatches.

**Portable value:** This is a **process failure that costs hours.** Documenting it prevents recurrence.

**Carry forward as:** DISTILL — Add to `CLAUDE.md` §Ticket validation discipline or `TEST_PYRAMID.md` §Validation gates. Include the specific check ("read the latest board ticket before marking fixed").

---

### **7. Bundle & Exec Budget Tracking (Infrastructure)**

**What:** The `scripts/check-bundle-size.sh` script with dual caps (bundle + main-exec).

**Current state:**
- **Total bundle:** 80 MB (default, adjusted for canvas + grammars)
- **Main exec:** 65 MB (bumped from 60 MB for grammar C parsers + Rust growth)
- **CI gate:** Fails if either threshold is exceeded.

**Tracked via:** Explicit budget files (TSK-660 decision, TSK-1214 owner-felt impact).

**Portable value:** Prevents silent bloat (a real trap the project hit). The greenfield can adopt the same dual-cap approach.

**Carry forward as:** PORT — Copy the script and integrate it into the merge gate. Keep the caps visible in CLAUDE.md with a comment on why each was bumped (date + TSK).

---

## Cadence & Effort Distribution

| Phase | Dates | Primary Work | Evidence |
|-------|-------|--------------|----------|
| **Drain (S3/S4 audit reconciliation)** | 2026-06-10 to 2026-06-11 | Validation of ~50 fixed-lane items, gap classification, mislabel sweeps | LOG +200 to +221; 20× TSK validated, 37 honest holds, 9 bounced |
| **Port completion & soak rounds** | 2026-06-12 to 2026-06-13 | TreeSitter integration (TSK-660), find/fuzzy/transcript adapters (TSK-645/646/647), hex_search FFI slice (TSK-580), LSP Code Actions (TSK-640) | 414 VM-lane mentions; 55 headless gates; 10 rust gates |
| **Fixed-lane residual + owner-gated clusters** | 2026-06-13 to 2026-06-20 | Performance investigation (TSK-791), perf cluster supervision (TSK-591/592/598), visual-hold batch (TSK-261/268/331) | Owner decisions parked (DECISIONS NEEDED doc updated) |
| **Canvas M0–M6 + Claude-Design lane** | 2026-06-24 to 2026-07-02 | Canvas WYSIWYG (M3 complete), Claude-Design brief lane (M4.S6, 10/10 complete, 0% escape rate) | UAT-M3 25/25 green; design-doc sprint; Mermaid canvas rendering |

**Key observation:** The project **never idled.** When the fixed-lane drained, the team pivoted to the next priority (perf, canvas, design). The board remained actionable (BACKLOG.md feeding decisions).

---

## Summary for Greenfield

**These 4,933 lines encode ~3 weeks of tight, iterative work across:**
1. Validation discipline (three-gate ladder, honest gaps)
2. Large feature completion (ports complete, soak rolling, canvas WYSIWYG)
3. Owner decision velocity (stage gates, parked clusters, DECISIONS NEEDED tracking)
4. Process tightening (mislabel trap catch, test-fixture lessons, FFI envelope progress)

**The portability high-water marks:**
- **Validation-gate scripts** (scripts/ + .github/workflows) — copy verbatim
- **VM harness** (test-in-vm.sh, rsync patterns) — adapt by project name
- **FFI envelope design** — architectural blueprint for remote-core
- **Stage-gated rollout pattern** — planning template for future features
- **Bundle/exec budget tracking** — CI gate + CLAUDE.md duality

**The process lessons (DISTILL):**
- Honest-gap classification (when to hold, when to fake)
- Mislabel-trap prevention (title/work match before "fixed")
- Rust migration policy (bugfix-only on Swift twins)
- Owner-decision velocity (stage gates, parked clusters, no blocking on ambiguity)

**Avoid (SKIP):**
- Per-ticket validation ceremonies (the project moved to batch gates + lane consolidation)
- Overly granular task tracking (the 275 LOG entries span ~4,933 lines; not every edit)
- Silent feature/scope creep (every gap is named; every decision is parked or recorded)
