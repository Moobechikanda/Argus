# ZamBase Phase 2A.3.4 — Stage 1B Readiness Report

> **Investigation only.** No migration files, application files, configuration,
> schema, data, role, grant, RLS policy, or function were changed. Database
> commands were SELECT-only. Existing uncommitted work was preserved.
>
> Findings marked **Directly verified**, **Inferred**, **Not verified**, or
> **Blocked by unavailable access** distinguish observed facts from conclusions
> and unknowns. Local findings do not establish hosted Supabase state.

## 1. Executive summary

**Recommendation: NO-GO for the Phase 2A.3.4 workflow-integrity migration.**

Key findings:

- **Directly verified —** Local PostgreSQL is 15.19. Its migration history
  contains `20261101000006` named `enforce_import_finish_lease`, while the
  current repository has no file with that version. The migration-history
  table retained the exact SQL statements; the current local function body
  matches the recorded version.
- **Directly verified —** Repository version `20261101000002` has the same
  migration name but different function SQL. It permits an error string up to
  10,000 characters; recorded version `20261101000006` reduces the limit to
  1,000. The local database therefore contains a function change not represented
  by the current repository migration files.
- **Inferred —** The most plausible explanation is that version 06 was applied
  from another repository state or that its file was later omitted. Database
  metadata proves the SQL recorded for the version, not who applied it or
  whether it was executed manually versus through the migration runner.
- **Directly verified —** `docs/WORKERS.md` names
  `20261101000006_enforce_import_finish_lease.sql` but describes it as part of
  lease-reclaim behavior. The recorded version 06 actually hardens import
  finalization; migration 04 contains the reclaim logic. This documentation is
  inconsistent with the recorded SQL.
- **Directly verified —** Local preflight checks from Stage 1A found zero
  findings. They do not establish hosted data integrity.
- **Directly verified —** Local table ACLs grant broad DML privileges to
  `authenticated`, with RLS narrowing actual operations. Member-level policies
  allow direct candidate updates, entity inserts, identifier inserts, and
  reviewer-decision inserts. A tenant member can bypass the intended
  owner/admin review workflow through direct database API writes.
- **Directly verified —** The local import and matching worker roles have no
  direct privileges on affected tables and retain scoped RPC execution.
- **Blocked by unavailable access —** Supabase CLI authentication appears
  available, but this workspace has no linked hosted project, and the
  authenticated project list has no exact match for the configured local
  project name. No hosted database was selected or queried.
- **Directly verified —** The installed Supabase CLI is 2.119.0. Its
  version-tagged migration source recognizes `CREATE INDEX CONCURRENTLY` as a
  pipeline-incompatible statement and executes it outside the normal SQL
  batch. Such a migration is not atomic across the standalone statement and
  surrounding batches; index validity and migration-history state need
  explicit recovery procedures.
- **Directly verified —** Soft-deleted entities are not excluded from the
  entity listing, confirmation reads, export page, or export action. The
  current accept path looks up identifier links without checking the linked
  entity's `deleted_at`, and can reuse a soft-deleted entity.

The local row-level preflight is clean, but migration provenance, direct DML
bypass, soft-delete behavior, and hosted-state uncertainty are blockers. Do
not implement or apply the workflow-integrity migration on the basis of local
results alone.

## 2. Migration `20261101000006` investigation

### 2.1 Directly verified local migration metadata

The local `supabase_migrations.schema_migrations` table has columns `version`,
`statements`, and `name`. For version `20261101000006`, it records:

- `name`: `enforce_import_finish_lease`
- `statement_count`: 4
- Statements: `CREATE OR REPLACE FUNCTION`, `ALTER FUNCTION ... OWNER`,
  `REVOKE ALL ...`, and `GRANT EXECUTE ...`

The exact historical SQL recorded in the local database is recoverable below.
This is **database-recorded SQL**, not a recovered Git file. No missing file was
created.

