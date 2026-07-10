export const meta = {
  name: 'prelaunch-audit',
  description: 'Production-grade pre-launch review of the app across ~45 quality dimensions, with adversarial verification, prioritized synthesis, and worktree-isolated fixes',
  phases: [
    { title: 'Scope', detail: 'discover extra dimensions + subsystem inventory' },
    { title: 'Review', detail: 'one deep reviewer per dimension, detailed report each' },
    { title: 'Verify', detail: 'adversarial refutation of P0/P1 findings' },
    { title: 'Synthesize', detail: 'dedupe, prioritize, master report, fix batches' },
    { title: 'Fix', detail: 'worktree-isolated fix agents per batch' },
  ],
}

const ROOT = '/Users/me/Documents/workspaces/claude/markdown_viewer'
const RDIR = ROOT + '/docs/research/prelaunch-audit-2026-07-09'
const SESSION = 'https://claude.ai/code/<session>'

// MODEL ROUTING (owner directive 2026-07-09): SPLIT the load across both models.
// Reserve FABLE for HIGH-PRIORITY (safety/correctness-critical) work; run the
// bulk on OPUS (freshly reset). `isHighPriority` classifies a dimension/batch.
function isHighPriority(text) {
  return /secur|attack|exploit|vuln|threat|\bdepend|supply.?chain|sanitiz|injection|traversal|malicious|quarantine|crash|\bconsisten|concurren|\brace\b|thread|editor.?stabil|error.?recov|functional.?bug|bugs-functional|hidden.?gotcha|save.?fidel|persistence|migration|input.?robust|trust.?boundar|read.?write|data.?loss|data.?exposure|privacy|filesystem/i.test(text || '')
}
const modelForHP = (hp) => (hp ? 'fable' : 'opus')   // Fable = high-priority; Opus = the rest
const M_INFRA = 'opus'    // scope / inventory / critic — conserve Fable
const M_SYNTH = 'fable'   // synthesis produces the master report → high-priority

