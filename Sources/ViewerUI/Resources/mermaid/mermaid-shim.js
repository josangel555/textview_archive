/* TextView mermaid shim — runs after mermaid.min.js defines window.mermaid.
   Owns: initialization, render orchestration, step animation, controls,
   keyboard handlers, theme tracking, walkthrough API.

   API-injected via WKUserScript at .atDocumentEnd; not subject to page CSP. */
(function() {
  'use strict';

  if (!window.mermaid) {
    // Runtime missing means the WKUserScript for mermaid.min.js failed to
    // load (vendored bundle stripped from the app bundle, etc). Bail
    // loudly but don't throw — the rest of the page should still render.
    console.warn('[mdv-mermaid] mermaid runtime missing; shim aborted');
    return;
  }

  // ----- Theme + init -----

  function resolveTheme() {
    var cs = getComputedStyle(document.documentElement);
    var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    return {
      dark: dark,
      fg:   cs.getPropertyValue('--mdv-fg').trim()    || (dark ? '#e8e8ea' : '#1d1d1f'),
      bg:   cs.getPropertyValue('--mdv-bg').trim()    || (dark ? '#1e1e1e' : '#ffffff'),
      link: cs.getPropertyValue('--mdv-link').trim()  || (dark ? '#5ac8fa' : '#0066cc')
    };
  }

  function initMermaid() {
    var t = resolveTheme();
    window.mermaid.initialize({
      startOnLoad: false,
      theme: t.dark ? 'dark' : 'default',
      // strict disables htmlLabels + sanitizes click handlers. Combined
      // with our page CSP (no frame-src, no object-src) this neutralizes
      // mermaid's XSS surface even when rendering hostile source.
      securityLevel: 'strict',
      flowchart:  { htmlLabels: false, useMaxWidth: true },
      sequence:   { useMaxWidth: true },
      state:      { useMaxWidth: true },
      class:      { useMaxWidth: true },
      gantt:      { useMaxWidth: true },
      fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
    });
  }

  // ----- Step animation registry -----
  // diagramId -> { host, total }
  var registry = Object.create(null);

  function annotateSteps(host, manifest) {
    if (!manifest || !manifest.length) return 0;
    var src = host.getAttribute('data-mdv-src') || '';
    var lines = src.split('\n');
    var stepDirectives = manifest.slice().sort(function(a, b) {
      return a.line - b.line;
    });

    // Walk source statements (non-blank, non-comment lines) in document
    // order, mapping each to the step number established by the most
    // recent preceding `%% @step` directive. Lines before the first
    // directive map to step 0 (always visible).
    var currentStep = 0;
    var directiveIdx = 0;
    var stmtSteps = [];
    for (var j = 0; j < lines.length; j++) {
      // Advance the step pointer for every directive at or before this line.
      while (directiveIdx < stepDirectives.length &&
             stepDirectives[directiveIdx].line <= j) {
        currentStep = stepDirectives[directiveIdx].step;
        directiveIdx++;
      }
      var ln = lines[j].replace(/^\s+|\s+$/g, '');
      if (!ln) continue;
      if (ln.indexOf('%%') === 0) continue;
      stmtSteps.push(currentStep);
    }

    // Pair statements with rendered SVG elements in document order.
    // Selector list covers the v1-tier diagram types from MERMAID_IMPL §5.
    // Gantt is included for completeness even though its bars render in
    // date order rather than source order (documented v2 limitation).
    var svg = host.querySelector('svg');
    if (!svg) return 0;
    var elements = svg.querySelectorAll(
      'g.node, g.edgePath, g.edgePaths > g, ' +
      'line.messageLine0, line.messageLine1, ' +
      'g.actor, ' +
      'g.classGroup, ' +
      'g.task, rect.task'
    );

    var maxStep = 0;
    var pairCount = Math.min(elements.length, stmtSteps.length);
    for (var k = 0; k < pairCount; k++) {
      var s = stmtSteps[k] || 0;
      elements[k].setAttribute('data-mdv-step', String(s));
      if (s > maxStep) maxStep = s;
    }
    return maxStep;
  }

  function applyStep(host, current) {
    var els = host.querySelectorAll('[data-mdv-step]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var s = parseInt(el.getAttribute('data-mdv-step'), 10) || 0;
      if (s <= current) el.classList.add('mdv-step-visible');
      else              el.classList.remove('mdv-step-visible');
    }
    var label = host.querySelector('.mdv-mermaid-counter');
    if (label) {
      var total = parseInt(host.getAttribute('data-mdv-total-steps'), 10) || 0;
      label.textContent = 'step ' + current + ' of ' + total;
    }
  }

  function currentOf(host) {
    return parseInt(host.getAttribute('data-mdv-current-step'), 10) || 0;
  }

  function gotoStep(host, n) {
    var total = parseInt(host.getAttribute('data-mdv-total-steps'), 10) || 0;
    if (n < 0) n = 0;
    if (n > total) n = total;
    host.setAttribute('data-mdv-current-step', String(n));
    applyStep(host, n);
  }

  function buildControls(host, total) {
    var bar = document.createElement('div');
    bar.className = 'mdv-mermaid-controls';
    bar.setAttribute('role', 'toolbar');
    bar.setAttribute('aria-label', 'diagram step controls');

    function btn(label, action, ariaLabel) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'mdv-mermaid-btn';
      b.textContent = label;
      b.setAttribute('aria-label', ariaLabel);
      b.addEventListener('click', action);
      return b;
    }

    bar.appendChild(btn('|<', function() { gotoStep(host, 0); }, 'first step'));
    bar.appendChild(btn('<',  function() { gotoStep(host, currentOf(host) - 1); }, 'previous step'));
    var playBtn = btn('>', function() { togglePlay(host, playBtn); }, 'play');
    playBtn.dataset.playing = '0';
    bar.appendChild(playBtn);
    bar.appendChild(btn('>', function() { gotoStep(host, currentOf(host) + 1); }, 'next step'));
    bar.appendChild(btn('>|', function() { gotoStep(host, total); }, 'last step'));

    var counter = document.createElement('span');
    counter.className = 'mdv-mermaid-counter';
    counter.textContent = 'step 0 of ' + total;
    bar.appendChild(counter);

    host.appendChild(bar);
  }

  function togglePlay(host, btn) {
    var playing = btn.dataset.playing === '1';
    if (playing) {
      clearInterval(host.__mdvPlayTimer);
      host.__mdvPlayTimer = null;
      btn.dataset.playing = '0';
      btn.textContent = '>';
      btn.setAttribute('aria-label', 'play');
      return;
    }
    btn.dataset.playing = '1';
    btn.textContent = '||';
    btn.setAttribute('aria-label', 'pause');
    var total = parseInt(host.getAttribute('data-mdv-total-steps'), 10) || 0;
    host.__mdvPlayTimer = setInterval(function() {
      var cur = currentOf(host);
      if (cur >= total) {
        clearInterval(host.__mdvPlayTimer);
        host.__mdvPlayTimer = null;
        btn.dataset.playing = '0';
        btn.textContent = '>';
        btn.setAttribute('aria-label', 'play');
        return;
      }
      gotoStep(host, cur + 1);
    }, 1200);
  }

  function wireKeyboard(host) {
    host.tabIndex = 0;
    host.addEventListener('keydown', function(ev) {
      var total = parseInt(host.getAttribute('data-mdv-total-steps'), 10) || 0;
      if (!total) return;
      switch (ev.key) {
        case 'ArrowLeft':  gotoStep(host, currentOf(host) - 1); ev.preventDefault(); break;
        case 'ArrowRight': gotoStep(host, currentOf(host) + 1); ev.preventDefault(); break;
        case 'Home':       gotoStep(host, 0);                   ev.preventDefault(); break;
        case 'End':        gotoStep(host, total);               ev.preventDefault(); break;
        default: break;
      }
    });
  }

  // ----- Render orchestration -----

  async function renderHost(host) {
    if (host.hasAttribute('data-rendered')) return;
    try {
      await window.mermaid.run({ nodes: [host] });
    } catch (e) {
      // Replace the host contents with an inline error + source dump.
      // Keep the same host element so the surrounding markdown layout
      // doesn't shift.
      var src = host.getAttribute('data-mdv-src') || host.textContent;
      host.innerHTML = '';
      var err = document.createElement('div');
      err.className = 'mdv-mermaid-error';
      err.textContent = 'mermaid: ' + String(e && e.message || e);
      var pre = document.createElement('pre');
      pre.textContent = src;
      host.appendChild(err);
      host.appendChild(pre);
      host.setAttribute('data-rendered', 'error');
      return;
    }

    var manifestRaw = host.getAttribute('data-mdv-steps');
    if (manifestRaw) {
      try {
        var manifest = JSON.parse(manifestRaw);
        var total = annotateSteps(host, manifest);
        if (total > 0) {
          host.setAttribute('data-mdv-total-steps', String(total));
          host.setAttribute('data-mdv-current-step', '0');
          applyStep(host, 0);
          buildControls(host, total);
          wireKeyboard(host);
          var id = host.getAttribute('data-mdv-id');
          if (id) {
            registry[id] = { host: host, total: total };
          }
        }
      } catch (e) {
        console.warn('[mdv-mermaid] bad step manifest', e);
      }
    }

    host.setAttribute('data-rendered', '1');
  }

  async function renderAll() {
    var hosts = document.querySelectorAll('div.mdv-mermaid:not([data-rendered])');
    for (var i = 0; i < hosts.length; i++) {
      // Serialize renders. Mermaid is memory-hungry on large diagrams;
      // parallelizing here doesn't speed up the typical doc (1-3
      // diagrams) and risks OOMing on a 30-diagram doc.
      await renderHost(hosts[i]);
    }
  }

  // ----- Theme flips -----

  function rerenderAll() {
    initMermaid();
    var hosts = document.querySelectorAll('div.mdv-mermaid[data-rendered]');
    hosts.forEach(function(host) {
      host.removeAttribute('data-rendered');
      host.removeAttribute('data-mdv-total-steps');
      host.removeAttribute('data-mdv-current-step');
      var oldBar = host.querySelector('.mdv-mermaid-controls');
      if (oldBar) oldBar.remove();
      if (host.__mdvPlayTimer) {
        clearInterval(host.__mdvPlayTimer);
        host.__mdvPlayTimer = null;
      }
      var src = host.getAttribute('data-mdv-src');
      if (src) host.textContent = src;
    });
    renderAll();
  }

  // ----- Public API (walkthroughs / Swift driver) -----

  window.__mdvMermaidStep = function(id, n) {
    var entry = registry[id];
    if (!entry) return false;
    gotoStep(entry.host, n);
    return true;
  };

  window.__mdvMermaidStepCount = function(id) {
    var entry = registry[id];
    return entry ? entry.total : 0;
  };

  window.__mdvMermaidRender = renderAll;

  // ----- Bootstrap -----

  initMermaid();

  var mq = window.matchMedia('(prefers-color-scheme: dark)');
  if (mq.addEventListener) {
    mq.addEventListener('change', rerenderAll);
  } else if (mq.addListener) {
    // Safari < 14 fallback. We target macOS 15 so this branch is dead
    // in practice, but keeps the shim portable if someone tests in an
    // older WebKit.
    mq.addListener(rerenderAll);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderAll);
  } else {
    renderAll();
  }
})();
