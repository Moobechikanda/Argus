# ZamBase Phase 2A.3.4 — Stage 1A Preflight Report

> **Read-only assessment.** Queries in this report were SELECT-only. No schema,
> data, role, policy, or configuration changes were made. Results describe the
> local development database only; they do not establish hosted-project state.
> Inspection timestamp: 2026-11-02, local environment.

## 1. Execution environment

- Local Supabase Docker project: `supabase-multitenant-starter`.
- Local database container: `supabase_db_supabase-multitenant-starter`,
  reported healthy.
- PostgreSQL: `15.19` (`x86_64-pc-linux-gnu`).
- Supabase CLI: `2.119.0`.
- Local DB endpoint configured in `supabase/config.toml`: port `54322`;
  database and server were queried from inside the existing database container.
- `psql` was not installed on the Windows host. The existing container's
  `psql` client was used. No service was started or reconfigured.
- `supabase migration list --local` compared repository migration files with
  the local database migration history. It showed database-history version
  `20261101000006` with no corresponding local migration file. Repository
  migration files contain `20261101000005` followed by
  `20261101000007`. This is a local migration-history discrepancy and must be
  investigated before a new migration is pushed.
- No production/hosted Supabase endpoint was queried. Hosted PostgreSQL
  version, data, grants, policies, and migration history remain **NOT
  VERIFIED**.

## 2. Preflight execution results

Local row counts at inspection time:

| Table | Rows |
|---|---:|
| `reconciliation_source_records` | 5 |
| `reconciliation_entities` | 1 |
| `reconciliation_identifiers` | 2 |
| `reconciliation_match_candidates` | 1 |
| `reconciliation_reviewer_decisions` | 0 |
| `audit_log` | 225 |

The one candidate was `pending`; no terminal candidates or reviewer-decision
rows were present. Its IDs are omitted because no preflight finding implicated
it. The sole entity had two identifier links and `record_count = 2`.

### Query 1 — source records linked to multiple entities

```sql
SELECT
    i.company_id,
    i.source_record_id,
    count(DISTINCT i.entity_id) AS entity_count,
    array_agg(DISTINCT i.entity_id ORDER BY i.entity_id) AS entity_ids
FROM public.reconciliation_identifiers AS i
GROUP BY i.company_id, i.source_record_id
HAVING count(DISTINCT i.entity_id) > 1
ORDER BY i.company_id, i.source_record_id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** no local source record currently has multiple entity links.
**Migration impact:** does not block the local unique-index precondition.
Hosted data still requires this check.

### Query 2 — identifier parent/tenant mismatches

```sql
SELECT
    i.company_id AS identifier_company_id,
    i.entity_id,
    e.company_id AS entity_company_id,
    i.source_record_id,
    s.company_id AS source_company_id
FROM public.reconciliation_identifiers AS i
LEFT JOIN public.reconciliation_entities AS e ON e.id = i.entity_id
LEFT JOIN public.reconciliation_source_records AS s ON s.id = i.source_record_id
WHERE e.id IS NULL
   OR s.id IS NULL
   OR e.company_id IS DISTINCT FROM i.company_id
   OR s.company_id IS DISTINCT FROM i.company_id
ORDER BY i.company_id, i.entity_id, i.source_record_id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** no local missing identifier parent or tenant mismatch was
found. **Migration impact:** does not block local composite-FK validation.

### Query 3 — candidate source/entity tenant mismatches

