# Feature exploration — Jupyter notebooks, browser tab, and the 2026-06-16 wishlist

Captures a design discussion (2026-06-16) on a batch of larger features, with the
deep-dive focused on **executable Jupyter notebooks**. Tracks effort, dependency
implications (every new dep needs owner approval), and what reuses existing
subsystems. Board epics are linked at the bottom.

---

## 0. Sandboxing context (relevant to the risky features)

The app is **deliberately not sandboxed** (DESIGN §8 locked decision: non-sandboxed
dev builds + **DMG-direct distribution**, chosen to avoid App Sandbox's friction with
arbitrary file/folder access; App Store would force the sandbox, DMG-direct doesn't).
Reinforced by what the app grew into: PTY terminal, spawning git/ffmpeg/LSP/(soon)tmux,
arbitrary-repo access, plugin subprocesses.

**Can we sandbox *part* of the app?** The *main process* is all-or-nothing
(`com.apple.security.app-sandbox` is per-process), **but** you can confine a *child*
process independently: an **XPC service** (its own entitlements) or a spawned helper
that calls `sandbox_init()` with a restrictive SBPL profile. Direction matters: an
**unsandboxed parent can spawn a more-sandboxed child** (✓); a sandboxed parent's
children inherit and can't loosen (✗). So our unsandboxed app is well-positioned to
confine the *executor* of risky features (Jupyter kernel, plugins, future VST host)
without sandboxing the whole app. (A profile isn't a VM — true untrusted-code isolation
is still hard — but it's the right tool for confining our own spawned interpreters.)

---

## 1. Jupyter notebooks (executable) — the deep dive  ·  epic **TSK-717**

Goal: a real notebook surface (cells, Python kernel, execution, rich output, cached
output, rerun-from-middle), **talking to a host kernel** (the user's Python/venv).

### 1.1 External vs ours — and the "we just run the kernel" nuance

Kernel, venv, pip/conda packages are **100% external/host-side** — we never bundle
Python or any package. **But** the bare kernel speaks **ZeroMQ**, while any web UI speaks
**WebSocket**, so the external thing we run is a **bridge server that manages kernels**,
not the raw kernel:

- **`jupyter-server`** — full server; `@jupyterlab/services` is built against it →
  the most robust backend. (We use only its kernels API; its notebook UI is ignored.)
- **`jupyter-kernel-gateway`** — leaner, kernels-only over WebSocket/REST, purpose-built
  for programmatic embed. BUT JupyterLab 4.x broke its gateway client path
  (jupyterlab#14977) — **verify gateway compat in the spike**; default to `jupyter-server`.

The kernel itself runs in **the user's chosen venv with their packages** (same model as
picking an `ffmpeg` on PATH). Our footprint = the front-end JS we vendor + spawn/wiring code.

### 1.2 The front-end architectures (with vendored bundle sizes)

| Option | What | Vendored JS | Backend | Who builds the notebook UI |
|---|---|---|---|---|
| **A. Primitives** | `@jupyterlab/services` + `rendermime` + `outputarea` + **our CM6** + KaTeX | **~0.3–0.5 MB gz** (services confirmed 157 KB min / **38 KB gz**, 11 deps) | jupyter-server | **You** (cell shell + run/output orchestration; CM6 = cell editor only) |
| **B. Embed installed JupyterLab/Notebook** | load `http://localhost:port/lab?token=…` in a WKWebView | **0** (uses the user's install) | jupyter-server | Jupyter (prebuilt) |
| **C. Thebe** → server | the `thebe` browser bundle (its own CodeMirror + services + outputarea) | **~1–3 MB** min | jupyter-server (or `thebe-lite`→Pyodide) | Mostly Thebe |
| **D. JupyterLite + Pyodide** | in-browser WASM kernel | **Pyodide ≈ 200+ MB** (can't vendor offline) | none (in-browser) | Jupyter |

**Discards / why:**
- **D (JupyterLite/Pyodide)** is **out** for a desktop bundle: Pyodide is 200+ MB
  (can't vendor within the 48 MB cap), and it's a *different* model (in-browser kernel —
  no raw sockets, 2–4 GB/tab, Pyodide-only packages, ephemeral FS). Not our host-kernel goal.
  Also: **JupyterLite + remote gateway is not a supported combo** (community wish / 3rd-party
  extension only) — JupyterLite *is* the no-server variant.
- **C ships heavy** if you load `thebe-lite` (drags Pyodide). Point plain Thebe at the server.

### 1.3 The CM6 reality in Option A

Option A reuses CM6 only as the **cell editor**. You still hand-build the **notebook
shell** in the WebView: the cell list (add/delete/reorder), run buttons/toolbar,
execution-count gutter, and the `run → execute_request → stream outputs → rendermime →
output <div>` orchestration + busy/idle state. That shell is the *bulk* of the UI work.
So "CM6 fits" is true but narrow — it's the editor box, not the notebook app.

### 1.4 Embed (Option B) — what you give up, and does it render?

**Render:** best-guess **yes** — JupyterLab is a modern web app and WKWebView *is*
current WebKit (Safari). Concrete things to handle in the spike: an **ATS exception for
http/ws to localhost** (non-TLS), service-worker/clipboard/popup quirks, token/cookie
handling, intercepted keyboard shortcuts. (JupyterLite's COOP/COEP+service-worker needs
are *not* in play for server-backed Lab.)

**What you give up vs a native (Option A) notebook:**
- **Integration / native feel** — it's Jupyter's whole UI (its menus, command palette,
  file browser, settings) in a webview; doesn't match your chrome/tabs/theme/keybindings.
  Two command palettes, two shortcut sets (⌘S/⌘F/⌘P conflicts).
- **Your features don't apply** — your CM6 config, **vim mode**, themes, find bar, LSP,
  status bar; Jupyter brings its own editor instance/config.
- **Tab/session model** — the notebook lives in one webview tab; your per-tab
  session/scroll/state, workspace restore, hot-exit don't see individual notebooks/cells.
- **File handling** — Jupyter owns save/dirty/checkpoint (its `DocumentModel`, not yours)
  → two sources of truth for "dirty"; your save pipeline / external-rename-follow bypass it.
- **Theming** — light/dark sync is manual (drive Jupyter's theme).
- **Coupling/surface** — depends on the user's installed Lab version + quirks; a full Lab
  also exposes a terminal + file browser + extensions (more surface; mitigate via server
  config: disable terminals, set `root_dir`, token). Slower first paint (full server).

**What you gain:** ~zero build, full features (widgets, debugger, extensions), always current.

### 1.5 What else is needed (beyond kernel + front-end libs)

1. **The bridge server** — `jupyter-server` (external, pip). *The* "something else."
2. **Auth + origin** — pass the server token from the WebView; ATS localhost exception; CORS.
3. **Math typesetter** — `rendermime` LaTeX needs MathJax (~1 MB) or **KaTeX** (lighter; pick this).
4. **`.ipynb` document model** — read/write notebook JSON (cells + cached outputs), dirty,
   tab/session integration. ("Cache output" persists here; "rerun-from-middle" is free once
   the kernel holds state.)
5. **Notebook/output CSS** — vendor JupyterLab's output-area stylesheet.
6. **Process lifecycle** — discover/spawn/health/interrupt/restart/shutdown (we have the
   PTY/ffmpeg/LSP pattern).
7. *(Optional, heavy)* **ipywidgets** (`@jupyter-widgets/*`) — skip in v1.

### 1.6 Recommendation + open questions

- **Spike BOTH ends** before committing: (B) embed installed Lab in a webview vs (A) a
  one-cell primitives page executing against a real kernel — to feel **integration vs
  build-cost** and get the **real bundle/dep numbers**. The **localhost browser tab
  (TSK-676)** is the natural vehicle for the (B) spike.
- **Dep gate (owner):** Option A needs the `@jupyterlab/*` packages + KaTeX (sizable
  transitive tree — bigger supply-chain surface than `@replit/codemirror-vim`). Approval required.
- **Effort:** **L** (was XL before the web-UI insight — the kernel protocol + output
  rendering are outsourced to Jupyter's stack).
- Open: which backend (server vs gateway — pending #14977 check); how much of the multi-kernel
  (Python+Kotlin) TSK-717 scope to take in v1 (start Python-only).

---

## 2. Built-in / localhost browser tab  ·  epic **TSK-676**

Owner ask (2026-06-16): **New Tab → Browser** — a WKWebView tab with a URL, **locked to
localhost + its dependencies** ("dangerously load websites" gated behind the allowlist).

- **Near-buildable (S–M MVP)** — the app already hosts WKWebViews. Work = a URL/browser
  tab type + a `WKNavigationDelegate` enforcing an allowlist.
- **Design questions (the spike):**
  1. **Navigation policy** — top-level nav restricted to `localhost`/`127.0.0.1`/`::1`.
  2. **"localhost dependencies" policy** — may a localhost page pull sub-resources from
     off-host (CDN scripts/fonts)? *strict* (block all off-host) breaks some apps;
     *permissive* (allow sub-resources, block top-level nav away) is the usual safe middle.
     **Owner to choose.**
  3. **ATS exception** for http/ws to localhost.
  4. JS on; cookie / 3rd-party policy (this epic already says block 3rd-party cookies);
     no `file://` access.
- **Key link:** this tab type is the clean **enabler for embedding Jupyter (Option B)** —
  and any localhost dev tool — with ~zero feature-specific code.

---

## 3. The rest of the wishlist (feasibility overview)

Effort = rough T-shirt for a focused dev. "Dep?" = needs owner dependency approval.

| Feature | Epic | Effort | Dep? | Reuses | Hardest part |
|---|---|---|---|---|---|
| **Snippets** | TSK-705 | **~done** | no | already built (`ViewerCore/Snippets/*`) | — |
| **Universal Paste** | **TSK-958** | M | no | NSPasteboard + image/table/text viewers | type-precedence matrix |
| **RSS Reader** | **TSK-955** | M | no | tool-window + JSON store + WKWebView | feed-format variety, refresh |
| **Macros** | **TSK-957** | M–L | no | CommandRegistry + vim macros | safe record/replay set |
| **Docx/Xlsx (read)** | TSK-682 | L | **yes** (Rust crates) | rust-core + table/HTML views | OOXML fidelity |
| **tmux `-CC`** | TSK-690 | L–XL | no (external tmux) | PTY terminal + SplitPaneView | control-mode protocol + layout mapping |
| **AU + MIDI** | **TSK-956** | L–XL | no (native) | AVAudioEngine | real-time graph; **VST = separate/avoid** |
| **Jupyter Notebook** | TSK-717 | L | **yes** (`@jupyterlab/*`) | .ipynb read + webview output | the architecture choice (§1) |

Notes:
- **Snippets is shipped** (TSK-705); only **Macros** (TSK-957) is net-new on that front.
- **VST** is the trap in TSK-956: no native macOS support → Steinberg VST3 SDK
  (GPLv3/proprietary) or a JUCE bridge (heavy C++ + bundle-cap) → owner decision; do **AU + MIDI** first.
- **Docx/Xlsx** = do it in **rust-core** (`calamine` for xlsx → existing table viewer;
  `zip`+`quick-xml` for docx → HTML), read-only; write/edit is XL (defer). TSK-680 covers MD→docx *export* separately.

---

## 4. Board epics filed / enriched (2026-06-16)

- **TSK-717** — Notebooks (Python kernel) — *enriched* with the §1 architecture spike.
- **TSK-676** — Built-in / localhost browser tab — *enriched* with the §2 design + Jupyter-enabler link.
- **TSK-690** — tmux `-CC` — *enriched* with the spike scope.
- **TSK-682** — View DOCX/XLSX/RTF/PDF — *enriched* with the rust-core approach + dep gate.
- **TSK-955** — RSS / Atom reader — *new*.
- **TSK-956** — AU hosting + CoreMIDI (+ VST decision) — *new*.
- **TSK-957** — Editor Macros (record/replay) — *new*.
- **TSK-958** — Universal Paste (multi-type dispatcher; broadens TSK-935) — *new*.
- Related: TSK-705 (Snippets, done), TSK-935 (paste→scratch), TSK-680 (MD→docx export),
  TSK-361 (large-.ipynb hang), TSK-635 (rendered-MD subresource default-deny — reuse for RSS).

---

## 5. Sources (research 2026-06-16)

- JupyterLab `services`/`rendermime`/`outputarea` — npm + API docs (transport 38 KB gz).
- Thebe — github.com/jupyter-book/thebe, thebe.readthedocs.io (packages: thebe / thebe-core / thebe-lite / thebe-react).
- Datalayer jupyter-ui / jupyter-react (ships Pyodide → heavy).
- Jupyter Kernel Gateway docs (websocket mode); jupyterlab#14977 (Lab4 broke gateway client).
- JupyterLite + jupyterlite/pyodide-kernel; Pyodide downloading/deploying (full ≈ 200+ MB).
- jupyterlab-katex (swap MathJax→KaTeX).