```sql
-- Ensure import finalization matches the live-lease contract used by heartbeat
-- and insert RPCs. This correction is additive; do not rewrite applied history.
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
END $$
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

### 2.2 Comparison with current repository and active local function

**Directly verified:**

- The repository contains
  [`20261101000002_enforce_import_finish_lease.sql`](../supabase/migrations/20261101000002_enforce_import_finish_lease.sql).
- Local migration history has both version `20261101000002` and
  `20261101000006`, with the same name.
- The SQL statement arrays differ: version 02 truncates `_error` at 10,000
  characters; version 06 truncates at 1,000.
- `pg_get_functiondef` for the local active
  `public.reconciliation_finish_import` function matches the version 06
  behavior: live `lease_until > now()` condition, 1,000-character error
  limit, `SECURITY DEFINER`, and empty search path.
- The local function owner is `postgres`; the import-worker role can execute
  it; `authenticated` cannot.

Thus, the migration's effect is still present locally. It replaced the import
finish function body and reaffirmed function owner and execute grants. It did
not add tables, columns, or indexes.

### 2.3 Filename and Git history

- **Directly verified:** the database records the migration name
  `enforce_import_finish_lease`; the filename convention yields
  `20261101000006_enforce_import_finish_lease.sql`.
- **Directly verified:** `docs/WORKERS.md` references that exact filename.
- **Directly verified:** Git path history and available commit trees were
  searched across current and listed refs. The missing version 06 file was not
  found in those trees. The current worktree has no such path.
- **Not verified:** whether the original file existed in an unreachable Git
  object, another clone/branch, or a previous repository state not available
  in this checkout.
- **Not verified:** whether it was applied by the Supabase CLI from a file
  later removed, or whether migration history was synchronized/inserted by a
  different process. The SQL metadata and active function do not identify the
  operator or execution path.

The migration-history row is strong evidence that the version was recorded as
a migration. Do not reconstruct a replacement file and call it the original;
preserve the distinction between the SQL recovered from database metadata and
the absent original repository artifact.

### 2.4 Documentation inconsistency

**Directly verified:** [`docs/WORKERS.md`](./WORKERS.md) says migrations
`20261101000004` and `20261101000006` reclaim running jobs/runs with missing
or expired leases. Version 04 contains import/matching claim recovery. The
recorded SQL for version 06 instead replaces `reconciliation_finish_import`
and enforces that finalization has a live lease. The docs describe the wrong
responsibility for version 06.

No documentation was edited as part of this investigation.

## 3. Local migration-history reconciliation

### 3.1 Version comparison

The local database has 20 migration-history rows. The repository has 19
migration files. The versions agree except for database-only `20261101000006`.
No repository migration file version was absent from local history.

| Comparison | Local finding |
|---|---|
| Current repository files absent from local history | None |
| Local history versions absent from repository files | `20261101000006` |
| Duplicate version values | None found |
| Duplicate migration names | `enforce_import_finish_lease` appears at versions `20261101000002` and `20261101000006` |
| Same-name SQL consistency | Inconsistent; the error truncation bound differs |
| Local schema change not represented by current migration files | Active import-finish function matches database-only version 06, not current repository version 02 |

Supabase CLI `migration list --local` showed the database-only version 06 as
having no matching local file. The database metadata also records the exact
four statements above.

### 3.2 Stage 1A data-integrity checks

The seven local checks in the
[Stage 1A preflight report](./PHASE-2A-3-4-STAGE-1A-PREFLIGHT-REPORT.md)
returned zero rows:

1. Source records linked to multiple entities.
2. Identifier parent/tenant mismatches.
3. Candidate source/entity tenant mismatches.
4. Pending candidates with conflicting entity links.
5. Candidate state versus reviewer-decision history.
6. Duplicate, reversed, or self-pair candidates.
7. Stored entity record counts versus identifier links.

Query 4 as originally written used `min(uuid)`, which PostgreSQL 15.19 does
not support. The Stage 1A report records the corrected SELECT-only query and
its zero-row result. The clean local results do not clear hosted data.

## 4. Hosted migration-history assessment

- **Directly verified:** the local Supabase CLI is authenticated sufficiently
  for `supabase projects list --output json` to succeed. Its output and
  project identifiers were suppressed.
- **Directly verified:** no `supabase/.temp/project-ref` link file exists.
- **Directly verified:** the authenticated project list contained three
  visible projects and no exact match for the local configured project name
  `supabase-multitenant-starter`. Project names and IDs were not printed.
- **Directly verified:** `supabase migration list --linked` exited unsuccessfully
  because this checkout is not linked to an available hosted project.
- **Blocked by unavailable access:** no hosted project was selected, and no
  hosted DB query was run. Hosted PostgreSQL version, migration history,
  schema, table grants, roles, RLS policies, functions, worker privileges,
  and seven data-integrity checks are all **NOT VERIFIED**.

An authorized inspection requires confirmation of the correct hosted project
reference and a read-only database inspection path authorized for that
project. Do not link this checkout or query one of the visible projects by
guessing. No credentials or tokens were requested or displayed.

## 5. Local security findings

All six affected tables have RLS enabled and forced locally:

- `reconciliation_match_candidates`
- `reconciliation_entities`
- `reconciliation_identifiers`
- `reconciliation_reviewer_decisions`
- `reconciliation_source_records`
- `audit_log`

### 5.1 Effective `authenticated` access: ACLs and RLS together

The local table ACLs include broad SELECT/INSERT/UPDATE/DELETE privileges for
`authenticated` on reconciliation tables. These ACLs do not independently
prove that a request succeeds: RLS policies and the source immutability
trigger also apply.

| Table | Direct INSERT under local authenticated ACL + RLS | Direct UPDATE | Direct DELETE |
|---|---|---|---|
| Match candidates | Allowed by member-level INSERT policy | Allowed by member-level UPDATE policy | Denied by absence of DELETE policy |
| Entities | Allowed by member-level INSERT policy | Allowed for admin+ by UPDATE policy | Allowed for owner by DELETE policy |
| Identifiers | Allowed by member-level INSERT policy | Denied by absence of UPDATE policy | Denied by absence of DELETE policy |
| Reviewer decisions | Allowed by member-level INSERT policy when `reviewer_id = auth_uid()` | Denied by absence of UPDATE policy | Denied by absence of DELETE policy |
| Source records | Allowed by member-level INSERT policy | Denied by absence of UPDATE policy; trigger also rejects UPDATE | Denied by absence of DELETE policy; trigger also rejects DELETE |
| Audit log | Denied by revoked INSERT ACL and absence of INSERT policy | Denied by revoked UPDATE ACL and absence of UPDATE policy | Denied by revoked DELETE ACL and absence of DELETE policy |

**Directly verified security finding:** ordinary tenant members can write
candidate status and fields directly, create entities, add identifiers, and
insert their own reviewer-decision rows. The UI's owner/admin gate does not
prevent direct database API access. The intended review workflow is therefore
currently bypassable. This is a **high-priority blocker** for the integrity
migration and must be addressed by narrowly granted transactional RPCs and
direct-DML revocation.

The relation ACLs are broad for `anon` too, but the inspected reconciliation
RLS policies target `authenticated`, not `anon`; forced RLS without a
permissive applicable policy denies those table operations. `service_role` is
`BYPASSRLS` and has broad privileges; do not use it to implement review RPCs.

### 5.2 Role attributes and worker boundaries

**Directly verified locally:**

- `reconciliation_import_worker`: `LOGIN`, non-superuser,
  `NOCREATEDB`, `NOCREATEROLE`, `NOINHERIT`, `NOBYPASSRLS`, no memberships,
  and no direct privileges on the six affected tables.
- `reconciliation_matching_worker`: same attributes and no direct privileges
  on the six affected tables.
- `reconciliation_scheduler`: `NOLOGIN`, non-superuser, `NOBYPASSRLS`, no
  direct affected-table privileges.
- Matching claim/read/heartbeat/write/finish RPCs are `SECURITY DEFINER`,
  owned by `postgres`, and have `search_path = ''`. Execute is granted to the
  matching worker and `service_role`, not `authenticated` or `anon`.
- Import finish RPC is `SECURITY DEFINER`, owner `postgres`, empty search path,
  executable by the import worker, and not by authenticated users.
- `log_audit` is `SECURITY DEFINER`, owner `postgres`, empty search path, and
  executable by `authenticated` and `service_role`; authenticated use checks
  own-tenant membership. Direct audit table mutation remains revoked.
- `log_reconciliation_audit` has no execute grants to application, service,
  worker, or scheduler roles in the inspected local ACL.

Worker table restrictions and RPC privileges must remain unchanged in any
future workflow migration. `service_role` execute grants on some worker RPCs
are present locally; their continued existence does not justify using that
role for human workflow operations.

### 5.3 Hosted security state

**Blocked by unavailable access:** none of the local ACL, RLS, role, worker,
function, or audit findings above have been verified against hosted Supabase.

## 6. Soft-delete and record-count semantics

### 6.1 Repository and local observations

- **Directly verified:** `reconciliation_entities.deleted_at` exists and the
  entity company index is partial on `deleted_at IS NULL`; there is no
  identifier soft-delete/active flag.
- **Directly verified:** the entity listing selects by company and does not
  filter `deleted_at`. Soft-deleted entities would remain visible.
- **Directly verified:** `confirmEntity` reads a candidate entity without a
  `deleted_at IS NULL` condition. Its update policy can update entity columns,
  including `deleted_at`, for admins; no application restore action was found,
  but an authenticated admin can directly clear `deleted_at` under the current
  broad table UPDATE grant and RLS policy.
- **Directly verified:** the export page and `exportEntity` action select
  entities by ID/company without filtering `deleted_at`; entity exports
  include soft-deleted entities.
- **Directly verified:** identifiers have no deleted-state column. A soft
  delete of an entity leaves identifier links in place; a physical entity
  delete cascades those links.
- **Directly verified:** current match acceptance queries identifier links
  without joining the entity to test `deleted_at`; it may reuse an inactive
  linked entity.
- **Directly verified:** no entity soft-delete or restore action exists in
  the inspected reconciliation application code. The only implemented
  soft-delete action found in this area is for data sources.
- **Directly verified:** new entities are created with `record_count = 2`.
  When current acceptance attaches a record to an existing entity, it does
  not increment that entity's count. No trigger or separate worker maintains
  identifier-derived counts. The entity page displays the stored count and
  confirmation audit records it.
- **Directly verified locally:** one entity has `deleted_at IS NULL`,
  `record_count = 2`, and two links; no soft-deleted entities or links to
  deleted entities exist. This is not evidence about hosted state.

### 6.2 Recommended policy for the new RPC

The proposed rule is **not supported by the current accept implementation**.
The new RPC should treat any source link to a soft-deleted entity as an
explicit `inactive_entity_conflict`. It must not reuse the entity, clear
`deleted_at`, delete/reassign the link, or create a new entity while leaving
the old provenance relationship unresolved.

For Stage 1, retain uniqueness over all identifier links, including links to
soft-deleted entities. This conservative policy avoids silently creating a
second relationship. Reassignment or restoration requires a separate
authorized, audited workflow and explicit product policy. Recalculate
`record_count` from identifier links within the accept transaction for the
selected active entity; preserve existing counts/links on inactive entities.

Open policy question: whether a future explicit resolution should restore the
old entity or represent prior links as historical/inactive and allow a new
current link. The current schema has no relationship history model; do not
infer one.

## 7. Migration-runner and index execution findings

### 7.1 Local CLI behavior

- **Directly verified:** installed CLI version is `2.119.0`.
- **Directly verified:** the version-tagged CLI source at
  [`apps/cli-go/pkg/migration/file.go`](https://github.com/supabase/cli/blob/v2.119.0/apps/cli-go/pkg/migration/file.go)
  batches regular migration statements. It recognizes
  `CREATE [UNIQUE] INDEX CONCURRENTLY` as pipeline-incompatible, flushes the
  open batch, executes the index statement outside the batch, and then resumes
  batching. The migration-history insert is in the final batch.
- **Conclusion — directly verified from that versioned source:** the CLI
  supports concurrent index statements in migration files, but a migration
  containing one is not atomic across the standalone statement and normal
  batches. Earlier flushed statements may remain committed if a later
  statement fails; an index can also be created while migration history is
  not yet recorded if the final batch fails.
- **Not verified by an execution test:** this task did not run DDL or test
  failure recovery. This is intentionally not tested against the live local
  database because it would require mutating schema.

PostgreSQL itself prohibits `CREATE INDEX CONCURRENTLY` inside a transaction
block. The inspected v2.119.0 source handles it by executing outside the
ordinary batch. Keep such statements isolated and idempotent where possible;
after any failure, inspect index catalog validity and migration history before
retrying. Do not assume the entire migration will roll back.

### 7.2 Recommended migration order

1. Reconcile migration version 06 provenance and repository/history state
   under separate approval. Do not fabricate or apply a replacement file.
2. Repeat data preflight and catalog inspection on the authorized deployment
   target.
3. Build required unique parent indexes on `(company_id, id)` and the
   one-source-to-one-identifier index. For large tables, use concurrent
   index creation in isolated migration steps and inspect validity after
   failure.
4. Add composite FKs as `NOT VALID`, then validate after clean scans.
   PostgreSQL supports `NOT VALID` for foreign keys, not unique constraints.
5. Add reviewer-decision columns; build unique partial indexes only after
   validating existing data. Keep legacy decisions unchanged.
6. Create the function-owner role, targeted policies, RPCs, and grants only
   after constraints and decision schema are ready.
7. Disable review actions during direct-DML revocation and application
   cutover. Verify function grants and worker RPC access before re-enabling.

The migration-history discrepancy must be resolved before deploying another
timestamped migration, because local CLI comparison already reports an applied
version that has no corresponding local file.

## 8. Blocking issues and severity

| Severity | Finding | Evidence/status | Required disposition |
|---|---|---|---|
| **High** | Direct authenticated decision-workflow bypass | Local effective ACL + RLS permits member candidate updates and member inserts to entities, identifiers, and own reviewer decisions | Add transactional RPC boundary and revoke direct DML only after callers are inventoried and cut over |
| **High** | Missing repository migration version 06 with different active function body | Local metadata recovers SQL; active local function matches it; repo has only version 02 file | Recover authoritative provenance from repository owner/history before new migration; do not guess or silently recreate |
| **High** | Hosted state uninspected | CLI auth works, but no link and no exact project match; remote query not attempted | Confirm correct project ref and use an authorized read-only inspection path |
| **High** | Deleted entity can be reused/displayed/exported | Current entity and export queries omit deleted-state filters; accept links ignore entity deletion | New RPC must return inactive-entity conflict; decide whether UI read/export behavior should also filter |
| **Medium** | `docs/WORKERS.md` misstates version 06 purpose | Repository text conflicts with database-recorded version 06 SQL | Correct documentation after migration provenance is confirmed |
| **Medium** | Concurrent-index migration is non-atomic across flush boundaries | Supabase CLI v2.119.0 source | Isolate concurrent index statements and define invalid-index/history recovery runbook |
| **Medium** | Existing reviewer FK uses `ON DELETE SET NULL` on a non-null decision reviewer | Local schema constraint verified | Approve account-erasure semantics and the new FK delete policy |
| **Low** | No local row-level preflight violations | Seven Stage 1A checks clean on local data | Repeat on hosted target; no repair required locally |

## 9. Recommended next steps in execution order

1. Ask the database/project owner to identify the provenance of migration 06:
   confirm the original file/commit if available, verify the recorded SQL, and
   explain why version 02 and 06 share a name but differ in behavior.
2. Reconcile local documentation and migration history only after the
   authoritative origin is established. This report does not authorize file
   creation, migration repair, or database changes.
3. Have the project owner identify the correct hosted project reference.
   Repeat the SELECT-only preflight and catalog inspection there using
   authorized read-only access.
4. Review the direct DML bypass and approve a staged application/RPC cutover
   that preserves worker privileges and source immutability.
5. Resolve inactive entity behavior and reviewer deletion/retention policy.
6. Verify concurrent-index recovery and `NOT VALID` FK operations in a
   disposable environment before scheduling any production migration.
7. Only then prepare a reviewed implementation plan; do not apply migrations
   until separately approved.

## 10. Commands and SQL used

### Read-only commands executed

- `docker ps --format ...` — inspected running container status; did not start
  or stop services.
- `supabase --version`
- `supabase migration list --local`
- `supabase migration list --linked` — read-only attempt; no linked project was
  available.
- `supabase projects list --output json` — read-only; output values suppressed.
- `supabase migration list --help`
- `supabase migration up --help` and `supabase db push --help` — help only;
  neither migration command was executed.
- `git status --short`, `git branch --all`, `git log --all`,
  `git ls-tree`, `git show`, `git grep` — read-only Git inspection.
- Read-only public-source inspection of Supabase CLI tag `v2.119.0` to verify
  concurrent-index handling. No credentials were sent.

### SELECT-only SQL executed

- Local `information_schema.columns` and
  `supabase_migrations.schema_migrations` reads, including `to_jsonb` of
  migration version 06 metadata.
- Local version/name inventory from `supabase_migrations.schema_migrations`.
- Local migration statement comparison and extraction for versions 02 and 06.
- Local `pg_get_functiondef` and `pg_proc`/`pg_roles` reads for the active
  import-finish function.
- Stage 1A's seven SELECT-only data-integrity checks, recorded in the linked
  [Stage 1A report](./PHASE-2A-3-4-STAGE-1A-PREFLIGHT-REPORT.md); query 4 was
  corrected because PostgreSQL 15.19 does not implement `min(uuid)`.
- Local table row counts and entity/identifier counts.
- Local `pg_class`, `pg_constraint`, `pg_indexes`, `pg_roles`,
  `pg_auth_members`, `has_table_privilege`, `pg_policies`,
  `pg_proc`/`has_function_privilege`, and `pg_trigger` catalog reads.

No `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `ALTER`, `DROP`, `CREATE`, reset,
push, migration-up, or other database mutation command was run. No secrets,
tokens, API keys, project identifiers, or database passwords are included in
this report.

## 11. Verification and final decision

- `git diff --check`: passed.
- Report trailing whitespace: none.
- Local Markdown file links: verified.
- `git status --short`: inspected; pre-existing dirty/untracked files remain
  untouched. This task added only
  `docs/PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md`.
- No migrations, application files, configuration, schema, data, grants, roles,
  RLS policies, or functions were modified.

**Final recommendation: NO-GO.** The local row-level checks are clean, but
workflow migration implementation is not ready until migration 06 provenance
is reconciled, direct authenticated DML bypass is addressed through an
approved transaction boundary, deleted-entity behavior is enforced, and the
correct hosted database is inspected read-only. No encryption work is part
of this assessment.