```sql
SELECT
    c.id AS candidate_id,
    c.company_id AS candidate_company_id,
    c.record_a_id,
    a.company_id AS record_a_company_id,
    c.record_b_id,
    b.company_id AS record_b_company_id,
    c.entity_id,
    e.company_id AS entity_company_id,
    c.status
FROM public.reconciliation_match_candidates AS c
LEFT JOIN public.reconciliation_source_records AS a ON a.id = c.record_a_id
LEFT JOIN public.reconciliation_source_records AS b ON b.id = c.record_b_id
LEFT JOIN public.reconciliation_entities AS e ON e.id = c.entity_id
WHERE a.id IS NULL
   OR b.id IS NULL
   OR a.company_id IS DISTINCT FROM c.company_id
   OR b.company_id IS DISTINCT FROM c.company_id
   OR (c.entity_id IS NOT NULL AND (
       e.id IS NULL OR e.company_id IS DISTINCT FROM c.company_id
   ))
ORDER BY c.company_id, c.id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** no local candidate with missing/cross-tenant parents was
found. **Migration impact:** does not block local composite-FK validation.

### Query 4 — pending candidates with conflicting source/entity links

The exact query in the prior specification used `min(uuid)`. PostgreSQL
15.19 rejected it with `function min(uuid) does not exist`; it returned no
result and is not an executable preflight query. I reran the same conflict
conditions with `bool_or(a.entity_id <> b.entity_id)` instead:

```sql
WITH source_links AS (
    SELECT DISTINCT company_id, source_record_id, entity_id
    FROM public.reconciliation_identifiers
)
SELECT
    c.id AS candidate_id,
    c.company_id,
    c.record_a_id,
    array_agg(DISTINCT a.entity_id ORDER BY a.entity_id)
        FILTER (WHERE a.entity_id IS NOT NULL) AS record_a_entities,
    c.record_b_id,
    array_agg(DISTINCT b.entity_id ORDER BY b.entity_id)
        FILTER (WHERE b.entity_id IS NOT NULL) AS record_b_entities,
    c.entity_id AS candidate_entity_id
FROM public.reconciliation_match_candidates AS c
LEFT JOIN source_links AS a
    ON a.company_id = c.company_id
   AND a.source_record_id = c.record_a_id
LEFT JOIN source_links AS b
    ON b.company_id = c.company_id
   AND b.source_record_id = c.record_b_id
WHERE c.status = 'pending'
GROUP BY c.id, c.company_id, c.record_a_id, c.record_b_id, c.entity_id
HAVING count(DISTINCT a.entity_id)
           FILTER (WHERE a.entity_id IS NOT NULL) > 1
    OR count(DISTINCT b.entity_id)
           FILTER (WHERE b.entity_id IS NOT NULL) > 1
    OR bool_or(a.entity_id <> b.entity_id)
           FILTER (WHERE a.entity_id IS NOT NULL AND b.entity_id IS NOT NULL)
    OR bool_or(a.entity_id <> c.entity_id)
           FILTER (WHERE a.entity_id IS NOT NULL AND c.entity_id IS NOT NULL)
    OR bool_or(b.entity_id <> c.entity_id)
           FILTER (WHERE b.entity_id IS NOT NULL AND c.entity_id IS NOT NULL)
ORDER BY c.company_id, c.id;
```

**Result:** 0 rows. **Clean:** yes, using the corrected executable query.
**Affected IDs:** none. **Significance:** the local pending candidate does not
have conflicting source or candidate entity links.
**Migration impact:** no local data blocker. Fix the preflight SQL in any
future operational runbook; do not deploy the `min(uuid)` variant.

### Query 5 — candidate state versus reviewer-decision history

```sql
WITH decision_history AS (
    SELECT
        d.company_id,
        d.decision_target_id,
        count(*) AS decision_count,
        count(*) FILTER (WHERE d.decision = 'accept_match') AS accept_count,
        count(*) FILTER (WHERE d.decision = 'reject_match') AS reject_count,
        array_agg(d.id ORDER BY d.reviewed_at, d.id) AS decision_ids
    FROM public.reconciliation_reviewer_decisions AS d
    WHERE d.decision_target_table = 'reconciliation_match_candidates'
      AND d.decision IN ('accept_match', 'reject_match')
    GROUP BY d.company_id, d.decision_target_id
),
candidate_history AS (
    SELECT
        c.id AS candidate_id,
        c.company_id,
        c.status,
        c.reviewer_id,
        c.reviewed_at,
        COALESCE(h.decision_count, 0) AS decision_count,
        COALESCE(h.accept_count, 0) AS accept_count,
        COALESCE(h.reject_count, 0) AS reject_count,
        h.decision_ids,
        CASE
            WHEN c.status = 'accepted'
                THEN COALESCE(h.accept_count, 0) = 1
                     AND COALESCE(h.reject_count, 0) = 0
            WHEN c.status = 'rejected'
                THEN COALESCE(h.reject_count, 0) = 1
                     AND COALESCE(h.accept_count, 0) = 0
            WHEN c.status IN ('pending', 'escalated')
                THEN COALESCE(h.decision_count, 0) = 0
            ELSE false
        END AS history_is_consistent
    FROM public.reconciliation_match_candidates AS c
    LEFT JOIN decision_history AS h
        ON h.company_id = c.company_id
       AND h.decision_target_id = c.id::text
)
SELECT
    candidate_id,
    company_id,
    status,
    reviewer_id,
    reviewed_at,
    decision_count,
    accept_count,
    reject_count,
    decision_ids,
    CASE
        WHEN status IN ('accepted', 'rejected') AND decision_count = 0
            THEN 'legacy_finalized_without_decision'
        WHEN NOT history_is_consistent
            THEN 'inconsistent_history'
        WHEN status IN ('accepted', 'rejected')
             AND (reviewer_id IS NULL OR reviewed_at IS NULL)
            THEN 'terminal_state_missing_reviewer_metadata'
    END AS finding
