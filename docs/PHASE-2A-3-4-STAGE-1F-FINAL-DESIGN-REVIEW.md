# ZamBase Phase 2A.3.4 — Stage 1F Independent Final Design Review

> **Read-only review.** No source, migration, configuration, database object,
> data, role, grant, policy, or function was modified. No database write,
> migration, hosted-project connection, or destructive operation was performed.
> This review creates only this report. Prior local database findings are
> identified as prior evidence, not as fresh observations.

## 1. Executive summary

**Verdict: NO-GO for Stage 2 implementation.**

Stage 1E substantially improves Stage 1C. Its executor policies are
tenant-scoped, it separates source/membership locking from executor DML, it
sets a coherent committed-decision idempotency contract, corrects the main
typed-index ordering issue, inventories more application paths, and expands
the test plan. The Stage 1E text is materially better specified, but it does
not genuinely resolve every F1–F11 to implementation-ready certainty:

- The security and locking design has not been executed under the proposed
  executor and real Supabase JWT context. In addition, the RPC locks a
  candidate before checking the caller's locked owner/admin membership. A
  tenant member can execute the RPC and may acquire that row lock under the
  executor's member-scoped SELECT policy before the helper rejects them.
- Acceptance tests only for `deleted_at`; actual entity status also includes
  `rejected` and `merged`. The executor cannot SELECT `status`, and no policy
  says whether either state may receive new links.
- The migration sequence still places reviewer-decision child indexes before
  the nullable columns those indexes reference.
- Authenticated users can still submit `match.accepted` or
  `match.rejected` to the generic audit function. Stage 1E identifies this
  but leaves the mitigation as an unresolved choice.
- Existing source immutability triggers make the stated company-level
  `ON DELETE CASCADE` lifecycle unsafe: a cascade that tries to delete a
  source row fires the trigger and raises. This interaction is not addressed
  in the deletion plan.
- Application conflict/replay responses and durable key retention are not
  specified down to the actual Next.js action/UI contract.
- No local executor/RLS, ownership-transfer, or workflow concurrency test has
  been run or added. The existing worker tests do not establish this design.
- Migration 06 provenance and hosted database state remain unverified.

Thus, proposed corrections are not equivalent to verified resolution. Stage
1E itself appropriately says NO-GO; this independent review agrees.

## 2. Scope and limitations

This review inspected the Stage 1C, 1D, and 1E documents; current
reconciliation schema/RLS, helper, worker, and audit migrations; current
Next.js reconciliation actions/pages; and existing worker/idempotency tests.
PostgreSQL 15 documentation was fetched for row-lock privileges, RLS, and
function ownership transfer. No PostgreSQL execution was performed.

Evidence labels:

- **Repository verified:** directly visible in checked-out repository files.
- **Prior local finding:** recorded in Stage 1A/1B from prior local
  read-only database inspection; not queried again for Stage 1F.
- **PostgreSQL 15 documented:** confirmed against the cited official
  PostgreSQL 15 documentation, but not a ZamBase runtime test.
- **Unverified:** depends on actual role attributes/ACLs, function bodies,
  JWT claims, runtime transaction behavior, or hosted state not inspected.

This review does not certify local database state merely because Stage 1A/1B
reported results. It does not identify or inspect a hosted Supabase project.

## 3. Documents and repository files inspected

The three mandatory design documents were read:

- [Stage 1C blueprint](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md)
- [Stage 1D verification](./PHASE-2A-3-4-STAGE-1D-DESIGN-VERIFICATION.md)
- [Stage 1E corrected blueprint](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md)

Repository sources checked include:

- [Reconciliation schema, policies, audit wrapper, and source trigger](../supabase/migrations/20261029000001_reconciliation_module.sql)
- [Membership/identity helper functions](../supabase/migrations/20260514000007_helper_functions.sql)
- [Membership RLS policies](../supabase/migrations/20260514000008_rls_policies.sql)
- [Worker and audit security](../supabase/migrations/20261031000001_worker_and_audit_security.sql)
- [Audit containment and wrapper revokes](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql)
- [Current reconciliation server actions](../examples/nextjs/lib/actions/reconciliation.ts)
- [Current review page](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx)
- [Current entity list](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx)
- [Current entity export page](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx)
- [Existing reconciliation RLS tests](../supabase/tests/rls.test.sql)
- [Worker security SQL test](../supabase/tests/worker_security.test.sql)
- [Worker lease unit tests](../services/reconciliation/tests/test_matching_worker_lease.py)
- [Existing idempotency SQL fixture](../services/reconciliation/tests/test_idempotency.sql)
- [Stage 1B migration-history report](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md)

The filename `supabase/migrations/20261101000006_enforce_import_finish_lease.sql`
is absent from the current worktree. `git log --all -- <that path>` returned
no commits in the inspected repository. This does not establish that no
unreachable Git object or other clone contains it.

## 4. Verification matrix for F1–F11

“Resolved in design” means the correction is coherent on paper; it does not
mean the proposed role/function/schema was executed or verified.

