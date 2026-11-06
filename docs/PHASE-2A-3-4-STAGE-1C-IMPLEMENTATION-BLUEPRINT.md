# ZamBase Phase 2A.3.4 — Stage 1C Implementation Blueprint

> **Design only.** This blueprint proposes database and application changes; it
> does not authorize implementation, migration execution, or hosted changes.
> The Stage 1A/1B evidence describes the local development database only.
> Hosted Supabase remains uninspected.

## 1. Executive summary

**Recommendation: NO-GO for implementation or deployment.** The local data
preflight is clean, but the missing migration history entry, authenticated
direct-write bypass, application cutover requirements, and unknown hosted
state remain unresolved.

The approved business boundary is:

- A source record may be linked to no more than one canonical entity.
- Accepting a match creates/establishes entity relationships and preserves
  provenance; it does not select, merge, or overwrite canonical values.
- A source pair already linked to different entities returns an explicit
  conflict. Entity merges require a separate authorized, reviewed, and audited
  workflow.
- A new entity starts with `{}` canonical data and
  `manual_review_required` survivorship.
- Only a current tenant owner or administrator may accept or reject.
- Rejection creates no entity or identifier links.
- Source records are immutable. Legacy final candidates without a typed
  reviewer-decision row remain historical; no decision is backfilled.
- `record_count` is the current count of identifier links and is recalculated
  transactionally for entities changed by acceptance.
- A deleted entity retains its links and is not eligible for new acceptance.

