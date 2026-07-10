export const meta = {
  name: 'feature-readiness',
  description: 'Production-readiness review of EVERY feature + gap analysis, reconciled into a hierarchical feature tree (Fable throughout)',
  phases: [
    { title: 'Discover', detail: 'inventory features per area from inventory docs + menus + verbs + views' },
    { title: 'Review', detail: 'per-area deep review: completeness, gaps, production-readiness' },
    { title: 'Reconcile', detail: 'build the hierarchical feature tree + gaps report + readiness verdict' },
  ],
}

const ROOT = '/Users/me/Documents/workspaces/claude/markdown_viewer'
const RDIR = ROOT + '/docs/research/feature-readiness-2026-07-09'
const M = 'fable'   // owner directive: whole workflow on Fable

// Feature AREAS to fan out over (each reviewed independently, then reconciled).
const AREAS = [
  { slug: 'editor', title: 'Text editor (CM6 + NSTextView source)', hint: 'CM6 WebView editor, NSTextView source view, editing, save/dirty, snippets, indent/wrap, spell/autocomplete, folds, gutters, find bar.' },
  { slug: 'markdown-rendering', title: 'Markdown rendering + preview', hint: 'HTMLRenderer, WKWebView preview, mermaid/diagrams, outline, TOC, DOM-patch, scroll sync, math.' },
  { slug: 'data-viewers', title: 'Data viewers (CSV / JSON / hex / sqlite / archive / pdf / audio / video / image-view)', hint: 'Each viewer: load, render, edit-where-applicable, export, lens switching, extracted-doc (docx/xlsx/ods).' },
  { slug: 'image-editing', title: 'Image editor', hint: 'Paint tools, shapes, selection, fill, curve/polygon/text, layers, zoom/pan, undo, save-vs-copy.' },
  { slug: 'code-intelligence', title: 'Code intelligence (LSP + syntax highlight)', hint: 'TreeSitter highlight, LSP hover/definition/completion/diagnostics/format, multi-language, status chip.' },
  { slug: 'git-devtools', title: 'Git + devtools', hint: 'Git status/stage/commit/diff, file history, blame, unified history viewer, git panel, code review, monitor.' },
  { slug: 'sessions-workspaces', title: 'Sessions + workspaces + tabs', hint: 'Tab lifecycle, split view, sessions save/restore, workspaces, recents, bookmarks, recover-deleted, local history.' },
  { slug: 'automation-mcp', title: 'Automation: script verbs + MCP + command palette', hint: 'ScriptVerb catalog, MCP tool surface, command palette, macros, keybindings, agent services.' },
  { slug: 'chrome-navigation', title: 'App chrome + navigation', hint: 'New-tab launchpad/omnibox, sidebar panels, menu bar, toolbar, status bar, multi-window, first-run.' },
  { slug: 'canvas', title: 'Canvas (WYSIWYG diagram/doc)', hint: 'Canvas engine, editing, import/export, timeline, vocab, lint — check M-milestone completeness.' },
  { slug: 'terminal-plugins', title: 'Terminal + plugins + walkthroughs', hint: 'Embedded terminal, terminal favorites, plugin system, walkthrough engine + browser.' },
  { slug: 'search', title: 'Search (in-doc + cross-file + structural)', hint: 'Find bar, cross-file search, structural search, replace, regex, results panel.' },
]

const AREA_SCHEMA = { type: 'object', required: ['reportPath', 'features'], properties: { reportPath: { type: 'string' }, features: { type: 'array', items: { type: 'object', required: ['name', 'status', 'summary'], properties: { name: { type: 'string' }, parent: { type: 'string' }, status: { enum: ['complete', 'mostly', 'partial', 'stub', 'broken', 'missing'] }, summary: { type: 'string' }, gaps: { type: 'array', items: { type: 'string' } }, files: { type: 'array', items: { type: 'string' } }, productionReady: { type: 'boolean' } } } } } }
const TREE_SCHEMA = { type: 'object', required: ['treePath', 'gapsPath', 'topGaps'], properties: { treePath: { type: 'string' }, gapsPath: { type: 'string' }, verdict: { type: 'string' }, topGaps: { type: 'array', items: { type: 'object', required: ['feature', 'gap', 'severity'], properties: { feature: { type: 'string' }, gap: { type: 'string' }, severity: { enum: ['blocker', 'major', 'minor'] } } } } } }