const OWNER_DIMS = [
  { slug: 'dual-ui-refactor', title: 'Two-UI-implementations refactor analysis', hint: 'The app renders through BOTH native SwiftUI/AppKit and WKWebView/CM6 stacks. Map every duplicated surface, divergence, and inconsistency between the two; propose a consolidation strategy. The refactor itself is a one-way-door (goes to NEEDS_OWNER) — findings here are concrete duplication/divergence instances.' },
  { slug: 'performance-optimization', title: 'Extreme performance optimization', hint: 'Hot paths, main-thread blocking work, IO on the UI thread, redundant parsing/allocations, missing caching/laziness, startup time. PerfSignpost + InteractionProfiler infra exists — flag unmeasured hot paths too.' },
  { slug: 'accessibility', title: 'Accessibility, tooltips, keyboard navigation', hint: 'AX identifiers/labels coverage, VoiceOver usability, full-keyboard operation and focus order, .help tooltips coverage, contrast.' },
  { slug: 'ui-liveliness', title: 'UI responsiveness / interactivity feel', hint: 'The owner says the UI feels DEAD. Find every interactive element missing hover highlight, click/pressed feedback, NSCursor pointer changes, tooltips, subtle transitions. Inventory concrete controls + files.' },
  { slug: 'ui-best-practices', title: 'macOS UI best practices (HIG)', hint: 'HIG conformance: control sizes/spacing, sheet vs panel use, toolbar/menu conventions, dark-mode correctness, vibrancy, SF Symbols usage.' },
  { slug: 'ux-defects', title: 'Bad UX: defaults, icons, text', hint: 'Bad default settings, confusing icons, unclear button/label/error copy, jargon, destructive actions without confirm, missing empty states.' },
  { slug: 'ui-consistency', title: 'UI consistency', hint: 'Inconsistent naming, icons, notations, animations, interactions, sizes, spacing, capitalization across panels/menus/views.' },
  { slug: 'ux-best-practices', title: 'UX best practices', hint: 'Discoverability, feedback loops, undo-ability, progressive disclosure, onboarding, error prevention over error messages.' },
  { slug: 'internationalization', title: 'Internationalization + character support', hint: 'Hardcoded user-facing strings (localizability), Unicode/emoji/CJK/RTL handling in editor+viewers, locale-aware number/date formatting, UTF-16 vs grapheme handling.' },
  { slug: 'security-core', title: 'Security review', hint: 'Input validation on every untrusted-bytes parser, WebView CSP/JS bridges, file-URL fencing, path traversal, symlink handling, quarantine handling, secret handling, MCP/socket surface auth.' },
  { slug: 'attack-surface', title: 'Attack surface enumeration', hint: 'Enumerate every input surface (file parsers md/csv/hex/archives/sqlite/images, the MCP socket bridge, URL schemes, clipboard, plugins, git integration, LSP servers, terminal). For each: what untrusted input reaches it and what happens.' },
  { slug: 'tech-debt', title: 'Tech debt', hint: 'TODO/FIXME/HACK inventory with age+risk, dead code, deprecated API usage, orphaned features, stale scaffolding.' },
  { slug: 'code-quality', title: 'Code quality issues', hint: 'Duplication, oversized functions/files, unclear naming, error-prone idioms, missing abstractions, layering violations.' },
  { slug: 'regressions', title: 'Regression risks', hint: 'Scan recent git history for risky changes, behavior changes without tests, weakened/deleted assertions, TODO-disabled tests.' },
  { slug: 'bugs-functional', title: 'Functional bugs', hint: 'Logic errors: inverted conditions, wrong ranges, bad math, wrong string/offset handling (UTF-16 vs Character), state machines with unreachable/absorbing states.' },
  { slug: 'hidden-gotchas', title: 'Hidden bugs + gotchas', hint: 'Silent failure paths: try? swallowing errors, force-unwraps, force-casts, ignored return values, implicit assumptions that break on edge inputs, fenceposts.' },
  { slug: 'defects-spec', title: 'Spec/behavior mismatches', hint: 'Where docs, code comments, UI text, or menu labels promise behavior the code does not deliver (and vice versa).' },
  { slug: 'inefficiencies', title: 'Inefficiencies + bottlenecks', hint: 'Algorithmic complexity traps (O(n^2) on file size/tab count), N+1 IO, repeated whole-buffer scans, unnecessary copies, chatty polling.' },
  { slug: 'test-coverage', title: 'Test coverage + testing gaps', hint: 'Which subsystems/paths have NO tests, missing edge cases, per-surface real-render matrix gaps, untested error paths.' },
  { slug: 'concurrency-races', title: 'Concurrency, threading, races', hint: 'Actor-isolation violations, @MainActor gaps, unstructured Tasks, data races on shared mutable state, TOCTOU, off-by-ones in async chains, arbitrary sleeps/waits, unbounded task spawning.' },
  { slug: 'read-write-consistency', title: 'Read/write consistency scrutiny', hint: 'EVERY persisted read+write (session snapshots, UserDefaults, history/bookmark/trust stores, editor saves, local-history, watcher reloads): atomicity, torn/partial writes, stale reads, lost updates, concurrent-writer safety, crash-mid-write recovery.' },
  { slug: 'magic-numbers', title: 'Magic numbers + hardcoded assumptions', hint: 'Unexplained constants, hardcoded sizes/timeouts/paths/ports, assumptions about screen sizes, file sizes, line counts, encodings.' },
  { slug: 'scaling-limits', title: 'Scaling bottlenecks + boundaries', hint: 'Behavior at extremes: 1GB files, 10k-line docs, 500 tabs, giant sessions, unbounded caches/history growth, memory ceilings. Where are the missing caps?' },
  { slug: 'crash-analysis', title: 'Crash situations + consequences', hint: 'What can crash the app (force-unwraps, index OOB, FFI panics across the Rust boundary, recursion) and WHAT HAPPENS: is state lost? does it relaunch clean? unsaved-edit recovery?' },
  { slug: 'error-recovery', title: 'Error recovery + handling', hint: 'Boundary error handling quality, user-facing degradation vs silent breakage, corrupted-store recovery, disk-full/permission-denied/network-gone paths.' },
  { slug: 'editor-stability', title: 'Editor stability + reliability', hint: 'Data-loss paths in the editor: external-change detection (file changed underneath — is the user ALWAYS told?), save integrity, encoding round-trips, undo reliability, dirty-state truthfulness.' },
  { slug: 'comment-drift', title: 'Code-comment quality + drift', hint: 'Comments that mis-describe the code, stale ticket references, doc-comments contradicting behavior, load-bearing comments missing where code is subtle.' },
  { slug: 'config-hygiene', title: 'Configuration hygiene', hint: 'Misconfigurations, bad configs, config that should be code, code that should be config, env-var sprawl, per-machine assumptions in scripts.' },
  { slug: 'dependency-audit', title: 'Dependency + supply-chain review', hint: 'Full dep tree (SwiftPM + cargo): pinning, health/maintenance, scale of use. Flag small deps (<1000 LOC) that should be vendored per owner policy, and any insecure/stale/ill-maintained dep. Include dev-machine tooling surface.' },
  { slug: 'test-quality', title: 'Test quality + false greens', hint: 'Tests that cannot fail (tautologies, over-mocking), asserts on the wrong thing, greens that never went red, flaky patterns (timing/shared state), disabled/skipped tests hiding failures.' },
]

