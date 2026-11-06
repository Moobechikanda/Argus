# ZamBase Phase 2A.3.4 — Stage 1P Independent Adversarial Design Review

> **Read-only design review.** This report reviews the proposed contracts in
> Stage 1O against repository sources. No application code, SQL, migration,
> configuration, credential, database state, or hosted project was changed or
> accessed. No tests were run. Existing worktree changes were preserved.

## 1. Executive summary and verdict

**Verdict: CONDITIONAL GO for another documentation-only amendment and
independent review.**

Stage 1O improved materially on Stage 1N: it named a proposed executor role,
defined a resumable pair-mapping concept, required a database fence, and
described durable request outcomes. Those are useful design directions, but
several of the stated contracts are not executable as written and some
conflict with repository schema and function behavior:

1. The executor membership helper is not granted membership-table `SELECT`,
   lacks an executor RLS policy, and proposes `SELECT ... FOR SHARE` without
   the required `UPDATE` privilege. The membership table is `FORCE ROW LEVEL
   SECURITY` and its visible policy targets `authenticated`, not the proposed
   executor.
2. The database fence relies on `current_user` without defining the trigger
   security mode or distinct old-writer, migrator, and new-writer identities.
   Existing worker definer functions are assigned to `postgres` in repository
   migration source, so a `current_user` allow/deny check could conflate an
   old writer and the privileged migration path.
3. The reviewer RPCs lack a complete pair-state transaction. They can accept
   different candidate IDs for the same unordered pair unless all decisions
   are serialized and constrained by a single pair-level state machine.
4. The manual discrepancy RPC is listed as externally callable although its
   JSON payload is expressly excluded from the canonical request format.
   Its target field and manual value also do not appear in the ledger's
   defined digest tuple.
5. The proposed audit relation conflicts with the existing `audit_log`
   identity key and existing operational audit rows. The writer takes a UUID
   audit ID, whereas repository `audit_log.id` is a `bigint` identity. Making
   `decision_id` mandatory for every audit row would prevent ordinary
   worker, membership, invitation, cron, and retention events.
6. The reserved event names do not match the repository's existing
   `audit_action` labels such as `match.accepted`, `entity.confirmed`, and
   `discrepancy.resolved`. The generic reject list therefore does not yet
   close the current spoofable names.
7. The executor RLS matrix omits required membership and audit policies,
   while its grant matrix leaves pair, decision, and ledger privileges
   unfinished. Under `FORCE ROW LEVEL SECURITY`, the proposed trusted audit
   writer cannot insert without an executor policy.
8. Pair backfill classifications infer terminal outcomes from candidate
   statuses without defining authoritative evidence. The design also does
   not give a representable mapping for missing/cross-tenant source pairs
   while requiring a pair-registry reference.
9. The migration/lifecycle plan does not reconcile the existing reviewer
   decision table, the audit `bigint` ID, current cascade FKs, and current
   retention deletion with the new deferred constraints.
10. The caller inventory omits direct Storage operations and does not close
    the effective grants for several named functions or relation columns.

These are design defects, not merely environment checks. Environment
verification remains important, but it cannot substitute for resolving the
contracts. No finding in this report authorizes implementation, tests,
SQL, database access, hosted Supabase access, deployment, or Stage 2.

## 2. Scope and evidence

Read the complete [Stage 1O corrected design amendment](PHASE-2A-3-4-STAGE-1O-CORRECTED-DESIGN-AMENDMENT.md)
and compared its proposed functions and state rules with:

- [Stage 1N independent review](PHASE-2A-3-4-STAGE-1N-INDEPENDENT-DESIGN-REVIEW.md).
- [Reconciliation schema, policies, and helpers](../supabase/migrations/20261029000001_reconciliation_module.sql).
- [Membership table](../supabase/migrations/20260514000004_memberships.sql),
  [membership RLS policies](../supabase/migrations/20260514000008_rls_policies.sql),
  [membership helpers](../supabase/migrations/20260514000007_helper_functions.sql),
  and [membership triggers](../supabase/migrations/20260514000009_triggers.sql).
- [Base audit table and enum](../supabase/migrations/20260514000006_audit_log.sql)
  and [audit action enum](../supabase/migrations/20260514000001_extensions_and_enums.sql).
