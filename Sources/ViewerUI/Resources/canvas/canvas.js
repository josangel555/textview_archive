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
  window.__cvDrain = function (after) {
    var out = [];
    for (var i = 0; i < window.__cvOutbox.length; i++) {
      var entry = window.__cvOutbox[i];
      if (entry.postId > after) out.push(entry.json);
    }
    return JSON.stringify(out);
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

  function applyPatches(patches) {
    var applied = 0;
    var missing = [];
    for (var i = 0; i < patches.length; i++) {
      var p = patches[i];
      var el = nodeById(p.id);
      if (!el) { missing.push(p.id); continue; }
      if (p.op === "setText") {
        el.textContent = p.text;
        applied += 1;
      } else if (p.op === "setStyle") {
        el.style.setProperty(p.key, p.value);
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
      var el = nodeById(ids[i]);
      if (!el) continue;
      var r = el.getBoundingClientRect();
      boxes.push({ id: ids[i], x: r.x, y: r.y, w: r.width, h: r.height });
    }
    return boxes;
  }

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