// ---------- Schemas ----------
const SCOPE_SCHEMA = { type: 'object', required: ['dimensions'], properties: { dimensions: { type: 'array', items: { type: 'object', required: ['slug', 'title', 'hint'], properties: { slug: { type: 'string' }, title: { type: 'string' }, hint: { type: 'string' } } } } } }
const INVENTORY_SCHEMA = { type: 'object', required: ['summary', 'subsystems'], properties: { summary: { type: 'string' }, subsystems: { type: 'array', items: { type: 'object', required: ['name', 'paths'], properties: { name: { type: 'string' }, paths: { type: 'array', items: { type: 'string' } }, loc: { type: 'number' }, notes: { type: 'string' } } } } } }
const FINDINGS_SCHEMA = { type: 'object', required: ['reportPath', 'findings'], properties: { reportPath: { type: 'string' }, findings: { type: 'array', items: { type: 'object', required: ['title', 'severity', 'description', 'files', 'fixSize', 'fixRisk'], properties: { title: { type: 'string' }, severity: { enum: ['P0', 'P1', 'P2', 'P3'] }, description: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, line: { type: 'number' }, suggestedFix: { type: 'string' }, fixSize: { enum: ['S', 'M', 'L', 'XL'] }, fixRisk: { enum: ['safe', 'careful', 'one-way-door'] } } } } } }
const VERDICT_SCHEMA = { type: 'object', required: ['verdict', 'reason'], properties: { verdict: { enum: ['CONFIRMED', 'REFUTED', 'UNCERTAIN'] }, reason: { type: 'string' } } }
const SYNTH_SCHEMA = { type: 'object', required: ['batches', 'needsOwner'], properties: { batches: { type: 'array', items: { type: 'object', required: ['name', 'area', 'approach', 'findings'], properties: { name: { type: 'string' }, area: { type: 'string' }, approach: { type: 'string' }, findings: { type: 'array', items: { type: 'object', required: ['title', 'severity', 'files', 'description'], properties: { title: { type: 'string' }, severity: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, description: { type: 'string' }, suggestedFix: { type: 'string' } } } } } } }, needsOwner: { type: 'array', items: { type: 'object', required: ['title', 'why', 'recommendation'], properties: { title: { type: 'string' }, why: { type: 'string' }, options: { type: 'string' }, recommendation: { type: 'string' } } } } } }
const FIX_SCHEMA = { type: 'object', required: ['branch', 'commits', 'fixed', 'skipped'], properties: { branch: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, fixed: { type: 'array', items: { type: 'string' } }, skipped: { type: 'array', items: { type: 'object', required: ['title', 'reason'], properties: { title: { type: 'string' }, reason: { type: 'string' } } } }, testsAdded: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } } }

// ---------- Phase: Scope ----------
phase('Scope')
log('Scope: discovering additional review dimensions + inventorying subsystems (Opus infra)')
const ownerList = OWNER_DIMS.map(d => d.slug + ' — ' + d.title).join('\n')
const [scopePrimed, scopeBlank, inventory] = await parallel([
  () => agent(
    'You are planning a production-grade PRE-LAUNCH REVIEW of the app at ' + ROOT + ' (a macOS document viewer/editor, Swift + a Rust core + WebView surfaces). The owner already listed these review dimensions:\n' + ownerList + '\n\nYour job: propose ADDITIONAL review dimensions the list is missing (do NOT repeat the ones above). Skim the repo (README/DESIGN.md/docs/, Sources/ layout) to ground your proposals in what the app actually does. Think: launch readiness for a real product — anything that could embarrass or hurt the product post-launch. Return ONLY the new dimensions, each with a kebab-case slug, a title, and a one-line hint telling a reviewer what to examine.',
    { label: 'scope:primed', phase: 'Scope', schema: SCOPE_SCHEMA, model: M_INFRA }),
  () => agent(
    'A macOS document viewer/editor app (Swift, with a Rust core and WebView-based surfaces) at ' + ROOT + ' is about to launch publicly as a production product. With completely fresh eyes — you have NO other context — enumerate every distinct quality dimension a demanding pre-launch review should cover. Skim the repo briefly to see what the product is. Return each dimension with a kebab-case slug, title, and a one-line hint for the reviewer.',
    { label: 'scope:blank-slate', phase: 'Scope', schema: SCOPE_SCHEMA, model: M_INFRA }),
  () => agent(
    'Inventory the codebase at ' + ROOT + ' for a review fan-out. Identify the major subsystems (e.g. by Sources/ target + directory: ViewerCore engines, ViewerUI views/coordinators, MarkdownViewer app shell, rust-core crates, Automation/MCP, scripts). For each: name, key paths, approximate LOC (use find/wc via Bash), one-line notes on what it does. Also produce a 15-line orientation summary a reviewer could use to navigate the codebase fast. Do not modify anything.',
    { label: 'scope:inventory', phase: 'Scope', schema: INVENTORY_SCHEMA, model: M_INFRA }),
])

const dims = OWNER_DIMS.map(d => ({ slug: d.slug, title: d.title, hint: d.hint, fresh: false, hp: isHighPriority(d.slug + ' ' + d.title + ' ' + d.hint) }))
const seen = new Set(dims.map(d => d.slug))
const extras = []
for (const src of [scopePrimed, scopeBlank]) {
  if (!src) continue
  for (const d of (src.dimensions || [])) {
    const slug = (d.slug || '').toLowerCase()
    if (!slug || seen.has(slug)) continue
    const head = slug.split('-')[0]
    if ([...seen].some(s => s.startsWith(head + '-') || s === head) && head.length > 4) continue
    seen.add(slug)
    extras.push({ slug, title: d.title, hint: d.hint, fresh: false, hp: isHighPriority(slug + ' ' + d.title + ' ' + (d.hint || '')) })
  }
}
extras.length = Math.min(extras.length, 14)
dims.push(...extras)

const subsystems = ((inventory && inventory.subsystems) ? inventory.subsystems : [])
  .slice().sort((a, b) => (b.loc || 0) - (a.loc || 0)).slice(0, 8)
