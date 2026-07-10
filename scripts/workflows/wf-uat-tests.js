export const meta = {
  name: 'uat-test-authoring',
  description: 'Author as many AX + UI-UAT tests as possible (Opus). Authoring parallelizes in worktrees; VM GUI-lane validation is a SERIAL singleton, so validation runs in one looping lane.',
  phases: [
    { title: 'Plan', detail: 'inventory AX + UI-UAT testable surfaces -> batches (tag uat|ax)' },
    { title: 'Author', detail: 'concurrent worktree writers: write tests + host swift build compile-check + commit' },
    { title: 'Validate', detail: 'SINGLE serial lane: integrate uat batches, run VM GUI lane one at a time (loop); AX = author-only' },
  ],
}

const ROOT = '/Users/me/Documents/workspaces/claude/markdown_viewer'
const RDIR = ROOT + '/docs/research/uat-authoring-2026-07-09'
const SESSION = 'https://claude.ai/code/<session>'
const M = 'opus'   // owner directive: this whole workflow on Opus
// How many UI-UAT batches to actually run on the VM inside this workflow (the VM
// GUI lane is a singleton + each run is slow, so validation is serial + bounded;
// the rest get a documented serial plan for follow-up ticks).
const VM_VALIDATE_BUDGET = 4

const PLAN_SCHEMA = { type: 'object', required: ['batches'], properties: { batches: { type: 'array', items: { type: 'object', required: ['slug', 'kind', 'surface', 'what', 'suite'], properties: { slug: { type: 'string' }, kind: { enum: ['uat', 'ax'] }, surface: { type: 'string' }, what: { type: 'string' }, suite: { type: 'string' }, scene: { type: 'string' } } } } } }
const AUTHOR_SCHEMA = { type: 'object', required: ['branch', 'commits', 'testsAdded', 'compiles'], properties: { branch: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, testsAdded: { type: 'array', items: { type: 'string' } }, compiles: { type: 'boolean' }, notes: { type: 'string' } } }
const VALIDATE_SCHEMA = { type: 'object', required: ['reportPath', 'validated', 'pending'], properties: { reportPath: { type: 'string' }, integrationBranch: { type: 'string' }, validated: { type: 'array', items: { type: 'object', required: ['suite', 'result'], properties: { suite: { type: 'string' }, result: { enum: ['pass', 'fail', 'error'] }, detail: { type: 'string' } } } }, pending: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } } }

// ---------- Plan ----------
phase('Plan')
log('UAT authoring: planning testable surfaces (Opus). CONCURRENCY: authoring parallelizes; VM validation is a serial singleton.')
const plan = await agent(
  'Plan an AX + UI-UAT TEST AUTHORING sweep for ' + ROOT + '. Read docs/TEST_PYRAMID.md, docs/TEST_* , the existing UAT scenes (Sources/ViewerCore/UISceneRegistry.swift + Sources/ViewerUI/UISceneApplier.swift + scripts/vm-uitest.sh), the AX identifier catalog + matrix (grep AXIdentifierCatalog, TSK-1543), and the existing Tests/ViewerUITests harness (TierBaseCases, LiveAppTestCase T4, PixelTestCase T5, WebViewTestCase). Enumerate the app surfaces that NEED more UI/AX test coverage and are realistically authorable.\n\nProduce test BATCHES, each:\n- slug (kebab), surface (what UI area), what (the specific behaviors/interactions to cover), suite (the XCTest/Swift-Testing class name to create or extend), scene (the MDV_UI_SCENE name if a scene is needed, else omit).\n- kind: "uat" = a UI-UAT test validatable on the VM GUI lane (T4 LiveApp / T5 pixel / MDV_UI_SCENE window-capture / in-process WebView) — these CAN be VM-validated (serially). "ax" = an AX-driven real-AXUIElement-event interaction test — these are the owner-off-limits tier to RUN, so they are AUTHORED + host-compile-checked only, owner validates.\n\nAim for 8-14 batches, file-DISJOINT (no two batches create/edit the same test file — they author in parallel worktrees). Prefer NEW test files per batch. Cover: editor interactions, markdown/preview render, data viewers, image editor, git panel, sidebar panels, command palette, launchpad, conflict-resolution sheet, content menus, first-run, find bars. Return the batches. Modify nothing.',
  { label: 'plan', phase: 'Plan', schema: PLAN_SCHEMA, effort: 'high', model: M })
if (!plan) throw new Error('plan agent died')
const batches = plan.batches.slice(0, 14)
const uatBatches = batches.filter(b => b.kind === 'uat')
const axBatches = batches.filter(b => b.kind === 'ax')
log('Plan: ' + batches.length + ' batches (' + uatBatches.length + ' uat / ' + axBatches.length + ' ax). Authoring all concurrently; validating <= ' + VM_VALIDATE_BUDGET + ' uat batches serially on the VM.')