- [Worker security and grants](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
  [audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
  [lease recovery](../supabase/migrations/20261101000004_recover_missing_worker_leases.sql),
  and [cron and retention setup](../supabase/migrations/20261030000002_reconciliation_security_ops.sql).
- [Reconciliation Server Actions](../examples/nextjs/lib/actions/reconciliation.ts),
  [import upload form](../examples/nextjs/app/dashboard/reconciliation/imports/upload-form.tsx),
  [import-download Edge Function](../supabase/functions/import-download-url/index.ts),
  and [invitation Edge Function](../supabase/functions/invitations/index.ts).

Evidence labels:

- **Repository evidence** is source or migration text in this worktree; it does
  not establish committed provenance or deployment.
- **Proposed design** is Stage 1O text; it is not implemented or validated.
- **Prior local observation** is a fact recorded in earlier documentation only.
  The migration-06 observation is not rechecked here and says nothing about a
  hosted project.
- **Environment verification** means a future, explicitly authorized
  inspection. None was performed for this review.

No Supabase or PostgreSQL database was queried. No tests, SQL, migration
commands, secret inspection, or hosted access were performed.

## 3. Findings summary

| ID | Severity | Stage 1O section | Core issue | Blocks implementation authorization? | Classification |
|---|---|---|---|---|---|
| 1P-1 | High | §2.4–2.5 | Membership helper cannot read/lock memberships under proposed ACL/RLS; `FOR SHARE` privilege omitted | Yes | Design defect |
| 1P-2 | High | §2.2, §5.1–5.2 | Manual discrepancy JSON RPC is externally listed but omitted from canonical digest | Yes | Design contradiction |
| 1P-3 | Critical | §4.1 | Fence's `current_user` check lacks a defined trigger context and distinct identities; legacy definer owner may equal migration identity | Yes | Design defect and environment dependency |
| 1P-4 | High | §2.2, §2.4, §4.2, §8 T15 | Pair state is not the sole enforced decision state; different candidate IDs can receive separate outcomes | Yes | Design defect |
| 1P-5 | High | §3.2, §2.3, §9 steps 9–11 | Audit link types/order do not fit existing audit PK or generic events; audit RLS insertion policy missing | Yes | Design defect |
| 1P-6 | High | §3.1 | Reserved audit actions do not match existing enum labels; direct and generic writers are not closed by exact signatures | Yes | Design defect |
| 1P-7 | High | §2.3–2.5 | RLS, helper dependencies, table grants, search path, and ownership transfer remain incomplete | Yes | Design defect and environment dependency |
| 1P-8 | High | §4.2–4.3, §7, §9 | Backfill can infer an outcome from partial history and cannot represent every orphan/conflict case | Yes | Design defect |
| 1P-9 | Medium | §2.2, §5 | Recovery interface, ledger identity and authorization do not align for discrepancy/manual requests | Yes | Design defect / owner choice |
| 1P-10 | High | §7, §9 | Existing decision table, current FK cascades, audit retention, and circular audit constraints lack a compatible migration/lifecycle plan | Yes | Design defect and owner/legal dependency |
| 1P-11 | Medium | §6, §9 | Caller closure omits direct Storage paths and exact app/worker/function grants | Yes for grant cutover | Design defect and environment dependency |

## 4. Detailed findings

### 1P-1 — High: membership authorization helper cannot perform its proposed read and lock

**Exact Stage 1O contract:** §2.4 proposes
`workflow_assert_membership(uuid, uuid)` as `SECURITY DEFINER`, owned by
`zambase_workflow_executor`, and performs `SELECT ... FOR SHARE` on the
membership row. §§2.3 and 2.5 do not grant the executor a membership-table
privilege or define an executor membership policy.

**Repository evidence:** `public.memberships` has `(company_id,user_id)` as
its primary key and a `role` column in
[the membership schema](../supabase/migrations/20260514000004_memberships.sql).
RLS is enabled and forced in
[the RLS migration](../supabase/migrations/20260514000008_rls_policies.sql);
its SELECT policy is `TO authenticated`, not `zambase_workflow_executor`.
The helper is not a table owner and is expressly `NOBYPASSRLS`.

**Concrete failure:** the function owner has no `SELECT` grant and no
applicable policy, so the membership query returns no visible row or raises
on insufficient privilege. Even if `SELECT` is granted, PostgreSQL locking
SELECTs, including `FOR SHARE`, additionally require `UPDATE` privilege on at
least one column of the locked table. Stage 1O grants no such privilege.
Granting broad UPDATE on `memberships` would unnecessarily place role changes
within the executor's authority.

**Revocation race and ordering:** a row lock acquired before checking the
database role can serialize a concurrent membership UPDATE/DELETE, but no
lock is obtained when the row is absent. The RPC also needs the candidate's
company ID before it can check membership. It must do a nonlocking,
nonrevealing candidate lookup to derive that company, acquire membership
serialization, validate the role from the locked/current database row, then
lock and revalidate the candidate and pair. No target/pair lock or mutation
should precede authorization. A plain SELECT plus an unrelated advisory lock
does not serialize membership changes unless every membership mutation takes
the same lock.

**Required correction:** specify one implementable path. A narrow alternative
is a transaction-scoped advisory lock keyed by `(company_id,user_id)`:
the membership assertion takes it before a plain SELECT, and a `BEFORE ROW`
membership trigger takes the same lock on every INSERT/UPDATE/DELETE,
including removal and role change. Give the workflow executor only
column-limited SELECT plus an RLS policy `TO zambase_workflow_executor`
whose predicate limits rows to `user_id = auth.uid()`; do not make that
policy call a membership helper recursively. The membership trigger and
helper must use identical, collision-safe key construction and transaction
scope. Alternatively, document the exact minimal column UPDATE grant and
explain why it cannot be exercised by any external or unintended function.
Specify lock order, missing-row behavior, and whether the role is exactly
`owner`/`admin` from the row. The helper must have a fixed path, explicit
owner, exact grants, and generic denial.

**Disposition:** Blocks implementation authorization. The missing grants and
RLS path are design defects. Actual role ownership and deployed policies also
require future environment verification.

### 1P-2 — High: the manual discrepancy RPC contradicts request canonicalization

**Exact Stage 1O contract:** §2.2 lists
`resolve_reconciliation_discrepancy(..., uuid, jsonb, uuid)` as externally
callable. It accepts a manual JSON value and claims the request ledger is
atomic. §5.1 says manual JSON cannot be part of the idempotent API until a
canonical JSON algorithm is approved. The canonical tuple in §5.1 contains
neither discrepancy `field_name` nor JSON value. D3 explicitly leaves
canonicalization unresolved.

**Concrete failure:** two JSON values with semantically equal but differently
ordered object keys can produce different payload encodings; conversely a
digest that omits the field name/value can treat two different field edits
as the same request. The API therefore cannot reliably distinguish a retry
from key reuse, and a lost response may be replayed as a different
discrepancy edit.

**Required correction:** defer manual JSON resolution and remove the manual
RPC from the externally callable function list until a separate canonical
value contract is approved. Keep only a source-winner operation if its
payload tuple is fully specified. Do not write a `manual` decision, ledger
result, or authoritative discrepancy audit event through a generic writer.
If manual resolution is later restored, the exact versioned canonical
encoding must include tenant, operation, discrepancy ID, field name,
resolution kind, value-presence marker, canonical value bytes, and all
result-affecting arguments; the digest, typed decision payload, audit event,
and recovery response must all bind to that same representation.

**Disposition:** Blocks implementation authorization. This is a design
contradiction, not an environment question.

### 1P-3 — Critical: the worker fence does not define a trustworthy caller identity

**Exact Stage 1O contract:** §4.1 says the trigger/legacy writer guard checks
the effective `current_user`, permits a migration-owner exception, blocks
old definer functions because their owner is not the migrator, and later
recognizes the new writer owner. It does not specify the trigger function's
security mode or owner, the exact allowed roles, or how old writers are
separated from the migration owner.

**Repository evidence:** worker functions in
[the worker security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql)
are `SECURITY DEFINER` and are explicitly assigned to `postgres`. Migration
source also shows the legacy candidate writer
`reconciliation_matching_write_candidates(uuid,uuid,jsonb)` and direct
candidate DML in that function. Deployed role ownership is not established by
this source.

**Concrete failure:** inside a `SECURITY DEFINER` trigger function,
`current_user` denotes the trigger function owner, not the original
application role. If the trigger is `SECURITY INVOKER`, a call made by an old
`SECURITY DEFINER` worker observes that worker function's effective owner.
The existing worker owner shown in source is `postgres`; if the migration
path also uses `postgres`, the guard cannot distinguish the old writer from
authorized backfill. If the trigger is `SECURITY DEFINER`, all calls instead
observe the trigger owner and the proposed `current_user` distinction
collapses. Table owners or superusers can also disable triggers or alter the
fence; `BYPASSRLS` is not a trigger fence.

**Required correction:** define three disjoint, non-login function identities:
legacy writer owner, new pair-writer owner, and controlled migrator. Transfer
old worker function ownership to the dedicated legacy owner before enabling
the fence, verify no function or login can assume the migrator/new owner, and
deny the legacy owner in the fence. Use a `SECURITY INVOKER` guard trigger
only if every effective writer owner can safely read the fence state; specify
that access and the exact allowlist. The migration path must be an explicit
controlled owner-only operation and must not share identity with any old
definer. The new writer is allowed only as its own dedicated non-login owner,
after deployment gate and lease checks. Keep the trigger and fence row
immutable to application/worker roles. State the trusted-DBA threat boundary,
prohibit application ownership/superuser/replication privileges, and
document controlled DDL/trigger-disable authority. Include direct DML,
old RPC, restarted worker, new RPC, migration and superuser cases.

**Disposition:** Blocks implementation authorization. Identity design is
incomplete; exact existing function owners and memberships also require
environment verification.

### 1P-4 — High: pair-level state is not the sole decision authority

**Exact Stage 1O contract:** §§2.2 and 2.4 accept a candidate ID, lock a
canonical pair registry, and describe candidate state separately. §4.2
preserves multiple historical candidate IDs for a pair. The report does not
give the full reviewer transaction or an exact unique constraint that limits
terminal decision rows to one per pair. T15 states a desired outcome but
does not specify its implementation.

**Concrete failure:** two reviewers concurrently submit different pending
candidate IDs for reversed or duplicate source directions. If each RPC only
checks and updates its candidate row, both may produce an accepted/rejected
decision even though they serialize on a registry row. A lock alone is not
enough unless the second transaction re-reads the registry state and rejects
or replays the already committed pair result. A registry row without a
pair-level terminal constraint is also vulnerable to another writer or
future function that does not follow the convention.

**Required correction:** define one authoritative pair state machine and
transaction sequence: (1) resolve candidate by ID with a generic
cross-tenant miss; (2) derive company; (3) serialize and verify current
membership; (4) lock the canonical `(company, low_source, high_source)`
registry row; (5) re-read candidate, source, mapping, entity links, and
registry state; (6) reject self/cross-tenant/deleted/missing sources and
pre-existing identifier/entity conflicts; (7) if pair is `accepted`,
`rejected`, or `conflict`, return a stable prior result or safe conflict and
write no second terminal decision; (8) if pending, write exactly one typed
decision with a database unique key on `pair_id`; (9) create/validate the
entity and identifier links; (10) create the correlated audit row; (11)
transition the pair and candidate projection; (12) commit the ledger result.
Registry transition, terminal decision, entity links, audit, and request
ledger must commit atomically. Both worker directions must acquire the same
canonical lock and insert/resolve the same registry row. Rollback releases
transaction locks and leaves no terminal state. Specify deterministic result
semantics for competing candidate IDs and for any prior pair state.

**Disposition:** Blocks implementation authorization. This is a design
defect.

### 1P-5 — High: audit correlation is incompatible with the existing audit schema and operational events

**Exact Stage 1O contract:** §3.2 proposes a mutually deferred one-to-one
decision/audit FK, a writer with signature
`write_reconciliation_decision_audit(uuid, uuid) RETURNS uuid`, mandatory
decision/audit IDs, and an audit insert including `id`. §2.3 also revokes
direct audit DML and §9 steps 9–11 sequence the constraints and ledger.

**Repository evidence:** [the existing audit table](../supabase/migrations/20260514000006_audit_log.sql)
uses a `bigint GENERATED ALWAYS AS IDENTITY` primary key, `actor_user_id`,
`action`, and `metadata`. The current reconciliation decision table already
exists in
[the reconciliation schema migration](../supabase/migrations/20261029000001_reconciliation_module.sql);
its reviewer FK is `NOT NULL` while `ON DELETE SET NULL`, and the company FK
is cascading. The audit table contains generic operational events without
reviewer decisions.

**Concrete failure:** the writer's UUID audit ID and `RETURNS uuid` do not
match `audit_log.id bigint`. Inserting an explicit UUID into the existing
identity PK is not the described operation. If `audit_log.decision_id` is
mandatory as §3.2 says, ordinary audit events cannot be inserted without a
reviewer decision. If it is nullable, the report's stated required
mutual-FK contract must be revised precisely. In addition, the executor has
an `INSERT` grant in §2.3's column matrix but no `TO zambase_workflow_executor`
INSERT policy on the FORCE-RLS audit table, so its definer writer is denied
by RLS.

**Required correction:** decide whether to retain `audit_log`'s bigint ID or
introduce a separately typed workflow audit relation. If retaining the
existing table, use bigint-compatible references, allow `decision_id` to be
NULL for nonworkflow events, and define the exact nullable/composite FK and
uniqueness rules that enforce one correlated row for every typed decision
without requiring decisions for generic audit rows. Add a narrowly scoped
executor INSERT policy and exact table/column grants. Specify insertion
order, `NOT NULL` behavior, deferred constraints, existing rows, and rollback.
If a new dedicated table is selected, define how it is the authoritative
audit record and how current audit readers/retention continue to work. Update
the already-existing decision table rather than assuming it is absent; define
safe nullable-column, backfill, and constraint steps.

**Disposition:** Blocks implementation authorization. These are schema
contract defects; deployed table alterations and historical rows require
environment verification.

### 1P-6 — High: reserved audit names do not cover the repository's current event values

**Exact Stage 1O contract:** §3.1 reserves only
`reconciliation.match.accepted`, `reconciliation.match.rejected`,
`reconciliation.entity.confirmed`, `reconciliation.entity.created`,
`reconciliation.entity.rejected`, `reconciliation.entity.merged`, and
`reconciliation.discrepancy.resolved`.

**Repository evidence:** the
[audit enum migration](../supabase/migrations/20261029000001_reconciliation_module.sql)
adds `match.accepted`, `match.rejected`, `entity.created`,
`entity.confirmed`, `entity.rejected`, `entity.merged`, and
`discrepancy.resolved`. The
[Server Actions](../examples/nextjs/lib/actions/reconciliation.ts) call the
generic `log_audit` with those existing labels. Generic `log_audit` and
`log_reconciliation_audit` overloads are defined in
[the helper migration](../supabase/migrations/20260514000007_helper_functions.sql)
and
[the reconciliation migration](../supabase/migrations/20261029000001_reconciliation_module.sql).

**Concrete failure:** an implementation that rejects only Stage 1O's
prefixed labels will still permit an authenticated caller to submit the
actual enum values through `log_audit` or `log_reconciliation_audit`. It
would block none of the current reviewer action names. Current worker,
cron, and retention paths also invoke generic reconciliation audit helpers,
so blanket revocation without replacing those exact call sites breaks
operational logging.

**Required correction:** enumerate every actual `audit_action` value and
map old/new spellings to the single authoritative action vocabulary. Reject
all reserved values at every generic overload, including wrappers/defaulted
signatures. Give a complete source/deployment search result for direct audit
inserts and generic helper callers. Specify exact fixed-purpose replacements
for worker start/finish, cron schedules, retention cleanup, membership
triggers, and invitation events, with invoker, owner, and EXECUTE grants.
Do not treat a future enum label as a synonym unless its compatibility and
history mapping are explicit.

**Disposition:** Blocks implementation authorization. This is a design
defect; deployed overload inventory is also an environment check.

### 1P-7 — High: helper, RLS, and role closure remains incomplete

**Exact Stage 1O contract:** §§2.3–2.5 claim exact ACL/RLS contracts but leave
the pair-registry, mapping, decision, and ledger column grants open for future
specification. The membership table is omitted. The audit table has no
executor policy. `workflow_lock_candidate_pair` requires pair-table insert
and update/locking rights that are not granted. The functions that call one
another and the privileges on every dependency are not fully listed.

**Repository evidence:** reconciliation tables and current policies are in
[the reconciliation migration](../supabase/migrations/20261029000001_reconciliation_module.sql);
membership RLS is forced as described above; audit RLS is forced in
[the RLS migration](../supabase/migrations/20260514000008_rls_policies.sql).
The current audit table policy has authenticated scoped SELECT and no direct
insert policy. The existing worker functions use `SET search_path = ''` and
qualified relation references in
[the worker migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql).

**Concrete failure:** the executor cannot execute its principal operations
without grants/policies, or an implementer grants broad table DML to make the
functions work. Policies that invoke functions without EXECUTE privileges
fail. A `SECURITY DEFINER` helper with a broad return or missing tenant
predicate can become a cross-tenant oracle. A policy `TO executor` does not
apply to the existing `postgres` worker function owner. The path
`pg_catalog, public, auth` also omits explicit handling of `pg_temp`; absent
`pg_temp` may be searched ahead of listed schemas for relation/type names.
Because helper bodies are not specified as fully schema-qualified, the
security-definer path is not yet a complete search-path contract.

**Required correction:** deliver a signature-by-signature dependency graph
and ACL matrix covering `EXECUTE`, schema `USAGE`, function ownership,
table/column `SELECT/INSERT/UPDATE/DELETE`, sequences, types, control-table
reads, and every RLS policy. Include the exact memberships RLS path without
recursive policy calls, audit insert policy, and pair/ledger transition
privileges. State which policies are permissive/restrictive and how they
compose with existing authenticated policies. Transfer ownership only via a
controlled migration identity that is not an application/worker member.
Use fully qualified objects in every definer body and a fixed path that
explicitly accounts for `pg_temp` (last) or otherwise proves all relation
references are qualified. Revoke defaults and test effective privileges.

**Disposition:** Blocks implementation authorization. The contract is
incomplete by design; catalog and deployment role closure remain
environment-verification requirements.

### 1P-8 — High: historical pair outcome classification can silently invent terminal truth

**Exact Stage 1O contract:** §4.2 promotes an accepted/rejected registry state
from candidate statuses where the outcome is “uniquely consistent”; it marks
pending candidates superseded in mapping metadata. For missing/cross-tenant
sources it proposes conflict classification, while each mapping requires a
non-null pair-registry FK. §4.3 says batches compare “decisions and audit
references” but gives no matching rule.

**Repository evidence:** the existing
[accept action](../examples/nextjs/lib/actions/reconciliation.ts) marks a
candidate accepted before entity creation/linking; subsequent identifier
insert/update results are not all checked before the separate audit call.
The current candidate table preserves direction and has pending-only
directional uniqueness. The old worker writer in
[the worker security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql)
uses ordered `(record_a_id, record_b_id)` candidate inputs.

**Concrete failure:** an `accepted` status alone may reflect a partially
completed legacy action, not a fully linked entity or a uniquely authoritative
review decision. A pair with one accepted row and one pending row can be
classified accepted despite incomplete entity links, a missing/failed audit,
or a different reviewer outcome recorded elsewhere. A missing source cannot
reference a normal registry row if that row's source FKs require existing
sources; the proposed mapping's required `pair_id` then cannot be created.
The design also does not define how the existing
`reconciliation_reviewer_decisions` rows and text targets map to candidate
IDs and audit records.

**Required correction:** default every ambiguous, orphaned, cross-tenant,
duplicate, partially applied, or uncorrelated history to a nonreviewable
conflict/exception state. A terminal pair outcome may be inferred only from
an authoritative historical decision with a unique, verified candidate ID,
action, actor, tenant, timestamp, and correlated audit result plus consistent
entity/identifier links. Candidate status alone is not proof. Define a
separate exception mapping that retains a candidate ID and original source
directions when no valid pair registry row can exist. Include explicit
conflict evidence tables and row counts. No candidate, decision, audit row,
status, or timestamp may be rewritten or discarded. Resume is blocked on any
unmapped candidate or unverifiable decision/audit reference.

**Disposition:** Blocks implementation authorization. This is a design
defect; the actual historical distribution is unknown and requires authorized
data inspection later.

### 1P-9 — Medium: request recovery contract is not consistent across the RPCs

**Exact Stage 1O contract:** §2.2 candidate review takes a request UUID as
argument two, while discrepancy resolution takes it as its last argument.
§5.1's canonical tuple encodes only operation, tenant, target type/ID,
decision, and reason. §5.2 describes keyless recovery using a request UUID
and requires current membership.

**Concrete failure:** the discrepancy request has no canonical position for
its resolution, winning source ID, `field_name`, or manual payload. The
`recover_reconciliation_request(uuid)` name does not say whether its input
is a globally unique request UUID or `request_key`; the ledger's unique
constraint is only `(actor_id, request_key)`. If the browser loses its key,
the promised recent-request-list API is not in the externally callable
function list. If membership is revoked, the result exists but is not
recoverable until restoration; that is a valid policy choice only if stated
as the actual guarantee.

**Required correction:** use one request-envelope contract for every
operation: key location/type, versioned canonical fields, digest, actor/
tenant binding, terminal outcome semantics, and recovery identifier. Remove
deferred operations from the externally callable API. Decide whether keyless
recovery means by retained UUID only or an authenticated actor-scoped list;
include the chosen list function in the grants and caller inventory if
needed. Define actor FK/pseudonymization and expiration so an expired key
cannot silently permit a second terminal action.

**Disposition:** Blocks implementation authorization until the supported
operation set and recovery guarantee are fixed. The UI recovery guarantee is
also an owner decision.

### 1P-10 — High: migration and lifecycle ordering does not fit the existing objects

**Exact Stage 1O contract:** §§7 and 9 describe parent keys, typed decisions,
audit links, request ledger, source uniqueness, and coordinated deletion, but
do not specify how the existing decision table and current FKs are altered.

**Repository evidence:** `reconciliation_reviewer_decisions` already exists
with `reviewer_id NOT NULL REFERENCES auth.users ON DELETE SET NULL` and a
company FK `ON DELETE CASCADE` in
[the reconciliation schema migration](../supabase/migrations/20261029000001_reconciliation_module.sql).
Entities, identifiers, source records, candidates, and discrepancies also
have cascade relationships. The audit table has its bigint identity described
in 1P-5. Current retention cleanup deletes audit rows by age in
[the operations migration](../supabase/migrations/20261030000002_reconciliation_security_ops.sql)
and
[the worker security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql).

**Concrete failure:** new `ON DELETE RESTRICT` constraints may be layered
over existing cascades without removing them; company deletion can still
cascade to provenance. The reviewer FK's `SET NULL` conflicts with its
`NOT NULL` column. A deferred audit FK to a missing UUID audit key cannot be
created on the current bigint key. Retention cleanup may fail under
`RESTRICT`, or may delete an audit record still required by a decision. A
source `UNIQUE(company_id,source_record_id)` cannot be added until duplicate
source identifiers are classified, and the order for its parent key and
composite FKs is underspecified.

**Required correction:** provide a catalog-aware alter plan for existing
tables, columns, FK names/actions, and historical rows. Sequence parent
unique keys only after duplicate preflight, add child indexes after columns
exist, then composite FKs and validation. Define nullable/legacy decision
columns, existing decision/audit mappings, and exactly how cascade constraints
are removed/replaced. Make the authoritative audit/decision retention
operation transactional and FK-aware. Specify archive-only company behavior;
physical purge remains blocked pending owner/legal approval. Define reviewer
pseudonymization without impossible `NOT NULL`/`SET NULL` combinations.

**Disposition:** Blocks implementation authorization. Migration design is
incomplete; duplicate data, deployed constraint names, and retention
configuration require environment inspection and owner/legal decisions.

### 1P-11 — Medium: caller and privilege closure omits Storage paths

**Exact Stage 1O contract:** §6 lists application exports, imports, and the
import-download Edge Function but does not identify Storage object writes,
reads, signed URLs, or object policies.

**Repository evidence:** `exportEntity` in
[the reconciliation Server Actions](../examples/nextjs/lib/actions/reconciliation.ts)
uploads an export and creates a signed URL. The
[import upload form](../examples/nextjs/app/dashboard/reconciliation/imports/upload-form.tsx)
uploads import files directly to Supabase Storage. The
[import-download Edge Function](../supabase/functions/import-download-url/index.ts)
creates a signed download URL using a service-role client.

**Concrete failure:** a table-only caller inventory can preserve database
reads while a Storage policy/grant change breaks uploads or enables
cross-company object reads. Conversely, a service-role signing path can
bypass object RLS unless authorization and object path binding are checked
before signing.

**Required correction:** add each Storage caller, bucket, object-path format,
actor/JWT or service-role identity, invoker, secret holder, policy, and
read/write/sign scope to the inventory. Verify company binding and file
ownership before service-role signing. Include object retention and cleanup
in the lifecycle and test proposal. Do not infer deployed bucket policies
from source code.

**Disposition:** Blocks a permission-cutover authorization. This is an
inventory defect; actual bucket policy and credential configuration require
authorized environment verification.

## 5. Historical finding closure matrix

The classifications below reassess the Stage 1O on-paper claims against
Stage 1N and repository evidence. “Resolved” concerns only the specific
design defect, not implementation or environment verification.

### 5.1 Stage 1N findings

| Finding | Stage 1O claim | Stage 1P classification | Reason |
|---|---|---|---|
| 1N-1 Executor, RLS, helpers, grants | §2 supplies roles, helpers, and policies | Unresolved | Membership helper lacks SELECT/RLS/locking grants; audit insert policy and pair/ledger grants are missing |
| 1N-2 Audit integrity | §3 supplies a reserved set and deferred one-to-one FKs | Unresolved | Audit ID type conflicts with existing `bigint`; required decision link breaks generic events; actual action labels are not reserved; no executor INSERT policy |
| 1N-3 Worker fence and pair history | §4 supplies fence, pair mapping, and recovery | Unresolved | `current_user` security mode/identity closure is undefined; historical terminal inference and orphan representation are unsafe |
| 1N-4 Idempotency/recovery | §5 supplies canonical request envelope and recovery | Partially resolved | Candidate operation has a base format, but discrepancy/manual RPC contradicts it and keyless UI recovery remains optional |
| 1N-5 Caller/privilege inventory | §6 lists broad app/worker/Edge/cron paths | Partially resolved | Storage operations and exact grants/function owners are missing; deployment completeness correctly remains unverified |
| 1N-6 Schema/lifecycle | §§7/9 supply relationships and sequence | Partially resolved | Existing decision/audit schema, cascade FKs, and retention deletes do not fit the proposed new links |

### 5.2 Earlier findings

| Family | Finding | Stage 1P classification | Reason |
|---|---|---|---|
| L | L1 | Resolved by architecture change, with runtime verification pending | Authenticated JWT remains the primary reviewer identity; no Stage 1P evidence disproves that choice |
| L | L2 | Partially resolved | `auth.uid()` direction is sound, but audit actor correlation remains structurally invalid |
| L | L3 | Unresolved | The database fence can conflate old definer and migrator identity |
| L | L4 | Partially resolved | Durable conflicts are proposed, but discrepant/manual request binding is incomplete |
| L | L5 | Partially resolved | Broader inventory, but Storage and exact runtime privileges remain open |
| L | L6 | Unresolved | Executor membership and audit policies/ACLs do not work as written |
| L | L7 | Partially resolved | Recovery sequencing exists but current FK/retention behavior is not coordinated |
| J | J1 | Resolved for the selected architecture | The user JWT, not a shared service-role gateway, is the proposed reviewer identity |
| J | J2 | Unresolved | Executor has no specified working membership/audit RLS access and incomplete grants |
| J | J3 | Unresolved | Reserved names and audit linkage do not match current schema |
| J | J4 | Unresolved | Fence identity and pair-level serialization are incomplete |
| J | J5 | Partially resolved | Request ledger base exists conceptually; discrepancy payload is not bound |
| J | J6 | Partially resolved | Storage and exact invoker/owner closure remain missing |
| H | H1 | Partially resolved | Source uniqueness/composite keys are stated but not coordinated with existing data/FKs |
| H | H2 | Unresolved | Membership and audit RLS/ACL contract is not executable |
| H | H3 | Unresolved | Existing audit ID/action schema conflicts with proposed link |
| H | H4 | Partially resolved | Pair mapping is proposed, but mixed historical statuses may be misclassified |
| H | H5 | Resolved by architecture change | Direct authenticated PostgREST calls are intended to use the same RPC checks |
| H | H6 | Partially resolved | No complete request envelope or UI/storage-loss recovery contract |
| N | N1 | Partially resolved | Target lookup/membership lock order is not fully executable and lacks privileges |
| N | N2 | Partially resolved | Entity/source/link eligibility and pair-level terminal transitions are incomplete |
| N | N3 | Partially resolved | A broad sequence is given, but existing typed decision columns/table and dependent keys are not resolved |
| N | N4 | Unresolved | Actual enum action names remain callable through generic helpers |
| N | N5 | Partially resolved | Archive/purge distinction is stated, but existing cascade FKs remain unplanned |
| N | N6 | Partially resolved | Ledger/decision/audit references and retention do not yet match actual schemas |
| F | F1 | Unresolved | Executor RLS does not permit membership lookup or audit insert |
| F | F2 | Partially resolved | Source UPDATE is correctly avoided, but membership locking privilege remains incorrect |
| F | F3 | Unresolved | Function and relation grants/dependencies are not closed |
| F | F4 | Unresolved | Exact ownership transfer and legacy function-owner separation are absent |
| F | F5 | Partially resolved | Candidate request binding is specified; discrepancy request is not |
| F | F6 | Unresolved | Membership mutation and reviewer lock do not share an implementable lock contract |
| F | F7 | Partially resolved | Migration steps exist, but existing typed table and audit keys make order indeterminate |
| F | F8 | Partially resolved | Archive and retention intent exists; actual cascades/deletes still conflict |
| F | F9 | Partially resolved | Storage and complete read/permission closure are absent |
| F | F10 | Partially resolved | Request result/recovery semantics differ between candidate and discrepancy APIs |
| F | F11 | Partially resolved | Test cases are proposed but omit a successful membership-revocation race and do not validate the contradictory contracts |

## 6. Unresolved owner and environment decisions

| Item | Classification | Required decision or evidence | Blocks |
|---|---|---|---|
| Membership authorization method | DESIGN DECISION | Choose advisory-lock-plus-trigger or an explicitly bounded row-lock privilege; define lock order and role lookup | All reviewer RPCs |
| Manual discrepancy JSON | DESIGN DECISION | Defer it or approve an exact canonical format, size/type limits, and representation | Discrepancy reviewer RPC |
| Pair state transitions | DESIGN DECISION | Define one terminal decision per unordered pair, replay/conflict results, and entity/link conflict handling | Reviewer and matching writers |
| Fence role graph | DESIGN DECISION + ENVIRONMENT VERIFICATION | Define distinct legacy/new/migrator owners; verify every deployed function owner and membership | Backfill and worker resume |
| Audit schema | DESIGN DECISION | Retain bigint `audit_log` key or introduce a separate workflow audit relation; make nonworkflow events compatible | Audit writer and all callers |
| Historical outcome proof | DESIGN DECISION + ENVIRONMENT VERIFICATION | Define authoritative evidence criteria and inspect actual candidate/decision/audit records only after authorization | Pair backfill |
| Storage grants/policies | ENVIRONMENT VERIFICATION | Enumerate bucket policies, API roles, object naming, and all service-role secret holders | Import/export cutover |
| Retention and deletion | OWNER and LEGAL/PRIVACY DECISION | Approve retention and erasure/pseudonymization model; no duration is assumed | Company purge, audit cleanup, ledger expiry |
| Migration-06 provenance | ENVIRONMENT VERIFICATION | Authorized target-specific provenance inspection only; no reconstruction | Migration planning |
| Hosted Supabase state | ENVIRONMENT VERIFICATION | Inspect only after separate authorization; no repository claim establishes it | Any hosted work |

## 7. Exact recommended next step

Produce a Stage 1Q design amendment that corrects findings 1P-1 through
1P-11, with priority order:

1. Make membership authorization and the writer fence executable under
   explicit, disjoint role identities.
2. Define one canonical pair-level state machine and a conservative,
   lossless historical classifier.
3. Redesign the decision/audit relation around the existing audit key and
   ordinary operational audit events; enumerate every actual reserved action.
4. Remove manual JSON discrepancy resolution from the public contract until
   request canonicalization is fully specified.
5. Reconcile all proposed privileges, RLS policies, migration steps, current
   constraints, retention, and Storage callers.

Then obtain another independent documentation-only review. Do not begin
implementation authorization review until no Critical or High design issue
remains and owner/legal/environment prerequisites are separately authorized
and resolved.

## 8. Validation and completion record

- Markdown links: validated local targets; no missing local links.
- Markdown anchors: no local fragment links used; none to validate.
- Code fences: zero; balanced.
- Trailing whitespace: none.
- `git diff --check`: passed; Git emitted only the pre-existing LF-to-CRLF
  warning for `examples/nextjs/app/auth/signup/page.tsx`.
- Worktree status: the existing modifications and untracked files were left
  untouched; the only file added by this task is this Stage 1P report.
- No implementation, tests, SQL, database operations, hosted Supabase access,
  migration activity, deployment operations, or migration-06 reconstruction
  were performed.