for (const s of subsystems) {
  const slug = 'code-review-' + s.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
  if (seen.has(slug)) continue
  seen.add(slug)
  // Code reviews of core/rust engines are high-priority; UI/scripts reviews are not.
  dims.push({ slug, title: 'Full code review: ' + s.name, hint: 'Line-level review of ' + (s.paths || []).join(', ') + ' — correctness, robustness, idiom, hidden bugs. ' + (s.notes || ''), fresh: false, hp: /core|engine|rust|ffi|parser|store|persist/i.test(s.name + ' ' + (s.paths || []).join(' ')) })
}
dims.push({ slug: 'fresh-eyes-1', title: 'Fresh-eyes product scrutiny #1', hint: '', fresh: true, hp: false })
dims.push({ slug: 'fresh-eyes-2', title: 'Fresh-eyes product scrutiny #2', hint: '', fresh: true, hp: false })
const hpCount = dims.filter(d => d.hp).length
log('Scope complete: ' + dims.length + ' dimensions (' + hpCount + ' high-priority on Fable, ' + (dims.length - hpCount) + ' on Opus) — ' + OWNER_DIMS.length + ' owner + ' + extras.length + ' discovered + ' + subsystems.length + ' subsystem reviews + 2 fresh-eyes')

const invSummary = inventory ? inventory.summary : '(inventory unavailable)'

// ---------- Phase: Review ----------
function reviewPrompt(d) {
  const focus = d.fresh
    ? 'Approach with completely fresh eyes: explore the app as a demanding senior engineer AND end user. No prior context, no assumptions — find what is actually wrong or embarrassing for launch.'
    : 'Focus lens: ' + (d.hint || d.title) + '\n\nCodebase orientation:\n' + invSummary
  return 'PRE-LAUNCH PRODUCT REVIEW — dimension: ' + d.title + '\n\nRepo: ' + ROOT + ' (treat as read-only except your report file)\n\n' + focus + '\n\nTASK:\n1. Deeply review the codebase through ONLY this lens. Read real code (rg/grep/find via Bash, Read for files). Every finding must cite exact file paths (+ line numbers where possible) and be independently verifiable — no vibes.\n2. Write a DETAILED markdown report to ' + RDIR + '/' + d.slug + '.md (Write tool; the directory exists). Structure: Executive summary / Methodology (what you examined + how much) / Findings (each: severity, file:line, evidence, impact, suggested fix, fix size S-M-L-XL, fix risk safe|careful|one-way-door) / Positive observations / Coverage gaps (what you did NOT examine).\n3. Severity rubric: P0 = ship-blocker (data loss, crash, broken core flow). P1 = major (user-visible bug, significant perf, missing table-stakes UX). P2 = quality (debt, inconsistency, minor bug). P3 = polish.\n4. If this dimension genuinely does not apply, say so in the report and return zero findings.\n\nConstraints: do NOT modify any repo file other than writing your report. Do NOT run UI/window-opening tests or anything that opens windows (a targeted headless swift test --filter is allowed but prefer static analysis; NEVER a bare full swift test — too slow). NEVER killall anything. Do not touch OwnerWishlist*, Untitled*, HANDOFF.md, BACKLOG.md.\n\nReturn: reportPath + the findings array (cap at the 25 MOST IMPORTANT findings; the full detail lives in your report file).'
}
function refutePrompt(dim, f, i) {
  return 'ADVERSARIAL VERIFICATION (vote ' + (i + 1) + ') — try to REFUTE this pre-launch review finding. Repo: ' + ROOT + ' (read-only).\n\nDimension: ' + dim.title + '\nFinding: ' + f.title + ' [' + f.severity + ']\nFiles: ' + (f.files || []).join(', ') + (f.line ? ' (line ~' + f.line + ')' : '') + '\nClaim: ' + f.description + '\n\nRead the actual code and determine whether the claim is REAL as stated. CONFIRMED only if you can point to the exact code that exhibits the problem. REFUTED if the claim is wrong, already handled elsewhere, or misreads the code (say where). UNCERTAIN only if genuinely undecidable from the code. Default toward REFUTED when the evidence is weak.'
}
async function verifyDim(res, d) {
  if (!res) return null
  const findings = res.findings || []
  const critical = findings.filter(f => f.severity === 'P0' || f.severity === 'P1').slice(0, 10)
  const rest = findings.filter(f => !critical.includes(f))
  const verified = await parallel(critical.map(f => () => {
    const votes = f.severity === 'P0' ? 2 : 1
    return parallel(Array.from({ length: votes }, (_, i) =>
      () => agent(refutePrompt(d, f, i), { label: 'verify:' + d.slug, phase: 'Verify', schema: VERDICT_SCHEMA, model: modelForHP(d.hp) })
    )).then(vs => {
      const vv = vs.filter(Boolean)
      const refuted = vv.some(v => v.verdict === 'REFUTED')
      const confirmed = vv.length > 0 && vv.every(v => v.verdict === 'CONFIRMED')
      return Object.assign({}, f, { verdict: refuted ? 'REFUTED' : (confirmed ? 'CONFIRMED' : 'UNCERTAIN') })
    })
  }))
  return { dim: d.slug, title: d.title, reportPath: res.reportPath,
           findings: verified.filter(Boolean).concat(rest.map(f => Object.assign({}, f, { verdict: 'UNVERIFIED' }))) }
}

