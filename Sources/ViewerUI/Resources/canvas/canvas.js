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
    for (var i = 0; i < window.__cvOutbox.length; i++) {
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
    overlay.style.left = (r.left + window.scrollX) + "px";
    overlay.style.top = (r.top + window.scrollY) + "px";
    overlay.style.width = r.width + "px";
    overlay.style.height = r.height + "px";
    overlay.style.display = "block";
  }

  function setSelection(ids) {
    selectedId = (ids && ids.length) ? ids[0] : null;
    positionOverlay();
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