FROM candidate_history
WHERE (status IN ('accepted', 'rejected') AND decision_count = 0)
   OR NOT history_is_consistent
   OR (status IN ('accepted', 'rejected')
       AND (reviewer_id IS NULL OR reviewed_at IS NULL))
ORDER BY company_id, candidate_id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** no finalized candidate/history inconsistency was found. The
one local candidate is pending with no decision, which is consistent.
**Migration impact:** no local history blocker. Do not infer this applies to
hosted data; legacy finalized candidates, if found there, must remain
historical and must not be assigned fabricated decisions.

### Query 6 — duplicate, reversed, or self-pair candidates

```sql
SELECT
    c.company_id,
    LEAST(c.record_a_id, c.record_b_id) AS pair_low_id,
    GREATEST(c.record_a_id, c.record_b_id) AS pair_high_id,
    count(*) AS candidate_count,
    array_agg(c.id ORDER BY c.created_at, c.id) AS candidate_ids,
    array_agg(c.status::text ORDER BY c.created_at, c.id) AS statuses,
    bool_or(c.record_a_id = c.record_b_id) AS contains_self_pair
FROM public.reconciliation_match_candidates AS c
GROUP BY
    c.company_id,
    LEAST(c.record_a_id, c.record_b_id),
    GREATEST(c.record_a_id, c.record_b_id)
HAVING count(*) > 1
    OR bool_or(c.record_a_id = c.record_b_id)
ORDER BY c.company_id, pair_low_id, pair_high_id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** no local duplicate/reversed pair or self-pair was found.
**Migration impact:** does not block the local data preflight. The proposed
decision migration should not add an all-history unique pair constraint
without separate product approval.

### Query 7 — stored entity `record_count` versus identifier links

```sql
SELECT
    e.company_id,
    e.id AS entity_id,
    e.record_count AS stored_record_count,
    count(i.source_record_id)::integer AS linked_record_count,
    e.deleted_at
FROM public.reconciliation_entities AS e
LEFT JOIN public.reconciliation_identifiers AS i
    ON i.company_id = e.company_id
   AND i.entity_id = e.id