phase('Review')
log('Fanning out ' + dims.length + ' reviewers (high-priority on Fable, rest on Opus; P0/P1 verify as each lands)')
const reviewed = (await pipeline(
  dims,
  d => agent(reviewPrompt(d), { label: 'review:' + d.slug, phase: 'Review', schema: FINDINGS_SCHEMA, effort: 'high', model: modelForHP(d.hp) }),
  (res, d) => verifyDim(res, d)
)).filter(Boolean)

// ---------- Phase: Synthesize ----------
phase('Synthesize')
const allFindings = []
for (const r of reviewed) for (const f of r.findings) allFindings.push({ dim: r.dim, title: f.title, severity: f.severity, verdict: f.verdict, files: f.files || [], description: f.description, suggestedFix: f.suggestedFix || '', fixSize: f.fixSize, fixRisk: f.fixRisk })
const live = allFindings.filter(f => f.verdict !== 'REFUTED')
log('Reviews complete: ' + reviewed.length + ' dimensions, ' + allFindings.length + ' findings (' + (allFindings.length - live.length) + ' refuted)')

const critic = await agent(
  'COMPLETENESS CRITIC for a pre-launch review of ' + ROOT + '. Dimensions reviewed (reports in ' + RDIR + '): ' + reviewed.map(r => r.dim).join(', ') + '. Skim 3-4 of those reports and the repo layout. What did this review MISS — dimensions not covered, subsystems no reviewer examined, claims nobody verified? Return a concise markdown list (10-20 bullets max) of gaps and follow-ups. Text only.',
  { label: 'completeness-critic', phase: 'Synthesize', model: M_INFRA })

const findingsCompact = live.map((f, i) => '[' + i + '] ' + f.severity + '/' + (f.verdict || '?') + ' ' + f.fixSize + '/' + f.fixRisk + ' (' + f.dim + ') ' + f.title + ' — files: ' + f.files.slice(0, 3).join(', ') + ' — ' + f.description.slice(0, 200)).join('\n')
const synth = await agent(
  'SYNTHESIS of a pre-launch product review of ' + ROOT + '. Per-dimension detailed reports live in ' + RDIR + '/ (Read any you need). The deduplicated finding stream (severity/verdict/fixSize/fixRisk, REFUTED already removed):\n\n' + findingsCompact + '\n\nCompleteness-critic gaps:\n' + (critic || '(none)') + '\n\nDO:\n1. DEDUPE overlapping findings (multiple reviewers often hit the same issue) and re-rank severity where reviewers disagreed.\n2. Write ' + RDIR + '/MASTER_REPORT.md — executive summary, stats table (per severity/dimension), the full prioritized finding list P0 first (cite the per-dimension reports), the completeness gaps, and a launch-readiness verdict.\n3. Write ' + RDIR + '/NEEDS_OWNER.md — every one-way-door / XL / product-decision item (e.g. any dual-UI consolidation refactor), each with homework: context, options, and YOUR recommendation.\n4. Return fix BATCHES for autonomous fixing NOW: only safe|careful risk, S|M|L size, severity P0-P2. Group by subsystem/area so NO TWO BATCHES TOUCH THE SAME FILES (they run as parallel git worktrees). 8-14 batches, each 3-12 findings, highest severity first. Include per-finding description + suggestedFix so a fixer needs no other context. Everything not batched stays in the master report.\n\nConstraints: do not modify any file outside ' + RDIR + '.',
  { label: 'synthesis', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'xhigh', model: M_SYNTH })
