import Foundation

/// TSK-1183 — the JS side of the rendered-MD DOM-patch apply path. A single
/// source of truth for the `applyBlockPatch` routine: the WebViewTestCase
/// validates THIS string in isolation (slice A), and the guarded
/// `updateNSView` rewiring (slice B) injects the SAME string into the rendered
/// page so the live path and the test exercise identical code.
///
/// `mdvApplyBlockPatch(containerSelector, opsJSON)` consumes the JSON produced
/// by `RenderedBlockDiff.jsPayload` (`[{op,index,html?}]`) and mutates ONLY the
/// changed top-level block elements of the container — the block-grained
/// alternative to a full `loadHTMLString` reload (which kills the 2–9s reload
/// storm). It replays `RenderedBlockDiff.apply`'s exact index semantics: ops in
/// order, each `index` against the container's CURRENT element list; `insert`
/// clamps to `[0, count]` (append past the end), `replace`/`remove` are
/// bounds-checked no-ops out of range. Returns `true` on a clean apply, `false`
/// if the container is missing or the payload won't parse — the Swift caller
/// treats `false` (and any thrown JS) as "fall back to loadHTMLString", so the
/// patch path is non-regressing by construction.
public enum BlockPatchJS {
    public static let applyFunction = #"""
    (function () {
      function mdvParseBlock(html) {
        var t = document.createElement('template');
        t.innerHTML = (html || '').trim();
        return t.content.firstElementChild;
      }
      window.mdvApplyBlockPatch = function (containerSelector, opsJSON) {
        var container = document.querySelector(containerSelector);
        if (!container) { return false; }
        var ops;
        try { ops = JSON.parse(opsJSON); } catch (e) { return false; }
        if (!Array.isArray(ops)) { return false; }
        for (var i = 0; i < ops.length; i++) {
          var op = ops[i];
          var n = container.children.length;
          var idx = op.index | 0;
          if (op.op === 'remove') {
            if (idx >= 0 && idx < n) { container.children[idx].remove(); }
          } else if (op.op === 'replace') {
            if (idx >= 0 && idx < n) {
              var rEl = mdvParseBlock(op.html);
              if (rEl) { container.replaceChild(rEl, container.children[idx]); }
            }
          } else if (op.op === 'insert') {
            var clamped = Math.max(0, Math.min(idx, n));
            var iEl = mdvParseBlock(op.html);
            if (iEl) { container.insertBefore(iEl, container.children[clamped] || null); }
          }
        }
        return true;
      };
    })();
    """#
}