GROUP BY e.company_id, e.id, e.record_count, e.deleted_at
HAVING e.record_count IS DISTINCT FROM count(i.source_record_id)::integer
ORDER BY e.company_id, e.id;
```

**Result:** 0 rows. **Clean:** yes. **Affected IDs:** none.
**Significance:** the one local entity's stored count matches its two links.
**Migration impact:** no local count blocker. The query counts links regardless
of entity soft-delete state; the policy below keeps that behavior explicit.

### Consolidated preflight result

| Query | Returned rows | Clean? | Blocks local migration? |
|---|---:|---|---|
| 1. Source linked to multiple entities | 0 | Yes | No |
| 2. Identifier tenant mismatch | 0 | Yes | No |
| 3. Candidate tenant mismatch | 0 | Yes | No |
| 4. Pending candidate entity conflict | 0 with corrected query; original SQL errored | Yes after correction | No local data finding; fix the query before reuse |
| 5. Candidate/decision history | 0 | Yes | No |
| 6. Duplicate/reversed/self pairs | 0 | Yes | No |
| 7. Entity count mismatch | 0 | Yes | No |

These are local results only. The missing local migration-history file
`20261101000006` is a separate deployment blocker even though the row-level
preflight is clean.

## 3. Database security and privilege findings

### Tables, constraints, and indexes

All six affected tables have RLS enabled and forced in the local database.
Existing local constraints are simple ID foreign keys, not tenant-composite
keys:

- `reconciliation_identifiers` primary key is `(entity_id, source_record_id)`.
  There is no unique key on `(company_id, source_record_id)`, so the schema
  does not enforce one entity per source.
- Candidate rows reference source/entity IDs individually. Same-company
  relationships are not enforced by their FKs.
- Reviewer decisions have an ordinary primary key and indexes on
  `(company_id, reviewed_at)` and `(decision_target_table,
  decision_target_id)`. There is no typed candidate key or idempotency index.
- The candidate pair unique index is partial on `(record_a_id, record_b_id)`
  only while status is `pending`; it does not normalize reversed pairs.
- The entity company index is partial on `deleted_at IS NULL`; the status index
  is not partial. Identifier links have no soft-delete column or active flag.
- Reviewer FKs in candidates and reviewer decisions use `ON DELETE SET NULL`.
  The decision table's reviewer column is declared `NOT NULL` in the migration,
  making `SET NULL` incompatible with deletion of a referenced user.

The local source immutability trigger is enabled and rejects UPDATE/DELETE.
Its function is owned by `postgres`, is `SECURITY DEFINER`, and has an empty
search path.

### Role attributes and table ACLs

`has_table_privilege` reports relation-level ACLs; it does **not** evaluate RLS
policies. In local ACLs, `anon` and `authenticated` have broad table privileges
on the affected reconciliation tables, while RLS determines which operations
and rows are usable. The matching candidates, entities, identifiers, and
reviewer-decision policies currently permit member-level writes for their
configured commands. Audit table mutation privileges are revoked and there is
no authenticated audit INSERT policy. Hosted ACLs were not inspected.

| Role | Local observed attributes/access |
|---|---|
| `authenticated` | Not a login role; RLS policies apply to API requests. Relation ACLs include SELECT/INSERT/UPDATE/DELETE on affected reconciliation tables. Candidate writes are policy-permitted at member level; entity/identifier/decision policies are also broader than the UI admin/owner gate for their configured commands. |
| `anon` | Relation ACLs are broad locally, but no matching reconciliation RLS policies are defined for `anon`; do not treat table ACL alone as access. |
| `service_role` | `BYPASSRLS`; broad table ACLs. Not an acceptable workaround for workflow authorization. |
| `reconciliation_import_worker` | Login role, non-superuser, no create privileges, `NOINHERIT`, `NOBYPASSRLS`, no direct affected-table privileges, no role memberships. |
| `reconciliation_matching_worker` | Same least-privilege attributes as import worker; no direct affected-table privileges. |
| `reconciliation_scheduler` | No-login, non-superuser, `NOBYPASSRLS`, no direct affected-table privileges. |
| `postgres` | Local function/table owner context; not marked superuser in this container, but `BYPASSRLS` and privileged role memberships are present. |
| `reconciliation_workflow_executor` | Does not exist locally. |

### RLS policy summary

- `reconciliation_match_candidates`: authenticated SELECT for members;
  INSERT and UPDATE policies permit `member` or higher.
- `reconciliation_entities`: authenticated SELECT for members; INSERT at
  `member`, UPDATE at `admin`, DELETE at `owner`.
- `reconciliation_identifiers`: authenticated SELECT for members; INSERT at
  `member`; no UPDATE/DELETE policies.
- `reconciliation_reviewer_decisions`: authenticated SELECT for members and
  INSERT at `member` when `reviewer_id = auth_uid()`; no UPDATE/DELETE.
- `reconciliation_source_records`: authenticated SELECT for members and INSERT
  at `member`; no UPDATE/DELETE policy, plus immutability trigger.
- `audit_log`: authenticated SELECT for admin+; no direct mutation policy.
  Table INSERT/UPDATE/DELETE ACLs are explicitly revoked.

The broad authenticated table ACLs plus member-level policies confirm the
repository concern: the UI's owner/admin check does not itself protect the
decision tables from a tenant member. The new design must revoke direct
decision-related DML and expose only the authenticated RPC boundary.

### Function owners, security settings, and grants

Local inspection found:

- Worker matching functions are owned by `postgres`, `SECURITY DEFINER`, with
  `search_path = ''`.
- `reconciliation_claim_matching_runs`,
  `reconciliation_matching_source_records`,
  `reconciliation_heartbeat_matching_run`,
  `reconciliation_matching_write_candidates`, and
  `reconciliation_finish_matching_run` are executable by the matching-worker
  role. The matching RPCs are also executable by `service_role`; they are not
  executable by `authenticated` or `anon`.
- `log_audit` is owned by `postgres`, `SECURITY DEFINER`, and has an empty
  search path. It is executable by `authenticated` and `service_role`;
  authenticated calls validate tenant membership.
- `log_reconciliation_audit` is owned by `postgres`, is `SECURITY DEFINER`
  with an empty search path, and has no execute grants to application,
  service, worker, or scheduler roles in the inspected ACL.
- No workflow executor role or accept/reject RPC exists.

The existing worker-role constraints and no-direct-table-access boundary must
remain intact. Tests should verify role ACLs and function execute privileges
again after any future migration.

### Repository evidence

- Entity and relationship definitions, including `deleted_at`,
  `record_count`, candidate/source/entity foreign keys, and decision fields:
  [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L185)
- Candidate and reviewer-decision RLS policies:
  [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L478)
- Source immutability trigger:
  [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L592)
- Worker role creation, scoped RPCs, grants, and ownership:
  [`20261031000001_worker_and_audit_security.sql`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L1)
- Audit mutation revocation:
  [`20261101000005_revoke_audit_mutation_grants.sql`](../supabase/migrations/20261101000005_revoke_audit_mutation_grants.sql#L1)
- Current match accept/reject and entity creation:
  [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L159)
- Entity listing and deleted-state visibility:
  [`entities/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx#L20)