if (!synth) throw new Error('synthesis agent died')
log('Synthesis: ' + synth.batches.length + ' fix batches, ' + synth.needsOwner.length + ' owner decisions -> NEEDS_OWNER.md')

// ---------- Phase: Fix ----------
phase('Fix')
function fixPrompt(b) {
  const list = b.findings.map((f, i) => (i + 1) + '. [' + f.severity + '] ' + f.title + '\n   files: ' + f.files.join(', ') + '\n   problem: ' + f.description + (f.suggestedFix ? '\n   suggested fix: ' + f.suggestedFix : '')).join('\n')
  return 'You are FIXING pre-launch review findings in an ISOLATED GIT WORKTREE (your current working directory — verify with pwd/git status; work ONLY here). Read the repo CLAUDE.md first and follow its conventions.\n\nBATCH: ' + b.name + ' (area: ' + b.area + ')\nApproach: ' + b.approach + '\n\nFINDINGS:\n' + list + '\n\nRULES:\n- RE-VERIFY each finding against the code FIRST. If it is not real / already fixed, SKIP it and record why — never change code for a bogus finding.\n- Production-quality fixes matching the surrounding style. Every behavior change ships with a HOST test that pins it (Swift Testing for new pure-logic, XCTest otherwise).\n- swift build must pass; run swift test --filter <the suites you touched/added> and make them green. Do NOT run the full suite or gate; do NOT run UI/window tests; NEVER killall.\n- FORBIDDEN: new dependencies (skip + record instead); modifying OwnerWishlist.md, OwnerWishlist.md.bak, Untitled.txt, archive/Untitled.txt, HANDOFF.md, BACKLOG.md, CHANGELOG.md; git push; touching the VM or anything outside this worktree.\n- Commit per logical unit: subject "fix(audit/' + b.name + '): <what>", body says why + names the finding, and ends with this exact trailer line:\nClaude-Session: ' + SESSION + '\n\nReturn: branch (git branch --show-current), commit SHAs, fixed titles, skipped {title, reason}, testsAdded, notes.'
}
const fixResults = (await parallel(
  synth.batches.slice(0, 14).map(b => () =>
    agent(fixPrompt(b), { label: 'fix:' + b.name, phase: 'Fix', schema: FIX_SCHEMA, isolation: 'worktree', effort: 'high', model: modelForHP(isHighPriority(b.name + ' ' + b.area)) })
      .then(r => r ? Object.assign({ batch: b.name }, r) : null)
  )
)).filter(Boolean)
log('Fix phase done: ' + fixResults.length + '/' + Math.min(synth.batches.length, 14) + ' batches returned')

return {
  reportDir: RDIR,
  masterReport: RDIR + '/MASTER_REPORT.md',
  needsOwnerReport: RDIR + '/NEEDS_OWNER.md',
  dimensionsReviewed: reviewed.map(r => ({ dim: r.dim, report: r.reportPath, findings: r.findings.length })),
  stats: { dimensions: reviewed.length, findings: allFindings.length, refuted: allFindings.length - live.length,
           p0: live.filter(f => f.severity === 'P0').length, p1: live.filter(f => f.severity === 'P1').length,
           p2: live.filter(f => f.severity === 'P2').length, p3: live.filter(f => f.severity === 'P3').length },
  needsOwner: synth.needsOwner,
  batchesPlanned: synth.batches.map(b => b.name),
  fixes: fixResults,
}