// ---------- Author (concurrent, worktree-isolated) ----------
phase('Author')
function authorPrompt(b) {
  return 'AUTHOR ' + (b.kind === 'ax' ? 'AX-INTERACTION' : 'UI-UAT') + ' TESTS in an ISOLATED GIT WORKTREE (your cwd — verify with pwd/git status; work ONLY here). Read the repo CLAUDE.md + docs/TEST_PYRAMID.md first.\n\nBATCH: ' + b.slug + '\nSurface: ' + b.surface + '\nSuite to create/extend: ' + b.suite + (b.scene ? '\nScene: ' + b.scene + ' (add to UISceneRegistry.staticScenes + a UISceneApplier handler + map in scripts/vm-uitest.sh if new)' : '') + '\nCover: ' + b.what + '\n\nRULES:\n- Write REAL, meaningful tests (not tautologies) that would FAIL if the behavior regressed. Pin the model/behavior outcome. For ' + (b.kind === 'ax' ? 'AX tests: exercise the real AXUIElement adapter path where the harness supports it, else the exact wired action closure; these are AUTHORED for the owner to run on the VM AX lane (do NOT run them).' : 'UI-UAT: prefer a MDV_UI_SCENE + window-capture assertion or an in-process WebViewTestCase / T4 LiveAppTestCase, whichever fits.') + '\n- swift build MUST pass (compile-check your tests). Do NOT run the tests (UI/AX/VM tests are validated later in a serial lane). Do NOT run the full suite/gate. NEVER killall.\n- New test files ONLY where possible (avoid editing shared files so parallel batches don\'t collide). If you must touch UISceneRegistry/UISceneApplier/vm-uitest.sh for a scene, keep edits additive + minimal.\n- FORBIDDEN: new dependencies; modifying OwnerWishlist*/Untitled*/HANDOFF.md/BACKLOG.md/CHANGELOG.md; git push.\n- Commit per suite: subject "test(uat/' + b.slug + '): <what>", body ends with:\nClaude-Session: ' + SESSION + '\n\nReturn: branch (git branch --show-current), commits, testsAdded (file paths), compiles (did swift build pass), notes.'
}
const authored = (await parallel(batches.map(b => () =>
  agent(authorPrompt(b), { label: 'author:' + b.slug, phase: 'Author', schema: AUTHOR_SCHEMA, isolation: 'worktree', effort: 'high', model: M })
    .then(r => r ? Object.assign({ slug: b.slug, kind: b.kind, suite: b.suite }, r) : null)
))).filter(Boolean)
const authoredUat = authored.filter(a => a.kind === 'uat' && a.compiles)
log('Authoring done: ' + authored.length + ' batches returned, ' + authoredUat.length + ' uat compile-clean. Integrating + serially VM-validating up to ' + VM_VALIDATE_BUDGET + '.')

// ---------- Validate (SINGLE serial lane — the VM GUI session is a singleton) ----------
phase('Validate')
const toValidate = authoredUat.slice(0, VM_VALIDATE_BUDGET)
const branchList = authored.map(a => a.slug + ' [' + a.kind + ', compiles=' + a.compiles + '] branch=' + a.branch + ' suites=' + (a.testsAdded || []).join(',')).join('\n')
const valList = toValidate.map(a => a.slug + ' branch=' + a.branch + ' suite=' + a.suite).join('\n')
const validate = await agent(
  'You are the SINGLE SERIAL VALIDATION LANE for authored UI-UAT tests of ' + ROOT + '. The VM GUI lane (ssh macOS15, scripts/test-in-vm.sh) is a SINGLETON — exactly one GUI session / window server — so UI validation CANNOT run concurrently; you run it ONE suite at a time in a loop. Work on the MAIN worktree (' + ROOT + '); NEVER commit to main — use a scratch branch.\n\nAuthored batches (each on its own worktree branch):\n' + branchList + '\n\nDO:\n1. Create a scratch integration branch off main (e.g. `uat-validate-<n>`). Merge/cherry-pick the commits from the UI-UAT branches listed below onto it (git merge --no-ff <branch> or cherry-pick their commit SHAs). Resolve trivial conflicts; skip a branch that conflicts badly and record it as pending.\n2. Host sanity: `swift build` must pass on the integration branch. Fix trivial compile breaks from the merge; if a suite won\'t compile, drop it + record pending.\n3. SERIALLY validate up to these UI-UAT suites on the VM, ONE AT A TIME (the lane is a singleton). For each: rsync to macOS15 then `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all` filtered to that suite (or `webview` mode for in-process WebView suites). READ the full output; record pass/fail per suite. Do NOT run them in parallel.\nSUITES TO VALIDATE (in order):\n' + (valList || '(none compile-clean)') + '\n4. All OTHER authored batches (the rest of the uat ones beyond the budget, and ALL ax batches) go into `pending` with the exact serial VM command to run each — the follow-up loop / owner runs those (ax tests are the owner-off-limits AX tier: author-only).\n5. Write ' + RDIR + '/VALIDATION_REPORT.md — the authored inventory, per-suite VM results, the pending serial plan, and the concurrency rationale (why authoring parallelized but validation did not).\n\nConstraints: never killall; never push; never commit to main; do not touch OwnerWishlist*/Untitled*/HANDOFF.md/BACKLOG.md.\n\nReturn: reportPath, integrationBranch, validated [{suite,result,detail}], pending [suite names], notes.',
  { label: 'serial-vm-validate', phase: 'Validate', schema: VALIDATE_SCHEMA, effort: 'high', model: M })

return {
  reportDir: RDIR,
  validationReport: validate ? validate.reportPath : null,
  integrationBranch: validate ? validate.integrationBranch : null,
  plannedBatches: batches.length,
  authoredBranches: authored.map(a => ({ slug: a.slug, kind: a.kind, branch: a.branch, compiles: a.compiles, tests: (a.testsAdded || []).length })),
  vmValidated: validate ? validate.validated : [],
  pending: validate ? validate.pending : authored.map(a => a.slug),
  axAuthorOnly: axBatches.map(b => b.slug),
}
