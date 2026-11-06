# ZamBase Phase 2A.3.4 — Stage 1D Design Verification

> **Read-only independent review.** No application code, migrations, database
> objects, data, roles, grants, RLS policies, or configuration were changed.
> No database connection, migration command, or hosted-project operation was
> performed for this review. PostgreSQL-specific statements below are checked
> against PostgreSQL 15 documentation; repository/database observations from
> Stage 1A/1B are identified as prior local findings, not new live checks.

## 1. Executive verdict

**NO-GO for Stage 2 implementation.**

The Stage 1C blueprint has the right business direction: no automatic entity
merge or canonical-value survivorship, current owner/admin review, immutable
source records, explicit deleted-entity conflicts, tenant-aware constraints,
and atomic decision/audit intent. However, it is not yet a safe or executable
implementation specification:

- The executor's listed privileges do not permit all specified row locks.
- The existing membership RLS policies do not apply to the executor, and no
  tenant-filtered executor policies are specified. A broad executor policy
  would give the SECURITY DEFINER owner cross-tenant table access.
- Existing helper/audit EXECUTE grants do not include the new executor.
- PostgreSQL ownership transfer has an additional schema-privilege and role
  membership precondition missing from the proposed role plan.
- Migration ordering builds typed-decision indexes before adding their
  columns.
- Idempotency behavior for conflicts, error retries, and caller-generated key
  persistence is not fully defined.
- Direct entity confirmation and discrepancy resolution are not covered by
  the two match RPCs; DML revocation would break confirmation and would leave
  the discrepancy decision path non-atomic.
- The test plan needs actual adversarial RLS/definer, retry, deadlock,
  membership-race, and concurrent-index recovery cases.

No correctness claim is made about hosted Supabase. It was not inspected in
Stage 1A/1B, and this review did not link or connect to a hosted project.

### Evidence labels

- **Repository verified:** checked directly in the current repository.
- **Stage 1 local finding:** reported from prior read-only local PostgreSQL
  inspection; not re-queried for this review.
- **PostgreSQL 15 verified:** checked against official PostgreSQL 15 docs.
- **Inference / unverified:** plausible from the code or design, but not
  proven by a live hosted database or execution test.

## 2. Findings

### F1 — High: executor RLS needs explicit tenant scoping; otherwise it is a cross-tenant definer

**Issue.** The blueprint proposes a NOLOGIN, NOBYPASSRLS executor that owns
the SECURITY DEFINER RPCs and receives policies “targeted only” to that role,
but it does not define the policies' `USING`/`WITH CHECK` expressions. A policy
such as `USING (true)` on candidates, sources, entities, identifiers, and
decisions makes every tenant row accessible to either definer function.
NOLOGIN prevents direct connection; it does not constrain queries executed
under the function owner's identity.

**Why it matters.** PostgreSQL executes a SECURITY DEFINER function with the
function owner's privileges. With FORCE RLS, a non-BYPASSRLS, non-table-owner
function owner is subject to RLS, but only to policies applicable to that
owner. Row policies can use SECURITY DEFINER helpers; their expressions run
with the invoking role's privileges unless the helper itself is SECURITY
DEFINER. The executor's policy set is therefore part of the authorization
boundary, not an administrative detail.

