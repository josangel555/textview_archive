// Canvas M0 spike runtime (TSK-1353) — the JS half of the patch loop.
// Plain hand-written JS on purpose (no npm build in M0). One entry point
// (window.cvDispatch), one reply channel (mdvCanvas message handler) — the
// CM6 bridge discipline. Envelope: {v, type, ...} both directions.
(function () {
  "use strict";

  var PROTOCOL_VERSION = 1;
  var root = document.getElementById("cv-root");

  // Reply OUTBOX (M0.S3 finding): the VM's older WebKit (macOS 15)
  // intermittently DROPS script-message posts made from an eval-initiated
  // stack (~30% observed), while the eval itself runs fine. Every post is
  // therefore also appended here with a monotonic postId; the Swift host
  // drains missed entries by pull (`window.__cvDrain(after)`). Push stays
  // the fast path; the drain closes the reliability gap.
  var postSeq = 0;
  window.__cvOutbox = [];
  // M3.S1b transport fix: the drain RE-POSTS pending entries through the
  // script-message channel instead of RETURNING them via the eval result —
  // on the VM's older WebKit BOTH push posts (~30%) AND eval results drop,
  // so a drain that answers through eval-return is built on the channel it
  // exists to bypass. Re-posting gives each drain an independent retry
  // (geometric recovery); the Swift SET-dedup absorbs duplicates. Returns a
  // count (loss-tolerant).
  window.__cvDrain = function (after) {
    var n = 0;
    for (var i = 0; i < window.__cvOutbox.length && n < 16; i++) {
      var entry = window.__cvOutbox[i];
      if (entry.postId > after) {
        n += 1;
        try {
          window.webkit.messageHandlers.mdvCanvas.postMessage(entry.json);
        } catch (e) { /* next drain retries */ }
      }
    }
    return n;
  };

  function post(msg) {
    msg.v = PROTOCOL_VERSION;
    postSeq += 1;
    msg.postId = postSeq;
    var json = JSON.stringify(msg);
    window.__cvOutbox.push({ postId: postSeq, json: json });
    if (window.__cvOutbox.length > 256) window.__cvOutbox.shift();
    try {
      window.webkit.messageHandlers.mdvCanvas.postMessage(json);
    } catch (e) {
      // Host handler absent (plain browser) or post failed — the outbox
      // drain is the recovery path either way.
    }
  }

  function nodeById(id) {
    // Ids are numeric arena indices in M0; attribute-select by exact value.
    return root.querySelector('[data-cv-id="' + id + '"]');
  }

  // The 7 applier verbs (M1.S5c — the real engine's patch vocabulary).
  // insertNode/moveNode anchor on `before` (insertBefore semantics; absent =
  // append); fragments arrive as engine-lowered HTML strings.
  function applyPatches(patches) {
    var applied = 0;
    var missing = [];
    function parentAndAnchor(p) {
      var parent = nodeById(p.parent);
      if (!parent) return null;
      var anchor = null;
      if (p.before) {
        anchor = nodeById(p.before);
        if (!anchor || anchor.parentNode !== parent) anchor = null;
      }
      return { parent: parent, anchor: anchor };
    }
    for (var i = 0; i < patches.length; i++) {
      var p = patches[i];
      if (p.op === "insertNode") {
        var t = parentAndAnchor(p);
        if (!t) { missing.push(p.parent); continue; }
        var tpl = document.createElement("template");
        tpl.innerHTML = p.html;
        t.parent.insertBefore(tpl.content, t.anchor);
        applied += 1;
        continue;
      }
      if (p.op === "setTheme") {
        // Zero-op retheme (M4.S4): ID-LESS patch — handled BEFORE the
        // nodeById guard. Swap the theme block's custom props; every var()
        // reference repaints, no re-lower.
        var themeEl = document.getElementById("cv-theme");
        if (themeEl) { themeEl.textContent = ":root{" + p.css + "}"; applied += 1; }
        else { missing.push("cv-theme"); }
        continue;
      }
      var el = nodeById(p.id);
      if (!el) { missing.push(p.id); continue; }
      if (p.op === "setText") {
        el.textContent = p.text;
        applied += 1;
      } else if (p.op === "setStyle") {
        el.style.setProperty(p.prop, p.value);
        applied += 1;
      } else if (p.op === "removeStyle") {
        el.style.removeProperty(p.prop);
        applied += 1;
      } else if (p.op === "setAttr") {
        if (p.value === "") { el.removeAttribute(p.attr); }
        else { el.setAttribute(p.attr, p.value); }
        applied += 1;
      } else if (p.op === "removeNode") {
        el.parentNode && el.parentNode.removeChild(el);
        applied += 1;
      } else if (p.op === "replaceNode") {
        // Definition-edit re-render (M4.S1c): outerHTML swap in place.
        el.outerHTML = p.html;
        applied += 1;
      } else if (p.op === "moveNode") {
        var m = parentAndAnchor(p);
        if (!m) { missing.push(p.parent); continue; }
        m.parent.insertBefore(el, m.anchor);
        applied += 1;
      } else {
        missing.push(p.id);
      }
    }
    return { applied: applied, missing: missing };
  }

  function geometry(ids) {
    var boxes = [];
    for (var i = 0; i < ids.length; i++) {
      // Document-scoped (not root-scoped): the selection overlay lives on
      // document.body (root.innerHTML is wiped by setContent), and it must
      // be measurable through this same query (M3.S3 tests + inspector).
      var el = document.querySelector('[data-cv-id="' + ids[i] + '"]');
      if (!el) continue;
      var r = el.getBoundingClientRect();
      boxes.push({ id: ids[i], x: r.x, y: r.y, w: r.width, h: r.height });
    }
    return boxes;
  }

  // M3.S3 (TSK-1374) — selection: ONE absolutely-positioned overlay box,
  // repositioned over the selected node (never per-node borders, so
  // geometry queries stay clean). Addressable for tests via the
  // data-cv-id "cv-overlay" (outside the engine's nd:* space).
  var selectedId = null;
  var overlay = document.createElement("div");
  overlay.setAttribute("data-cv-id", "cv-overlay");
  overlay.style.cssText =
    "position:absolute;display:none;pointer-events:none;z-index:2147483646;" +
    "outline:2px solid #0a84ff;outline-offset:1px;border-radius:2px;";
  document.body.appendChild(overlay);

  function positionOverlay() {
    if (!selectedId) { overlay.style.display = "none"; return; }
    var el = nodeById(selectedId);
    if (!el) { overlay.style.display = "none"; return; }
    var r = el.getBoundingClientRect();
    // T5 negative control: deliberately mis-anchor when the committed
    // break switch is on (MDV_ENABLE_BROKEN_CANVAS_OVERLAY -> user script).
    var dx = window.__cvBrokenOverlay ? 120 : 0;
    overlay.style.left = (r.left + window.scrollX + dx) + "px";
    overlay.style.top = (r.top + window.scrollY) + "px";
    overlay.style.width = r.width + "px";
    overlay.style.height = r.height + "px";
    overlay.style.display = "block";
  }

  function setSelection(ids) {
    selectedId = (ids && ids.length) ? ids[0] : null;
    positionOverlay();
    syncDraggable();
  }

  // The overlay must stay GLUED through reflow (patch applies, window
  // resizes, content edits). ResizeObserver on the root + window resize.
  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(positionOverlay).observe(root);
  }
  window.addEventListener("resize", positionOverlay);

  // Click hit-test → nodeClicked intent. Swift owns selection state and
  // echoes setSelection back (one authority, no local-echo divergence).
  root.addEventListener("click", function (e) {
    var el = e.target && e.target.closest
      ? e.target.closest("[data-cv-id]")
      : null;
    if (!el || el === root) return;
    post({
      type: "nodeClicked",
      id: el.getAttribute("data-cv-id"),
      shift: !!e.shiftKey
    });
  });

  // M3.S5 (TSK-1376) — inline text editing. Edit MODE is view state (JS
  // owns entry/exit); the COMMIT is an intent (Swift owns the doc). Entry:
  // dblclick on a text node, or the programmatic setEditable command (the
  // S8 inspector's path). Commit: blur or Enter (never mid-IME-composition).
  // Escape reverts to the pre-edit text and exits WITHOUT posting.
  var editing = null; // { id, el, original }

  function enterEdit(el) {
    if (editing) commitEdit();
    var id = el.getAttribute("data-cv-id");
    editing = { id: id, el: el, original: el.textContent };
    el.setAttribute("contenteditable", "true");
    el.focus();
    var range = document.createRange();
    range.selectNodeContents(el);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function exitEdit() {
    if (!editing) return;
    editing.el.removeAttribute("contenteditable");
    editing = null;
  }

  function commitEdit() {
    if (!editing) return;
    var id = editing.id;
    var text = editing.el.textContent;
    var changed = text !== editing.original;
    exitEdit();
    if (changed) post({ type: "textEdited", id: id, text: text });
  }

  function revertEdit() {
    if (!editing) return;
    editing.el.textContent = editing.original;
    exitEdit();
  }

  root.addEventListener("dblclick", function (e) {
    var el = e.target && e.target.closest
      ? e.target.closest('[data-cv-kind="text"]')
      : null;
    if (!el) return;
    enterEdit(el);
    e.preventDefault();
  });

  // Commit on blur (click-away), commit on Enter, revert on Escape — but
  // NEVER commit mid-IME-composition (compositionend re-arms Enter).
  root.addEventListener("focusout", function (e) {
    if (editing && e.target === editing.el) commitEdit();
  });
  window.addEventListener("keydown", function (e) {
    if (!editing) return;
    if (e.isComposing) return; // IME guard: composition owns the keys
    if (e.key === "Enter" && !e.shiftKey) {
      commitEdit();
      e.preventDefault();
    } else if (e.key === "Escape") {
      revertEdit();
      e.preventDefault();
      // stopImmediatePropagation, not stopPropagation: the selection-Escape
      // handler lives on the SAME target (window), and plain stopPropagation
      // only blocks OTHER nodes — same-target listeners still fire.
      e.stopImmediatePropagation();
    }
  }, true); // capture: beat the selection-Escape handler below

  // M3.S6 (TSK-1377) — drag-reorder within the flow. The SELECTED node is
  // draggable; dragover computes the drop SLOT (before the hovered sibling
  // when the cursor is in its upper half, after otherwise; hovering a
  // container drops INTO it, appending); a thin indicator line previews the
  // slot; drop posts dragEnded{id, parent, beforeId} and Swift lowers it to
  // the engine's exact-anchor move (the S4 write path).
  var dragging = null; // the dragged node's id
  var dropSlot = null; // { parent, beforeId }
  var indicator = document.createElement("div");
  indicator.style.cssText =
    "position:absolute;display:none;pointer-events:none;z-index:2147483645;" +
    "height:2px;background:#0a84ff;border-radius:1px;";
  document.body.appendChild(indicator);

  function hideIndicator() {
    indicator.style.display = "none";
    dropSlot = null;
  }

  function showIndicatorAt(rect, before) {
    indicator.style.left = (rect.left + window.scrollX) + "px";
    indicator.style.width = rect.width + "px";
    indicator.style.top =
      ((before ? rect.top : rect.bottom) + window.scrollY - 1) + "px";
    indicator.style.display = "block";
  }

  function syncDraggable() {
    var nodes = root.querySelectorAll("[draggable]");
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].removeAttribute("draggable");
    }
    if (selectedId) {
      var el = nodeById(selectedId);
      if (el) el.setAttribute("draggable", "true");
    }
  }

  root.addEventListener("dragstart", function (e) {
    var el = e.target && e.target.closest
      ? e.target.closest("[data-cv-id]") : null;
    if (!el || el.getAttribute("data-cv-id") !== selectedId) {
      e.preventDefault();
      return;
    }
    dragging = selectedId;
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = "move";
      try { e.dataTransfer.setData("text/plain", dragging); } catch (err) {}
    }
  });

  root.addEventListener("dragover", function (e) {
    if (!dragging) return;
    e.preventDefault(); // allow drop
    var el = e.target && e.target.closest
      ? e.target.closest("[data-cv-id]") : null;
    if (!el) { hideIndicator(); return; }
    var hoveredId = el.getAttribute("data-cv-id");
    if (hoveredId === dragging) { hideIndicator(); return; }
    var rect = el.getBoundingClientRect();
    var isContainer = el.getAttribute("data-cv-kind") === "frame"
      || el.getAttribute("data-cv-kind") === "page";
    if (isContainer && el.contains(e.target) && e.target === el) {
      // Hovering the container's own surface: drop INTO (append).
      dropSlot = { parent: hoveredId, beforeId: null };
      showIndicatorAt(rect, false);
      return;
    }
    // Sibling slot: before/after by the cursor's vertical midpoint.
    var parentEl = el.parentElement && el.parentElement.closest
      ? el.parentElement.closest("[data-cv-id]") : null;
    if (!parentEl) { hideIndicator(); return; }
    var before = e.clientY < rect.top + rect.height / 2;
    var beforeId;
    if (before) {
      beforeId = hoveredId;
    } else {
      var next = el.nextElementSibling;
      beforeId = next && next.getAttribute
        ? next.getAttribute("data-cv-id") : null;
    }
    dropSlot = {
      parent: parentEl.getAttribute("data-cv-id"),
      beforeId: beforeId === dragging ? null : beforeId
    };
    showIndicatorAt(rect, before);
  });

  root.addEventListener("drop", function (e) {
    e.preventDefault();
    if (dragging && dropSlot) {
      var msg = { type: "dragEnded", id: dragging, parent: dropSlot.parent };
      if (dropSlot.beforeId) msg.beforeId = dropSlot.beforeId;
      post(msg);
    }
    dragging = null;
    hideIndicator();
  });

  root.addEventListener("dragend", function () {
    dragging = null;
    hideIndicator();
  });

  // Keyboard intents (Swift owns the semantics; JS only reports).
  window.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { post({ type: "escapePressed" }); return; }
    // Never steal keys from an active inline edit (S5 contenteditable).
    if (e.target && e.target.isContentEditable) return;
    if ((e.key === "Delete" || e.key === "Backspace") && selectedId) {
      post({ type: "deletePressed" });
      e.preventDefault();
      return;
    }
    if (e.key === "z" && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
      post({ type: "undoRequested" });
      e.preventDefault();
    }
  });

  window.cvDispatch = function (json) {
    var msg;
    try {
      msg = typeof json === "string" ? JSON.parse(json) : json;
    } catch (e) {
      post({ type: "error", message: "cvDispatch: unparseable message" });
      return;
    }
    if (!msg || typeof msg.v !== "number" || msg.v > PROTOCOL_VERSION) {
      post({ type: "error", message: "cvDispatch: unsupported version" });
      return;
    }
    switch (msg.type) {
      case "setContent": {
        root.innerHTML = msg.html;
        post({
          type: "contentSet",
          seq: msg.seq,
          nodeCount: root.querySelectorAll("[data-cv-id]").length,
          tsMs: performance.now()
        });
        break;
      }
      case "applyPatches": {
        var t0 = performance.now();
        var result = applyPatches(msg.patches || []);
        positionOverlay();
        post({
          type: "applied",
          seq: msg.seq,
          applied: result.applied,
          missing: result.missing,
          tsMs: performance.now(),
          applyMs: performance.now() - t0
        });
        break;
      }
      case "queryGeometry": {
        post({ type: "geometry", replyId: msg.replyId, boxes: geometry(msg.ids || []) });
        break;
      }
      case "setSelection": {
        setSelection(msg.ids || []);
        break;
      }
      case "clearSelection": {
        setSelection([]);
        break;
      }
      case "setEditable": {
        if (msg.on) {
          var target = nodeById(msg.id);
          if (target) enterEdit(target);
        } else {
          revertEdit(); // programmatic off = cancel semantics
        }
        break;
      }
      case "queryText": {
        // M0 test aid: read back one node's textContent so the E2E assert is
        // structural, not screenshot-based.
        var el = nodeById(msg.id);
        post({
          type: "text",
          replyId: msg.replyId,
          found: !!el,
          text: el ? el.textContent : null
        });
        break;
      }
      default:
        post({ type: "error", message: "cvDispatch: unknown type " + msg.type });
    }
    // WKError-5 dodge (the TSK-1047 class): older WebKit rejects an eval whose
    // result is `undefined` ("result of an unsupported type") — return a
    // serializable value so evaluateJavaScript always has one.
    return true;
  };

  post({ type: "ready", tsMs: performance.now() });
})();
