export const meta = {
  name: 'finish-next-50',
  description: 'Complete the next ~50 actionable board tasks in one batch, grouped into worktree-isolated fixer agents (Fable throughout)',
  phases: [
    { title: 'Select', detail: 'pull the next ~50 ready tasks from the board, group into file-disjoint batches' },
    { title: 'Execute', detail: 'worktree-isolated agent per batch: implement + host-test + commit + board to review' },
  ],
}

const ROOT = '/Users/me/Documents/workspaces/claude/markdown_viewer'
const SESSION = 'https://claude.ai/code/<session>'
const M = 'fable'   // owner directive: whole workflow on Fable
const MAX_BATCHES = 14

const SELECT_SCHEMA = { type: 'object', required: ['batches'], properties: { totalTasks: { type: 'number' }, batches: { type: 'array', items: { type: 'object', required: ['name', 'area', 'tasks'], properties: { name: { type: 'string' }, area: { type: 'string' }, tasks: { type: 'array', items: { type: 'object', required: ['id', 'title'], properties: { id: { type: 'string' }, title: { type: 'string' }, files: { type: 'array', items: { type: 'string' } } } } } } } } } }
const EXEC_SCHEMA = { type: 'object', required: ['branch', 'completed', 'skipped'], properties: { branch: { type: 'string' }, commits: { type: 'array', items: { type: 'string' } }, completed: { type: 'array', items: { type: 'object', required: ['id', 'title', 'state'], properties: { id: { type: 'string' }, title: { type: 'string' }, state: { type: 'string' }, commit: { type: 'string' } } } }, skipped: { type: 'array', items: { type: 'object', required: ['id', 'reason'], properties: { id: { type: 'string' }, reason: { type: 'string' } } } }, testsAdded: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } } }

// ---------- Select ----------
phase('Select')
log('Finish-50: selecting the next ~50 ready board tasks (Fable) and grouping into file-disjoint batches')
const sel = await agent(
  'SELECT the next ~50 ACTIONABLE tasks to complete for the repo at ' + ROOT + '. The board is the tasked MCP (project "tasked", agent id claude-mdv) — reach mcp__tasked__task_list / task_next / task_get via ToolSearch. Also read BACKLOG.md §1 (the curated priority order) and HANDOFF.md for current state.\n\nRULES for selection:\n- ONLY tasks for THIS repo (project "tasked"). SKIP foreign tasks (agent:forge / sess-forge-* / other projects).\n- ONLY actionable states: reported / ack / triaged / progress. SKIP anything already fixed/review/validated/done.\n- SKIP owner-gated / blocked tasks: blocker != none, §2 OWNER-GATED items, [dep]/[XL]-epic/one-way-door, anything needing owner approval or a product decision, AX-driven-test tickets (owner-off-limits), and pure-VM-only render tasks that can\'t be host-progressed.\n- PREFER: BACKLOG §1 order, host-testable model/logic/wiring work, and tasks whose files you can identify (task_get to read report + files).\n\nGroup the selected tasks into ' + MAX_BATCHES + ' or fewer BATCHES by subsystem/area so batches are as FILE-DISJOINT as possible (each batch runs in its own git worktree; overlapping files across batches cause messy merges later). 3-5 tasks per batch. For each task include id, title, and the files you expect it to touch (from task_get). Return totalTasks + the batches. Modify nothing.',
  { label: 'select-tasks', phase: 'Select', schema: SELECT_SCHEMA, effort: 'high', model: M })
if (!sel) throw new Error('select agent died')
const batches = sel.batches.slice(0, MAX_BATCHES)
const taskCount = batches.reduce((n, b) => n + b.tasks.length, 0)
log('Selected ' + taskCount + ' tasks across ' + batches.length + ' worktree batches')

// ---------- Execute (concurrent, worktree-isolated) ----------
phase('Execute')
function execPrompt(b) {
  const list = b.tasks.map((t, i) => (i + 1) + '. ' + t.id + ' — ' + t.title + (t.files && t.files.length ? '  (files: ' + t.files.join(', ') + ')' : '')).join('\n')
  return 'You are COMPLETING board tasks in an ISOLATED GIT WORKTREE (your cwd — verify pwd/git status; work ONLY here). FIRST read the repo CLAUDE.md IN FULL and docs/TASK_WORKFLOW.md — follow the project SOP exactly.\n\nBATCH: ' + b.name + ' (area: ' + b.area + ')\nTASKS:\n' + list + '\n\nFOR EACH TASK:\n1. task_get (mcp__tasked__task_get via ToolSearch, agent claude-mdv) — READ its report + existing understanding/comments FIRST. Verify-before-build: many "open" items are already done on main — if so, skip + record.\n2. DIAGNOSE the real root cause, then implement a production-quality fix/feature matching the surrounding style.\n3. Every behavior change ships with a HOST test that pins it (Swift Testing for new pure-logic; XCTest otherwise). render/VM behavior: host-test the model + flag "on-screen UNVERIFIED — needs VM" (do NOT run VM/UI tests).\n4. swift build must pass; run `swift test --filter <suites you touched/added>` and make them green. Do NOT run the full suite/gate; do NOT run UI/window tests; NEVER killall.\n5. Commit per task: subject "<type>(<area>): <what> [<TSK-id>]", body says why, ends with:\nClaude-Session: ' + SESSION + '\n6. Board it: task_advance to fixed then task_record to review with a checks artifact (agent claude-mdv). NEVER task_validate. If a task needs an owner decision / a new dependency / is not actually doable host-side, SKIP it, record why, and leave it as-is (do not park from here).\n\nFORBIDDEN: new dependencies (skip + record); modifying OwnerWishlist.md/OwnerWishlist.md.bak/Untitled.txt/archive/Untitled.txt/HANDOFF.md/BACKLOG.md/CHANGELOG.md; git push; touching the VM or anything outside this worktree.\n\nReturn: branch (git branch --show-current), commits, completed [{id,title,state,commit}], skipped [{id,reason}], testsAdded, notes.'
}
const results = (await parallel(batches.map(b => () =>
  agent(execPrompt(b), { label: 'exec:' + b.name, phase: 'Execute', schema: EXEC_SCHEMA, isolation: 'worktree', effort: 'high', model: M })
    .then(r => r ? Object.assign({ batch: b.name }, r) : null)
))).filter(Boolean)

const done = results.reduce((n, r) => n + (r.completed || []).length, 0)
const skipped = results.reduce((n, r) => n + (r.skipped || []).length, 0)
log('Execute done: ' + done + ' tasks completed, ' + skipped + ' skipped, across ' + results.length + ' branches')

return {
  selected: taskCount,
  batches: batches.length,
  completed: done,
  skipped: skipped,
  branches: results.map(r => ({ batch: r.batch, branch: r.branch, completed: (r.completed || []).length, skipped: (r.skipped || []).length, tests: (r.testsAdded || []).length })),
  detail: results.map(r => ({ batch: r.batch, branch: r.branch, completed: r.completed, skipped: r.skipped, notes: r.notes })),
}