**Evidence.** Stage 1C proposes executor policies but does not state their
tenant predicates at [blueprint lines 294–320](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L294).
The existing reconciliation policies target `authenticated`, e.g.
[the source/entity policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L421)
and [candidate/decision policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L478).
Membership RLS has policies only for `authenticated`, including its SELECT
policy at [migration lines 109–145](../supabase/migrations/20260514000008_rls_policies.sql#L109).
PostgreSQL 15 documents SECURITY DEFINER policy helpers, FORCE RLS, and
BYPASSRLS behavior in [Row Security Policies](https://www.postgresql.org/docs/15/ddl-rowsecurity.html).

**Required correction.** Define executor SELECT/UPDATE/INSERT policies per
table and command. For tenant rows, use a predicate such as
`public.is_member_of(company_id)` for visibility and
`public.has_role_in(company_id, 'admin')` for decision writes, with explicit
EXECUTE grants to the executor. Keep the RPC's independently derived
`company_id` and explicit tenant predicates as defense in depth. Do not use
unqualified allow-all policies. For membership locking, prefer a narrow
SECURITY DEFINER helper that checks the JWT identity and locks only that
identity's `(company_id,user_id)` row, rather than broad executor membership
table access. Test function output and table effects for a foreign-tenant
candidate ID; the response must not disclose whether that candidate exists.

**Blocks implementation:** Yes.

### F2 — High: specified source and membership row locks cannot run with the stated privileges

**Issue.** The RPC contract requires `SELECT ... FOR UPDATE` on source records
and `SELECT ... FOR SHARE` on the current membership row. The privilege matrix
gives the executor SELECT on both, but no UPDATE privilege on source records
or memberships.

**Why it matters.** PostgreSQL 15 requires SELECT on referenced columns and
UPDATE privilege on at least one column of each table for `FOR UPDATE`,
`FOR SHARE`, `FOR NO KEY UPDATE`, or `FOR KEY SHARE`. Without the required
privilege, these statements fail before the decision can proceed. Existing
membership policies also do not authorize the executor, and source records
have no update policy. Simply granting a write privilege/policy broadens the
definer role's authority and is not the safest fix.

**Evidence.** Stage 1C requires candidate, membership, and source locks at
[blueprint lines 392–414](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L392)
but its executor matrix lists source/membership SELECT only at
[line 524](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L524).
The source table has only member SELECT/INSERT policies, not UPDATE, at
[migration lines 421–428](../supabase/migrations/20261029000001_reconciliation_module.sql#L421).
Membership UPDATE is authenticated admin-only at
[migration lines 119–145](../supabase/migrations/20260514000008_rls_policies.sql#L119).
The SELECT privilege rule is explicit in the
[PostgreSQL 15 SELECT documentation](https://www.postgresql.org/docs/15/sql-select.html).

**Required correction.** Retain `FOR UPDATE` on the candidate and selected
entity only where the executor has the corresponding column UPDATE privilege
and matching RLS policy. Implement a small, separately reviewed
SECURITY DEFINER lock helper owned by a trusted database owner for source and
membership row locks; have it accept only tenant/source identifiers derived
from the candidate and the current `auth.uid()`, return no sensitive payload,
use an empty search path, and grant EXECUTE only to the workflow executor.
Alternatively, explicitly document and test another locking primitive that
preserves the concurrency invariant without granting inappropriate UPDATE
access. Do not silently add UPDATE access to immutable source rows.

**Blocks implementation:** Yes.

### F3 — High: helper and audit EXECUTE grants are missing for the executor

**Issue.** SECURITY DEFINER functions and RLS predicates call helpers, but the
blueprint does not provide a complete executable grant set. In particular,
`is_member_of` and `has_role_in` are granted to authenticated/service_role,
not the new executor; `log_reconciliation_audit` is explicitly revoked from
application, service, worker, and scheduler roles, and no later grant to the
executor exists.

**Why it matters.** Table ACLs and RLS do not implicitly confer EXECUTE on
functions used inside a definer function or RLS expression. Missing EXECUTE
privileges produce runtime permission errors. Granting the audit wrapper to
authenticated or service_role as a workaround would broaden audit insertion
authority and bypass the intended RPC boundary.

**Evidence.** Existing helper grants are in
[helper migration lines 25–57 and 64–92](../supabase/migrations/20260514000007_helper_functions.sql#L25).
The audit wrapper is SECURITY DEFINER and its original grants are in
[reconciliation migration lines 551–580](../supabase/migrations/20261029000001_reconciliation_module.sql#L551);
later security migration revokes its grants at
[lines 107–110](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L107).
Stage 1C asks for helper EXECUTE at
[blueprint lines 313–321](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L313)
but does not state the resulting role-specific grants.

**Required correction.** List and grant only the needed functions to the
executor: `public.is_member_of`, `public.has_role_in`,
`public.log_reconciliation_audit`, the identity helper used by the policy or
lock helper, required UUID generator (or use an explicitly qualified
PostgreSQL 15 generator), and any required enum/schema usage. Verify effective
EXECUTE with `has_function_privilege` for authenticated, anon, service_role,
both workers, scheduler, and executor. The workflow RPCs themselves should
remain executable only by authenticated; their owner must not be a member of
any client or worker role.

**Blocks implementation:** Yes.

### F4 — High: changing function owner requires schema CREATE and role membership during transfer

**Issue.** The blueprint says the executor receives no schema CREATE privilege
but is to own the SECURITY DEFINER functions. PostgreSQL `ALTER FUNCTION ...
OWNER TO` requires the executing role to be a direct/indirect member of the
new owner role, and the new owner role must have CREATE on the function's
schema (unless the executing role is superuser). The hosted migration
principal's ability to satisfy these conditions is unknown.

**Why it matters.** The proposed ownership migration can fail even if the
function and executor role are otherwise valid. Permanently granting CREATE
on `public` to the executor would violate the intended least-privilege model.

**Evidence.** Stage 1C specifies no schema CREATE at
[blueprint lines 294–302](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L294).
PostgreSQL 15's
[ALTER FUNCTION documentation](https://www.postgresql.org/docs/15/sql-alterfunction.html)
states the membership and schema CREATE requirements for owner transfer.
Hosted migration-role attributes/privileges are not verified.

**Required correction.** Specify the migration principal's required role
membership/authority, provision the executor before function creation, grant
CREATE on `public` to the executor only temporarily if required, transfer
function ownership, then revoke CREATE in the same controlled migration
transaction. Verify final schema privileges, function owners, and future
migration maintenance procedure. Do not rely on undocumented superuser
behavior in hosted Supabase.

**Blocks implementation:** Yes.

### F5 — High: idempotency keys are not bound on conflicts, and the application key lifecycle is unspecified

**Issue.** The typed decision row stores a key only after a successful accept
or reject. Expected entity/inactive/candidate conflicts return without a
decision row. Therefore those keys are not reserved; reusing one after a
conflict can later execute a different outcome. This differs from the stated
“first successful binding wins” wording unless that wording is explicitly
limited to committed decisions. Also, current actions accept only a candidate
ID and do not generate or retain an idempotency key.

**Why it matters.** Retries after a committed response loss are safe only if
the client can repeat the identical key. Concurrent reuse on different
candidates/actions is only protected if the key lookup/lock scope and the
durable record semantics agree. Persisting keys only on decisions cannot
provide at-most-once semantics for requests whose expected result is a
conflict.

**Evidence.** The schema stores `idempotency_key` in reviewer decisions at
[blueprint lines 245–274](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L245);
the replay/advisory rules are at
[lines 387–414](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L387).
The current action signature has no key at
[reconciliation.ts lines 159 and 299](../examples/nextjs/lib/actions/reconciliation.ts#L159).

**Required correction.** Choose one contract:

1. Define keys as idempotency tokens for **committed decisions only**. State
   that conflict outcomes do not reserve keys; retries with the same key may
   be re-evaluated only after the client receives an explicit conflict and
   obtains a new user action. The “first successful binding wins” rule then
   applies only to committed decision rows.
2. If every request outcome must be permanently bound, add a separate
   idempotency-request table recording candidate, action, actor, key, and
   terminal response, including conflicts, with tenant constraints and
   retention policy.

Specify the exact advisory-lock key encoding/hash, uniqueness scope
(currently tenant+reviewer+key), and action-mismatch behavior. The application
must create the key once per user intent, retain it across network retries,
pass it to the RPC, and distinguish replay, expected conflict, authorization
failure, and transient SQLSTATE. A new user intent must use a new key.

**Blocks implementation:** Yes, until the behavior and caller lifecycle are
specified.

### F6 — High: membership authorization locking does not define the exact concurrent change semantics

**Issue.** The blueprint says to lock the membership row `FOR SHARE` and
require an owner/admin role. The intent is sound, but it does not say whether
the role is read and checked from the locked row or from a prior helper call,
nor how PostgreSQL READ COMMITTED versus REPEATABLE READ/SERIALIZABLE is
handled.

**Why it matters.** A separate unlocked `has_role_in` check can observe a role
that is downgraded before decision commit. The membership lock must be
acquired before the definitive role read and held through commit. Under
stronger isolation, concurrent membership changes or candidate/entity
updates can instead raise serialization failures; these are not domain
conflicts and must not be swallowed.

**Evidence.** Membership locks are proposed at
[blueprint lines 395–400](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L395).
The current helper `has_role_in` is STABLE and queries membership without a
row lock at
[helper migration lines 64–92](../supabase/migrations/20260514000007_helper_functions.sql#L64).
PostgreSQL 15 locking privilege requirements are documented in the
[SELECT reference](https://www.postgresql.org/docs/15/sql-select.html).

**Required correction.** Have the trusted membership-lock helper atomically
select and lock the current row, then return the role/authorization result;
use its locked result as the authorization decision. Define supported
transaction isolation (prefer the PostgREST default READ COMMITTED unless a
different isolation is deliberately tested). Treat SQLSTATE `40P01` and
`40001` as transient whole-transaction retries with bounded backoff and the
same idempotency key. A lock timeout or network timeout also requires a retry
policy that first reuses the same key.

**Blocks implementation:** Yes.

### F7 — Medium: migration ordering references typed columns before they exist

**Issue.** The sequence says to build decision/idempotency indexes in step 3,
then add nullable decision columns in step 5. Those indexes cannot be created
before `candidate_id` and `idempotency_key` exist.

**Why it matters.** A migration following the written order fails at the
CREATE INDEX statement. Because concurrent-index execution and migration
history are not atomic as a whole in the inspected Supabase CLI version,
failure can leave earlier artifacts applied without a migration history row.

**Evidence.** Index list/order is at
[blueprint lines 336–355](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L336).
Typed decision columns are specified in
[lines 245–274](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L245).
Stage 1B documents the CLI v2.119.0 batching behavior at
[readiness report lines 365–389](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md#L365).

**Required correction.** Order parent-key indexes first; add nullable
reviewer-decision columns and compatible checks transactionally; only then
build their unique partial indexes in isolated non-transactional steps; then
add/validate dependent FKs and finally install RPCs. Keep each concurrent
index step independently inspectable. Partial/expression indexes cannot be
attached as ordinary UNIQUE constraints; document them as indexes and verify
validity directly.

**Blocks implementation:** Yes until ordering is corrected.

### F8 — Medium: supporting child-side FK indexes and destructive lifecycle behavior are incomplete

**Issue.** PostgreSQL does not automatically create indexes on referencing
columns. The new composite FKs need a reviewed child-side index plan, notably
identifier `(company_id, entity_id)`, candidate `(company_id, record_a_id)`,
candidate `(company_id, record_b_id)`, candidate `(company_id, entity_id)`,
and reviewer decision `(company_id, candidate_id/result_entity_id)`. The
blueprint also proposes `ON DELETE RESTRICT` while existing simple FKs use
`CASCADE` or `SET NULL`, and company foreign keys cascade. It leaves physical
entity/company deletion behavior unresolved.

**Why it matters.** Parent delete/update checks may scan large child tables.
Two simultaneously active constraints with different delete actions can
produce confusing behavior during migration; company deletion may be blocked
by a new restrictive child relationship even though company-level cascades
currently remove rows.

**Evidence.** Existing identifier and candidate indexes/foreign keys are in
[schema migration lines 245–310](../supabase/migrations/20261029000001_reconciliation_module.sql#L245);
reviewer decisions are in
[lines 361–378](../supabase/migrations/20261029000001_reconciliation_module.sql#L361).
The proposed constraints and deletion behavior are at
[blueprint lines 202–273](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L202)
and unresolved deletion policy at
[lines 737–752](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L737).

**Required correction.** Inventory existing FKs by name and delete action.
Specify child-side indexes after table-size/plan review. For transition,
prevent entity/company deletion while old and new constraints coexist, then
replace old constraints in a controlled transaction after validating
composites. Explicitly decide whether company erasure is allowed to cascade
through historical decisions/provenance or requires a separate archival or
erasure workflow. Test both entity deletion and company deletion against
representative data.

**Blocks implementation:** Yes for final FK/delete-action rollout.

### F9 — Medium: match RPCs do not cover all current decision-related application paths

**Issue.** Revoking authenticated entity DML breaks `confirmEntity`, while the
two new RPCs do not replace it. The discrepancy action is a separate
multi-request human decision workflow. The Stage 1C privilege model does not
explicitly include `reconciliation_discrepancies`, and the current action does
not insert a typed reviewer-decision row.

**Why it matters.** A migration could make entity confirmation fail, or leave
discrepancy resolution writable through a non-atomic path while claiming that
human decisions have an RPC boundary. Entity status changes must not be
smuggled into match acceptance.

**Evidence.** Direct entity status update and separate audit call:
[reconciliation.ts lines 354–402](../examples/nextjs/lib/actions/reconciliation.ts#L354).
Discrepancy SELECT/UPDATE and audit call:
[lines 592–663](../examples/nextjs/lib/actions/reconciliation.ts#L592).
The executor matrix and its stated DML revocation are at
[blueprint lines 501–541](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L501).

**Required correction.** Before DML revocation, decide whether Stage 2 includes
a separately authorized `confirm_reconciliation_entity` RPC and whether
discrepancy resolution is in or explicitly out of scope. If in scope, give it
its own typed atomic decision, authorization, idempotency, audit, and
canonical-value policy. If out of scope, state that the current discrepancy
path remains a known separate workflow gap and do not claim all human review
is RPC-only. Keep match RPCs narrowly scoped.

**Blocks implementation:** Yes for the proposed broad direct-DML cutover.

### F10 — Medium: application-side idempotency and expected conflict UX are absent

**Issue.** Current accept/reject actions call multi-request PostgREST operations,
take only `candidateId`, and the review page expects an `{error}` or `{ok}`
result. They do not pass an idempotency key or define a stable conflict
presentation. The blueprint defines JSON status shapes but not the adapter
mapping, key lifecycle, or retry behavior in the action layer.

**Why it matters.** The database function contract alone does not provide safe
network retries. A timeout after commit must replay the same key, and expected
entity/inactive conflicts must be shown as conflicts, not as success or
generic failure.

**Evidence.** Current accept/reject implementations:
[reconciliation.ts lines 159–351](../examples/nextjs/lib/actions/reconciliation.ts#L159).
The review page consumes these actions at
[review/page.tsx lines 30–42](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L30).
RPC result shapes are proposed at
[blueprint lines 418–427](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L418).

**Required correction.** Specify a typed RPC response schema and action
adapter: accepted/rejected/replayed/conflict are distinct discriminants;
SQL authorization/unexpected failures remain errors. Pass and persist the
per-intent key across retries. The UI must refresh the candidate state and
render `entity_conflict`, `inactive_entity_conflict`, and
`candidate_already_decided` without suggesting that a rejected request
committed.

**Blocks implementation:** Yes for application integration/cutover.

### F11 — Medium: test plan omits privilege escalation and several concurrency/recovery cases

**Issue.** Stage 1C includes useful functional and separate-session tests, but
does not fully test the effective SECURITY DEFINER/RLS boundary, the lock
privileges, isolation-level retries, response-loss idempotency, or failed
concurrent-index recovery.

**Why it matters.** Happy-path RPC tests can pass under a privileged test
connection while authenticated callers or the definer owner can still bypass
tenant isolation. Concurrency correctness cannot be inferred from code
inspection alone.

**Evidence.** Existing test plan is at
[blueprint lines 544–650](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L544).
Supabase CLI non-atomic concurrent-index behavior is documented in Stage 1B
at [lines 365–389](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md#L365).

**Required correction.** Add the test matrix in §5 below. Do not run
destructive DDL failure injection in production.

**Blocks implementation:** Yes; staging concurrency, security, and recovery
gates must pass.

## 3. SECURITY DEFINER / RLS verification summary

| Area | Verification | Correction needed |
|---|---|---|
| SECURITY DEFINER owner | **PostgreSQL 15 verified:** function runs with owner privileges; owner transfer has CREATE/membership requirements. Executor ownership is viable in principle, not yet verified on hosted Supabase. | Provision and transfer safely; no client/worker role membership; verify final owner/ACL. |
| FORCE RLS | **PostgreSQL 15 verified:** table owner is normally subject unless BYPASSRLS; FORCE subjects owner, while superuser/BYPASSRLS still bypass. Local tables are reported FORCE RLS. | Executor must be neither owner nor BYPASSRLS, and must have explicit policies. |
| Role-specific policy | **Repository verified:** existing policies target `authenticated`; memberships RLS policies also target `authenticated`. | Add executor-specific, tenant-filtered policies and grant policy helpers. |
| Tenant isolation | **Not verified for proposed executor:** a broad executor policy would make the definer role cross-tenant. | `USING`/`WITH CHECK` scope to `auth.uid()` membership and exact tenant; keep function predicates. |
| Membership row lock | **PostgreSQL 15 verified:** row-locking SELECT requires UPDATE privilege. Existing membership RLS grants no executor access. | Trusted narrow definer lock helper or explicitly reviewed equivalent; lock and read current role atomically. |
| Candidate/entity row locks | Executor needs UPDATE on at least one column plus SELECT, as well as UPDATE RLS policy. Candidate fields and entity `record_count` updates are intended. | List exact column grants and RLS policies; prove a SELECT-only source reader cannot use `FOR UPDATE`. |
| Source row lock | Current source table has no UPDATE policy and source immutability trigger rejects UPDATE/DELETE. | Use narrow trusted lock helper; do not make source updates possible as a side effect of row-lock privilege. |
| Schema/type/function privileges | Stage 1C gives a general “USAGE” statement but no complete grant list. | Specify `USAGE` on schemas/types and EXECUTE on required `auth_uid`/RLS/audit/generator helpers. |
| Audit wrapper | **Repository verified:** `log_reconciliation_audit` is SECURITY DEFINER with empty search path; later migration revokes existing app/worker roles. | Explicitly grant only executor. Verify audit owner can insert despite audit RLS/ACL; audit failure must abort RPC. |
| `auth.uid()` in definer context | **PostgreSQL/Supabase semantics inferred, not tested here:** SECURITY DEFINER changes `current_user`, not the PostgREST JWT request settings from which Supabase `auth.uid()` is derived. | Call through `public.auth_uid()` or `auth.uid()` with explicit schema/function access; test with real authenticated JWT and executor owner. Never accept reviewer ID from arguments. |
| `service_role` | **Stage 1 local finding:** BYPASSRLS with broad ACLs. Hosted not verified. | No accept/reject grant; inventory service routes and explicitly revoke table DML only after caller migration. |
| Workers/scheduler | **Stage 1 local finding:** workers have no direct affected-table privileges and use scoped RPCs; scheduler is NOLOGIN. | Preserve exact RPC EXECUTE grants, leases, ownership, search path, and role attrs; no executor membership. |

### Required minimum privilege design before implementation

The executor needs explicit, column-scoped access rather than generic table
SELECT/INSERT/UPDATE:

- Candidates: SELECT only required candidate columns; UPDATE only
  `status`, `reviewer_id`, `reviewed_at`, `entity_id`; RLS SELECT and UPDATE
  policies tenant-scoped to current `auth.uid()`.
- Entities: SELECT only `id`, `company_id`, `deleted_at`, and fields needed
  to enforce non-overwrite/count behavior; INSERT only generated ID/default
  or exact creation fields; UPDATE only `record_count`; no canonical-data or
  survivorship UPDATE grant after insertion.
- Identifiers: SELECT `company_id`, `entity_id`, `source_record_id`; INSERT
  only tenant/entity/source/confidence; no UPDATE/DELETE.
- Source records: SELECT only `id` and `company_id` for integrity; do not
  grant source payload columns to the decision executor. Use a separate
  trusted lock helper for row locks.
- Reviewer decisions: SELECT only needed idempotency/result fields; INSERT
  only typed decision, actor, candidate, result entity, rationale, and
  constrained state/audit metadata; no UPDATE/DELETE.
- Membership: no direct executor table access preferred; use the trusted
  current-membership lock helper. If direct row lock is selected instead,
  explicitly solve RLS plus the PostgreSQL UPDATE privilege requirement.
- Audit: no direct table DML; EXECUTE only on the trusted audit wrapper.
- Schemas/types/functions: explicit USAGE/EXECUTE for `public`, required
  enum types, RLS helper(s), audit wrapper, UUID generator, and lock helper.

Exact columns and policies must be reconciled with SQL function body and
PostgreSQL privilege checks; the table above is a required specification
direction, not a finished grant script.

## 4. RPC correctness and concurrency

### 4.1 Correct elements

- `auth.uid()` rather than caller-supplied reviewer identity is correct for
  authenticated PostgREST RPCs; user metadata is not an authorization source.
- An empty `search_path` and fully qualified objects are appropriate for
  SECURITY DEFINER functions. Ensure all helper, type, and schema references
  are qualified and no unsafe dynamic SQL is used.
- Candidate `FOR UPDATE` serializes accept/accept and accept/reject on the
  same candidate, provided the executor has required UPDATE privilege and
  policy.
- Sorting source IDs before acquiring locks is a sensible common order.
- A unique `(company_id, source_record_id)` index is the final invariant guard
  against multiple entity links. A uniqueness failure must not be reported as
  accepted.
- Decision and audit writes inside one SQL function statement are atomic.
  An uncaught audit/constraint error aborts the statement; in an autocommit
  RPC, all its writes roll back.
- Advisory-lock hash collisions only cause extra serialization, not incorrect
  authorization, if the unique index and exact key lookup remain authoritative.

### 4.2 Concrete transaction sequences

| Concurrent operations | Expected behavior after corrections | Remaining condition |
|---|---|---|
| Two accepts on same candidate | T1 locks candidate and commits. T2 waits; under READ COMMITTED it sees terminal status and replays only for same stored key/action, otherwise returns already-decided. | At REPEATABLE READ/SERIALIZABLE, T2 may receive `40001`; retry whole call with same key. |
| Accept vs reject same candidate | Same candidate lock gives one winner. The loser must not insert a second decision or audit event. | Test both orderings and verify result mapping. |
| Different candidates share a source | Both lock their own candidate, then source IDs in sorted order. One obtains source lock first and commits link. The other then re-reads links and either attaches to the same active entity or returns a conflict. | Source locking currently lacks UPDATE privilege. All other identifier writers must obey the same locking protocol; unique index remains backstop. |
| Different candidates share an entity | Each locks its source rows first, then serializes on the entity row. The second recounts after lock and must not overwrite canonical fields. | Under stronger isolation, expect/retry serialization error. Other entity/link writers must use consistent lock order. |
| Concurrent membership removal/downgrade | Locked membership row is held through decision commit; role update/delete waits. If removal commits first, the RPC sees no current membership and denies. | Implement a lock helper with correct RLS bypass and ensure role is read after lock. Test owner-removal trigger behavior too. |
| Same idempotency key on different candidates/actions | Transaction advisory lock serializes matching tenant/reviewer/key; first committed decision binds key; later different binding returns conflict. | Specify hashing/namespace and what happens if first outcome is a non-persisted conflict. |
| Worker inserts candidate while accept locks sources | FK key-share locks may wait behind source row locks; worker does not need the reviewer's candidate lock for a new candidate, so no direct cycle is apparent. | Re-test worker's actual run-lock/insert order and unique conflict inference after pair-index change. |
| Two first-time accepts with different sources | Each can create an entity independently; no duplicate link conflict. | Test transaction rollback and generated UUID/default privileges. |

The lock order should be written as one invariant for every writer:
candidate → current membership authorization lock → idempotency key → source
rows sorted by UUID → target entity. Reviewers must not take entity/source
locks in a different order in any future workflow. Known external writers
must be inventoried.

### 4.3 Retry and error contract

Specify the following before application integration:

- Retry the **entire RPC transaction** for SQLSTATE `40P01` (deadlock) and
  `40001` (serialization failure), with bounded exponential backoff and the
  same key. Do not retry authorization errors or domain conflicts.
- On network timeout after request submission, retry with the same key; the
  client cannot assume the first attempt rolled back.
- On named uniqueness error (`23505`), distinguish expected idempotency
  collision from source-link/candidate invariant failure. Do not broadly catch
  all uniqueness/FK errors and turn them into success-shaped JSON.
- Define lock-timeout/cancellation behavior and whether those SQLSTATEs are
  retried. Never auto-retry with a new key.
- State that expected conflicts are returned without decision/audit writes, or
  introduce a request ledger if every attempted outcome must be durable.
- Define whether conflict attempts should be logged as security/audit events;
  current blueprint says no writes on domain conflict, which means no audit
  trail of conflict attempts.

## 5. Schema and migration verification

### Correct / PostgreSQL 15-compatible design elements

- A unique parent key on `(company_id,id)` is required for a composite FK
  referencing exactly those columns, even though `id` alone is already a
  primary key.
- PostgreSQL 15 supports composite FKs, `NOT VALID` for foreign keys, partial
  unique indexes, and expression indexes using UUID ordering with `LEAST` /
  `GREATEST`.
- A partial unique index on typed candidate ID preserves legacy rows with
  NULL `candidate_id`; a second partial index can scope non-NULL idempotency
  keys.
- Nullable composite FK columns use MATCH SIMPLE by default; a NULL optional
  `entity_id`/`result_entity_id` does not require a parent. Spell out checks so
  typed accept requires result entity and typed reject forbids one, while
  legacy rows with NULL `candidate_id` remain untouched.
- `CREATE INDEX CONCURRENTLY` cannot run in an explicit transaction. Stage 1B
  reports CLI v2.119.0 splits the index statement from normal migration
  batches, so earlier batches/index/history may persist independently. This
  is based on inspected version-tagged CLI source, not a DDL failure test.

### Corrections/decisions still required

1. Reorder typed decision indexes after adding their nullable columns. Add
   child-side indexes for new composite references where size/plan requires.
2. Define exact nullable-compatible CHECK expressions and preserve any
   historical match decision rows without fabricating `candidate_id`.
3. Keep `ON DELETE RESTRICT` semantics consistent while replacing existing
   `CASCADE`/`SET NULL` FKs. Pause deletes during the transition; test company
   deletion and retention/account erasure.
4. New reviewer `ON DELETE RESTRICT` changes account deletion behavior.
   The existing reviewer column is NOT NULL but currently uses `ON DELETE SET
   NULL`; require an approved erasure/pseudonymization policy.
5. Candidate-pair normalized unique expression index is compatible with PG15,
   but worker insert must normalize source ordering and use an explicit
   conflict target compatible with the new index. Do not assume the old
   `ON CONFLICT (record_a_id, record_b_id) WHERE status = 'pending'` infers
   the expression index.
6. Unique partial/expression indexes cannot be attached as ordinary UNIQUE
   constraints; maintain them as indexes and validate catalog definitions.
7. Any concurrent-index migration can leave a valid/invalid index while its
   migration history row is absent. Never retry blindly; inspect
   `pg_index.indisvalid`, definition, duplicates, and history first.
8. Recalculate `record_count` after links are inserted while holding the
   entity row lock. It is correct only if every link writer follows compatible
   locking and no direct/service-role writer remains. Existing entity counts
   must not be silently rewritten during rollout.
9. Keep the one-source unique index unfiltered so links to soft-deleted
   entities remain relationship-protecting. Acceptance returns
   `inactive_entity_conflict`; list/export filters and restore require separate
   decisions.

## 6. Application write-path inventory

Current paths are from the repository. “Required before DML revocation” means
the caller must be replaced or explicitly retained under an approved,
narrowly scoped privilege before the proposed broad authenticated DML revoke.

| Existing path | Current database operation | Proposed replacement | Required before DML revocation |
|---|---|---|---|
| Match accept: [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L159) | Candidate SELECT/UPDATE; identifier SELECT/INSERT; source SELECT; entity INSERT; candidate entity UPDATE; separate `log_audit` call. Writes are multiple PostgREST requests and errors from some writes/audit are ignored. | `accept_reconciliation_match` for all decision-side writes; preserve source/entity reads only if needed by UI. | Yes; change action to one RPC call, idempotency key lifecycle, typed result/conflict mapping. |
| Match reject: [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L299) | Candidate SELECT/UPDATE then separate `log_audit`. | `reject_reconciliation_match`. | Yes; change action and return handling. |
| Review queue: [`review/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L21) | SELECT pending candidates plus joined source IDs/raw data; UI gates actions using app metadata. | Keep tenant SELECT under RLS; frontend gate is presentation only; database RPC authorizes. | No DML migration, but adapt conflict/replay UI and deleted-entity conflict display. |
| Entity confirm: [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L354) | Entity SELECT/UPDATE status, then separate audit call. | Separate narrow `confirm_reconciliation_entity` RPC (or define it explicitly out of scope and retain a specific safe path). | Yes; current UPDATE fails after entity DML revoke. Do not extend match RPC to cover it. |
| Entity list: [`entities/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx#L29) | SELECT by company without `deleted_at IS NULL`. | Same SELECT, filtered for active entities; optional authorized historical view. | No DML, but required to implement soft-delete UX before claiming completion. |
| Export page: [`export/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx#L27) | SELECT entity by ID/company without deleted filter, then invokes export action. | Reject or hide deleted entities in normal export; separate historical export policy if approved. | No DML, but mandatory for soft-delete policy. |
| Entity export action: [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L406) | SELECT entity, identifiers, and source raw data; writes an audit event. | Preserve least-privilege tenant reads; filter inactive entity; keep audit failure visible. | No match-table DML; review sensitive export/service calls and deleted filter. |
| Import detail: [`imports/[id]/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/imports/[id]/page.tsx#L20) | SELECT imported source rows/raw data. | Keep scoped SELECT if product policy allows; no client INSERT/UPDATE/DELETE. | No; ensure SELECT grants and source immutability remain. |
| Source ingestion: [`reconciliation_import_insert_record`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L100) | Worker SECURITY DEFINER RPC inserts source records after lease validation; worker has no direct table DML. | Preserve this import worker RPC and exact role grants. | No app replacement; regression-test worker insert/lease and no direct worker table access. |
| Matching candidate generation: [`reconciliation_matching_write_candidates`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L199) | Matching worker RPC inserts pending candidate rows; uses current directional `ON CONFLICT`. | Preserve lease boundary; normalize pair order and update conflict target for new expression index. | Yes, for candidate pair index rollout; worker write behavior must be deployed/tested with index. |
| Discrepancy resolution: [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L592) | Direct discrepancy SELECT/UPDATE plus separate audit RPC; no typed reviewer-decision insert in this action. | Separate discrepancy-resolution RPC if this milestone promises all human decisions atomic; otherwise explicitly keep outside scope with separate risk acceptance. | Not blocked by the listed table revoke if discrepancy privileges remain, but remains a non-atomic human-decision path. |
| Reviewer-decision direct writes | No direct app `.insert()` into `reconciliation_reviewer_decisions` found in inspected Next.js app. | New match RPC is the only new writer; preserve legacy history. | Inventory any external/admin scripts before revoking; repository search is not proof of no external callers. |
| Identifier writes | Current app inserts occur only in `acceptMatch`; worker SQL does not insert identifiers. | New accept RPC only. | Yes; verify service/admin scripts and direct service_role callers. |

## 7. Missing test cases and classification

| Test | Class | Required assertion |
|---|---|---|
| Function-owner privilege escalation | Local integration | `proowner`, `prosecdef`, `proconfig`, EXECUTE ACLs, schema CREATE, role memberships, owner cannot be impersonated by authenticated/anon/workers. |
| FORCE RLS under the function owner | Local integration | Execute as authenticated JWT through the SECURITY DEFINER RPC; verify executor policies apply and a foreign-tenant candidate cannot be read, mutated, or distinguished from missing. |
| Exact helper/audit grants | Local integration | `is_member_of`, `has_role_in`, current-user/lock helper, UUID generator, and audit wrapper execute only for intended roles; direct wrapper call cannot forge tenant/action. |
| Row-lock privilege contract | Local integration | Lock candidate/entity/source/membership as actually deployed; prove required table/column grants and RLS policies; no source update bypass. |
| Same-candidate accept/accept and accept/reject | Staging concurrency | Barrier-controlled independent sessions; exactly one terminal decision and success audit; replay only when key/action match. |
| Different candidates sharing one source | Staging concurrency | Both lock same source in sorted order; final source has at most one entity; same active entity can be reused; conflict causes no partial decision. |
| Different candidates sharing one entity | Staging concurrency | Entity lock serializes count recalculation; canonical data and survivorship remain unchanged. |
| Concurrent entity creation | Staging concurrency | Shared-source candidates cannot create two entities/links; disjoint sources can create independent entities. Assert unique source link after both commit. |
| Deadlock/serialization handling | Staging concurrency | Force a lock cycle and a stronger-isolation serialization failure; verify `40P01`/`40001` cause bounded full-transaction retry with same key, never partial writes. |
| Concurrent membership downgrade/removal | Staging concurrency | Verify membership lock order: revoke-first denies; decision-first blocks revocation until atomic decision commit; no stale role acceptance. |
| Idempotency after response loss | Staging integration | Commit RPC, simulate dropped response, retry same key and receive saved result without duplicate decision/audit/link/count. Also test conflict-key semantics selected by product. |
| Key reuse across action/candidate/reviewer/tenant | Local integration + staging concurrency | Verify exact uniqueness namespace, advisory-key implementation, collision safety, and explicit mismatch response. |
| Audit wrapper failure | Local integration | Fail inside `log_reconciliation_audit`, not just table INSERT; verify candidate, entity, links, decision, and audit all roll back. |
| Cross-tenant disclosure | Local integration | Compare nonexistent ID with foreign-tenant ID for both RPCs; no foreign candidate/source/entity details in result or metadata. |
| Worker compatibility | Local integration + staging integration | Preserve import/matching role attributes, scoped RPC EXECUTE, lease/tenant checks, pair normalization, and no direct table privileges. |
| Candidate-generation conflict inference | Local integration | Verify the new partial expression index and exact `ON CONFLICT` clause handle both pair directions without suppressing unrelated violations. |
| Historical rows and FK transition | Local integration | Legacy untyped decisions remain byte-for-byte unchanged; nullable composite FK/check behavior works; no cascade/SET NULL ambiguity. |
| Entity/company deletion and reviewer erasure | Local integration + policy approval | Confirm proposed RESTRICT semantics, company cascade behavior, reviewer account deletion, and approved retention/erasure process. |
| Concurrent index failure recovery | Local disposable database | Interrupt/fail a `CREATE UNIQUE INDEX CONCURRENTLY`; inspect invalid index and missing migration history; execute documented targeted recovery and prove safe rerun. |
| Soft-delete list/export/read paths | Staging integration | Deleted entities excluded from normal list/export; links/count remain; acceptance returns explicit inactive conflict; no implicit restore. |
| Production verification | Production read-only | Confirm project identity, migration parity, catalog/grants/RLS/functions/workers, indexes valid, and all preflight data checks; no destructive test. |

The current Stage 1C list covers many happy paths, tenant constraints, and
some concurrency cases at
[blueprint lines 549–650](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md#L549),
but does not explicitly require all tests above.

## 8. Prioritized remediation before Stage 2

1. **Fix the executor security model:** exact per-table/column privileges,
   tenant-filtered executor RLS policies, helper EXECUTE grants, no broad
   membership/source read, and a safe membership/source lock helper.
2. **Make role/function ownership deployable:** resolve migration-principal
   capabilities; specify temporary schema CREATE and role membership for
   owner transfer, then remove permanent CREATE.
3. **Finalize idempotency and errors:** committed-decision-only versus all
   outcomes; exact key scope/encoding; application key persistence; expected
   conflict JSON; bounded retries for `40P01`/`40001`; no broad exception
   fallbacks.
4. **Correct migration order:** parent unique indexes → nullable typed columns
   and checks → typed indexes → composite FK add/validate → function/grant
   rollout. Add child-side FK indexes and deletion/cascade transition gates.
5. **Complete application cutover scope:** accept/reject actions, entity
   confirmation, exports/list deleted filters, candidate pair generation, and
   an explicit in/out decision for discrepancy resolution. Inventory any
   external service_role or operational writers.
6. **Resolve Stage 1 blockers:** reconcile migration 06 provenance and inspect
   the exact hosted project read-only. Do not guess/link a project.
7. **Add and pass tests:** complete §7 locally and in staging, including
   separate-session races, audit-wrapper failure, retry after response loss,
   effective RLS/definer boundaries, worker compatibility, and concurrent
   index recovery. Production checks remain read-only.

## 9. Final Stage 2 authorization checklist

Stage 2 implementation should be authorized only when all boxes are checked:

- [ ] Executor policy predicates are fully specified and tenant-scoped;
  no executor policy grants unrestricted cross-tenant row access.
- [ ] Row-lock privileges/policies are valid for PostgreSQL 15; immutable
  source records do not receive direct UPDATE access.
- [ ] Membership authorization is read and locked atomically using current
  database membership, with no user-metadata trust.
- [ ] Exact schema/type/helper/audit/UUID grants and function ACLs are
  enumerated and tested for every listed role.
- [ ] Function-owner provisioning/transfer works on the intended hosted
  migration role; final executor has no LOGIN, BYPASSRLS, membership, schema
  CREATE, or table ownership.
- [ ] Idempotency key lifecycle, conflict persistence, response schema, and
  retry SQLSTATEs are approved and supported by the application.
- [ ] Migration ordering is corrected; parent/child indexes and FK/delete
  semantics, including company deletion and reviewer erasure, are approved.
- [ ] Entity confirmation and discrepancy-resolution scope are explicitly
  resolved before direct authenticated DML is revoked.
- [ ] Version 06 provenance and the exact hosted project/migration state are
  reconciled using authorized read-only access.
- [ ] All preflight checks pass on the target or have approved remediation;
  no automatic historical data repair is assumed.
- [ ] Local security/integration tests and staging two-session concurrency,
  retry, rollback, worker, and index-recovery rehearsals pass.
- [ ] Production rollout and rollback are separately reviewed and explicitly
  approved.

**Final implementation recommendation: NO-GO.** Before Stage 2, correct the
executor grants/RLS/locking design, settle idempotency and application
cutover scope, fix migration ordering, complete the missing security and
concurrency tests, reconcile migration `20261101000006`, and inspect the
confirmed hosted target read-only. This report does not authorize
implementation.