The repository's Stage 1A/1B reports are the available written Phase 2A.3.4
specification and evidence. No separate final specification file was found in
`docs/`. Repository facts and observed local state are distinguished below from
proposed design. The primary repository sources inspected were the
[Stage 1A preflight report](./PHASE-2A-3-4-STAGE-1A-PREFLIGHT-REPORT.md),
[Stage 1B readiness report](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md),
[reconciliation schema and RLS migration](../supabase/migrations/20261029000001_reconciliation_module.sql),
[worker and audit security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[reconciliation security operations migration](../supabase/migrations/20261030000002_reconciliation_security_ops.sql),
and [current reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts).

## 2. Evidence and migration recovery

### 2.1 Evidence classification

| Item | Finding | Evidence status |
|---|---|---|
| Local migration history | PostgreSQL 15.19 records version `20261101000006`, name `enforce_import_finish_lease`, with four statements. | Directly verified locally; see the [Stage 1B report](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md). |
| Repository history | No matching migration file was found in the worktree or searched Git refs/commits. `docs/WORKERS.md` references the filename but describes a different function. | Directly verified within inspected refs; unreachable Git objects and other clones are not verified. |
| Earlier repository migration | `20261101000002_enforce_import_finish_lease.sql` is present and caps errors at 10,000 characters. | Directly verified in the repository. |
| Database-recorded version 06 SQL | The migration metadata retains the four statements reproduced below. Its function caps errors at 1,000 characters and requires a live lease. | Recovered from local database metadata; this is not proof of the original Git file or its provenance. |
| Active local function | `pg_get_functiondef` reportedly matches version 06, is owned by `postgres`, has an empty search path, and is executable by the import worker but not `authenticated`. | Directly verified locally per Stage 1B; not verified hosted. |
| Reason it was applied | It may have come from another repository state or a file later omitted. | Inference only. Actor, source commit, and whether it was applied by CLI or manually are unknown. |

### 2.2 SQL recovered from local database metadata

The following is the function statement stored in the local
`supabase_migrations.schema_migrations.statements` value for version
`20261101000006`. Preserve it as **database-recovered SQL**, not as a recovered
historical repository artifact:

```sql
CREATE OR REPLACE FUNCTION public.reconciliation_finish_import(
    _job_id uuid, _claim_token uuid, _status text, _row_count integer,
    _error_count integer, _error text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid; _action public.audit_action;
BEGIN
    IF _status NOT IN ('completed', 'failed') THEN RAISE EXCEPTION 'invalid terminal status'; END IF;
    IF _row_count < 0 OR _error_count < 0 THEN RAISE EXCEPTION 'invalid import counts'; END IF;
    UPDATE public.reconciliation_import_jobs j
       SET status = _status::public.reconciliation_import_status, completed_at = now(),
           row_count = _row_count, error_count = _error_count, error = left(_error, 1000),
           lease_until = NULL, claim_token = NULL
     WHERE j.id = _job_id AND j.status = 'running' AND j.claim_token = _claim_token
       AND j.lease_until > now()
     RETURNING j.company_id INTO _company_id;
    IF _company_id IS NULL THEN RETURN false; END IF;
    _action := CASE WHEN _status = 'completed' THEN 'import_job.completed'::public.audit_action
                    ELSE 'import_job.failed'::public.audit_action END;
    PERFORM public.log_reconciliation_audit(_action, _company_id, 'reconciliation_import_jobs',
        _job_id::text, jsonb_build_object('row_count', _row_count, 'error_count', _error_count));
    RETURN true;
END $$;
```

The remaining recorded statements are:

```sql
ALTER FUNCTION public.reconciliation_finish_import(
    uuid, uuid, text, integer, integer, text
) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.reconciliation_finish_import(
    uuid, uuid, text, integer, integer, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.reconciliation_finish_import(
    uuid, uuid, text, integer, integer, text
) TO reconciliation_import_worker;
```

The active local definition is not independent historical evidence: it
confirms the present local function behavior. Version 02 and version 06 share
the name but differ in their error limit. Version 04, not version 06, contains
the lease-recovery behavior incorrectly attributed to version 06 in
`docs/WORKERS.md`.

### 2.3 Safe repository/history reconciliation plan

Do not edit or apply either migration as part of this blueprint. After a
separate approval:

1. Ask the database/project owner to confirm the intended provenance and
   whether the exact database-recorded SQL is authoritative.
2. Preserve the existing version 02 file and all applied history. Never edit
   an already-applied migration to make it appear consistent.
3. If the owner approves, add a repository artifact at the recorded version
   using the exact metadata-recovered statements, clearly identified in its
   commit/review record as reconstructed from local migration metadata. Do not
   claim it was recovered from Git. Compare its parsed statement sequence with
   the stored metadata and verify `supabase migration list --local` recognizes
   the existing version without reapplying it.
4. If the owner cannot establish that the local row is authoritative, do not
   fabricate a version-06 file or edit `schema_migrations`. Resolve the
   discrepancy through a separately approved migration-history process, with
   backup, exact-target verification, and a reviewed recovery plan.
5. Before any later migration push, compare repository files and history on
   the actual target and ensure there are no duplicate/inconsistent versions.

For hosted verification, first obtain the exact Supabase project reference
from the authorized project owner and independently confirm its organization
and environment. Then, using an approved read-only database session, inspect:

- `supabase_migrations.schema_migrations` for version, name, and stored
  statements at `20261101000006`;
- `pg_get_functiondef` for the exact function signature;
- `pg_proc.proowner`, `prosecdef`, `proconfig`, and effective EXECUTE grants;
- the hosted `supabase migration list` result, if already linked and that
  command is confirmed read-only.

Compare these results with local evidence. Do not infer the hosted project
from a local project name, visible project list, or credentials. Do not print
project secrets or connection strings. A read-only SQL inspection is required
before approving hosted parity.

## 3. Final business and security model

### 3.1 Business rules

1. An identifier row is the current provenance relationship from one source
   record to one entity; it is not deleted or reassigned by either RPC.
2. A source may have zero or one entity link, including when that entity is
   soft-deleted. The uniqueness rule includes deleted entities because the
   current schema has no historical-link/active-link model.
3. If existing links or the candidate's preassigned `entity_id` identify more
   than one entity, return `entity_conflict`; do not merge or modify entities.
4. If the single target entity is soft-deleted, return
   `inactive_entity_conflict`. Do not restore it, unlink it, or create a
   replacement entity.
5. If neither source has a link and the candidate has no target entity, create
   an entity with `canonical_data = '{}'::jsonb`,
   `survivorship_rule = 'manual_review_required'`, `status = 'candidate'`,
   `record_count = 0`, and `created_by = auth.uid()`. Link the two records;
   recalculate the count to 2 in the same transaction.
6. If one or both records already link to the same active entity, add only
   missing links to that entity. Do not change its canonical data,
   survivorship rule, status, or creator.
7. Rejection changes the pending candidate and records a typed decision and
   audit event. It creates no entity and no identifier link.
8. Legacy accepted/rejected candidates without a typed decision remain
   untouched. They are historical, not evidence to synthesize.

### 3.2 Soft-delete policy

- Acceptance of a source already linked to a deleted entity returns
  `inactive_entity_conflict`, with no writes. The existing entity, source,
  identifier, candidate, and decision history remain unchanged.
- Restoration is a separate owner/admin-authorized, audited workflow, not part
  of these RPCs. It must not be implemented by clearing `deleted_at` inside
  acceptance. Whether restoration is eventually allowed, and what review it
  requires, remains a product decision.
- Physical entity deletion should be restricted where it would erase current
  provenance. Prefer `ON DELETE RESTRICT` for current identifier-to-entity and
  decision-to-entity relationships; company/account lifecycle behavior needs a
  separate verified cascade policy before rollout.
- `record_count` means `COUNT(*)` of all identifier links for the entity,
  without excluding the entity because it is soft-deleted. For acceptance,
  lock the chosen entity, write any missing identifiers, then recalculate its
  count transactionally. Do not alter counts on unrelated or inactive
  entities. A separate audited repair process is needed for pre-existing
  mismatches; do not silently backfill them.
- Review screens and exports should exclude soft-deleted entities from normal
  active lists and exports. Provide a distinct historical/deleted view only
  if product authorization and UX are approved. Candidate review must show an
  explicit inactive-entity conflict rather than offering automatic reuse.
  These UI/query changes are required before claiming consistent end-to-end
  behavior; current list, confirmation, and export paths include deleted
  entities.

## 4. Schema and migration sequence

This section is a proposed end state, not executable migration SQL. Names are
suggested stable names for review.

### 4.1 Tenant-safe keys and relationships

Create unique parent keys, required for PostgreSQL composite foreign keys:

- `reconciliation_source_records(company_id, id)`
- `reconciliation_entities(company_id, id)`
- `reconciliation_match_candidates(company_id, id)`

Existing primary keys on `id` remain. These additional unique keys are
redundant for uniqueness but necessary as referenced composite keys.

Create a non-partial unique index:

- `reconciliation_identifiers_one_entity_per_source_uidx` on
  `(company_id, source_record_id)`.

It includes links to soft-deleted entities. The Stage 1A local preflight found
no duplicate source-to-entity links, but the exact hosted target must be
preflighted. Never repair conflicts automatically.

Add composite foreign keys, initially `NOT VALID`, then validate after clean
preflight:

- Identifier `(company_id, entity_id)` to entity `(company_id, id)`.
- Identifier `(company_id, source_record_id)` to source record
  `(company_id, id)`.
- Candidate `(company_id, record_a_id)` and `(company_id, record_b_id)` to
  source record `(company_id, id)`.
- Candidate `(company_id, entity_id)` to entity `(company_id, id)`.
- Typed decision `(company_id, candidate_id)` to candidate `(company_id, id)`.
- Typed decision `(company_id, result_entity_id)` to entity `(company_id,id)`.

Retain the existing simple foreign keys until the composite replacements are
validated; then remove redundant simple constraints in a later transactional
step. Use `ON DELETE RESTRICT` for provenance and typed-decision references.
Do not use a composite `SET NULL` action that can null `company_id`.

### 4.2 Typed reviewer decisions and idempotency

Add nullable columns to `reconciliation_reviewer_decisions`:

- `candidate_id uuid NULL` — typed candidate target for new match decisions.
- `result_entity_id uuid NULL` — entity established by acceptance; NULL for
  rejection and for legacy non-match rows.
- `idempotency_key uuid NULL` — opaque caller-generated key for new RPC
  decisions; NULL for historical decisions.

Keep `decision_target_table`, `decision_target_id`, `decision`,
`previous_state`, and `new_state` for compatibility and history. For new
typed rows, store `decision_target_table =
'reconciliation_match_candidates'` and `decision_target_id = candidate_id::text`.
Add checks (nullable-compatible with legacy rows) requiring:

- `candidate_id` is present only for `accept_match` or `reject_match`;
- a non-NULL idempotency key requires a non-NULL candidate;
- a typed accept has a result entity and a typed reject has no result entity;
- typed target table/id agree with `candidate_id`.

Add unique partial indexes:

- `(company_id, candidate_id)` where `candidate_id IS NOT NULL`, allowing at
  most one typed terminal reviewer decision per candidate;
- `(company_id, reviewer_id, idempotency_key)` where
  `idempotency_key IS NOT NULL`.

Do not backfill these columns from candidate status, audit rows, or generic
legacy target strings. Historical decisions remain nullable and unchanged.
Replace the reviewer FK's contradictory `ON DELETE SET NULL` behavior with
`ON DELETE RESTRICT` so reviewer attribution remains intact; this intentionally
blocks account deletion until a separately approved erasure/retention policy
exists.

### 4.3 Candidate pair uniqueness

The existing unique index only prevents duplicate same-direction pending
pairs. Add a preflight for duplicate/reversed pending pairs, then consider a
partial unique expression index over
`(company_id, LEAST(record_a_id, record_b_id), GREATEST(record_a_id, record_b_id))`
for `status = 'pending'`. Update the matching worker's candidate insertion to
normalize source order and use conflict handling compatible with that index.
Keep its lease validation and worker grants unchanged. This index prevents
simultaneous duplicate/reversed pending candidates, not a future re-run after
a pair reaches a terminal state.

### 4.4 Function owner, RLS, and grants

Provision a dedicated `reconciliation_workflow_executor` role:

- `NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS`;
- no memberships for login/client/worker roles, no schema CREATE, and no
  ownership of tables or types;
- own only the two workflow RPCs;
- receive only the table/column grants and role-targeted RLS policies listed
  in the privilege matrix below.

If the hosted migration principal cannot safely create/alter a role, platform
administrators must provision and verify the role before the migration.
Do not grant BYPASSRLS or make the executor a table owner. Because affected
tables use `FORCE ROW LEVEL SECURITY`, add internal policies targeted only to
the unloginable executor role. Policies must be limited to needed operations;
tenant and relationship validation remains mandatory in the RPC code.

Both functions must:

- be `SECURITY DEFINER`, owned by
  `reconciliation_workflow_executor`, and use `SET search_path = ''`;
- fully qualify all relation, type, and helper names;
- revoke EXECUTE from `PUBLIC`, `anon`, `service_role`, both workers, and
  scheduler; grant EXECUTE only to `authenticated`;
- have no dynamic SQL and expose no raw/normalized source payloads.

The executor needs `USAGE` on `public` and required enum types; narrowly scoped
SELECT/INSERT/UPDATE privileges on the tables below; EXECUTE on
`has_role_in`/`log_reconciliation_audit` and any required UUID generator; and
SELECT access to only the actor's current `memberships` row for a row lock.
Grant no direct audit-table DML to the executor; use the existing
`SECURITY DEFINER` audit wrapper. Add executor-only RLS policies for these
privileges. Do not grant the executor to any login role.

### 4.5 Index and transaction constraints

Stage 1B inspected Supabase CLI v2.119.0 source: it flushes regular SQL
batches around `CREATE [UNIQUE] INDEX CONCURRENTLY`, executes the concurrent
statement outside those batches, then records migration history in a later
batch. Thus concurrent indexes are supported by that version but a migration
containing them is **not atomic across the flush boundaries**. Do not assume a
failed migration rolls back its index or earlier statements.

Recommended order:

1. Reconcile version 06 provenance and confirm the exact migration runner
   version on each deployment environment.
2. Run all seven Stage 1A checks, plus duplicate/reversed pending-pair checks,
   against the exact target. Stop on any violation; obtain reviewed remediation
   rather than auto-fixing.
3. Build each required large unique index in a standalone migration file
   containing only its `CREATE UNIQUE INDEX CONCURRENTLY` statement. This
   includes parent `(company_id,id)` keys, one-source uniqueness, typed
   decision/idempotency indexes, and the optional normalized pending-pair
   index. No surrounding statements should rely on all-or-nothing behavior.
4. After each build, verify `pg_index.indisvalid`, index definition, and
   migration history. If interrupted, inspect before retrying; remove only a
   specifically identified invalid index using an approved non-transactional
   recovery step.
5. In ordinary transactional migrations, add nullable decision columns,
   checks and composite FKs `NOT VALID`; validate FKs in a later step after
   scans. PostgreSQL permits `NOT VALID` for foreign keys/check constraints,
   not unique constraints.
6. Retain the old simple FKs and pending-pair index until replacement
   composite constraints/indexes are validated; then drop redundant old
   constraints/indexes transactionally.
7. Deploy/verify the executor role, internal RLS policies, functions and
   function grants. In one reviewed cutover, revoke direct authenticated DML
   and switch application calls to RPCs. Do not expose a window where the UI
   assumes atomicity while direct multi-request writes remain available.

## 5. RPC contracts

Both calls are single PostgreSQL transactions under the caller's transaction.
The proposed signature is:

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

There is deliberately no caller-supplied tenant ID, reviewer ID, action, or
target entity ID. `auth.uid()` is the only reviewer identity source; never use
user metadata, request metadata, or frontend authorization as proof.

### 5.1 Shared authorization, locks, and idempotency

1. Reject a NULL authenticated identity or malformed/missing candidate/key
   with an authorization/argument SQLSTATE. Do not return a success-shaped
   fallback.
2. Lock the candidate by ID `FOR UPDATE`. Derive `company_id`, status, source
   IDs, and optional `entity_id` from that locked row. A missing candidate is
   indistinguishable from an unauthorized target to prevent cross-tenant
   discovery.
3. Lock the matching `public.memberships` row for
   `(company_id, auth.uid()) FOR SHARE`; require current role `owner` or
   `admin`. This serializes the decision against concurrent membership-role
   changes/removal. Do not trust app metadata. An unauthorized caller receives
   SQLSTATE `42501`.
4. Acquire a transaction-scoped advisory lock over the stable
   `(company_id, reviewer_id, idempotency_key)` tuple before querying the
   idempotency index. Hash collisions may only serialize unrelated requests;
   the unique index remains authoritative.
5. If the key already exists for the same company/reviewer/candidate/action,
   return the persisted decision outcome with `replayed: true`, without new
   writes or audit rows. If it is bound to another candidate or action, return
   `idempotency_key_conflict`, with no writes.
6. If the candidate is not pending and no matching idempotency replay exists,
   return `candidate_already_decided`. Do not synthesize a legacy reviewer
   decision or reinterpret an earlier decision.
7. Lock both source rows in ascending UUID order using `FOR UPDATE`. Confirm
   that both exist and have the candidate's tenant. A missing/cross-tenant row
   is an explicit `candidate_integrity_conflict`; composite FKs are the final
   integrity backstop.
8. Keep the candidate lock before the ordered source locks for both RPCs.
   The common lock order makes same-candidate requests serialize and reduces
   deadlocks for different candidates sharing a source.
9. Insert reviewer-decision and audit rows only for a successful final
   decision. Expected domain conflicts perform no candidate/entity/link/
   decision/audit mutation. Unexpected SQL errors are not swallowed.

Conflict results use a stable shape such as:

```json
{"status":"conflict","code":"entity_conflict","candidate_id":"..."}
```

Success results include `status`, `candidate_id`, `decision_id`,
`entity_id` (NULL for rejection), and `replayed`. Authorization and unexpected
database errors raise errors; callers must not treat them as conflicts or
success.

### 5.2 Accept behavior

After shared authorization and locks:

1. Read all identifier links for both source IDs and the optional
   `candidate.entity_id`; join entities and verify tenant IDs.
2. If the source records or candidate target imply more than one entity,
   return `entity_conflict`; never merge or overwrite entities.
3. If the one target entity has `deleted_at IS NOT NULL`, return
   `inactive_entity_conflict`. Do not clear deletion, unlink, or create a new
   entity.
4. If exactly one active target exists, lock it `FOR UPDATE`; otherwise create
   an entity with the neutral/empty values in §3.1.
5. Insert missing identifier links for the two records with the same target
   and tenant. Existing links to that same entity are preserved. The unique
   `(company_id, source_record_id)` index is the final no-double-link guard.
   If a uniqueness or unexpected FK violation remains, let it abort the
   function statement; no partial entity, link, decision, or audit survives.
6. Recalculate the selected entity's `record_count` from all its identifier
   rows after insertion, while holding the entity row lock. Do not update
   canonical data, survivorship rule, entity status, or unrelated entity
   counts.
7. Set candidate status to `accepted`, `reviewer_id = auth.uid()`,
   `reviewed_at = now()`, and `entity_id` to the selected entity.
8. Insert one typed `accept_match` reviewer decision with candidate,
   idempotency key, result entity, rationale, and ID/status-only previous/new
   state. Do not store raw/normalized source values.
9. Insert `match.accepted` through the audit wrapper in the same transaction.
   Audit metadata should contain IDs and outcome only, not PII/source values.
10. Return accepted result. Any audit insert failure, constraint failure, or
    unexpected error aborts the statement and rolls back every preceding
    write, including the entity and links.

If two source records are already linked to different entities, step 2 returns
an explicit conflict before any write. The entities and their canonical data
remain unchanged. A future entity-merge process must separately define
authorization, review, provenance, audit, and recovery.

### 5.3 Reject behavior

After shared authorization and locks:

1. Do not create an entity or inspect/overwrite canonical values. Source locks
   serialize the outcome against acceptance attempts on either record.
2. Set candidate status to `rejected`, `reviewer_id = auth.uid()`, and
   `reviewed_at = now()`. Do not change `entity_id` or any identifier links.
3. Insert one typed `reject_match` reviewer decision with the candidate,
   idempotency key, rationale, and ID/status-only state.
4. Insert `match.rejected` through the audit wrapper in the same transaction.
5. Return rejected result with `entity_id: null`. Any database/audit error
   aborts and rolls back the candidate status, decision, and audit together.

The same-key retry returns the saved rejection. A new key for an already
decided candidate returns `candidate_already_decided`, not a second decision.

### 5.4 Concurrency and failure contract

| Situation | Required outcome |
|---|---|
| Same candidate, accept/accept, same key | Candidate row serializes callers; one commit, the other returns the saved outcome as replay. |
| Same candidate, accept/accept, different keys | One commit; the other returns `candidate_already_decided`; no second decision. |
| Same candidate, accept/reject | Candidate row serializes callers; one terminal decision commits; the other returns `candidate_already_decided`. |
| Different candidates share a source | Source rows lock in deterministic order. Both may succeed only if relationships remain consistent with the same entity; a conflicting entity target returns `entity_conflict`. No source receives two entity links. |
| Same key used concurrently for different candidates/actions | Advisory lock serializes the key; first successful binding wins; the other returns `idempotency_key_conflict` without writes. |
| Existing sources linked to different entities | Accept returns `entity_conflict`; no merge, decision, entity update, or success audit. |
| Existing source linked to deleted entity | Accept returns `inactive_entity_conflict`; existing relationship remains intact. |
| Unique-index/FK violation | Unexpected violation aborts the RPC statement and transaction; do not broadly catch or convert all SQL errors. |
| Audit insert failure | Exception aborts the statement; all decision-side writes roll back. |
| Caller transaction rollback after RPC success | Candidate, entity/link, decision, and audit writes all roll back together. |

An application retry after a network timeout must reuse the same UUID
idempotency key. A new key is a new request and must not be treated as a retry.

## 6. Proposed privilege matrix

The matrix is for the sensitive review tables:
`reconciliation_match_candidates`, `reconciliation_entities`,
`reconciliation_identifiers`, `reconciliation_reviewer_decisions`,
`reconciliation_source_records`, and `audit_log`. It is a target proposal;
current local ACLs are broader. Inventory all application and operational
callers before changing grants.

| Role | SELECT | INSERT | UPDATE | DELETE | EXECUTE / other |
|---|---|---|---|---|---|
| `authenticated` | Keep member-scoped RLS reads for review/source/entity data; audit reads remain admin+ under existing RLS. | None on the six tables. | None on the six tables. | None on the six tables. | Only `accept_reconciliation_match` and `reject_reconciliation_match`, each enforcing current owner/admin membership internally. Existing narrowly scoped helpers remain only as currently required. |
| `anon` | None on the six tables. | None. | None. | None. | No accept/reject or worker/scheduler RPCs. Revoke PUBLIC function execution explicitly. |
| `service_role` | Preserve only existing reads needed by inventoried backend paths; it is a trusted platform role with `BYPASSRLS`. | None on review tables, source records, or audit. | None on review tables, source records, or audit. | None on review tables, source records, or audit. | No new accept/reject grant. Preserve only explicitly inventoried existing RPC grants; do not use service role as a human-review authorization shortcut. |
| `reconciliation_import_worker` | No direct table SELECT. | None. | None. | None. | Preserve EXECUTE only on existing import claim/insert/heartbeat/finish RPCs, including verified lease checks; no workflow RPCs. |
| `reconciliation_matching_worker` | No direct table SELECT. | None. | None. | None. | Preserve EXECUTE only on existing matching claim/read/heartbeat/candidate-write/finish RPCs; no workflow RPCs. |
| `reconciliation_scheduler` | No direct table SELECT. | None. | None. | None. | `NOLOGIN`; preserve only EXECUTE on `reconciliation_audit_retention_cleanup()`. |
| `reconciliation_workflow_executor` | Narrow SELECT for memberships, candidates, sources, entities, identifiers, and reviewer decisions. | Narrow INSERT for new entities, identifiers, and typed reviewer decisions. | Column-scoped UPDATE only for candidate status/reviewer/time/entity and entity `record_count`. | None. | `NOLOGIN`, no memberships, `NOBYPASSRLS`; owns only the two `SECURITY DEFINER` RPCs. EXECUTE only on required membership/audit/UUID helpers. No direct audit DML. |

Additional constraints:

- Keep `audit_log` direct INSERT/UPDATE/DELETE revoked, including for the
  executor and service role; `log_reconciliation_audit` performs the append
  through its own protected definer boundary.
- The executor's SELECT/INSERT/UPDATE is accompanied by RLS policies targeted
  only to that non-login role. Do not add a permissive policy for
  `authenticated` or `service_role`.
- Revoke authenticated DML and remove corresponding member-level DML policies
  on candidate, entity, identifier, decision, and source tables. Direct source
  insert is also removed so source ingestion remains behind the import worker
  RPC. Preserve authenticated SELECT policies.
- This necessarily blocks current direct entity confirmation/update workflows.
  Before cutover, route any still-supported entity confirmation/status changes
  through separately authorized narrow RPCs; the match RPCs must not become a
  general entity-update endpoint.
- Preserve RLS enabled/forced status. Workers remain `NOLOGIN` only for
  scheduler, `LOGIN` only for the two existing worker accounts, all
  non-superuser, `NOINHERIT`, `NOBYPASSRLS`, no direct table privileges, and
  no role memberships.
- Local `service_role` has `BYPASSRLS` and broad ACLs. Its proposed DML
  revocation is a deliberate security tightening and requires caller
  inventory plus staging verification; hosted state is unknown.

## 7. Database and integration test plan

All tests use synthetic tenants/records. No production PII. SQL unit tests
should follow the repository's existing Supabase test conventions.

### 7.1 Local automated database tests

1. **Owner acceptance:** valid owner identity/membership accepts a pending
   same-tenant candidate; exactly two links exist; new entity has empty
   canonical data and `manual_review_required`; candidate, typed decision,
   count, and one audit event commit.
2. **Administrator acceptance:** same checks for a current admin.
3. **Ordinary-member rejection attempt:** member is denied both accept and
   reject with authorization error; candidate, entity, identifiers, reviewer
   decisions, and audit remain unchanged. The phrase “member rejection” is a
   denial test, not permission for members to reject.
4. **Cross-tenant denial:** missing or foreign candidate/source/entity IDs
   cannot reveal whether another tenant's candidate exists or mutate any row.
5. **Current-membership check:** role downgrade/removal before the RPC denies;
   a concurrent role change serializes against the membership row lock.
6. **Direct DML denial:** authenticated cannot insert/update/delete candidates,
   insert entities or identifiers, insert decisions, or insert/update/delete
   source rows. SELECT remains tenant-filtered. Audit table writes fail.
7. **Worker preservation:** assert role attributes/memberships, no direct
   affected-table privileges, and exact EXECUTE grants for all existing import,
   matching, and scheduler RPCs. Verify lease and tenant checks remain.
8. **Duplicate acceptance:** same key/same action returns replay without
   duplicate decision, links, entity, count change, or audit row. Different
   key for a terminal candidate returns conflict.
9. **Idempotency-key reuse:** same reviewer/tenant/key with a different
   candidate or opposite action returns `idempotency_key_conflict`; no writes
   on the second request.
10. **Entity conflicts:** two source links to different entities returns
    `entity_conflict`; assert neither entity's canonical data/status/count
    changes, no links move, and no decision is fabricated.
11. **Soft-deleted target:** accepting a candidate whose source or candidate
    target points to a deleted entity returns `inactive_entity_conflict`;
    links remain and no replacement entity is created.
12. **Rejection:** no entity or identifier is created; one terminal candidate
    status, typed reject decision, and one `match.rejected` audit event commit.
13. **Source immutability:** updates and deletes to source records fail for
    authenticated, service, and worker-facing access paths; imports can only
    insert through the existing guarded RPC.
14. **Historical decisions:** seed legacy candidates/decision rows without
    `candidate_id`; migration leaves their fields and status untouched and
    does not fabricate typed decisions.
15. **Tenant constraints:** deliberately attempt mismatched identifier,
    candidate, and reviewer-decision parents; composite FKs reject each case.
16. **Record count:** accepted links recalculate from the identifier table;
    existing entity canonical fields remain byte-for-byte unchanged; soft
    deletion does not change the count.
17. **Audit hygiene/atomicity:** assert accepted/rejected audit actor and
    tenant match the decision, metadata contains IDs/outcome only, and no raw
    source values. In an isolated test database, inject an audit insert
    failure with a test-only trigger, call the RPC, and assert candidate,
    entity, links, decision, and audit are all rolled back.
18. **Function security:** inspect `proowner`, `prosecdef`, `proconfig`,
    `proacl`, role attributes, RLS enabled/forced status, policies, and
    `has_table_privilege`/`has_function_privilege`. Verify only authenticated
    can execute the wrappers and only the unloginable executor accesses rows
    under its internal policies.
19. **Duplicate/reversed candidate generation:** ensure the matching worker
    emits normalized pairs and the pending-pair unique index prevents both
    orderings from creating two pending rows.
20. **Preflight regression:** rerun all seven Stage 1A checks and the
    duplicate/reversed pending-pair query; preserve query 4's PostgreSQL 15
    compatible `bool_or` form, not `min(uuid)`.

### 7.2 Separate-session staging concurrency tests

Use two or more independent authenticated database sessions with explicit
barriers; test result rows and final database state, not timing assumptions:

- accept/accept, same key: one commit, one replay result, one decision and
  audit;
- accept/accept, different keys: one commit, one already-decided conflict;
- accept/reject on the same candidate: exactly one final status/decision;
- two pending candidates sharing one source: verify source locks serialize;
  compatible same-entity relationships may both succeed, but the source has
  exactly one entity link; incompatible entity targets cause explicit
  conflict;
- same idempotency key concurrently on different candidates/actions: one key
  binding only and no side effects on the losing request;
- concurrent membership downgrade/removal: determine ordering by the
  membership row lock and verify a reviewer lacking current owner/admin role
  cannot commit;
- hold audit insertion/failure in one session and verify no partial rows
  become visible to the other session.

### 7.3 Staging integration and production verification

**Staging:** repeat hosted-style catalog and all seven data checks against a
staging project with known identity. Run the application review flow using
user-session JWTs (not service role); verify UI handles explicit conflicts,
idempotent network retries, deleted entities, and terminal candidates.
Verify entity lists/exports exclude deleted entities and remaining entity
confirmation paths use their own narrow RPC. Verify worker connection roles,
leases, RPC privileges, audit consistency, migration state, and rollback
runbook. Run a restore rehearsal from a pre-change backup.

**Production, read-only before approval:** verify project identity, PostgreSQL
version, migration history, role/grant/policy/function state, worker boundary,
soft-delete behavior, and all preflight results. After a separately approved
deployment, verify migration status, index validity, function owner/config/
ACL, RLS and direct DML denials, worker RPC grants, audit events, count/link
invariants, and application health. Do not run destructive fault-injection
tests in production.

## 8. Hosted environment dependency

Hosted state is **not verified**. To inspect safely, the project owner must
provide/confirm:

1. Exact Supabase project reference and owning organization/environment
   (production versus staging), confirmed out of band.
2. Explicit authorization for read-only inspection of that project.
3. An approved read-only SQL access route or an already-linked, authenticated
   CLI session with project identity independently confirmed.
4. A read-only DB identity with catalog visibility and SELECT access to the
   migration-history and relevant reconciliation data; no DDL, DML, role, or
   grant privileges are required for preflight.

Do not guess a project, request credentials in chat, print tokens/passwords,
or run `supabase link` as part of this blueprint. Until hosted inspection is
complete, hosted migration parity, data cleanliness, direct authenticated
DML, RLS, worker grants, function ownership/security, and soft-delete/count
semantics cannot be approved.

## 9. Deployment and rollback

### 9.1 Deployment gates and order

1. **Resolve migration 06** with its owner; preserve immutable migration
   history and document recovered-versus-original evidence.
2. **Identify and inspect hosted target** read-only; run seven checks and
   additional pending-pair check. Any finding blocks index/constraint
   enforcement until reviewed.
3. **Inventory callers** of direct candidate/entity/identifier/decision/source
   DML, service-role routes, exports, entity confirmation, and imports.
   Prepare application changes for RPC-only acceptance/rejection and any
   entity status paths affected by revoked DML.
4. **Back up and rehearse** against a production-like staging database.
   Record index definitions/validity, migration versions, grants, RLS, and
   function signatures before deployment.
5. **Build concurrent indexes** in isolated steps and verify each index before
   continuing. If a standalone statement succeeds but the migration history
   batch fails, stop and inspect; do not blindly rerun.
6. **Install schema constraints** in ordered transactional migrations:
   decision columns/checks, composite FKs `NOT VALID`, later validation, and
   removal of superseded simple FKs only after validation.
7. **Install executor role/policies/functions** and verify ownership, empty
   search path, RLS, execute ACLs, and internal role non-membership.
8. **Cut over atomically:** disable review UI/actions; deploy RPC callers;
   revoke direct DML/remove permissive policies and enable RPC grants in the
   approved cutover; verify direct DML denial and worker access; then re-enable
   review actions.
9. **Run post-deployment checks** and monitor acceptance/rejection, conflicts,
   audit, source-link uniqueness, and count consistency. Keep encryption
   changes entirely out of scope.

### 9.2 Rollback and recovery

- Before cutover, if an index build fails, inspect `pg_index.indisvalid`,
  definitions, duplicate data, and migration history. Remove/rebuild only the
  specific failed index with an approved non-transactional operation. Do not
  use broad reset or migration repair commands.
- A concurrent index can remain while the later migration-history batch is
  absent. Stop, compare actual schema and history, and have the database owner
  approve a targeted recovery. Do not rerun without proving the statement is
  safe for current state.
- If an ordinary transactional migration fails, PostgreSQL rolls back that
  transaction; verify runner boundaries rather than assuming all migrations
  (especially one containing concurrent indexes) are atomic.
- After RPC cutover, prefer a forward fix. Do not restore broad authenticated
  DML as a rollback shortcut. If review is unsafe, leave review actions
  disabled while preserving reads and worker RPCs.
- Do not delete reviewer decisions, audit events, identifiers, or historical
  candidates as rollback. Do not reverse accepted relationships automatically.
  Correcting a committed decision requires a separately approved,
  authorized, audited resolution workflow.
- Restore a verified predeployment backup only under the incident/recovery
  plan after impact review; account for writes accepted after the snapshot.

## 10. Outstanding decisions and risks

1. **Migration 06 provenance:** owner confirmation and hosted parity remain
   unavailable.
2. **Hosted project identity/access:** exact project reference and authorized
   read-only route are required.
3. **Role provisioning:** confirm whether the hosted migration role can
   provision the dedicated non-login executor safely; otherwise arrange
   platform-admin provisioning.
4. **Account erasure:** `ON DELETE RESTRICT` preserves reviewer attribution,
   but legal/account-erasure requirements need an approved retention or
   pseudonymization policy before rollout.
5. **Entity physical deletion and tenant cascade:** adopt the proposed
   provenance-preserving restriction, or define a separate audited lifecycle
   model. Do not assume current cascades are acceptable.
6. **Inactive entity UX:** approve whether deleted entities are hidden from
   normal exports and what historical access is authorized.
7. **Non-match entity status actions:** direct entity DML revocation affects
   current confirmation/update paths; replacement RPC scope and rollout must
   be agreed.
8. **Executor RLS policies/grants:** verify exact managed-Postgres behavior
   with `FORCE ROW LEVEL SECURITY`, `SECURITY DEFINER`, membership row locking,
   and privilege inspection in staging.
9. **Migration recovery and non-atomic index boundaries:** rehearse invalid
   index/history mismatch recovery using the deployed CLI version.
10. **No silent data remediation:** any hosted preflight violations require
    human-reviewed correction/waiver before unique indexes or FK validation.

## 11. GO/NO-GO checklist

Implementation remains **NO-GO** until all are true:

- [ ] Database owner resolves version 06 provenance; repository/history plan is
  approved and local migration list is consistent.
- [ ] Exact intended hosted project is confirmed and all hosted checks are
  read-only completed.
- [ ] Seven integrity checks and duplicate/reversed pending-pair check are
  clean, or each finding has an explicitly approved remediation.
- [ ] Current DML callers and service-role use are inventoried; required
  entity/status UX is migrated before direct DML is revoked.
- [ ] Product confirms inactive-entity behavior, physical-delete behavior, and
  account-erasure/reviewer attribution policy.
- [ ] Executor role provisioning, RLS policies, function ownership, search
  path, grants, and least privilege pass staging inspection.
- [ ] Local automated tests, separate-session concurrency tests, staging
  integration, audit-failure rollback, and restore rehearsal pass.
- [ ] Deployment/rollback runbooks account for the actual CLI version's
  non-atomic concurrent-index statements.
- [ ] Production receives a separate explicit implementation/deployment
  approval.

**Final recommendation: NO-GO.** Local integrity checks are clean, but hosted
state, migration provenance, authenticated DML cutover, and several lifecycle
policies remain unresolved. This blueprint does not authorize implementation
or migration execution.
