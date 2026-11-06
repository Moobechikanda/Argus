# ZamBase Phase 2A.3.4 — Stage 1E Corrected Implementation Blueprint

> **Documentation only.** This is a proposed design, not implementation
> approval. No application source, migration, database object, role, grant,
> policy, function, index, data, or configuration was changed or executed.
> Hosted Supabase was not inspected.

## 1. Executive summary and final readiness verdict

**Final verdict: NO-GO for Stage 2 implementation at this time.**

The corrected target is implementable on PostgreSQL 15 in principle, subject
to the explicit privilege and hosting prerequisites below being verified in a
disposable local database and the intended staging project. Stage 1D found
material defects in the Stage 1C specification. This document corrects them,
but does not demonstrate that the design has passed execution or hosted
verification.

Preserved business rules:

- One source record has at most one current entity link, including links to
  soft-deleted entities.
- Acceptance establishes relationship provenance only. It never merges
  entities or changes canonical values or survivorship rules on an existing
  entity.
- If existing links or candidate state identify different entities, accept
  returns an explicit conflict and changes nothing.
- A new entity starts with `{}` canonical data and the neutral
  `manual_review_required` survivorship rule.
- Only a current tenant owner or administrator may accept or reject.
- Rejection creates no entity or identifier links.
- Source records are immutable.
- Legacy terminal candidates without typed reviewer decisions remain
  historical. No historical decision is fabricated.
- `record_count` is the current number of identifier links, recalculated
  transactionally for entities changed by a successful acceptance.
- A source linked to a soft-deleted entity is not silently reassigned or
  attached elsewhere.

Evidence labels used here:

- **Repository verified:** inspected in the checked-out source/migrations.
- **Prior local finding:** reported from Stage 1A/1B local read-only
  inspection; not independently re-queried for this document.
- **PostgreSQL 15 documented:** supported by the official PostgreSQL 15
  documentation. Documentation support is not a successful runtime test.
- **Unverified:** hosted role/schema state, actual migration privileges,
  actual concurrent behavior, or any result not established by the above.