| Finding | Original severity | Stage 1E proposed correction | Independent verification | Remaining risk | Status |
|---|---|---|---|---|---|
| F1 — Executor RLS isolation | High | §4.1 gives per-table/command tenant predicates, exact grants, and forbids allow-all policies. | The predicates use existing SECURITY DEFINER membership/role helpers. Base migration enables and forces RLS on these tables; existing policies target `authenticated`, so executor policies are necessary. Under PostgreSQL 15, FORCE RLS subjects a non-owner, non-BYPASSRLS executor to policies; it does not validate the JWT/helper behavior for Supabase. | No local invocation under executor + authenticated JWT; candidate lock-before-admin-check leaves a lock surface (N1). Helper runtime/ownership/effective ACL and hosted policy behavior are not inspected. | **PARTIALLY VERIFIED** |
| F2 — Row-lock privileges | High | §3.3/§5 use the executor for candidate/entity locks and `postgres`-owned helper functions for membership/source locks; no source UPDATE is granted to executor. | PostgreSQL 15 requires SELECT plus UPDATE privilege on at least one column for `SELECT ... FOR UPDATE/SHARE`. The design's privilege separation is directionally correct if helper owner has the needed privileges and is protected. The helper function signatures, exact SQL, return types, and actual ACL/RLS execution are not supplied or tested. | `postgres` is a privileged local owner per prior reports; hosted attributes/capabilities are unknown. Authorization currently happens after candidate locking. | **PARTIALLY VERIFIED** |
| F3 — Helper/audit grants | High | §3.4/§4 list schema/type USAGE, identity/role helper EXECUTE, audit-wrapper EXECUTE, and UUID approach. | Existing `auth_uid`, `is_member_of`, and `has_role_in` revoke PUBLIC and grant only to authenticated/anon/service_role; the new executor therefore needs explicit grants as Stage 1E says. `log_reconciliation_audit` is SECURITY DEFINER and its later migration revokes application/service/worker/scheduler EXECUTE. | Effective grants, function owners, wrapper audit RLS behavior, and hosted ACL are not tested. Generic audit action spoofing remains (N4). Stage 1E also inaccurately says the existing policy helpers read identity “through `public.auth_uid()`”; their SQL bodies call `auth.uid()` directly. | **PARTIALLY VERIFIED** |
| F4 — Ownership transfer | High | §12.2 provides temporary schema CREATE/role-membership, transfer, revoke, and final-state checks. | PostgreSQL 15 `ALTER FUNCTION ... OWNER TO` requires the caller to own the function and be a member of the new owner role; the new owner must have CREATE on the function schema. Stage 1E describes these conditions correctly. | The managed Supabase migration principal's authority and the proposed temporary grant/revoke sequence have not been tested. | **RESOLVED IN DESIGN; NOT RUNTIME-VERIFIED** |
| F5 — Idempotency | High | §7 selects committed-decision-only keys, scoped by `(company_id, reviewer_id, idempotency_key)`, with candidate/action binding, advisory lock, mismatch response, and same-key network retry. | This is a coherent, explicitly limited contract. Conflicts do not reserve keys; replay is available only after a committed decision. The database partial unique indexes provide a durable committed-key guard. | No implementation or response-loss test. Key persistence location across page reload/process restart and uncertain action/UI result mapping remain vague (F10). | **RESOLVED IN DESIGN; NOT TESTED** |
| F6 — Membership race | High | §5.2/§5.3 reads the role from a locked membership tuple, retains `FOR SHARE` through transaction end, specifies READ COMMITTED and retry SQLSTATEs. | Row-locking an existing membership row serializes with a concurrent update/delete; the proposed lock-first/role-read behavior is coherent at READ COMMITTED. No actual PostgREST isolation/JWT test was performed. | The RPC takes the candidate lock before membership authorization; same-session behavior and lock denial for ordinary members require correction/testing (N1). | **PARTIALLY VERIFIED** |
| F7 — Migration ordering | Medium | §8.4 adds typed columns before typed partial unique indexes; §8.7 isolates concurrent indexes and later adds/validates FKs. | The prior ordering defect for the unique indexes is fixed. However §8.3 also defines decision child-side indexes on `candidate_id` and `result_entity_id`, while §8.7 step 4 creates child-side indexes before step 5 adds those columns. Following the sequence literally fails. | Migration sequence remains non-executable as written. Move those two indexes after the typed columns and before FK validation/creation as appropriate. | **UNRESOLVED; BLOCKS MIGRATION DESIGN** |
| F8 — Child indexes/FK deletion lifecycle | Medium | §§8–9 enumerate parent/child keys, composite FKs, `NOT VALID` validation, RESTRICT actions, company/entity/reviewer lifecycle. | Most relevant FK and index issues are addressed. The base source immutability trigger raises on DELETE, including FK-driven source deletion; the company CASCADE plan does not account for that. Entity/reviewer state semantics and actual constraint transition are not runtime-verified. | Company deletion can fail due to the source trigger; existing/replaced FKs can also block deletion. Reviewer erasure and historical rows remain unresolved by design. | **PARTIALLY VERIFIED; LIFECYCLE BLOCKED** |
| F9 — All application write paths | Medium | §10 inventories accept/reject, confirmation, export, discrepancies, import/matching workers, lists, and operational paths; confirmation gets a separate RPC; discrepancies are deferred. | This is a substantial and useful inventory. Existing `confirmEntity` performs direct UPDATE + separate audit; `resolveDiscrepancy` is another non-atomic human decision. Stage 1E does not specify the confirmation RPC contract or provide a deployable cutover; discrepancy DML must remain outside the limited revoke. | Direct entity DML cannot be revoked until confirmation replacement exists. The app/service/external caller inventory is not exhaustive. | **PARTIALLY VERIFIED** |
| F10 — Application idempotency/result handling | Medium | §7 describes key lifecycle; §6 defines JSON outcomes; §10 requires action/UI adapter changes. | Existing action signatures accept only candidate IDs. The review UI checks only `result.error`; it does not render a conflict/status result. Stage 1E says to map typed outcomes but does not define the exact action return union, alert/refresh behavior, or persistent key location. | A conflict/replay could be silent or misrepresented; retries after component/page loss may not retain the key. | **PARTIALLY VERIFIED** |
| F11 — Test completeness | Medium | §11 adds local security/integration, staging concurrency, and production read-only cases, including all Stage 1D omissions. | The listed tests are relevant. Existing `rls.test.sql` covers base authenticated tenant isolation, entity status RBAC, and source immutability; `worker_security.test.sql` covers worker boundaries. Neither proves proposed executor RLS or human decision RPC behavior. The SQL idempotency fixture is source-ingest deduplication, not RPC idempotency. | Tests are plans only; none were run or added (this review is read-only). | **RESOLVED IN TEST PLAN; NOT VERIFIED** |

### PostgreSQL 15 behaviors verified versus assumed

Verified from official PostgreSQL 15 docs:

