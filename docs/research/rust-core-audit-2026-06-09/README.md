# rust-core production-readiness audit — 2026-06-09

9-agent ultracode audit of `rust-core/` (workflow `wf_6b6443d9-5c6`, all Fable 5): 7 primed dimensions
+ 2 blank-slate explorers; every S1–S3 finding adversarially verified; design proposals critique-judged.
**PARTIAL RUN:** the review phase completed in full; ~26 verifications + the synthesis hit the session
usage limit (resets 10:40pm Toronto). Resume: `Workflow({scriptPath, resumeFromRunId: "wf_6b6443d9-5c6"})`
— completed agents return cached. Findings below marked UNVERIFIED had their verifier die on the limit,
NOT a refutation.

| Dimension | Kind | Confirmed | Refuted | Unverified | Nits | Proposals |
|---|---|---|---|---|---|---|
| [unsafe-ffi](unsafe-ffi.md) | findings | 3 | 0 | 0 | 5 | 0 |
| [security](security.md) | findings | 1 | 0 | 3 | 3 | 0 |
| [performance](performance.md) | findings | 5 | 0 | 6 | 6 | 0 |
| [correctness](correctness.md) | findings | 0 | 0 | 3 | 4 | 0 |
| [architecture](architecture.md) | proposals | 0 | 0 | 0 | 0 | 8 |
| [api-contract](api-contract.md) | proposals | 0 | 0 | 0 | 0 | 10 |
| [testing](testing.md) | proposals | 0 | 0 | 0 | 0 | 9 |
| [efficiency-of-means](efficiency-of-means.md) | findings | 0 | 0 | 10 | 4 | 0 |
| [explorer-a](explorer-a.md) | findings | 8 | 0 | 0 | 6 | 0 |
| [explorer-b](explorer-b.md) | findings | 0 | 0 | 4 | 2 | 0 |

**Totals:** confirmed 17 · proposals 27 · synthesis: PENDING (resume after limit reset).

Tickets: confirmed findings filed under epic **TSK-538**, tag `rust-core-audit`.