The Stage 1A/1B reports and existing migrations are the available written
Phase 2A.3.4 evidence. No separate earlier final specification was found.
Principal references are the [Stage 1A report](./PHASE-2A-3-4-STAGE-1A-PREFLIGHT-REPORT.md),
[Stage 1B report](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md),
[Stage 1C blueprint](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md),
[Stage 1D verification](./PHASE-2A-3-4-STAGE-1D-DESIGN-VERIFICATION.md),
[reconciliation schema/RLS migration](../supabase/migrations/20261029000001_reconciliation_module.sql),
[worker security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[membership policy migration](../supabase/migrations/20260514000008_rls_policies.sql),
[helper migration](../supabase/migrations/20260514000007_helper_functions.sql),
and [current reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts).

## 2. Stage 1C changes required by Stage 1D

| Stage 1D finding | Correction in this blueprint | Blocking disposition |
|---|---|---|
| F1: executor RLS is unspecified and could allow cross-tenant access | §4 defines command-specific tenant policies and forbids `USING (true)` policies; sources and memberships are not directly readable by the executor. | Must pass effective-RLS tests before implementation approval. |
| F2: source and membership row locks require privileges missing from the matrix | §5 assigns candidate/entity locks to the executor with only required column UPDATE rights; trusted `postgres`-owned helper functions lock membership/source rows. No source UPDATE is granted to the executor. | Must verify helper owner capabilities and behavior in staging. |
| F3: helper and audit EXECUTE grants are missing | §4 gives the executor exact helper grants and denies all non-authorized roles. | Must verify with `has_function_privilege`. |
| F4: transferring function ownership needs schema CREATE and role membership | §12.2 defines a temporary-grant/transfer/revoke procedure and a hosted-capability gate. | If platform privileges cannot support the procedure, stop and redesign; do not assume superuser access. |
| F5: idempotency for conflicts and application keys is undefined | §7 selects committed-decision-only keys, exact key scope, locking, replay, mismatch, application persistence, and retry behavior. | Conflicts do not reserve keys; application must discard their key and create a new key for a new intent. |
| F6: membership lock/check and isolation semantics are underspecified | §5.2 makes authorization a locked-row read inside a trusted helper; supported isolation and race behavior are explicit. | Must test under the actual Supabase/PostgREST transaction isolation. |
| F7: typed indexes precede their columns | §8 orders column/check creation before typed unique indexes. | Corrected sequence is mandatory. |
| F8: FK child indexes and deletion transitions are incomplete | §8 and §9 list child-side indexes, old/new FK transitions, company deletion, entity deletion, and reviewer-erasure policy. | Physical deletion policy needs explicit owner approval and staging verification. |
| F9: entity confirmation/discrepancy operations are outside the match RPCs | §10 provides separate cutover rows; entity confirmation requires its own RPC; discrepancy resolution is explicitly deferred from this milestone unless separately approved. | Do not revoke its current DML path until caller/product scope is resolved. |
| F10: action-layer idempotency and conflict UX are absent | §§7 and 10 specify the client key lifecycle, typed response mapping, and required action/UI work. | RPC-only application cutover is not ready until implemented and tested. |
| F11: adversarial security, retries, and recovery tests are incomplete | §11 adds local integration, staging concurrency, and production read-only verification cases. | All applicable local/staging gates must pass. |

These are specification corrections only. The Stage 1C and Stage 1D documents
remain unchanged.

## 3. Corrected security and role architecture

### 3.1 Roles and trust boundaries

1. **`authenticated`** is the PostgREST caller role. It retains RLS-filtered
   reads needed by existing tenant UI, loses direct DML on match decisions,
   links, entity creation/counts, reviewer decisions, and source records, and
   receives EXECUTE only on the two match RPCs for this milestone.
2. **`anon`** receives no access to the reconciliation data tables or either
   RPC. Public function EXECUTE is revoked explicitly.
3. **`service_role`** remains a privileged platform role with
   `BYPASSRLS` (prior local finding). It receives no accept/reject RPC grant
   and no direct DML on the protected tables in the proposed end state.
   Existing operational RPC grants are inventoried and preserved only where
   required; hosted effective grants are unknown.
4. **`reconciliation_import_worker`** and
   **`reconciliation_matching_worker`** retain separate login credentials,
   no direct table privileges, and their existing narrow lease-checked RPCs.
   They are not members of the workflow executor and receive no human-review
   RPC privileges.
5. **`reconciliation_scheduler`** remains NOLOGIN and can execute only its
   existing retention-cleanup wrapper.
6. **`reconciliation_workflow_executor`** is a dedicated NOLOGIN,
   non-superuser, NOBYPASSRLS role with no role memberships and no table
   ownership. It owns only the two public workflow RPCs. It receives
   narrow table/column grants and tenant-scoped policies, not general access.
7. **Trusted lock-helper owner:** the proposed lock helpers are owned by the
   existing privileged `postgres` database role, not the executor. Prior
   Stage 1A inspection reported local `postgres` has BYPASSRLS; the exact
   hosted attributes, ownership, and source-table UPDATE privilege are
   **unverified**. If the hosted helper owner cannot lock the rows while
   respecting RLS, do not grant BYPASSRLS to a worker/executor; pause and
   redesign.

`NOLOGIN` and `NOBYPASSRLS` are necessary but not sufficient controls. The
executor's function code, table grants, RLS policies, helper execution
rights, JWT identity, and owner-transfer process are all part of the security
boundary.

### 3.2 SECURITY DEFINER contract

Both `accept_reconciliation_match` and `reject_reconciliation_match`:

- are `SECURITY DEFINER`, owned by `reconciliation_workflow_executor`;
- set `search_path = ''`;
- qualify every schema, relation, type, helper, and built-in that is not
  inherently in `pg_catalog`;
- use no dynamic SQL;
- derive reviewer identity only from `public.auth_uid()` (the existing
  SECURITY DEFINER wrapper around `auth.uid()`) and tenant only from the
  candidate row;
- never accept caller-supplied reviewer, company, action, or target entity IDs;
- have EXECUTE revoked from `PUBLIC`, `anon`, `service_role`,
  `reconciliation_import_worker`, `reconciliation_matching_worker`, and
  `reconciliation_scheduler`; grant EXECUTE only to `authenticated`;
- have no direct privileges granted to login roles through membership in
  `reconciliation_workflow_executor`.

The `auth.uid()`/JWT request context is expected to remain available inside
SECURITY DEFINER execution; this is a Supabase/PostgreSQL integration
assumption and must be proved with real authenticated JWT tests. The function
owner changes `current_user`, not the caller identity used by Supabase's
request-claim helper. Never trust a client-supplied user ID.

### 3.3 Trusted lock helpers

Two internal, non-public RPC helpers avoid giving the executor UPDATE access
to immutable source records or memberships merely to obtain row locks:

**`public.authorize_reconciliation_reviewer(_candidate_id uuid)`**

- `SECURITY DEFINER`, owner `postgres`, empty search path.
- EXECUTE only for `reconciliation_workflow_executor`; revoke from PUBLIC,
  anon, authenticated, service_role, workers, and scheduler.
- Derives `_reviewer_id` through `public.auth_uid()`; never takes a user ID.
- Looks up the candidate by ID under the privileged owner to derive its
  `company_id`, but returns no data before authorization. Missing and
  unauthorized candidates use the same generic authorization/not-found
  result.
- Locks the current membership tuple
  `(company_id, auth.uid())` with `FOR SHARE`, then reads the role from that
  locked row. Returns only the derived company ID and approved role (owner or
  admin); otherwise raises SQLSTATE `42501`.
- Does not expose membership rows, other member identities, or arbitrary
  tenant records.

**`public.lock_reconciliation_match_sources(_candidate_id uuid)`**

- `SECURITY DEFINER`, owner `postgres`, empty search path.
- EXECUTE only for `reconciliation_workflow_executor`; same explicit revokes
  as the authorization helper.
- Re-derives and verifies candidate tenant and source IDs from the candidate
  row, verifies the JWT identity is still an owner/admin through the
  authorization helper, and locks only the two referenced source rows in
  ascending UUID order with `FOR UPDATE`.
- Requires each locked source row to exist and have the candidate's
  `company_id`; any mismatch raises a generic integrity/authorization error.
- Returns no source fields or payload; only success/failure, with no
  distinction that reveals a foreign candidate/source.
- Never UPDATEs or DELETEs source records and never disables or bypasses the
  immutability trigger.

The helper owner must have the database privileges PostgreSQL requires for
`SELECT ... FOR UPDATE`, plus either table-owner/BYPASSRLS capability or a
verified narrowly scoped RLS policy that permits its locked row reads. Stage
1A/1B report local `postgres` as BYPASSRLS; actual hosted state is unknown. Do
not silently add UPDATE on source or membership tables to the workflow
executor. If the verified helper owner cannot satisfy lock privileges, stop
rather than weakening source immutability.

`authorize_reconciliation_reviewer` itself locks the membership row. Its
owner must have SELECT and PostgreSQL's required UPDATE privilege for
`FOR SHARE`; this uses the existing privileged helper owner, not an
application/worker role. No direct membership grants or executor membership
table policy is added. The role and attributes of this helper owner must be
verified on the target.

### 3.4 Schema, type, and helper privileges

The executor and function owner need only:

- `USAGE` on `public`; the workflow executor requires type USAGE on
  `public.app_role`, `public.reconciliation_match_status`,
  `public.reconciliation_entity_status`,
  `public.reconciliation_decision`, and `public.audit_action` as referenced
  by function bodies, policy helpers, and inserts.
- EXECUTE for the executor on `public.auth_uid()`,
  `public.is_member_of(uuid)`, `public.has_role_in(uuid, public.app_role)`,
  `public.log_reconciliation_audit(public.audit_action, uuid, text, text,
  jsonb)`, both internal lock helpers, and any explicitly used UUID generator.
- Prefer `pg_catalog.gen_random_uuid()` explicitly for the new entity and
  decision IDs on PostgreSQL 15 so the executor does not require extension
  schema access. Grant INSERT on the `id` columns only if the function
  supplies those values explicitly.
- The lock helper owner, not executor, requires USAGE on `auth` only if its
  implementation calls `auth.uid()` directly. Prefer the already-qualified
  `public.auth_uid()` wrapper and verify its owner/EXECUTE chain.
- No CREATE privilege on `public` for the executor after ownership transfer.
  No USAGE/CREATE on unrelated extension schemas, no TEMP privilege, and no
  sequence privileges are expected by the proposed UUID design.

Existing helper ACLs do not include the new executor. The migration must
explicitly grant the required EXECUTE rights after revoking PUBLIC/default
access. For every role in §4, verify effective privileges, not only direct
ACL text.

## 4. Corrected RLS and privilege matrix

### 4.1 Executor RLS policies

Tables below have RLS enabled and forced per existing migrations. Add
role-specific policies for `reconciliation_workflow_executor` only where the
workflow function directly accesses a table. Do not add `USING (true)` or
`WITH CHECK (true)` policies. All tenant predicates use
`public.is_member_of(company_id)` and administrative write predicates use
`public.has_role_in(company_id, 'admin'::public.app_role)`. These helpers are
SECURITY DEFINER and must have explicit executor EXECUTE grants.

| Table | Command for executor | Policy `USING` | Policy `WITH CHECK` | Executor column grant |
|---|---|---|---|---|
| `reconciliation_match_candidates` | SELECT | `public.is_member_of(company_id)` | — | SELECT only `id, company_id, record_a_id, record_b_id, entity_id, status, match_score` (omit score if not audited). |
| Same | UPDATE | `public.is_member_of(company_id) AND public.has_role_in(company_id, 'admin'::public.app_role)` | Same predicate | UPDATE only `status, reviewer_id, reviewed_at, entity_id`. |
| `reconciliation_entities` | SELECT | `public.is_member_of(company_id)` | — | SELECT only `id, company_id, deleted_at, record_count`. Do not grant canonical_data or survivorship_rule SELECT to the executor. |
| Same | INSERT | — | `public.is_member_of(company_id) AND public.has_role_in(company_id, 'admin'::public.app_role)` | INSERT only `id, company_id, canonical_data, survivorship_rule, record_count, status, created_by`; `id` supplied by `pg_catalog.gen_random_uuid()`. |
| Same | UPDATE | `public.is_member_of(company_id) AND public.has_role_in(company_id, 'admin'::public.app_role)` | Same predicate | UPDATE only `record_count` (and `updated_at` only if required by a verified trigger/application invariant). Never grant update on canonical_data or survivorship_rule. |
| `reconciliation_identifiers` | SELECT | `public.is_member_of(company_id)` | — | SELECT only `company_id, entity_id, source_record_id`. |
| Same | INSERT | — | `public.is_member_of(company_id) AND public.has_role_in(company_id, 'admin'::public.app_role)` | INSERT only `company_id, entity_id, source_record_id, confidence`. |
| `reconciliation_reviewer_decisions` | SELECT | `public.is_member_of(company_id)` | — | SELECT only `id, company_id, candidate_id, result_entity_id, reviewer_id, idempotency_key, decision, reviewed_at`. |
| Same | INSERT | — | `public.is_member_of(company_id) AND public.has_role_in(company_id, 'admin'::public.app_role)` | INSERT only `id, company_id, decision_target_table, decision_target_id, decision, rationale, previous_state, new_state, reviewer_id, reviewed_at, candidate_id, result_entity_id, idempotency_key`. |
| `reconciliation_source_records` | None for executor | No executor policy | No executor policy | No executor table/column privileges. Access/locks only through `lock_reconciliation_match_sources`; source payload never returned to the match RPC. |
| `memberships` | None for executor | No executor policy | No executor policy | No executor table/column privileges. Access/lock only through the trusted authorization helper. |
| `audit_log` | None for executor | No executor policy | No executor policy | No executor table privilege. Audit only through `log_reconciliation_audit`. |

The executor policies authorize only the authenticated caller's current
tenant. They are defense in depth, not a substitute for the RPC's explicit
candidate-derived tenant filters and locked role check. The policy helpers
read the request identity through `public.auth_uid()`; their behavior under
the actual Supabase JWT context must be tested before approval.

No executor DELETE policy or DELETE grant exists. No executor INSERT policy
exists on candidate, source, or membership tables. Candidate generation and
source ingestion remain on their existing worker RPC boundaries.

### 4.2 Role matrix

“Protected tables” means candidates, entities, identifiers, reviewer
decisions, source records, and audit_log. Ancillary app tables (imports,
sources, runs, discrepancies) are inventoried separately in §10 and are not
implicitly changed by this matrix.

| Role | SELECT on protected tables | INSERT | UPDATE | DELETE | EXECUTE / other |
|---|---|---|---|---|---|
| `authenticated` | Existing tenant-scoped RLS reads needed for review/list/export; audit SELECT remains existing admin+ policy. | None directly. | None directly. | None directly. | EXECUTE on accept/reject RPCs only among new workflow functions. May retain unrelated existing helpers/RPCs according to their current policy. No EXECUTE on internal lock helpers or reconciliation audit wrapper. |
| `anon` | None. | None. | None. | None. | No workflow or worker RPCs; PUBLIC EXECUTE revoked. |
| `service_role` | No protected-table SELECT unless a specifically inventoried service path requires it. | None directly. | None directly. | None directly. | No accept/reject EXECUTE. Preserve only verified existing operational RPC grants that have active callers; do not change unrelated storage/invitation behavior. `BYPASSRLS` is not changed by this workflow migration. |
| `reconciliation_import_worker` | No direct table access. | None. | None. | None. | EXECUTE only on existing import claim, insert-record, heartbeat, and finish RPCs. No membership in executor. |
| `reconciliation_matching_worker` | No direct table access. | None. | None. | None. | EXECUTE only on existing matching claim, source-read, heartbeat, candidate-write, and finish RPCs. No membership in executor. |
| `reconciliation_scheduler` | No direct table access. | None. | None. | None. | NOLOGIN; EXECUTE only on existing audit retention cleanup wrapper. |
| `reconciliation_workflow_executor` | As §4.1; no source, membership, or audit table SELECT. | Entities, identifiers, typed reviewer decisions, exact columns only. | Candidate outcome columns and entity `record_count` only. | None. | Owns only the two human-review RPCs. Has only §3.4 helper EXECUTE. NOLOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOINHERIT, NOBYPASSRLS, no role memberships, no final schema CREATE, no table ownership. |

Additional invariants:

- Keep audit_log INSERT/UPDATE/DELETE revoked from PUBLIC, anon,
  authenticated, service_role, workers, scheduler, and executor. The
  audit-wrapper owner must be able to append under the actual RLS/ACL state.
- Revoke authenticated DML and remove member-level DML policies on candidates,
  entities, identifiers, reviewer decisions, and source records only after
  application and worker callers are cut over and tested.
- Do not remove tenant SELECT policies. Preserve source immutability trigger.
- Before removing `service_role` DML ACLs, inventory Edge Functions and
  operational scripts. Its BYPASSRLS attribute means an RLS policy alone
  cannot restrict it.
- Explicitly revoke EXECUTE on each new RPC from PUBLIC, anon, service_role,
  workers, scheduler, and executor (the executor does not need to call itself);
  then grant authenticated. Verify there is no inherited role path that
  restores execution.

## 5. Corrected locking and authorization design

### 5.1 Required lock order

All acceptance/rejection RPC calls use this order:

1. Candidate row, `FOR UPDATE`, by `candidate_id`.
2. Current membership row, `FOR SHARE`, through the trusted authorization
   helper, derived from that candidate's company and `public.auth_uid()`.
3. Transaction-scoped idempotency advisory lock, derived from company,
   reviewer, and key.
4. Both source rows, `FOR UPDATE`, in ascending UUID order, through the trusted
   source-lock helper.
5. The selected existing entity row, `FOR UPDATE`, by tenant and entity ID.
6. Writes, decision, then audit; transaction ends and locks release.

Candidate and entity locks are acquired by the workflow executor. It has
UPDATE privilege on the exact candidate outcome columns and entity
`record_count` column; these UPDATE rights satisfy PostgreSQL's privilege
requirement for `SELECT ... FOR UPDATE`. Tenant-scoped SELECT and UPDATE RLS
policies apply. The actual row update remains column restricted.

Source and membership locks are performed by the two narrow SECURITY DEFINER
helpers in §3.3, owned by `postgres`. The executor receives no direct UPDATE
or SELECT privilege on those tables. The helper implementation uses explicit
tenant/identity predicates and returns no payload. PostgreSQL 15 requires
UPDATE privilege for row-locking SELECT; the trusted helper owner must already
have the required lock privilege by verified ownership/ACL. Do not grant a new
source UPDATE privilege to the executor. A failed owner/ACL/RLS precondition
blocks the design; do not silently replace it with unrestricted executor
policies.

Entity lock query must include the tenant predicate and active-state check.
Do not use a caller-supplied company or entity ID as authority; entity ID is
derived from existing links/candidate context and company from the candidate.

### 5.2 Current membership authorization

`authorize_reconciliation_reviewer(candidate_id)`:

1. Calls `public.auth_uid()` and rejects NULL with SQLSTATE `42501`.
2. Derives `company_id` from the candidate. A missing candidate and a
   cross-tenant candidate are reported identically to avoid enumeration.
3. Executes `SELECT role FROM public.memberships WHERE company_id = derived
   company AND user_id = auth_uid() FOR SHARE`.
4. Uses the role value returned by that locked row as the authorization
   decision. Only `owner` and `admin` pass. It must not call `has_role_in`
   before acquiring the lock and then trust that stale result.
5. Holds the membership lock until the RPC transaction ends.

The current `public.has_role_in` helper may still be used by executor RLS
policies as an additional write gate, but is not the authoritative
concurrency-safe role check.

### 5.3 Isolation and membership races

Supported deployment assumption: each RPC executes as one PostgREST database
transaction at `READ COMMITTED`. Verify this on the actual Supabase version.
Do not set transaction isolation inside the RPC. If the caller/session uses
REPEATABLE READ or SERIALIZABLE, serialization failures are allowed and must
be retried as defined in §7.

- If role downgrade/removal obtains the membership row lock first and commits,
  the RPC reads the absent/non-admin current membership and denies.
- If the RPC obtains `FOR SHARE` first and confirms owner/admin, concurrent
  downgrade/removal waits until the decision transaction ends; decision
  authorization is based on the locked current row.
- Any existing trigger enforcing at least one owner remains active.
- Membership changes do not acquire reconciliation candidate/source locks in
  the observed code. Any future path that does must adopt this lock order or
  be tested for deadlocks.

## 6. Final RPC contracts and transaction semantics

### 6.1 Proposed signatures

```text
accept_reconciliation_match(
  _candidate_id uuid,
  _idempotency_key uuid,
  _rationale text DEFAULT NULL
) RETURNS jsonb

reject_reconciliation_match(
  _candidate_id uuid,
  _idempotency_key uuid,
  _rationale text DEFAULT NULL
) RETURNS jsonb
```

No company, reviewer, action, entity, or decision ID is accepted as authority.
The function derives tenant/reviewer from the locked candidate and
`public.auth_uid()`.

### 6.2 Common RPC transaction flow

1. Validate non-NULL authenticated user, candidate ID, and UUID
   idempotency key. Invalid identity raises `42501`; invalid required
   arguments raise an argument SQLSTATE. No success-shaped fallback.
2. Select candidate by ID `FOR UPDATE` under executor SELECT/UPDATE ACL and
   RLS. No row means generic `candidate_not_found_or_not_authorized`.
3. Call `authorize_reconciliation_reviewer(candidate_id)` and use its locked
   membership result. Non-owner/admin raises `42501`.
4. Acquire `pg_advisory_xact_lock(bigint)` using
   `pg_catalog.hashtextextended(company_id::text || ':' ||
   reviewer_id::text || ':' || idempotency_key::text, fixed_seed)`.
   Delimiter components are canonical UUID text, so input tuple encoding is
   unambiguous. Hash collision only serializes unrelated requests; it never
   authorizes a request. The unique database index is authoritative.
5. Look up a committed typed reviewer-decision row on
   `(company_id, reviewer_id, idempotency_key)`. Same key, same candidate, and
   same action returns the persisted result with `replayed: true`; same key
   with different candidate or action returns
   `idempotency_key_conflict` and no writes.
6. If there is no replay and candidate status is not pending, return
   `candidate_already_decided`; do not fabricate historical typed decisions.
7. Call `lock_reconciliation_match_sources(candidate_id)`. The helper derives
   the source pair from the locked candidate, locks sorted IDs, and verifies
   tenant and parent existence.
8. Perform domain conflict checks and then either execute a complete
   acceptance or rejection. Expected conflicts are returned without any
   durable decision or audit write (see §7).
9. Insert typed reviewer decision and the corresponding audit event in the
   same function statement/transaction.
10. Return a stable typed JSON result. Unexpected SQL errors propagate; they
    do not return success-shaped data.

### 6.3 Accept semantics

1. Inspect both source links, candidate `entity_id`, and joined entity tenant
   and deletion state.
2. If the records or candidate target identify more than one entity, return
   `entity_conflict` before any write. Do not merge or modify either entity.
3. If the sole linked/target entity has `deleted_at IS NOT NULL`, return
   `inactive_entity_conflict`. Preserve its links, data, status, and count.
4. If one active entity is identified, lock it `FOR UPDATE`. If no entity is
   identified, insert one with:
   - `canonical_data = '{}'::jsonb`;
   - `survivorship_rule = 'manual_review_required'`;
   - `record_count = 0` initially;
   - `status = 'candidate'`;
   - `created_by = public.auth_uid()`;
   - explicit UUID from `pg_catalog.gen_random_uuid()`.
5. Insert missing identifier links to the selected entity. Existing links to
   that same entity are preserved; never update/delete/reassign them. The
   one-source unique index is the final integrity barrier.
6. Recalculate selected entity `record_count` from all its identifier links
   under the entity lock. Do not change canonical data, survivorship rule, or
   status of an existing entity. Do not update unrelated/inactive counts.
7. Update candidate status to accepted, reviewer to current `auth.uid()`,
   `reviewed_at = now()`, and `entity_id` to the chosen entity.
8. Insert one typed `accept_match` reviewer decision with candidate,
   result entity, reviewer, key, rationale, and ID/status-only previous/new
   state. Do not persist source raw/normalized payload in decision or audit.
9. Call the protected `log_reconciliation_audit` wrapper for
   `match.accepted`, with tenant, candidate/entity IDs, and outcome-only
   metadata. Audit actor must resolve to `auth.uid()`.
10. Return `{"status":"accepted","candidate_id":"...","decision_id":"...",
    "entity_id":"...","replayed":false}`.

Entity canonical data behavior is intentionally neutral. Existing entity
creation is preserved only as relationship creation, not the current
`first_non_null_wins` value selection. No automatic canonical values are
copied from source data.

### 6.4 Reject semantics

1. Use the same candidate, membership, idempotency, and source locking
   sequence. Reject does not need to read source payload or entity canonical
   data.
2. Update candidate status to rejected, reviewer to `auth.uid()`, and
   `reviewed_at = now()`. Do not create an entity, identifier, or result
   entity link. Do not alter existing relationships.
3. Insert one typed `reject_match` reviewer decision with NULL
   `result_entity_id`, key, rationale, and ID/status-only state.
4. Insert `match.rejected` audit event through the protected wrapper.
5. Return `{"status":"rejected","candidate_id":"...","decision_id":"...",
   "entity_id":null,"replayed":false}`.

### 6.5 Domain conflicts, constraints, and rollback

Expected domain results have a stable shape:

```json
{"status":"conflict","code":"entity_conflict","candidate_id":"..."}
{"status":"conflict","code":"inactive_entity_conflict","candidate_id":"..."}
{"status":"conflict","code":"candidate_already_decided","candidate_id":"..."}
{"status":"conflict","code":"idempotency_key_conflict","candidate_id":"..."}
```

- A conflict performs no candidate/entity/identifier/decision/audit writes.
- A source-link unique violation, unexpected FK/check violation, audit
  insertion failure, permission error, or internal SQL error raises. Do not
  catch all exceptions and translate them into a conflict or success.
- A named idempotency unique violation may only be mapped to replay/conflict
  after a narrowly scoped subtransaction rereads and verifies the committed
  key tuple; otherwise let it abort. The intended advisory lock should make
  this exceptional.
- Any uncaught failure aborts all writes in the RPC statement. If the outer
  caller transaction rolls back after the RPC returns, all its decision-side
  changes roll back too.
- Audit insertion is mandatory for successful decisions. Failure must raise
  and roll back every write.

### 6.6 Decision and audit data shape

New typed decision fields are specified in §8.4. `previous_state` and
`new_state` store only candidate status, IDs, and entity ID. Audit metadata
contains candidate/entity/reviewer identifiers and outcome, not raw/normalized
source data, names, values, secrets, or full comparison payloads.

The existing general `log_audit` function is executable by authenticated
users and accepts an action/target payload after membership validation
(repository verified in
[helper/security migrations](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L50)).
Therefore a client may be able to append a forged `match.accepted` or
`match.rejected` audit event even after table DML is revoked. Before treating
these audit actions as authoritative, either:

- prevent authenticated `log_audit` callers from submitting workflow-owned
  actions (after inventorying all callers), or
- make decision evidence authoritative only when a typed decision row and
  its transactionally inserted audit row correlate, and label uncorrelated
  client-generated events non-authoritative.

The RPC uses the separate `log_reconciliation_audit` wrapper, granted only to
the executor. This wrapper's actual owner, RLS behavior, and hosted ACL must
be verified before rollout. Do not grant it directly to authenticated or
service_role as a workaround.

## 7. Idempotency and retry contract

### 7.1 Chosen contract: committed decisions only

An idempotency key is persisted only with a successfully committed typed
accept/reject decision. Domain conflicts, authorization failures, malformed
requests, and transaction errors do not reserve keys and are not replayed.
This intentionally does not promise durable idempotency for every attempted
outcome.

The unique key scope is:

```text
(company_id, reviewer_id, idempotency_key)
```

The unique partial index excludes legacy rows whose key is NULL. A separate
unique partial index on `(company_id, candidate_id)` allows at most one typed
terminal decision per candidate. Existing untyped historical rows are not
backfilled.

### 7.2 Key use rules

- One UUID is generated by the application per user intent using a
  cryptographically secure UUID generator (e.g. `crypto.randomUUID()`).
- The action adapter accepts the key, validates UUID syntax, and sends it
  with the RPC. The UI/action caller persists the key until it receives a
  definitive RPC result; it reuses that key after timeout or transport loss.
- A new deliberate user action creates a new key. A conflict response ends
  that request; the client discards the key and creates a new key only if the
  user changes/retries the intent.
- Same reviewer/company/key + same candidate/action returns the recorded
  outcome without extra links, decisions, count changes, or audit events.
- Same reviewer/company/key + different candidate or opposite action returns
  `idempotency_key_conflict`.
- Different reviewers or companies have independent key namespaces. Candidate
  row lock and unique candidate decision index still prevent two final
  decisions on the same candidate.
- Conflict outcomes do not reserve a key. The application must not reuse a
  conflicted key for a newly submitted intent.

Advisory locking uses one transaction-level bigint:

```text
pg_catalog.hashtextextended(
  company_uuid_text || ':' || reviewer_uuid_text || ':' || key_uuid_text,
  fixed documented seed
)
```

The advisory lock key omits action and candidate so reuse of a key across
either dimension serializes before lookup and is rejected by comparing the
stored candidate/action. Hash collisions cause only extra waiting; the unique
index and exact tuple comparison determine correctness. Record the seed and
canonical UUID encoding in implementation comments/tests.

### 7.3 Retry and error policy

| Outcome | Application behavior |
|---|---|
| Same-key committed replay | Treat as the original accepted/rejected result; refresh UI. |
| Expected entity/inactive/already-decided/key conflict | Show distinct conflict; do not report success; discard key when the user ends/changes the intent. |
| SQLSTATE `40P01` deadlock | Retry the entire RPC transaction with bounded exponential backoff and the same key. |
| SQLSTATE `40001` serialization failure | Retry the entire RPC transaction with bounded exponential backoff and the same key. |
| Network timeout/connection loss after submission | Outcome is unknown; retry with the exact same key. Never generate a replacement key for the same intent. |
| `42501` authorization denial | Do not retry automatically; show permission/session error. |
| Invalid arguments / NULL identity | Do not retry; report validation/authentication error. |
| Unexpected `23505`, FK/check violation, audit error, permission error, or SQL exception | Do not translate to accepted/rejected JSON. Surface explicit failure and log safe diagnostics; investigate invariant/implementation error. |
| Lock timeout/cancellation | Treat as retryable only under a bounded documented policy and same key; do not convert to a domain conflict. |

Retries are whole-transaction retries, not continuation after an aborted
statement. Do not retry with a new key automatically.

## 8. Corrected schema and migration sequence

This section is a specification only. No SQL is to be executed from this
document.

### 8.1 Data preflight and migration-history gates

Before any target DDL, run the seven corrected SELECT-only Stage 1A checks on
the exact target and the pending duplicate/reversed-pair check. Stage 1A
reported zero local findings; hosted results are unknown. Stop on any row.
No automatic data repair, historical decision synthesis, link reassignment,
or count correction is allowed.

Resolve local/hosted migration version `20261101000006` separately:

- Stage 1B recovered SQL from local database metadata, not Git.
- The version-06 file is missing from inspected repository refs; original
  filename/content provenance and the reason it is recorded remain
  unresolved.
- Do not fabricate or silently reconstruct the file, edit applied migration
  history, apply version 06, or change the active function as part of this
  milestone. Obtain database-owner provenance, exact hosted migration history,
  function definition, owner, security mode, search path, and grants through
  authorized read-only inspection first.
- No later migration deployment is authorized until the migration-history
  discrepancy has a separately approved resolution plan.

### 8.2 Index build sequence and CLI behavior

Prior Stage 1B inspected Supabase CLI v2.119.0 source. It flushes normal
statement batches around `CREATE [UNIQUE] INDEX CONCURRENTLY`, executes the
index statement outside those batches, then records migration history in a
later batch. Such a migration is not atomic across the concurrent statement
and surrounding batches. PostgreSQL 15 prohibits `CREATE INDEX CONCURRENTLY`
inside an explicit transaction. This is source inspection, not a failure
rehearsal.

Sequence:

1. Reconcile version-06 provenance and verify CLI version/workflow in the
   deployment environment.
2. Run preflight and inspect table sizes, existing constraints/indexes, and
   duplicate/reversed pairs.
3. Build required large unique indexes **only after all required columns
   exist**. Isolate each `CREATE UNIQUE INDEX CONCURRENTLY` in a dedicated
   migration step/file with no dependent DDL before or after it.
4. For small tables where lock/downtime is accepted, a normal transactional
   unique index can be used after explicit operational review. Do not choose
   concurrent creation by default without size/lock rationale.
5. After every concurrent build, inspect `pg_index.indisvalid`,
   `indisready`, index definition, duplicates, and migration history. If the
   index succeeded but history insertion failed, stop and reconcile actual
   schema/history; do not blindly rerun.

### 8.3 Parent keys, identifier uniqueness, and child-side indexes

Create non-partial unique parent indexes required for composite FKs:

- source records: `(company_id, id)`;
- entities: `(company_id, id)`;
- match candidates: `(company_id, id)`.

Existing PKs on `id` remain; these unique indexes make the tenant/id pair a
referencable key.

Create a non-partial unique identifier index:

- `(company_id, source_record_id)`.

This invariant includes identifiers to soft-deleted entities. It prevents a
source from having a second current entity relationship. Do not use a partial
`deleted_at IS NULL` predicate because identifier rows have no active/historic
state.

Create/verify child-side indexes supporting FK lookups and deletes:

- identifiers `(company_id, entity_id)`;
- identifiers `(company_id, source_record_id)`;
- candidates `(company_id, record_a_id)`;
- candidates `(company_id, record_b_id)`;
- candidates `(company_id, entity_id)` (entity_id NULL rows may use a
  partial `WHERE entity_id IS NOT NULL` index);
- reviewer decisions `(company_id, candidate_id)` where candidate_id is not
  NULL;
- reviewer decisions `(company_id, result_entity_id)` where result_entity_id
  is not NULL.

The existing identifier source index and candidate entity index may cover
some access patterns, but do not assume they satisfy composite-FK
maintenance. Review actual plans/table sizes before building duplicates.

### 8.4 Typed reviewer decisions and checks

Add nullable columns to `reconciliation_reviewer_decisions`:

- `candidate_id uuid NULL`;
- `result_entity_id uuid NULL`;
- `idempotency_key uuid NULL`.

Legacy rows keep NULL typed fields; do not backfill from candidate status,
generic text targets, or audit records.

Add CHECK constraints (nullable-compatible) for new typed rows:

- `candidate_id IS NULL` is allowed for historical/non-match rows.
- If `candidate_id IS NOT NULL`, `decision` is `accept_match` or
  `reject_match`, `decision_target_table` equals
  `reconciliation_match_candidates`, and `decision_target_id` equals
  `candidate_id::text`.
- A typed accept requires non-NULL `result_entity_id`.
- A typed reject requires `result_entity_id IS NULL`.
- A non-NULL `idempotency_key` requires non-NULL `candidate_id` and reviewer.
- Do not require old rows to gain candidate/result/key values.

Create unique partial indexes only after the columns and checks exist:

- `(company_id, candidate_id) WHERE candidate_id IS NOT NULL`;
- `(company_id, reviewer_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL`.

Both are indexes; partial unique indexes cannot be attached as ordinary
UNIQUE constraints. `reviewer_id` is already NOT NULL in the existing
decision table; its current `ON DELETE SET NULL` action is contradictory.
Replace it with `ON DELETE RESTRICT` only after account-erasure policy
approval and a controlled FK transition.

### 8.5 Tenant composite FKs

After parent unique indexes exist, add composite FKs with `NOT VALID`, then
validate in a later controlled step:

- identifiers `(company_id, entity_id)` → entities `(company_id, id)`;
- identifiers `(company_id, source_record_id)` → source records
  `(company_id, id)`;
- candidates `(company_id, record_a_id)` →
  source records `(company_id, id)`;
- candidates `(company_id, record_b_id)` →
  source records `(company_id, id)`;
- candidates `(company_id, entity_id)` → entities `(company_id, id)`;
- decisions `(company_id, candidate_id)` → candidates `(company_id, id)`;
- decisions `(company_id, result_entity_id)` → entities `(company_id, id)`.

For nullable entity/result columns, default MATCH SIMPLE permits a NULL
optional reference. Checks in §8.4 enforce the typed accept/reject semantics.
Composite tenant IDs are NOT NULL on the child rows.

FK delete actions:

- Identifier → entity/source: proposed `ON DELETE RESTRICT` to preserve
  provenance.
- Candidate → source/entity: proposed `ON DELETE RESTRICT` for historical
  decision and candidate integrity; candidate entity NULL remains optional.
- Typed decision → candidate/result entity: proposed `ON DELETE RESTRICT`.
- Reviewer → `auth.users`: replace contradictory `SET NULL` with
  `RESTRICT`, subject to approved account-erasure/retention policy.
- All affected tables currently have company-level `ON DELETE CASCADE`
  references in the base migration. Do not assume restrictive child FKs
  compose safely with company cascade. Company deletion must be held/disabled
  during transition and explicitly tested. If historical decision/provenance
  retention is required, company deletion must be blocked or moved to a
  separate approved archival/erasure process.

For existing simple FKs with CASCADE/SET NULL, do not leave conflicting
actions indefinitely. After preflight and during a controlled deletion freeze,
replace the simple FK set with the validated composite set in a transactional
migration (no concurrent index statement in that transaction). New composite
FKs must enforce new writes immediately even while existing rows are
`NOT VALID`. Validate old rows separately. Test entity and company deletion
before and after transition.

### 8.6 Candidate-pair uniqueness and worker compatibility

Current schema has a partial unique index on directional
`(record_a_id, record_b_id)` while status is pending. The matching worker
inserts raw pair ordering and uses
`ON CONFLICT (record_a_id, record_b_id) WHERE status = 'pending' DO NOTHING`.

Preferred correction: normalize pair order in the matching worker by storing
`LEAST(a,b)` in `record_a_id` and `GREATEST(a,b)` in `record_b_id`, reject
self-pairs as today, and add/validate a `CHECK (record_a_id < record_b_id)`
for new and historical rows. Preflight all existing pairs first. Then the
ordinary partial unique index and its existing `ON CONFLICT` inference remain
compatible; no expression-index conflict target ambiguity is introduced.
The worker's lease/tenant authorization and exact EXECUTE grant stay
unchanged. This is a worker code change that must be cut over with the check.

### 8.7 FK/index migration ordering

Recommended ordered phases:

1. Preflight, migration-history resolution, backup, caller inventory.
2. Create parent unique indexes `(company_id,id)` concurrently where justified.
3. Create one-source unique identifier index concurrently where justified.
4. Create child-side FK-supporting indexes concurrently where justified.
5. Add nullable decision columns and compatible CHECK constraints in normal
   transactional migration(s).
6. Add candidate normalized-order check `NOT VALID` after worker update; validate
   only after historical scan.
7. Create decision/idempotency partial unique indexes concurrently; columns
   must already exist.
8. Add composite FKs `NOT VALID`; use separately reviewed transactional
   migration without concurrent-index statements.
9. Validate constraints in a later controlled step; retain old simple FKs
   until new tenant FKs validate, then replace old actions transactionally.
10. Install/verify internal lock helpers, executor role, tenant-scoped RLS
    policies, function owner transfer, RPCs, helper/audit grants, and explicit
    revokes.
11. Deploy application RPC caller and separate entity-confirmation path;
    update candidate worker normalization. Resolve discrepancy workflow scope.
12. In coordinated cutover, pause writes, revoke direct authenticated DML,
    enable only new RPC execution, verify worker/service behavior, then resume.

PostgreSQL 15 supports composite unique indexes/FKs, FK `NOT VALID`, partial
unique indexes, and expression/check constraints. Unique constraints cannot
be marked NOT VALID. Verify exact syntax and CLI behavior in a disposable
database before scheduling hosted changes.

### 8.8 Migration-06 recovery boundary

The only available Stage 1 evidence is that the local migration-history table
records `20261101000006` and retains four SQL statements; the active local
function reportedly matches those statements. Stage 1B found no matching file
in inspected repository refs, and `20261101000002` has same name but different
SQL. The stored SQL is database-recovered evidence, not Git history.

Do not recreate the missing file, apply it, edit the active function, or
change migration history in Stage 1E. Before any later migration:

1. Obtain database-owner confirmation of version-06 provenance and intended
   authority of the local metadata.
2. Confirm exact intended hosted project identity out of band.
3. Use authorized read-only hosted inspection for migration version/name/
   statements, `pg_get_functiondef`, `proowner`, `prosecdef`, `proconfig`, and
   effective grants.
4. Have the owner approve a separate history reconciliation plan. If
   provenance remains unknown, stop; do not fabricate a migration artifact
   and call it original.

## 9. Foreign keys and deletion lifecycle

### 9.1 Entity lifecycle

- Soft-deleting an entity sets `deleted_at`; it does not unlink identifiers.
- Acceptance targeting any source/candidate link to a soft-deleted entity
  returns `inactive_entity_conflict`; no new entity/link is created.
- Restoration is not part of match acceptance. Any restore operation requires
  a separate owner/admin-authorized and audited workflow plus a product
  decision.
- Physical entity deletion is blocked while identifiers or typed decisions
  reference it under the proposed RESTRICT relationships. A separate
  authorized, audited archival/erasure workflow is required to resolve those
  links; no silent cascade is allowed.
- Normal entity list, review context, and export must exclude deleted entities.
  Historical/deleted access is a separate authorized view. The current
  listing/export queries do not filter deleted entities.

### 9.2 Company deletion

Current company FKs on reconciliation rows use ON DELETE CASCADE. New
RESTRICT child FKs can block or interact with that cascade. Do not assume
PostgreSQL's cascade ordering provides the intended retention outcome.

Before changing constraints, decide whether company deletion:

- is blocked while provenance, decisions, or audit retention obligations exist;
- is an explicit tenant-erasure job that removes all dependent data under
  approved legal/security policy; or
- archives/pseudonymizes history before tenant deletion.

Freeze company deletion during FK transition. Test the chosen operation on a
disposable schema with the complete constraint graph. Do not change
company-level cascades by assumption.

### 9.3 Reviewer-account deletion and historical decisions

The current reviewer decision column is NOT NULL but its FK uses
`ON DELETE SET NULL`, which is contradictory. Proposed `ON DELETE RESTRICT`
preserves attribution and blocks account deletion while typed/legacy decisions
reference that user. This is not a final erasure policy. Obtain account-erasure
approval for retention, pseudonymization, or a separately audited attribution
redaction before deploying the FK change.

Legacy reviewer decisions remain unchanged and typed columns NULL. No
fabricated decision is permitted. If company data or user accounts are erased,
preserve applicable decision/audit retention requirements explicitly.

### 9.4 Record counts

`record_count = COUNT(*)` of all identifiers for an entity; deleted entity
status does not exclude its retained links. On successful acceptance:

1. Lock active target entity.
2. Insert only missing links.
3. Recount all entity identifiers.
4. Update only `record_count` (and `updated_at` only if required by existing
   verified timestamp semantics).

No background or migration backfill is implied. Existing mismatches require a
separate audited repair process. Recount correctness depends on all
identifier writers taking the same source/entity locks and direct writes
being revoked.

## 10. Application write-path cutover matrix

Paths are repository-verified. Existing external scripts, deployed
environment code, or untracked operational clients are **not verified** and
must be inventoried before revoking privileges.

| Existing path | Current database operation | Proposed replacement | Required before DML revocation / scope |
|---|---|---|---|
| Match acceptance — [`acceptMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L159) | Candidate read/update; identifier read/insert; source raw-data reads; entity create with merged `first_non_null_wins` canonical values; candidate entity update; separate audit RPC. Some write/audit errors are ignored. | Single `accept_reconciliation_match` RPC. | **Included.** Change action to pass durable per-intent key, map typed outcomes, and remove all multi-request writes/source-value reads. |
| Match rejection — [`rejectMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L299) | Candidate read/update, then separate audit RPC. | Single `reject_reconciliation_match` RPC. | **Included.** Typed decision/audit atomic; no entity/link insert. |
| Review queue — [`review/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L21) | Tenant SELECT of pending candidates and joined source IDs/raw data; presentation gate based on app metadata. | Keep tenant SELECT; DB RPC enforces current owner/admin. Display typed conflict/replay responses. | **Included integration.** UI role check is not authorization. Review raw-data display remains governed by existing privacy/read policy. |
| Entity creation / identifier insertion from accept | Direct inserts only in `acceptMatch` were found in app code. | Included accept RPC only. | **Included.** Search deployed scripts/service-role callers before direct DML revoke. |
| Entity confirmation — [`confirmEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L354) | Entity SELECT/UPDATE candidate→confirmed, followed by separate audit RPC. | Separate `confirm_reconciliation_entity` RPC with its own owner/admin authorization, status transition, audit, and concurrency semantics. | **Required before revoking entity UPDATE.** In scope for safe cutover as compatibility prerequisite, not part of match RPC contract. |
| Entity list — [`entities/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx#L29) | Tenant SELECT does not filter `deleted_at`; offers export link. | Filter `deleted_at IS NULL` in normal list; separate historical view only if approved. | **Included soft-delete UX.** No DML, but must be updated for stated policy. |
| Export page — [`export/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx#L27) | Reads entity by ID/company regardless of deletion, then calls export action. | Reject or hide deleted entities for ordinary export; no restore. | **Included soft-delete UX.** |
| Entity export action — [`exportEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L406) | Reads entity, identifiers, source raw data; uploads CSV to Storage, requests signed URL/fallback, then calls `log_audit`. | Keep explicit tenant authorization; filter deleted entity; surface audit failure; retain Storage path only after storage policy/caller review. | **Included as export compatibility/security requirement**, not implemented by match RPC. |
| Discrepancy resolution — [`resolveDiscrepancy`](../examples/nextjs/lib/actions/reconciliation.ts#L592) | Reads and updates discrepancy, then separately logs audit. No typed reviewer decision is inserted by this action. | **Deferred** from Phase 2A.3.4 unless product explicitly expands scope to a separate `resolve_reconciliation_discrepancy` RPC. | Do not claim all human decisions are atomic. Do not revoke discrepancy DML until a separate scope/cutover is approved. |
| Source-record import — [`reconciliation_import_insert_record`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L100) | Worker SECURITY DEFINER function inserts after a live import lease; dedicated import worker has no direct table DML. | Preserve existing import RPC and its owner, empty search path, lease checks, and EXECUTE grants. | **Preserve/test.** Authenticated source INSERT is revoked only after confirming imports use this boundary. |
| Matching candidate generation — [`reconciliation_matching_write_candidates`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L199) | Matching worker SECURITY DEFINER function inserts pending pairs using directional ON CONFLICT. | Preserve lease boundary and worker role. Normalize pair ordering and maintain compatible unique conflict inference. | **Included compatibility change** for candidate index/check rollout. |
| Import/run creation and retry actions — [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L12) | Direct writes to import jobs/reconciliation runs, outside the protected six-table set. | No change from match RPCs. Preserve existing per-table RLS/RPC design; inventory separately if broader DML revocation is proposed. | Not covered by match milestone. Do not inadvertently revoke their ACLs. |
| Entity/review/export reads in dashboard — [`reconciliation/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/page.tsx#L27) | Reads source/entity counts and statuses. | Keep tenant SELECT; filter deleted entities from active count if required by approved UX. | Read path only; no match RPC replacement. |
| Direct reviewer-decision insertion | No direct Next.js `.insert()` into `reconciliation_reviewer_decisions` found. Legacy table remains append-only under RLS. | New match RPC is the only new typed decision writer. | Inventory scripts/admin clients; no retroactive data writes. |
| Service-role / Edge Functions | Repository search finds service-role clients in invitation and import-download-url Edge Functions, not direct match/entity/identifier/reviewer-decision writes. Python workers use dedicated worker DB roles and scoped RPCs. | Preserve unrelated invitation/download behavior. Preserve only verified operational worker grants; no service-role accept/reject. | **Unverified external deployment callers.** Inspect deployed functions and effective target grants before DML revokes. |
| Test/operations fixtures | A service-side SQL idempotency fixture directly inserts source records; migrations create/alter tables through privileged migration execution. | Keep direct fixture writes confined to isolated test setup; test production role boundaries through worker RPCs. | Update fixture execution role/setup if it currently depends on authenticated/worker DML. Migrations remain privileged operations. |

The function's server-side export Storage fallback currently catches storage
errors and returns inline CSV; that behavior is unrelated to match acceptance.
The export path still needs an explicit audit-error policy and deleted-entity
filter before the broader reconciliation cutover.

## 11. Testing and verification matrix

All test data must be synthetic. Never use production PII for fixture or
concurrency tests.

### 11.1 Local database integration tests

| Test | Required assertions |
|---|---|
| SECURITY DEFINER ownership/privilege escalation | Inspect `proowner`, `prosecdef`, `proconfig`, schema CREATE, function ACLs, role attrs/memberships; authenticated/anon/workers cannot SET ROLE to executor or execute lock helpers. |
| FORCE RLS under actual executor | Invoke RPC under authenticated JWT. Confirm the function owner is executor, is not owner/BYPASSRLS, and role-specific policies filter rows by `public.auth_uid()` membership. Test no row for foreign tenant. |
| Cross-tenant candidate disclosure | Compare nonexistent ID and foreign-tenant ID. Both produce the same generic response/error and no candidate/source/entity details or writes. |
| Exact function grants | `has_function_privilege` for PUBLIC, anon, authenticated, service_role, import worker, matching worker, scheduler, executor, and lock-helper owner; only authenticated executes public RPCs, only executor invokes helpers/audit wrapper. |
| Exact table/schema/type grants | `has_table_privilege` at column scope; no direct executor source/membership/audit access; no protected-table DML to authenticated; no unintended service/worker ACL. |
| Row-lock privilege verification | Candidate/entity locks succeed with exact executor column UPDATE rights and RLS; membership/source locks succeed only through trusted helpers; executor cannot UPDATE source or membership. |
| Owner/admin accept | Correct tenant, typed decision, entity/link provenance, empty canonical data for new entity, neutral rule, count, candidate state, and exactly one audit row. |
| Member accept/reject denial | Authenticated member cannot call either RPC successfully; no state or audit changes. |
| Rejection | Candidate rejected; one typed decision/audit; no entity or identifier created or modified. |
| Existing entity conflict | Two different entities linked to pair returns `entity_conflict`; canonical data, status, links, count unchanged; no decision/audit. |
| Deleted entity conflict | Link to soft-deleted entity returns `inactive_entity_conflict`; link/entity/count remain; no restore or new entity. |
| Direct DML denial | Authenticated cannot insert/update/delete candidates; insert/update/delete entities; insert/update/delete identifiers; insert/update/delete reviewer decisions; insert/update/delete sources. Tenant SELECT still scoped. |
| Audit-wrapper failure | Fail inside `log_reconciliation_audit` in an isolated database. Assert candidate, entity, links, decision, count, and audit all roll back. |
| Audit forgery | Authenticated cannot create authoritative `match.accepted`/`match.rejected` audit events through generic `log_audit`; typed decision and audit transaction correlate. |
| Historical rows/FK compatibility | Existing reviewer decisions remain unchanged with typed NULLs; no fabricated decisions. Composite FKs validate without changing legacy state. |
| Candidate normalized pairs | Both input orders produce one pending candidate; self-pairs rejected; exact worker `ON CONFLICT` target is inferred; tenant foreign keys remain correct. |
| Soft-delete list/export | Active list/export excludes deleted entity; historical view only by approved path; count and links include retained relationships. |
| Reviewer/company/entity deletion | Verify chosen `RESTRICT`/cascade/erasure plan against full FK graph and audit retention. |
| Worker compatibility | Existing import/matching role attributes, no direct affected-table privileges, scoped RPC EXECUTE, live-lease checks, audit behavior, and service_role grants remain correct. |
| Counts/canonical data | Two concurrent compatible link operations yield exact count; existing canonical_data and survivorship remain unchanged. |

### 11.2 Staging integration and concurrency tests

Use independent authenticated DB sessions and barriers; run through actual
Supabase/PostgREST JWT and connection roles:

1. Accept/accept same candidate/same key: one commit, one replay, one decision,
   one audit.
2. Accept/accept same candidate/different keys: one decision; loser gets
   `candidate_already_decided`.
3. Accept/reject same candidate: one terminal outcome only.
4. Different candidates share a source: locks are sorted; one-source unique
   invariant holds; same active entity can be reused; conflict leaves no
   partial writes.
5. Different candidates share an entity: entity row lock serializes recount;
   no canonical overwrite or stale count.
6. Concurrent new-entity acceptance for shared sources: one entity/link pair
   only; second sees same link or conflict.
7. Concurrent membership downgrade/removal: revocation-first denies;
   decision-first holds current role until transaction completion.
8. Concurrent same-key reuse across candidates/actions: advisory lock
   serializes; mismatch returns conflict; no second write.
9. Simulated response loss after commit: retry same key returns persisted
   result with no duplicate audit/link/decision/count.
10. Force deadlock and serialization error in a disposable staging setup;
    verify SQLSTATE `40P01`/`40001` causes bounded full-transaction retry with
    the same key.
11. Worker candidate insertion concurrent with acceptance/source locks and
    normalized pair index: verify no deadlock cycle, lost candidate, duplicate,
    or lease bypass.
12. Verify entity/company deletion and reviewer account erasure only under
    approved policy. Do not use production for destructive tests.

### 11.3 Concurrent-index recovery test

In an isolated disposable database with the deployed Supabase CLI version:

- intentionally interrupt/fail one standalone concurrent unique index build;
- inspect whether the index is absent, invalid, or ready and whether migration
  history was written;
- execute the reviewed targeted cleanup/retry procedure;
- verify no unrelated index/data/history is touched;
- repeat with index success followed by simulated later migration failure.

Do not run DDL failure injection in production. Supabase CLI v2.119.0 behavior
is prior source-inspection evidence, not proof about a different hosted CLI
version.

### 11.4 Production read-only verification

Before any production approval, read-only inspect:

- exact project ref/org/environment confirmation;
- PostgreSQL/CLI versions and migration history, including version 06;
- all seven preflight checks plus duplicate/reversed pending-pair check;
- parent/child index definitions and `pg_index.indisvalid`;
- constraints, delete actions, RLS enabled/forced, and policy predicates;
- role attrs/memberships, schema/type/table/column privileges, function owner,
  SECURITY DEFINER, search path, and effective EXECUTE grants;
- worker and scheduler boundaries, source immutability trigger, service-role
  direct ACL, audit wrapper owner/grant, entity deleted filters and counts.

Production tests remain read-only. No concurrency race, injected failure,
delete, DDL, or DML test runs in production.

## 12. Deployment and rollback requirements

### 12.1 Preconditions and order

1. Obtain owner confirmation and separately resolve migration-06 provenance.
   Do not fabricate a migration file or change applied history.
2. Obtain exact hosted project identity out of band and explicit read-only
   inspection authorization. No project guessing or secret sharing.
3. Re-run preflight and catalog checks on the target. Stop on every finding
   until approved human remediation is complete.
4. Inventory all application, service-role, worker, scheduler, test, and
   operations callers of protected DML and log helpers.
5. Approve account-erasure, company deletion, physical entity deletion,
   discrepancy scope, entity confirmation RPC, and deleted export UX.
6. Back up and rehearse every migration/role/owner/RLS change on production-like
   staging, including index-failure recovery.
7. Build parent and child indexes in isolated concurrent steps if size/lock
   analysis requires. Inspect index validity/history after each.
8. Add typed columns/checks, then typed indexes, then composite FKs
   `NOT VALID`; validate after scans. Replace old simple FK delete actions
   under a controlled deletion freeze.
9. Provision roles and helpers; execute temporary ownership-transfer
   procedure in §12.2; install tenant policies/functions/grants and verify
   effective privilege boundaries.
10. Deploy application accept/reject RPC callers and key management, separate
    entity confirmation path, soft-delete filters, normalized matching worker,
    and agreed audit hardening. Keep discrepancy resolution explicitly
    deferred unless its own RPC is included.
11. Pause writes/review UI; apply direct authenticated DML revokes and RPC
    grants in the approved cutover; verify direct DML fails and worker paths
    pass; resume only after tests pass.
12. Run post-deployment checks and monitor conflicts, audited decisions,
    count/source uniqueness, worker leases, and application errors.

### 12.2 Deployable function-owner procedure

PostgreSQL requires the role executing `ALTER FUNCTION ... OWNER TO new_owner`
to own the function and be a member of the new owner role; the new owner must
have CREATE on the target schema. Managed Supabase migration principal
capabilities are **not verified**.

Subject to platform approval:

1. Provision `reconciliation_workflow_executor` with final NOLOGIN,
   NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOINHERIT, NOBYPASSRLS and no
   memberships.
2. Create the functions as the authorized migration owner/table owner.
3. Temporarily grant the minimum role membership required for the migration
   operator to transfer ownership, and temporarily grant CREATE on `public`
   to the new function owner only if PostgreSQL requires it for that transfer.
   These grants are migration-time capabilities, not final privileges.
4. Alter owner for the exact two public RPC signatures to
   `reconciliation_workflow_executor`.
5. Revoke temporary CREATE on `public` from executor and revoke temporary
   membership from migration operator in the same controlled transaction
   where the platform supports it.
6. Explicitly grant only the narrow helper/table/type permissions and
   function EXECUTE ACLs specified above.
7. Verify executor has no final schema CREATE, role memberships, LOGIN,
   BYPASSRLS, table ownership, or broad table ACL; verify functions have
   owner=executor, `prosecdef=true`, `proconfig` includes empty search path.

If the hosted migration role cannot obtain the required temporary membership
or schema grant, stop and have the Supabase/platform owner perform a reviewed
bootstrap or choose another design. Do not assume hosted superuser access,
leave CREATE granted permanently, or grant BYPASSRLS to executor/workers.

### 12.3 Rollback and recovery

- Concurrent index failure: inspect `pg_index.indisvalid`, `indisready`,
  `pg_get_indexdef`, conflicting data, and migration history. Remove/rebuild
  only the specifically identified failed index through an approved
  non-transactional procedure. Never blindly rerun.
- Index created but migration history absent: stop. Reconcile actual catalog
  and history with database owner; do not apply manual history edits or
  migration repair commands without separate approval.
- Transactional schema migration failure: verify the exact CLI batch boundary;
  ordinary DDL transaction rollback does not make a migration containing
  concurrent index segments atomic as a whole.
- RPC/application issue after direct-DML revocation: disable human review
  actions and prefer a forward fix. Do not restore broad DML as an emergency
  shortcut. Keep workers/read paths operating if safe.
- Do not delete reviewer decisions, audit records, identifiers, candidates,
  or reverse accepted relationships automatically. Correct a decision only
  through a separately approved, audited resolution workflow.
- Restore a verified backup only under incident/recovery approval and account
  for decisions committed after the snapshot.

## 13. Outstanding decisions and unresolved evidence

1. **Migration 06:** original Git artifact/provenance not recovered; local
   metadata SQL is not proof of original file or application mechanism.
2. **Hosted state:** exact project, migration history, row integrity,
   constraints, ACL/RLS, helper owner capabilities, worker grants, and active
   function definition remain unverified.
3. **Lock-helper owner capability:** local Stage 1 reports `postgres`
   privilege details; hosted `postgres` table ownership/BYPASSRLS/UPDATE
   privileges and FORCE RLS behavior remain unknown.
4. **Migration operator capability:** ability to grant temporary owner
   membership/schema CREATE and revoke them on hosted Supabase is unknown.
5. **Audit authenticity:** generic `log_audit` is currently callable by
   authenticated users. Decide whether to restrict workflow action enum values
   there or treat only transaction-correlated typed decision/audit records as
   authoritative.
6. **Account erasure:** approve `ON DELETE RESTRICT`, retention, or
   pseudonymization for reviewer attribution.
7. **Company/entity deletion:** approve the exact lifecycle and cascade or
   block behavior across composite FKs.
8. **Entity confirmation:** required separate narrow RPC before entity UPDATE
   revocation; exact scope/audit contract not yet designed.
9. **Discrepancy resolution:** remains a separate non-atomic workflow and is
   explicitly deferred unless separately approved.
10. **Service-role and external callers:** repository search did not find
    direct protected-table writes in the cited app/Edge paths, but deployed
    code, scripts, and external clients require owner inventory.
11. **CLI migration semantics:** source inspection applies to v2.119.0; hosted
    version and disposable failure-recovery rehearsal are still required.
12. **Data remediation:** local seven checks were clean; hosted findings are
    unknown. No silent repair is allowed.

## 14. Stage 2 authorization checklist

Stage 2 implementation may be authorized only after all conditions hold:

- [ ] Database owner resolves migration-06 provenance and approves a separate
  migration-history plan; no fabricated original is presented.
- [ ] Exact intended hosted project is confirmed; authorized read-only
  inspection verifies history, function, schema, constraints, roles, RLS,
  grants, workers, soft-delete behavior, and all preflight checks.
- [ ] Every preflight is clean or each finding has approved human remediation.
- [ ] PostgreSQL privilege proof establishes candidate/entity locks work with
  scoped UPDATE rights and source/membership helpers work without granting
  source UPDATE to executor.
- [ ] Helper owner can satisfy PostgreSQL row-lock and RLS requirements on the
  target; if not, an alternative has been designed and reviewed.
- [ ] Executor policies and exact table/column/type/function ACLs are
  specified, tenant-filtered, and pass FORCE RLS tests; no unrestricted policy
  exists.
- [ ] Function ownership transfer succeeds with temporary privileges, and
  final executor has no LOGIN, BYPASSRLS, memberships, schema CREATE, or table
  ownership.
- [ ] Current membership is locked/read atomically and is the authorization
  decision; isolation and retry behavior are tested.
- [ ] Committed-decision idempotency contract, UUID lifecycle, conflict
  semantics, response types, and retry SQLSTATEs are implemented in app design.
- [ ] Typed-column/index/FK order is corrected; child indexes, FK actions,
  validation, company deletion, entity deletion, and reviewer erasure are
  approved.
- [ ] Application cutover includes match RPC callers, confirmation RPC,
  deleted list/export filtering, worker candidate normalization, service
  caller inventory, and explicit discrepancy deferral/approval.
- [ ] Generic audit helper cannot create authoritative forged match events, or
  audit consumers explicitly require correlation with typed decision rows.
- [ ] Local security/integration tests and staging two-session concurrency,
  response-loss, deadlock/serialization retry, audit rollback, worker, and
  concurrent-index recovery tests pass.
- [ ] Production verification is read-only and production deployment receives
  a separate explicit approval.

**Final recommendation: NO-GO. Stage 2 is not authorized.** The blueprint is
corrected on paper, but hosted state, migration-06 provenance, trusted helper
and migration-role capabilities, lifecycle decisions, application cutover,
and runtime security/concurrency tests remain outstanding. This document
authorizes no code, migration, grant, role, policy, or database change.