- Local PostgreSQL major version and port configuration:
  [`config.toml`](../supabase/config.toml#L8)

## 4. Soft-delete findings and recommendation

### Repository-confirmed behavior

- `reconciliation_entities` has `deleted_at` and a partial company index for
  active entities. The schema does not define a soft-delete trigger or
  relationship policy for entity links.
- The inspected reconciliation application code soft-deletes **data sources**,
  not entities. No entity restore workflow or entity soft-delete action was
  found.
- The entities page selects and renders rows without filtering
  `deleted_at IS NULL`; the entity confirmation and export reads also lack a
  deleted-state predicate. Thus, if an entity were soft-deleted, the current
  application queries could still display or act on it.
- Identifiers have no `deleted_at`/active flag. Soft-deleting an entity would
  not remove its identifier links. A physical entity delete would cascade
  identifier links.
- Current accept logic queries identifier links without joining/filtering the
  entity's `deleted_at`, and can therefore reuse a linked soft-deleted entity.
- Current accept logic sets a newly created entity's `record_count` to 2, but
  does not update an existing entity's count when adding a record. Local
  stored count happens to match current links; the preflight found no mismatch.
- Local database has 1 entity, 0 soft-deleted entities, and 0 links to deleted
  entities. This does not prove hosted behavior.

### Recommended Stage 1 policy

Treat a soft-deleted entity as **inactive and ineligible** for match acceptance.
The RPC must not restore it, reuse it, or silently move its identifier links.
If either source is already linked to a soft-deleted entity, return an explicit
`inactive_entity_conflict` and make no writes; a separately authorized,
audited restore/reassignment workflow can resolve it.

For this milestone, keep the source-link uniqueness constraint over all
identifier rows, including links to soft-deleted entities. This is
intentionally conservative: it prevents a new current entity from being
silently created while the old provenance link remains. It is stronger than
"at most one current entity." If the product later wants old links archived
while permitting a source to join a new entity, first add an explicit
historical/current relationship model (for example, link validity state) and
migrate readers and constraints deliberately.

Recompute `record_count` for the chosen active entity as the number of its
identifier rows inside the transaction. Preserve counts and links on
soft-deleted entities; do not treat deletion as unlinking. Do not add a
restore path in Stage 1.

## 5. Migration-runner limitations and safe sequence

The installed Supabase CLI is `2.119.0`. Its local `migration up` and `db push`
help show migration application commands and dry-run support, but no
non-transactional migration switch or explicit transaction-control option.
The command help and read-only inspection do not establish whether the runner
wraps each SQL file in a transaction. Testing `CREATE INDEX CONCURRENTLY`
behavior by attempting DDL would violate this task's read-only boundary.

**Operational conclusion:** support for `CREATE INDEX CONCURRENTLY` through
the current migration runner is **NOT VERIFIED**. PostgreSQL prohibits that
statement inside a transaction block. Do not put it in a normal
`supabase db push` migration unless the exact runner behavior is independently
verified with a disposable environment. Safest plan: build large unique
indexes as a separately reviewed, explicitly non-transactional operational
step; then attach them and add/validate constraints in regular migrations.

Recommended order:

1. Resolve the local migration-history discrepancy at version
   `20261101000006`; do not repair migration history as part of this design
   work.
2. Run the preflight on the exact deployment target and stop on any finding.
3. Create unique parent indexes on `(company_id, id)` for source records,
   entities, and candidates. These are likely redundant with current primary
   keys for ID uniqueness, but are required as referenced keys for composite
   FKs. Use a separate concurrent build only if table size and lock analysis
   justify it.
4. Create the unique `(company_id, source_record_id)` identifier index,
   concurrently outside a transaction if required by table size. Preflight
   must be clean; inspect index validity after any failed build.
5. Add the composite foreign keys as `NOT VALID` in a transactional migration,
   then validate them in a later controlled step. PostgreSQL supports
   `NOT VALID` for foreign keys, not unique constraints.
6. Add nullable decision columns. Build partial unique indexes for candidate
   decision and idempotency keys; on a large populated decision table, build
   concurrently outside transaction, then attach constraints where
   PostgreSQL permits.
7. Create the dedicated non-login role, scoped policies, RPCs, ownership,
   search path, and grants only after required tables/columns/constraints
   exist.
8. Coordinate application rollout and direct-DML revocation in a maintenance
   window. Disable review actions, apply RPC and privilege changes, deploy
   the RPC-only action caller, verify grants, and only then re-enable review.
   Do not leave a period where the old multi-request workflow is presented as
   safe.
9. Run rollback/concurrency tests in staging before any hosted rollout.

`CREATE INDEX CONCURRENTLY` cannot run in an explicit transaction, cannot be
combined with attaching a constraint in the same statement, and can leave an
invalid index after interruption. Unique indexes cannot be declared
`NOT VALID`; violations must be resolved through an approved data process
before the index is built.

## 6. Blocking findings and required action

| Finding | Status | Blocks implementation? | Required action |
|---|---|---|---|
| Local preflight rows | All seven checks have zero findings; query 4 required SQL correction | No local data blocker | Re-run corrected query 4 and all checks against hosted target before migration |
| Local DB migration history has `20261101000006` without matching repo migration file | Confirmed local history discrepancy | **Yes** | Determine migration provenance and reconcile repository/history under separate approval |
| Broad local authenticated table ACLs and member-level decision-related RLS policies | Confirmed local | **Yes, for security rollout** | Replace direct decision DML with RPC-only access; test ACL and RLS behavior |
| Service role bypasses RLS and can call worker RPCs | Confirmed local | Not a new grant recommendation | Do not use it for workflow RPCs; retain explicit per-RPC checks and least privilege |
| Entity soft-delete not filtered in entity/review/confirmation/export reads | Confirmed in repository code | **Yes, for entity reuse semantics** | RPC rejects links to inactive entities; application query cleanup is separate and must be reviewed before enabling hidden/deleted entities |
| CLI non-transactional migration behavior | Not verified | **Yes for concurrent-index deployment choice** | Verify in a disposable environment or use separately controlled non-transactional index operation |
| Hosted data, grants, RLS, and migration history | Not inspected | **Yes before hosted rollout** | Repeat preflight/catalog inspection with an authorized read-only hosted connection |
| Account-erasure behavior for reviewer FK | Unresolved | Yes before final FK action | Approve `RESTRICT` or an attribution-preserving alternative |

## 7. Go/no-go recommendation

**NO-GO for database implementation or hosted rollout at this time.**

The local data preflight found no row-level relationship, tenant, history,
pair, or count violations. However, the local migration-history discrepancy
must be reconciled, direct authenticated DML boundaries need a reviewed RPC
transition, entity soft-delete semantics need to be enforced, migration-runner
transaction behavior for concurrent indexes is not verified, and hosted
state has not been inspected.

This assessment does not authorize implementation. No encryption work is
included or recommended in this report.