phase('Discover')
log('Feature-readiness: reviewing ' + AREAS.length + ' feature areas (Fable)')
function areaPrompt(a) {
  return 'FEATURE PRODUCTION-READINESS REVIEW — area: ' + a.title + '\nRepo: ' + ROOT + ' (read-only except your report file).\n\nScope: ' + a.hint + '\n\nGround yourself first: read docs/FEATURE_INVENTORY.md and docs/CAPABILITIES.md if they exist, plus the relevant Sources/ code, the menu (Sources/MarkdownViewer/main.swift buildMenu), and the verb catalog (Sources/ViewerCore/Automation/ScriptVerbCatalog.swift). Use rg/find/Read.\n\nFor THIS area, enumerate every distinct FEATURE and SUB-FEATURE. For each, judge:\n- status: complete | mostly | partial | stub | broken | missing (be honest — a model built but no UI wired = partial/stub; a view that renders nothing = broken).\n- what works, what is MISSING or half-built (concrete gaps), and whether it is PRODUCTION-READY for a public launch.\n- cite the key files.\n\nWrite a detailed markdown report to ' + RDIR + '/' + a.slug + '.md: a feature-by-feature table (feature / sub-feature / status / production-ready / gaps / files) + prose on the notable gaps. Use `parent` to express hierarchy (sub-feature -> parent feature name).\n\nConstraints: modify NOTHING except your report file. No UI/window tests, no full swift test, never killall. Don\'t touch OwnerWishlist*/Untitled*/HANDOFF.md/BACKLOG.md.\n\nReturn reportPath + the features array (with parent/status/productionReady/gaps).'
}
const areaResults = (await parallel(AREAS.map(a => () =>
  agent(areaPrompt(a), { label: 'area:' + a.slug, phase: 'Review', schema: AREA_SCHEMA, effort: 'high', model: M })
    .then(r => r ? { area: a.slug, title: a.title, reportPath: r.reportPath, features: r.features || [] } : null)
))).filter(Boolean)

phase('Reconcile')
const featLines = []
for (const ar of areaResults) for (const f of ar.features) featLines.push('(' + ar.area + ') ' + (f.parent ? f.parent + ' > ' : '') + f.name + ' [' + f.status + (f.productionReady ? ', prod-ready' : ', NOT prod-ready') + '] — ' + (f.summary || '') + (f.gaps && f.gaps.length ? ' | GAPS: ' + f.gaps.join('; ') : ''))
log('Discover/Review done: ' + areaResults.length + ' areas, ' + featLines.length + ' features. Reconciling into a tree.')

const tree = await agent(
  'RECONCILE a full feature inventory of ' + ROOT + ' into a single HIERARCHICAL FEATURE TREE + a gap analysis. Per-area reports are in ' + RDIR + '/ (Read them). The flattened feature stream (area / hierarchy / status / prod-ready / gaps):\n\n' + featLines.join('\n') + '\n\nDO:\n1. Write ' + RDIR + '/FEATURE_TREE.md — a nested Markdown tree of the ENTIRE app: top-level feature families -> features -> sub-features, each annotated with a status badge (✅ complete / 🟡 partial / 🟨 stub / 🟥 broken / ⬜ missing) and (prod-ready: yes/no). Deduplicate features that multiple areas reported. This is the canonical map of what the app is.\n2. Write ' + RDIR + '/FEATURE_GAPS.md — the prioritized gap list: every partial/stub/broken/missing feature + not-prod-ready item, grouped by severity (blocker = breaks a core promise or crashes; major = missing table-stakes sub-feature; minor = polish). Each gap: feature, what is missing, suggested next step, rough size.\n3. Give an overall production-readiness VERDICT (1 paragraph) + return the top 25 gaps (feature/gap/severity) for the owner.\n\nConstraints: modify nothing outside ' + RDIR + '.',
  { label: 'reconcile-tree', phase: 'Reconcile', schema: TREE_SCHEMA, effort: 'xhigh', model: M })
if (!tree) throw new Error('reconcile agent died')
log('Reconcile done -> FEATURE_TREE.md + FEATURE_GAPS.md (' + (tree.topGaps ? tree.topGaps.length : 0) + ' top gaps)')

return {
  reportDir: RDIR,
  featureTree: tree.treePath,
  featureGaps: tree.gapsPath,
  verdict: tree.verdict,
  areas: areaResults.map(a => ({ area: a.area, report: a.reportPath, features: a.features.length })),
  topGaps: tree.topGaps,
}