- `SELECT ... FOR UPDATE/SHARE` requires SELECT privileges and UPDATE
  privilege on at least one column of each locked table.
- RLS policies are role/command scoped; `FORCE ROW LEVEL SECURITY` subjects
  table owners, while superusers and BYPASSRLS roles still bypass RLS.
- Function owner transfer requires the current owner (or suitable authority),
  membership in the new owning role, and CREATE on the function schema for the
  new owner.
- Concurrent `CREATE INDEX` limitations are stated in PostgreSQL docs; the
  Stage 1B CLI v2.119.0 batching observation is prior source inspection, not a
  DDL failure rehearsal.

Not verified by PostgreSQL docs alone: Supabase `auth.uid()` request-claim
availability through nested SECURITY DEFINER calls; hosted role/ACL state;
PostgREST transaction isolation; effective policies/grants; helper SQL; and
all runtime concurrency claims.

References: [PostgreSQL 15 SELECT](https://www.postgresql.org/docs/15/sql-select.html),
[row security](https://www.postgresql.org/docs/15/ddl-rowsecurity.html),
[ALTER FUNCTION](https://www.postgresql.org/docs/15/sql-alterfunction.html),
and [privileges](https://www.postgresql.org/docs/15/ddl-priv.html).

## 5. Business-rule consistency review

| Business rule | Stage 1E consistency |
|---|---|
| One source record has at most one entity link | Proposed unique `(company_id, source_record_id)` index and tenant FK enforce this, including links to soft-deleted entities. Must be proven against existing rows and all writers. |
| Acceptance establishes provenance, not canonical merge | Consistent: new entity canonical data is `{}` and existing canonical data/survivorship are not updated. |
| Conflicting source links produce explicit conflict | Consistent for different linked entity IDs; requires source/link locks and one-source index at runtime. |
| New entity uses manual survivorship | Consistent: proposed `manual_review_required`. |
| Only current owner/admin may decide | Locked membership role is correct in concept; candidate is locked before this authorization and creates the N1 lock exposure. |
| Rejection creates no entity or identifier | Consistent in RPC contract. |
| Source rows remain immutable | No executor DML and existing trigger retained. Company cascade behavior conflicts with the deletion design (N5). |
| Soft-deleted entity is not restored or reused | Consistent for `deleted_at IS NOT NULL`; incomplete for nondeleted entities with status `merged` or `rejected` (N2). |
| Decision and audit atomic | The RPC design uses one statement/transaction and mandatory audit wrapper. Generic `log_audit` still permits forged workflow-labeled events, so the audit stream is not authoritative without a resolved correlation/restriction policy (N4). |
| Import/matching workers continue | Existing worker RPC boundaries are to be preserved; candidate pair normalization requires coordinated worker changes and tests. |

## 6. Migration 06 investigation

**Repository verified:** the worktree contains `20261101000002` but no
`20261101000006` migration file. A path-specific `git log --all` query found no
commit for the missing path in inspected history.

**Prior local finding only:** Stage 1B reports local migration metadata for
`20261101000006` with four stored statements, and reports the active local
`reconciliation_finish_import(...)` definition matches that stored SQL. Stage
1B also reports a 1,000-character error cap in 06 versus 10,000 in 02. Stage
1F did not connect to a database to recheck these claims.

**Not established:** the original Git contents/author, the process that
applied version 06, whether local metadata is authoritative, or whether any
hosted database has the same row/function. Stage 1E correctly says not to
reconstruct, apply, or silently edit migration history. Owner-approved
provenance and an exact-target read-only comparison are still required.

## 7. Hosted Supabase verification boundary

**Hosted Supabase state remains unverified. Stage 1F cannot establish production database readiness.**

The repository and earlier reports do not safely identify an intended hosted
project. No project was guessed, linked, or inspected. Production approval
requires the project owner to identify the exact project ref, organization,
and environment out of band and authorize read-only inspection. Required
checks include migration version 06; active function definition/owner/security
settings/grants; data preflight; constraints/index validity; RLS enabled and
forced; policy predicates; role attributes/memberships; schema/type/column
privileges; helper/audit wrapper ownership and EXECUTE; worker/service-role
boundaries; CLI/PostgreSQL versions; and entity/source/delete lifecycle.

Do not provide credentials, access tokens, or API keys in the report or chat.

## 8. New findings beyond F1–F11

### N1 — Medium: a tenant member can reach candidate locking before role denial

**Affected:** Stage 1E §§4.1, 5.1, 6.2; candidate SELECT/UPDATE policies in
the proposed executor model.

Stage 1E grants authenticated users EXECUTE on both RPCs. The executor's
candidate SELECT policy is tenant-membership scoped, while the RPC flow takes
`FOR UPDATE` on the candidate before calling the membership authorization
helper. PostgreSQL treats this as a SELECT command for RLS policy selection;
the locking clause additionally requires UPDATE privilege, which the
executor has. Therefore, a member who is not owner/admin can call the RPC,
pass tenant-scoped SELECT policy, acquire the row lock, and only then receive
`42501` from the helper. This is not a decision-write bypass, but concurrent
unauthorized calls can contend with legitimate review decisions.

**Required correction:** authorize and lock the caller's membership before
locking the candidate, then lock/re-read the candidate and revalidate tenant
and status; alternatively, use an executor candidate SELECT policy restricted
to owner/admin and prove the policy does not break intended access. Add a
two-session test showing a member cannot hold a candidate lock while an
authorized review proceeds. **Blocks Stage 2 security sign-off.**

Evidence: [Stage 1E lock order and common flow](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L300),
[executor candidate policies](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L229),
[existing candidate member SELECT policy](../supabase/migrations/20261029000001_reconciliation_module.sql#L484),
and [PostgreSQL SELECT locking/RLS docs](https://www.postgresql.org/docs/15/sql-select.html).

### N2 — Medium: accept does not define eligibility for merged/rejected entities

**Affected:** `reconciliation_entities.status`, executor entity SELECT
privileges, and accept RPC.

The repository enum has `candidate`, `confirmed`, `rejected`, and `merged`.
Stage 1E says to check the existing entity's deleted state, but its executor
SELECT grant omits `status`, and accept's conflict rules only reject
`deleted_at IS NOT NULL`. A nondeleted entity in `merged` or `rejected` state
can therefore be treated as an eligible existing target under the written
contract. This is inconsistent with an explicit lifecycle and can attach new
provenance to an entity that is no longer an active target.

**Required correction:** define which entity statuses are eligible (at
minimum explicitly decide the behavior for `merged` and `rejected`); include
status in the executor's narrow SELECT grant/policy if the RPC checks it; lock
and validate the status before links are inserted. A merged-entity redirect
or restoration must be a separate authorized operation, not implicit in
accept. **Blocks acceptance RPC implementation until the lifecycle rule is explicit.**

Evidence: [entity status enum](../supabase/migrations/20261029000001_reconciliation_module.sql#L36),
[entity table status/deleted columns](../supabase/migrations/20261029000001_reconciliation_module.sql#L226),
[Stage 1E executor entity SELECT grant](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L243),
and [accept semantics](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L425).

### N3 — Medium: typed-decision child-index order still references absent columns

**Affected:** Stage 1E §§8.3 and 8.7.

Section 8.3 includes child-side indexes on reviewer-decision
`(company_id, candidate_id)` and `(company_id, result_entity_id)`. Section
8.7 step 4 places child-side index creation before step 5 adds those nullable
columns. A migration following this order fails with undefined-column errors.
This is distinct from the fixed partial-unique-index ordering.

**Required correction:** split existing-column child indexes from the typed
decision indexes. Add the latter after §8.4 columns/checks and before
composite-FK validation; isolate concurrent indexes as already required.
**Blocks migration implementation until corrected.**

Evidence: [child-index list](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L685),
[typed-column addition](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L692),
and [migration ordering](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L787).

### N4 — High: authenticated callers can forge workflow-labeled audit events

**Affected:** `public.log_audit`, `audit_action`, and Stage 1E §6.6.

The current audit enum includes `match.accepted` and `match.rejected`.
`public.log_audit(...)` is SECURITY DEFINER and explicitly grants EXECUTE to
`authenticated`; its authorization checks tenant membership but do not
restrict `_action` to actions the caller is entitled to assert. A tenant
member can therefore append an audit row claiming a match was accepted or
rejected even when no typed decision exists. Stage 1E identifies this but
leaves two alternatives unresolved; the test plan says authenticated users
cannot create authoritative events without specifying how the generic helper
will enforce that.

**Required correction:** either reject workflow-owned action values in the
generic user-callable helper (after caller inventory), or define and enforce
that only a matching typed decision plus correlated RPC audit event is
authoritative, including consumer/query behavior. Add a negative audit
forgery test. **Blocks audit-integrity sign-off.**

Evidence: [workflow audit enum values](../supabase/migrations/20261029000001_reconciliation_module.sql#L125),
[generic audit helper](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L50)
and [authenticated EXECUTE grant](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L104),
[Stage 1E unresolved audit choice](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L502).

### N5 — Medium: source immutability trigger conflicts with company cascade deletion

**Affected:** source-record trigger and company/reconciliation FK lifecycle.

The base schema declares company-level `ON DELETE CASCADE` references, while
`source_records_immutable` raises on every DELETE. A company deletion that
cascades to source rows invokes this trigger; the trigger raises and aborts
the delete statement/transaction. Stage 1E discusses possible interactions
between new RESTRICT FKs and company cascades, but does not account for this
existing trigger. The actual current behavior was not executed in this
review; it follows from the migration definition and PostgreSQL trigger/FK
semantics.

**Required correction:** explicitly define company erasure/retention and a
reviewed archival/erasure mechanism compatible with the immutable-source
trigger. Do not remove the trigger or relax immutability as an incidental
cascade fix. Rehearse the full FK/trigger graph on disposable data before
approving deletion behavior. **Blocks deletion-lifecycle approval.**

Evidence: [Stage 1E company deletion section](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L857),
[source-record company cascade](../supabase/migrations/20261029000001_reconciliation_module.sql#L195),
and [immutability trigger](../supabase/migrations/20261029000001_reconciliation_module.sql#L585).

### N6 — Medium: typed-row checks do not require a key for every new typed decision

**Affected:** reviewer-decision checks and the committed-decision idempotency invariant.

Stage 1E's checks require a non-NULL idempotency key to imply a typed
candidate, but do not state the converse that every typed match decision
(`candidate_id IS NOT NULL`) must have a non-NULL idempotency key. RPC code
always supplies one, but the stated schema invariant permits a typed decision
without a key if another future privileged writer or implementation defect
inserts one. The candidate unique index prevents duplicate candidate
decisions but does not make the decision replayable by key.

**Required correction:** for new typed rows, require a non-NULL key whenever
`candidate_id` is non-NULL, while leaving legacy rows with `candidate_id IS
NULL` untouched. Test the constraint and preserve the intended historical
NULL cases. **Blocks schema/idempotency invariant sign-off.**

Evidence: [Stage 1E typed-decision checks and indexes](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L692)
and [idempotency contract](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md#L530).

## 9. Final implementation-readiness checklist

| Category | Status | Evidence / remaining gate |
|---|---|---|
| Database security | **PARTIALLY VERIFIED** | Least-privilege intent is coherent; executor/helper execution, direct ACLs, owner attributes, and member lock contention are not tested. |
| RLS and tenant isolation | **PARTIALLY VERIFIED** | Existing tables use ENABLE/FORCE RLS; proposed predicates are tenant-scoped. Must verify actual helper/JWT behavior and all policy/grant combinations under executor. |
| Function ownership and grants | **PARTIALLY VERIFIED** | PostgreSQL ownership procedure is documented correctly; hosted migration principal and final effective ACLs are unknown. |
| Locking and concurrency | **PARTIALLY VERIFIED** | Lock-order rationale is improved, but authorization follows candidate lock; no two-session tests; helper SQL/returns not finalized. |
| Idempotency | **PARTIALLY VERIFIED** | Committed-only contract is clear; schema check omits typed-row key requirement; application key persistence and response-loss tests are not verified. |
| Audit integrity | **NOT VERIFIED** | Atomic wrapper design is plausible, but generic `log_audit` permits workflow-labeled events; wrapper owner and hosted behavior unknown. |
| Migration safety | **NOT VERIFIED** | Decision child-index order is still wrong; index failure recovery is planned, not rehearsed; migration 06 unresolved. |
| Application integration | **PARTIALLY VERIFIED** | Main paths are inventoried. Confirmation RPC contract and UI status/result mapping are not specified/implemented; external callers not inventoried. |
| Worker compatibility | **PARTIALLY VERIFIED** | Existing restricted worker RPCs and tests were inspected. Normalized pair cutover is unimplemented and no post-change test exists. |
| Tests | **NOT VERIFIED** | Stage 1E test matrix is broad but proposed only; no Stage 2 integration/concurrency tests run or added. |
| Hosted environment verification | **BLOCKED** | Exact hosted project is not identified or authorized; no hosted state was inspected. |
| Rollback and recovery | **PARTIALLY VERIFIED** | Safe principles are documented; actual CLI version and concurrent-index failure procedure remain untested. |

## 10. Recommended Stage 2 implementation sequence, if justified

Stage 2 is **not justified or authorized** now. Before requesting authorization,
produce a narrowly scoped design correction that:

1. Reorders typed-decision child indexes after their columns exist.
2. Defines accepted entity status values and handles `merged`/`rejected`
   targets without implicit reuse.
3. Moves locked membership authorization before candidate row locking (or
   proves an admin-only executor SELECT policy prevents unauthorized locks).
4. Resolves generic audit action forgery and correlates authoritative audit
   events to typed decisions.
5. Reconciles company deletion with the immutable-source trigger and defines
   reviewer/account erasure.
6. Requires non-NULL keys on new typed decisions.
7. Specifies helper exact SQL signatures/return types, function grants, the
   application result union, and where a key survives a network timeout.

After that document correction, independently review it before any migration
work. Then, only with separate authorization, test the proposed design in a
disposable local database, followed by staging integration/concurrency tests.
Do not connect to hosted Supabase until its owner identifies the exact project
and explicitly authorizes read-only inspection.

## 11. Rollback and recovery considerations

- Concurrent-index success/failure and migration-history recording are not a
  single atomic unit in the CLI behavior reported by Stage 1B. Inspect index
  validity and history before retries; never blindly rerun.
- A later failure does not imply a preceding concurrent index or flushed
  migration batch was rolled back.
- Keep review actions disabled if RPC/audit checks fail after cutover; do not
  restore broad authenticated DML as an emergency workaround.
- Do not delete/rewire source links, fabricate historical decisions, or
  restore/merge entities as rollback. Use a separately approved, audited
  correction workflow.
- Company/account deletion remains blocked pending lifecycle approval and a
  disposable rehearsal that includes the source immutability trigger.
- No production DDL/DML, concurrency test, or failure injection is authorized
  by this report.

## 12. Final verdict

**NO-GO. Stage 2 is not authorized.**

Stage 1E genuinely resolves several Stage 1D design deficiencies—especially
the tenant-scoped policy design, use of trusted lock helpers, owner-transfer
preconditions, committed-decision idempotency, and breadth of test coverage.
It does **not** close all F1–F11: F1–F3 and F6 remain runtime-unverified; F7
still has an index-order defect; F8–F10 have unresolved lifecycle or
application cutover details; and F11 is a proposed test plan, not evidence
that tests pass. N1–N6 add material corrections to the design.

The missing migration 06 remains an unresolved local-history discrepancy.
Hosted Supabase state remains unverified. The next recommended action is a
Stage 1E design amendment addressing N1–N6 and the incomplete F7–F10 items,
followed by a fresh independent review. No database or application
implementation should begin before that review, local verification, migration
provenance resolution, and the required hosted read-only evidence gates.
