# ZamBase Phase 2A.3.4 — Stage 1G Design Amendment

> **Design only.** This amendment does not authorize application changes,
> migration creation or execution, database access, or changes to roles, grants,
> functions, policies, indexes, or data. It amends the design in the
> [Stage 1E blueprint](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md)
> in response to the
> [Stage 1F final review](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md).
> Stage 1C and 1D remain historical evidence and are not changed.

## 1. Executive summary and verdict

**Verdict: NO-GO for Stage 2 implementation.**

The Stage 1F findings require six concrete design corrections. This amendment
provides a proposed lock/authorization sequence, entity eligibility rules,
auditing controls, corrected migration ordering, deletion/retention safeguards,
application contracts, and additional tests. It does not convert repository
observations into hosted-database facts, nor does it claim that the proposed
executor and helpers have been executed or proven safe.

The main remaining blockers are:

1. The application must resolve whether the browser's authenticated database
   role may execute narrowly scoped review RPCs. The user requirement to deny
   clients access to those RPCs conflicts with the current Next.js action
   architecture, which calls Supabase using the user's authenticated session.
   A server-only gateway is an alternative, but its identity-bridging trust
   contract and platform feasibility are not verified.
2. The exact deployed owner/role memberships, `FORCE ROW LEVEL SECURITY`
   behavior, privileges, helper ownership, and PostgREST grants have not been
   verified in the intended hosted project.
3. Migration `20261101000006_enforce_import_finish_lease` is still missing.
   It must not be reconstructed or applied until provenance and migration
   history are resolved.
4. Company deletion, source-record retention, reviewer erasure, and historical
   decision retention require an explicit product/legal policy and a full
   cascade rehearsal.
5. Local implementation tests, hosted migration-runner behavior, and the final
   app cutover have not been performed.

No hosted project is identified. No credentials, environment variables, or
secrets were inspected or printed for this amendment.

## 2. Scope, evidence labels, and invariants

The design covers match accept/reject, narrowly scoped entity confirmation,
their typed reviewer decisions and audit events, and the required application
cutover for those writes. It does **not** broaden match RPCs into entity
merging, discrepancy resolution, source ingestion, or worker candidate
generation.

Evidence labels used below:

- **Repository-verified:** supported by checked-in or current-worktree source.
  The worktree contains pre-existing modifications and untracked files; those
  states are not attributed to this task.
- **Prior local finding:** reported in Stage 1A/1B from the local database or
  CLI. It is not a fresh database check and does not establish hosted state.
- **PostgreSQL 15 behavior:** a documented engine contract, not evidence that
  the target deployment has the expected grants or configuration.
- **Proposed / unverified:** a design requirement that must be tested before
  implementation authorization.

Business invariants:

- No automatic merge, canonical-value overwrite, or survivorship selection.
- Source records remain immutable; accepted matches create provenance links.
- No silent reassignment away from an existing link.
- A soft-deleted, merged, or rejected entity is never silently restored,
  redirected, or reused by match acceptance.
- A decision and its authoritative audit event commit or roll back together.
- No worker receives unrestricted table access or `BYPASSRLS`.
- Unknown SQL errors are errors, never success-shaped results.

## 3. Stage 1F findings N1–N6

| Finding | Amendment | Status / remaining gate |
|---|---|---|
| N1 — Candidate lock precedes current authorization | §7 establishes identity and locks current membership before any candidate row lock. Tenant discovery is membership-gated and non-locking; candidate locking is a later, trusted helper call. | Proposed; verify two-session behavior and exact helper ownership/grants. |
| N2 — Entity eligibility is undefined | §8 allows only active `candidate` or `confirmed` entities; rejects missing, deleted, `merged`, and `rejected` states without redirect/restoration. | Proposed business rule; product owner must approve and tests must pass. |
| N3 — Typed child indexes precede their columns | §11 orders typed nullable columns and compatible checks before indexes and constraints that reference those columns. | Corrected design; inspect actual historical rows/FKs before migration. |
| N4 — Generic audit events can be forged | §9 separates authoritative workflow events from generic caller-supplied audit; generic `log_audit` must reject workflow-owned action values for every non-trusted caller. | Requires caller inventory, a safe transition, and a forged-event test. |
| N5 — Company cascade conflicts with source immutability | §12 rejects hard-delete/cascade as the default. Tenant archive/tombstone and retention are proposed pending owner/legal approval and full-FK rehearsal. | Unresolved policy and schema compatibility; blocks deletion-related rollout. |
| N6 — New typed decisions may omit idempotency key | §10 requires non-null keys for every new typed accept/reject decision while preserving legacy rows. | Proposed; constraint must be validated against existing rows before enforcement. |

These are corrections to the prior design, not verified deployed behavior.

## 4. Residual Stage 1D findings F1–F11

| Finding | Stage 1G disposition | Evidence still required |
|---|---|---|
| F1 — Tenant-scoped executor RLS | Retain only company-scoped policies and the restricted context mechanism in §6; no unrestricted executor policy. | Execute under the actual forced-RLS executor and prove cross-tenant denial. |
| F2 — Row-lock privileges | Use narrowly scoped trusted lock helpers in §7; do not grant source-table UPDATE to make `FOR UPDATE` compile. | Verify helper owner capabilities, grants, locks, and return values in local integration tests. |
| F3 — Helper/audit grants | §6 lists the minimum helper, type, schema, and audit-wrapper grants. | Compare actual ACLs, including `PUBLIC`, inherited grants, and function defaults. |
| F4 — Ownership transfer | Use the staged temporary-grant/ownership transfer procedure in §13, only after platform capability is inspected. | Hosted role membership, schema CREATE, ownership transfer, and cleanup remain unknown. |
| F5 — Idempotency | §10 chooses committed-decision-only keys and defines replay/mismatch behavior. | Test uniqueness races and lost-response replay. |
| F6 — Membership race | Membership is locked and role-checked before candidate locking (§7). | Verify concurrent delete/downgrade semantics under chosen isolation and enforce the two-session test. |
| F7 — Typed-column migration order | §11 adds columns and checks before dependent indexes/FKs. | Validate old rows and all existing FK actions. |
| F8 — Child indexes and lifecycle | §11 specifies child-side indexes; §12 gates entity/company/account deletion. | Inspect the live constraints and rehearse every destructive lifecycle path. |
| F9 — Other app write paths | §14 gives the scope boundary and cutover rows, including confirmation and deferred discrepancy handling. | Complete caller inventory and implement every in-scope replacement before revocation. |
| F10 — App key lifecycle and UX | §15 defines the request/response contract and persistence behavior. | Implement and test timeout, replay, conflict, and authorization UX. |
| F11 — Test gaps | §16 includes privilege, RLS, locking, concurrency, migration-recovery, and retention tests. | Tests are plans only; none are authorized or reported as passing here. |

Finding text and evidence are in the
[Stage 1D findings](./PHASE-2A-3-4-STAGE-1D-DESIGN-VERIFICATION.md#L49)
and the
[Stage 1F review](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md#L190).

## 5. Corrected security and role architecture

### 5.1 Roles and trust boundaries

The proposed `reconciliation_workflow_executor` remains a `NOLOGIN`,
`NOBYPASSRLS` role, not granted to `authenticated`, `anon`, `service_role`,
workers, scheduler, or application connection roles. It is the owner of the
two workflow decision functions only if the target platform permits a verified
ownership transfer. It is not a general-purpose application identity.

Trusted row-lock helpers and the authoritative audit wrapper are proposed as
separate narrowly scoped `SECURITY DEFINER` functions owned by `postgres`,
with fixed empty `search_path`, fully qualified object references, explicit
input validation, and no dynamic SQL. Their use of elevated owner privileges
is a security-sensitive design dependency, not an assumed safe default.
They must not expose arbitrary row lookup, arbitrary SQL, or unrestricted
tenant data.

### 5.2 Workflow RPC access decision

There are two possible invocation designs, and they cannot be silently
combined:

1. **Authenticated RPC design (recommended only if “client access” means
   direct table access):** grant `authenticated` EXECUTE only on the exact
   accept/reject and confirmation functions. The functions derive
   `auth.uid()`, verify membership and current owner/admin role in the
   database, return no cross-tenant detail, and perform no caller-selected
   tenant operation. Revoke all direct decision-table DML. Workers and
   scheduler receive no EXECUTE. A logged-in user can still call the narrow RPC
   directly; authorization is enforced in that function.
2. **Server-only RPC design (required if clients must have no RPC EXECUTE):**
   only a dedicated server gateway may invoke the functions. The gateway must
   establish the real user identity from a verified Supabase session and pass
   it over a channel clients cannot forge. The database must authenticate the
   gateway separately from the actor and must not treat a caller-supplied user
   UUID as proof of identity. The current action's user-JWT `auth.uid()`
   contract cannot simply be reused under a service-role JWT. This design needs
   a separately specified and tested identity bridge; no such bridge or
   dedicated gateway is currently established by the evidence.

**Blocking interpretation:** until the product/security owner chooses one
design, the privilege matrix in §6 cannot be finalized. Under design 1, the
word “deny client access to workflow RPCs” must be changed to “deny direct
table access and deny unauthorized RPC outcomes.” Under design 2, the
server-only identity bridge must be specified and validated before the SQL
contract can be considered implementable.

### 5.3 Fixed `SECURITY DEFINER` requirements

For each workflow and helper function:

- Set `search_path = ''`; qualify every table, type, function, operator where
  needed, and sequence.
- Revoke EXECUTE from `PUBLIC`; explicitly grant only the selected invocation
  role and the workflow executor where required.
- Check `auth.uid()` before tenant or candidate data access in authenticated
  invocation mode. A null identity is an authorization failure.
- Do not accept `company_id`, reviewer identity, role, or tenant context from
  the browser as authoritative. Tenant is derived from the candidate through
  a membership-gated lookup. Reviewer is the verified JWT subject.
- Any executor RLS context is set by the function only after locked
  authorization. Policies must not trust an unvalidated caller-set GUC.
- Keep error messages uniform for nonexistent, cross-tenant, and unauthorized
  candidates to avoid tenant or candidate enumeration.
- No function changes session authorization or grants membership to the
  executor. No caller receives the executor role.

## 6. Corrected RLS and privilege matrix

This is the minimum proposed delta for the workflow tables, not a statement of
current grants. Existing names and exact columns must be reconciled against the
actual target catalog before implementation.

| Role | Direct table access for workflow tables | Workflow function EXECUTE | Other access |
|---|---|---|---|
| `anon` | No SELECT/INSERT/UPDATE/DELETE | None | No helper or audit-wrapper EXECUTE. |
| `authenticated` | SELECT only where existing tenant RLS permits; no direct INSERT/UPDATE/DELETE on candidates, entities, identifiers, reviewer decisions, or audit rows. | Design 1: only narrow workflow functions. Design 2: none. | `auth.uid()`/membership read helpers only as already required by read paths; no lock-helper or audit-wrapper EXECUTE. |
| `service_role` | Revoke direct workflow-table DML and unnecessary SELECT; verify inherited grants and `BYPASSRLS` status instead of assuming ACL revocation alone is sufficient. | None unless it is explicitly selected as the server gateway; if so, only the separately designed gateway entry point. | Preserve unrelated operational RPC access only after caller inventory. |
| `reconciliation_import_worker` | No direct table privileges. | None on decision/confirmation functions. | Existing import RPC grants only; preserve them and test them. |
| `reconciliation_matching_worker` | No direct table privileges. | None on decision/confirmation functions. | Existing matching/candidate-generation RPC grants only. |
| `reconciliation_scheduler` | No direct table privileges. | None on decision/confirmation functions. | Existing scheduler entry point only; no reviewer decision or entity-link path. |
| `reconciliation_workflow_executor` | Minimum column-level SELECT/INSERT/UPDATE for workflow effects, as listed below; no DELETE. RLS remains forced and tenant-scoped. | Owns and can invoke only required internal helpers. | `NOLOGIN`, `NOBYPASSRLS`; not a member of worker/service roles. |
| `postgres` (trusted function owner) | Elevated function-owner capability only. | Owns lock/audit helpers; never expose those helpers to clients. | Do not assume hosted migration role can become or act as `postgres`. |

### 6.1 Executor table/column grants and RLS

The workflow executor needs these operations, scoped to a verified company:

| Table | Executor operations | Column/policy restrictions |
|---|---|---|
| Match candidates | SELECT; UPDATE only `status`, decision timestamp/reviewer, and any required result-entity reference. | RLS `USING`/`WITH CHECK` restricts `company_id` to the verified transaction context; never update source IDs, normalized pair identity, score, or company. |
| Source records | No direct UPDATE/DELETE. No direct SELECT if lock helper returns the limited immutable fields required. | Trusted helper locks only the exact candidate's source IDs within its company and returns IDs/company/link facts only. |
| Entities | SELECT; INSERT for a new empty canonical entity; no general UPDATE if possible. | Company-scoped. New entity has empty canonical JSON/attributes, active `candidate` status, neutral/manual-review survivorship rule, and no copied source values. |
| Entity identifiers/links | SELECT and INSERT only. | Tenant-scoped; unique source-record link; never UPDATE a link to point elsewhere and never DELETE it. |
| Reviewer decisions | SELECT and INSERT only. | Insert only typed accept/reject rows with current actor, candidate, target/result entity, action, and required idempotency key; no UPDATE/DELETE. |
| Audit log | No direct table grant if the dedicated audit wrapper owns insertion. | Append-only policies; executor cannot update/delete audit entries. |
| Memberships | No direct general table access if the authorization/lock helper returns a narrow role result. | Helper locks only the caller's membership for the derived tenant; role is checked from the locked tuple. |

Required policy pattern: enable and **force** RLS on every affected table. Add
per-command policies only for executor operations above. Each policy must
predicate on the verified company context (for example, equality with a
transaction-local company ID set by the verified function), and INSERT/UPDATE
must enforce the same tenant in `WITH CHECK`. There must be no `USING (true)`,
no unrestricted role-wide policy, and no broad `TO PUBLIC`. Any context helper
used by an RLS policy is itself fixed-path, returns only the previously
authorized company, and is executable only in the required definer chain.
Functions must set/overwrite context after locking and authorization before
accessing executor-protected rows; a caller-set GUC must never authorize a
request.

### 6.2 Required schemas, types, and helper EXECUTE

Before granting the executor any access, inspect all actual object ACLs and
function signatures. The intended minimal capabilities are:

- `USAGE` on `public` and on every schema containing a referenced function or
  type. If the workflow directly calls `auth.uid()`, `USAGE` on `auth` plus
  EXECUTE on the exact `auth.uid()` signature is required. If only a trusted
  helper calls it, grant the helper owner what it needs and do not grant it to
  the executor unnecessarily.
- `USAGE` on `public` enum types used in function arguments, table columns, or
  casts (including decision/action/status types actually present in the target
  catalog). Verify the exact type names first.
- EXECUTE only on exact helper signatures required by the chosen call graph:
  the authorization/tenant discovery helper, row-lock helpers, and the
  authoritative audit wrapper. No blanket function grant.
- Audit-wrapper EXECUTE only from the workflow executor (or the selected
  dedicated gateway architecture), with the wrapper deriving actor identity
  from the verified context rather than accepting arbitrary actor/action
  values.
- Explicit `REVOKE ... FROM PUBLIC, anon, authenticated, service_role,
  reconciliation_import_worker, reconciliation_matching_worker,
  reconciliation_scheduler` on lock and audit helpers, followed by only the
  necessary explicit grant.

The exact permissions and owner capabilities are deployment-dependent and
must be read from `pg_roles`, `pg_auth_members`, `information_schema` and
`pg_catalog` ACLs on the intended local/staging target. Stage 1B local findings
do not establish hosted state.

## 7. Corrected authorization and lock sequence

### 7.1 Identity and tenant discovery without a pre-authorization candidate lock

For authenticated invocation mode, use this order:

1. Require non-null `auth.uid()`; do not trust a submitted reviewer UUID.
2. Call a narrowly scoped, trusted `SECURITY DEFINER` authorization helper
   with only the candidate UUID and verified `auth.uid()`.
3. The helper performs a **non-locking** candidate lookup whose predicate
   includes an `EXISTS` membership row for that same `auth.uid()` and
   `candidate.company_id`. It returns no company ID or candidate facts if that
   membership predicate fails; nonexistent and cross-tenant IDs have the same
   external result.
4. Using the discovered company, the helper selects the exact membership row
   for `(company_id, auth.uid()) FOR SHARE`, then checks `role IN ('owner',
   'admin')` from that locked row. The role check must not use a prior
   unlocked helper result.
5. Return only `(company_id, reviewer_id, role)` after authorization succeeds.
   A candidate lookup is not locked at this stage. A concurrent membership
   removal/downgrade either commits before the membership lock and causes
   denial, or waits until the decision transaction ends.
6. Acquire the transaction-scoped idempotency advisory lock and check for a
   committed replay as in §10. A replay still requires current authorization.
7. Only for a new key, lock the candidate through the trusted lock helper,
   verifying its company still equals the authorized company.
8. Lock all candidate source rows in ascending UUID order, then any existing
   linked entity rows in ascending UUID order. Re-read all links and status
   after these locks. Lock any entity to be linked/updated before deciding the
   final outcome.
9. Insert the new entity if needed, insert provenance link(s), insert typed
   decision and authoritative audit event, update the candidate state, then
   return. The transaction is atomic.

This sequence prevents an ordinary member from acquiring a candidate row lock
and blocking an authorized reviewer before being rejected. It also avoids
accepting a company ID from the caller. The initial membership-gated lookup
must be proven not to return tenant-specific details or lock candidate rows.

### 7.2 Trusted lock helper contract

Proposed helpers are owned by `postgres`, `SECURITY DEFINER`, fixed empty
`search_path`, and fully qualified. Their final owner and capability must be
verified on the target; if `postgres` ownership or required grants are
unavailable, stop and redesign rather than substitute a broader role.

| Helper | Arguments | Checks and locks | Returned information | EXECUTE |
|---|---|---|---|---|
| `authorize_reconciliation_review(candidate_id uuid, actor_id uuid)` | Candidate ID and actor from `auth.uid()` inside the caller; actor must equal `auth.uid()` in authenticated mode. | Membership-gated non-locking candidate tenant lookup; locks exact current membership `FOR SHARE`; verifies locked role owner/admin. | Authorized company ID and actor ID only. No candidate/source fields. | Workflow functions only. |
| `lock_reconciliation_candidate(candidate_id uuid, company_id uuid)` | Authorized candidate/company only. | Rechecks candidate belongs to company and locks candidate `FOR UPDATE`; must be called after authorization and idempotency replay check. | Candidate ID, two source IDs, current pending status, and current result link/state needed for the decision. | Workflow executor functions only. |
| `lock_reconciliation_sources(company_id uuid, source_ids uuid[])` | Company and exact IDs returned by the candidate helper. | Rejects null/duplicate/unexpected IDs; locks matching source rows in ascending UUID order `FOR UPDATE`; confirms every requested ID exists in that tenant. | Source IDs and existing immutable link/entity IDs only. No source payload. | Workflow executor functions only. |
| `lock_reconciliation_entities(company_id uuid, entity_ids uuid[])` | Company and exact linked/target IDs found after source locks. | Locks rows in ascending UUID order; rechecks tenant, `deleted_at`, and status. | ID, status, deletion marker, and required link count only. | Workflow executor functions only. |

No source-table UPDATE privilege is granted to the executor merely to satisfy
PostgreSQL's row-locking privilege requirement. PostgreSQL 15 requires a
locking `SELECT` to have SELECT and UPDATE privilege on at least one column of
the locked table; the trusted helper is the explicit exception to that
privilege boundary. Lock helper calls must be in the same transaction as the
decision. They must not catch errors and return empty/success-shaped rows.

If the helper executes under an owner that bypasses RLS, its tenant predicate,
actor authorization, argument bounds, and narrow return shape are mandatory
defense-in-depth; function ownership is not itself proof of safety.

### 7.3 Lock order and transaction isolation

Canonical lock order for all human review functions:

1. Membership row (`FOR SHARE`).
2. Candidate row (`FOR UPDATE`).
3. Source rows, ordered by UUID (`FOR UPDATE` in helper).
4. Existing/target entity rows, ordered by UUID (`FOR UPDATE` in helper).
5. Unique/index conflicts and inserts.

All paths must follow this order. A candidate is not locked before the
membership row is authorized. `READ COMMITTED` is the proposed isolation
baseline; each row is re-read after its lock, and uniqueness constraints
remain authoritative. `SERIALIZABLE` is not required for correctness if the
lock and unique-key invariants are implemented, but if selected it requires
full `40001` retry handling. The actual Supabase transaction wrapper and
PostgREST statement transaction semantics must be verified.

An admin membership row `FOR SHARE` conflicts with updates/deletes that change
or remove that row. Thus a membership downgrade/removal that wins first denies
the decision; if the decision's lock wins first, the revocation waits until
the decision commits. This is a linearization rule, not an assumption that
revocation retroactively cancels an in-flight authorized operation.

## 8. Entity eligibility and soft-delete policy

An entity may be a match acceptance target only if, after its row lock:

- it belongs to the authorized company;
- `deleted_at IS NULL`;
- status is exactly `candidate` or `confirmed`.

`candidate` is allowed so multiple explicitly accepted source records can
establish provenance before the entity is confirmed. `confirmed` is allowed
because a human may add provenance without changing its canonical values.
Status `merged` and `rejected`, any soft-deleted row, an unknown/future enum
state, or a missing/cross-tenant row produces a conflict/denial. No lookup
follows a merge pointer. No acceptance revives or changes a deleted entity.
This is a proposed business rule and requires owner approval.

If a source record is already linked to a soft-deleted entity, acceptance
returns a stable `entity_unavailable` conflict. Preserve the existing link;
do not delete, update, reassign, or count it as a new link. Restoring an entity
requires a separate authorized restoration operation, audit event, and
explicit review; restoration is outside this milestone. Historical links and
decisions remain intact.

`record_count` is derived from active provenance links to the entity, with a
precise agreed definition: count source-record links whose entity is not
soft-deleted, without double-counting duplicate identifiers. Prefer a query
over cached data; if a stored counter exists, update it atomically and add a
reconciliation/repair check. This definition must be checked against the
current schema and UI meaning before deployment.

Review screens and exports must filter soft-deleted entities by default,
label any retained historical link as unavailable/deleted, and never expose
deleted canonical data as a current target. Historical audit/decision views
may include deleted entities with an explicit deleted marker and suitable
authorization. Entity list, review and export behavior needs tests before
changing visibility.

## 9. Audit authenticity and atomicity

### 9.1 Authoritative workflow events

Accept/reject functions write their typed decision and authoritative audit
record in the same transaction. Use a dedicated audit wrapper that:

- accepts only a fixed event type/action for the specific workflow function;
- derives actor and company from the already verified context;
- derives target candidate/entity IDs from locked rows and inserted decision;
- does not accept arbitrary actor, tenant, action, target table, or metadata
  from application input;
- writes a minimal, non-sensitive payload; and
- raises on any insert failure so the entire transaction rolls back.

The wrapper is owned by the trusted owner described in §7, uses empty
`search_path`, and is executable only by the workflow executor (or the
separately approved gateway). The workflow action itself is the authoritative
event only when correlated to a matching typed decision and expected target.

### 9.2 Generic audit anti-forgery

Before cutover, inventory every `log_audit` caller and payload. The current
repository has generic calls in reconciliation server actions and invitation
functions, and documentation also demonstrates calls. The migration must
prevent all non-trusted callers—including `authenticated` and
`service_role`—from submitting workflow-owned actions such as
`match.accepted`, `match.rejected`, or the dedicated typed decision action.
Revoke the general function from a caller only after its legitimate actions
have a replacement; do not break unrelated invitation or entity workflows.

The exact guard must be enforced inside `log_audit` or by an equivalent
database constraint/wrapper, not merely by hiding UI. In addition, analytics
and audit consumers must classify an event as authoritative only when a
matching typed decision exists. Workflow-owned values from generic calls must
be rejected, not silently relabeled. Preserve an explicit migration plan for
historical rows, which cannot be retroactively authenticated by this design.

Any audit error, including wrapper permission failure, is fatal to the
decision transaction. Do not catch it and return an accepted/rejected result.

## 10. Decision, idempotency, and error contract

### 10.1 Decision semantics

`accept_reconciliation_match(candidate_id uuid, idempotency_key uuid)`:

- requires the verified actor to be current owner/admin of the candidate's
  company under the locked membership row;
- locks candidate, source records, and any existing entities in §7 order;
- accepts only a pending candidate (or returns replay for the exact prior
  committed decision);
- detects any source already linked to a different entity and returns an
  explicit conflict without changing that link;
- either links to one eligible existing entity or creates a new entity with
  empty canonical data and neutral/manual-review survivorship;
- inserts provenance links, typed `accept` decision, and authoritative audit
  event atomically; updates candidate decision state; and never merges,
  overwrites, restores, or redirects canonical records.

`reject_reconciliation_match(candidate_id uuid, idempotency_key uuid)`:

- applies the same actor/tenant/membership lock rules;
- locks candidate then source rows in the same order;
- rejects only a pending candidate (or returns exact replay);
- inserts the typed `reject` decision and audit event and updates candidate
  decision state atomically;
- creates no entity, identifier, or source-record link.

Any existing function signature that differs must be migrated only after
checking PostgREST overload resolution and all callers.

### 10.2 Committed-decision-only idempotency

Choose **committed decisions only**; conflicts and failed requests do not
reserve keys. The unique scope is
`(company_id, reviewer_id, idempotency_key)`. Every newly inserted typed
accept/reject decision (`candidate_id IS NOT NULL`) must have a non-null
key. Preserve legacy rows with `candidate_id IS NULL`; validate existing
typed rows before adding/enforcing the constraint.

Acquire a transaction-scoped advisory lock from a stable, documented encoding
of company UUID, reviewer UUID, and key UUID. Use a collision-resistant
mapping to the two signed 32-bit advisory-lock keys (for example, a fixed
versioned hash over the 48 UUID bytes); collisions may serialize unrelated
requests but must never equate their idempotency identities. The unique
constraint—not the hash—defines identity. Verify identical encoding across
all function versions and test known vectors.

After authorization and before candidate locking, look up the scoped key:

- Same key, same candidate, same action: return `replayed` with the original
  committed decision/result and do not duplicate links or audit events.
- Same key, different action or candidate: return
  `idempotency_key_reused`; do not reinterpret it or create a second decision.
- No committed row: proceed; any later conflict/error rolls back and leaves
  the key available for a new explicit intent.

The application creates a UUID once per user intent and persists it before
submission. A network timeout or lost response retries with the same key,
candidate, and action. A user changing the candidate/action creates a new key.
After a definitive conflict or result, the UI may close the intent and create
a new key for a new action. Do not infer success from a timeout.

### 10.3 Error mapping and retry

Expected outcomes are typed results: `accepted`, `rejected`, `replayed`,
`conflict`, `unauthorized`, and `not_found_or_unavailable`. Conflict codes
include `candidate_already_decided`, `source_already_linked`,
`entity_unavailable`, and `idempotency_key_reused`. Do not reveal whether a
cross-tenant candidate exists.

Retry SQLSTATE `40P01` (deadlock) and `40001` (serialization failure) using a
bounded application retry with jitter and the exact same idempotency key,
candidate, and action. After the retry budget, return a retryable failure and
retain the key. Unique violations must be mapped only when the exact expected
constraint is identified; all unexpected constraint, privilege, audit, or
SQL errors propagate as failures and must never be converted into success,
`replayed`, or a generic conflict.

## 11. Corrected schema and migration ordering

This is a dependency order, not executable SQL and not authorization to
reconstruct migration 06.

1. **Preflight and baseline.** Snapshot local and target schema, extension and
   enum definitions, table/column ACLs, role attributes/memberships, RLS and
   `FORCE RLS`, function owner/config/ACL, indexes including invalid indexes,
   constraints, and migration history. Check all existing rows against the
   proposed invariants. No data rewrite or deletion is implicit.
2. **Resolve migration-history gap.** Inspect the recorded SQL and checksum
   evidence for `20261101000006_enforce_import_finish_lease`, compare current
   function definition and Git history, and identify the intended hosted
   project through authorized project metadata. Do not fabricate a file,
   mark it applied, or apply recovered SQL until owners approve a provenance
   and reconciliation procedure. See §17.
3. **Parent composite keys.** Ensure parent tables have the unique keys needed
   by tenant-consistent references, such as `(company_id, id)` or
   `(company_id, source_record_id)`, with types/order matching the FK.
   PostgreSQL requires a matching unique or primary key on the referenced
   columns.
4. **Concurrent parent indexes, if needed.** Build eligible unique indexes
   with `CREATE UNIQUE INDEX CONCURRENTLY` only as standalone statements
   outside an explicit transaction, after duplicate preflight. If a valid
   unique constraint is needed, attach it in a later ordinary transactional
   migration using `ALTER TABLE ... ADD CONSTRAINT ... USING INDEX`, where
   supported by the exact target shape. Record and inspect invalid remnants
   before retry.
5. **Nullable typed decision columns.** Add candidate/result entity/action
   references and idempotency key columns first, initially nullable where
   needed for historical compatibility. Do not create indexes or constraints
   that reference a column before it exists.
6. **Compatible checks.** Add checks that distinguish legacy rows from new
   typed rows. New typed accept/reject decisions must have required actor,
   company, candidate, action, result relationship semantics, and non-null
   idempotency key. Legacy rows remain valid only under an explicit legacy
   branch. Use `NOT VALID` only where supported and appropriate, then validate
   after cleanup; do not silently rewrite history.
7. **Pair normalization.** Choose canonical ordering for candidate source
   pairs (e.g. smaller UUID as A, larger as B), prohibit self-pairs, normalize
   all new worker inserts, and reconcile historical reversed pairs before
   enforcing one pair. Match the uniqueness predicate to worker
   `ON CONFLICT` inference exactly; test the existing partial-index predicate
   and every worker version.
8. **Partial unique indexes.** After nullable typed columns exist and data is
   checked, build partial unique indexes for scoped idempotency keys and any
   required active candidate pair invariant. Concurrent build is outside an
   explicit transaction. A key's uniqueness should be enforced across
   committed typed outcomes as chosen, not accidentally only while pending.
9. **Child-side indexes.** Create supporting indexes only after the referenced
   child columns exist. Cover every FK's child columns in matching leading
   order, including company-scoped decision-to-candidate/entity references,
   entity links, and audit/lookup paths needed for deletion checks. These are
   performance and lock-duration controls; FK declarations do not
   automatically create child indexes.
10. **Tenant-consistent composite FKs.** Add composite FKs only after parent
    unique keys and child columns/indexes exist. Use `NOT VALID` then
    `VALIDATE CONSTRAINT` if historical rows require a staged check and the
    actual constraint supports it. Reconcile existing invalid/orphan rows
    explicitly; do not silently delete or reassign.
11. **Delete-action transition.** Inventory existing CASCADE/SET NULL/RESTRICT
    actions and all immutability triggers first. Change delete actions only
    with an approved retention policy and a tested transition; see §12.
12. **Trusted functions and helpers.** Create/replace lock helpers,
    authorization, audit wrapper, and workflow RPCs with fixed path and
    fully-qualified objects. Ownership transfer and temporary privileges
    follow §13 only after hosted capabilities are verified.
13. **RLS and exact grants.** Enable/force RLS and add tenant/command-specific
    executor policies; apply column grants, revoke broad direct DML, and grant
    exact function signatures according to the chosen invocation design.
    Preserve worker/scheduler RPC boundaries and prove compatibility.
14. **Backfill/validation gate.** Any backfill must be separately reviewed,
    reversible where possible, tenant-checked, and audited. Validate checks,
    FKs, index validity, source-link uniqueness, and idempotency before app
    cutover.
15. **Application cutover.** Deploy server actions and result handling while
    old permissions remain only as needed for compatibility. Verify no
    in-scope caller uses direct writes.
16. **Direct DML revocation.** Revoke direct decision DML only after all
    in-scope writers are on tested RPCs and grants are verified. Preserve
    deferred workflows' necessary access explicitly; do not claim the whole
    reconciliation module is closed while discrepancy or other direct paths
    remain.
17. **Post-cutover verification.** Read-only verify function definitions,
    owner/config, grants, policies, valid indexes, constraints, migration
    history, and representative app/worker behavior.

### 11.1 Supabase runner and concurrent-index recovery

Stage 1B reported Supabase CLI 2.119.0 recognizes concurrent index statements
as pipeline-incompatible and runs them outside the normal SQL batch. This is a
**prior local CLI finding**, not a guarantee about the hosted runner/version.
Therefore every concurrent index must be isolated and its execution/history
behavior verified against the exact CLI/deployment workflow. Never assume
`CREATE INDEX CONCURRENTLY` runs inside a transaction; PostgreSQL rejects that.

After an interrupted/failed concurrent build, inspect `pg_index.indisvalid`,
`indisready`, index definition, duplicate rows, and migration history. If an
invalid index remains, stop writes that can compound the inconsistency,
document the state, and remove/rebuild only that specifically identified
index using an approved recovery step. Do not rerun an entire migration
blindly, and do not mark history complete until the expected valid index and
constraints are verified.

## 12. Foreign keys, deletion lifecycle, and retention

Repository-verified schema includes company cascades on reconciliation
tables, while source-record immutability rejects DELETE. This makes a company
cascade that reaches a source row potentially fail; Stage 1F documents the
specific conflict in its
[N5 finding](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md#L329).
The audit log also has `ON DELETE SET NULL` for actor and company references
([base audit schema](../supabase/migrations/20260514000006_audit_log.sql#L10)).
The existing reviewer decision's non-null reviewer ID with `ON DELETE SET
NULL` also needs an explicit lifecycle correction before account erasure is
approved.

Proposed safe default pending approval:

- **Company:** prohibit physical hard delete while retained source,
  provenance, decision, or audit rows exist. Archive/deactivate access at the
  company level, retaining tenant-scoped records. If hard deletion is legally
  required, define a separate audited purge/retention job and prove how
  immutable source records are retained, anonymized, or lawfully destroyed;
  do not rely on ordinary cascading deletion.
- **Entity:** soft delete only through a separately authorized and audited
  operation; preserve links and decisions. No cascade from entity to source or
  decision history. Hard deletion is blocked while referenced.
- **Reviewer account:** preserve decision actor identity as retained,
  pseudonymized actor reference or immutable actor snapshot only after
  privacy/legal approval. Do not combine `NOT NULL` with `ON DELETE SET NULL`.
  Define erasure separately from authentication-account deletion and preserve
  the approved audit-retention obligations.
- **Historical decisions:** append-only. No update/delete to rewrite the
  reviewer, outcome, candidate, or key. Any legal purge must use a separate
  approved procedure and must not pretend the deleted history never existed.

For every parent-to-child relationship, document the current and proposed
`ON DELETE` action, whether a trigger fires during a cascade, and whether
history must survive. Build and verify child-side indexes before changing
delete actions. A disposable local full-FK/trigger rehearsal is mandatory;
no destructive test is allowed against production. The safe default and
retention period require product/legal owner approval.

## 13. Function ownership and privilege transfer

No ownership change is authorized by this document. If chosen, the deployable
procedure must be proven first in a disposable environment with the exact
migration role:

1. Read current function owner, schema owner, migration identity, `CREATE` on
   `public`, role attributes, role membership, grants, and default privileges.
2. Confirm the migration identity is permitted to set the desired owner and
   that the new owner has the required `CREATE` privilege on the containing
   schema at transfer time. PostgreSQL role membership and ownership rules
   apply; do not infer them from a successful local `postgres` session.
3. Create the non-login executor and narrowly defined owner roles, with
   `NOLOGIN`, `NOBYPASSRLS`, no inherited worker/service membership, and no
   client membership. Verify these attributes and membership graph.
4. If schema CREATE or role membership must be granted temporarily, grant only
   the exact privilege to the migration role, perform create/transfer, then
   revoke it in the same controlled deployment procedure where possible.
   Do not grant permanent schema CREATE to the executor. If the migration
   runner cannot perform and clean up the transfer safely, stop.
5. Set function owner explicitly; set security-definer configuration and
   function ACLs after ownership transfer, because ownership operations can
   affect expected grants. Revoke EXECUTE from PUBLIC and unwanted roles,
   then grant exact signatures.
6. Verify final owner, `prosecdef`, `proconfig`, EXECUTE ACLs, table/column
   ACLs, RLS enabled/forced state, and role attributes/memberships from
   catalogs. Repeat after deployment using a read-only role.

Do not assume a hosted Supabase migration connection can become `postgres`,
grant membership in protected roles, or revoke privileges granted through
platform-managed roles. That capability is a Stage 2 authorization gate.

## 14. Application write-path cutover matrix

Repository paths and operations below are based on current-worktree code; the
worktree includes uncommitted application files, so confirm the intended
baseline before implementation. Match actions currently accept only a
candidate ID and inspect a generic `{error}` result; confirmation does a
direct entity update followed by a separate audit call; discrepancy resolution
updates a row then audits separately. See
[`reconciliation.ts` accept/reject/confirm](../examples/nextjs/lib/actions/reconciliation.ts#L159),
[`exportEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L406), and
[`resolveDiscrepancy`](../examples/nextjs/lib/actions/reconciliation.ts#L592).

| Existing path | Current database operation | Proposed replacement | Required before DML revocation |
|---|---|---|---|
| Match acceptance | Direct candidate/entity/link/reviewer-decision writes and separate audit per existing action implementation. | `accept_reconciliation_match(candidate_id, idempotency_key)`; one atomic result. | Update action/UI to send durable key, map typed outcomes, and prove no direct write remains. |
| Match rejection | Direct candidate/reviewer-decision write and separate audit. | `reject_reconciliation_match(candidate_id, idempotency_key)`. | Same as acceptance; confirm rejection creates no entity/link. |
| Entity confirmation | Direct entity status UPDATE then separate `log_audit`. | Separate narrow `confirm_reconciliation_entity(entity_id)` RPC, with locked owner/admin check and atomic audit. This RPC is not a match RPC. | Decide whether confirmation is in this milestone; migrate action before revoking entity status UPDATE. |
| Entity creation/confirmation and manual entity operations | Existing reconciliation actions/pages may create or alter entities outside match review. | Separate entity-management RPCs or explicitly deferred operation; no match RPC expansion. | Inventory every call site and retain only explicitly approved DML. |
| Entity export and audit | Authenticated SELECTs plus audit calls; deleted entity filtering must be checked. | Keep reads separate; filter deleted entities by default; audit export through its existing safe server path. | Confirm tenant filters and deleted visibility; no decision DML grant required. |
| Discrepancy resolution | Read unresolved discrepancy, direct UPDATE, then generic audit. | **Deferred** from this milestone; a future atomic discrepancy RPC is separate scope. | Do not revoke the exact discrepancy UPDATE needed by the current action unless replaced; this leaves a documented residual workflow-integrity gap. |
| Identifier insertion / source-to-entity links | Current application/reconciliation writes may insert links directly. | Match acceptance only inserts provenance links it owns; unrelated manual identifier flows require a separate RPC. | Inventory all identifier writers; block direct insert only after each in-scope writer is replaced. |
| Candidate generation | Matching worker calls restricted candidate-generation RPC; worker code uses pending-pair conflict handling. | Preserve existing worker RPC; normalize pair order and align its `ON CONFLICT` predicate to the unique index. | Worker regression tests and pair-index inference test pass before constraint rollout. |
| Source ingestion | Import worker uses restricted import RPCs; no direct worker table grant was reported locally. | Preserve worker RPC boundary and source immutability. | Worker lease/import tests pass; no source-table UPDATE grant for review executor. |
| Entity list / deleted filtering | List queries may include soft-deleted entities. | Exclude deleted entities by default; add explicit historical/deleted filter only for authorized views. | Update list/review/export queries and test cross-tenant and soft-deleted behavior. |
| Service-role / operational writes | Generic audit, worker functions, or operational SQL may perform privileged writes. | Inventory and preserve only named operational entry points; no service-role bypass for human decisions. | Repository-wide and hosted caller/ACL inventory complete; exact exceptions documented. |

**Scope decision:** discrepancy resolution is explicitly deferred. Its current
non-atomic UPDATE/audit path must be tracked as a remaining risk; this
milestone does not claim that direct DML revocation is safe for the entire
reconciliation schema. Entity confirmation is a separate narrow operation,
not part of either match RPC.

## 15. Application RPC and result contract

For authenticated RPC invocation mode, actions accept and validate:

```ts
type MatchDecisionInput = {
  candidateId: string;
  idempotencyKey: string;
};

type MatchDecisionResult =
  | { kind: 'accepted'; entityId: string; decisionId: string }
  | { kind: 'rejected'; decisionId: string }
  | { kind: 'replayed'; outcome: 'accepted' | 'rejected'; entityId?: string; decisionId: string }
  | { kind: 'conflict'; code: string }
  | { kind: 'unauthorized' }
  | { kind: 'not_found_or_unavailable' }
  | { kind: 'retryable_failure'; requestId: string }
  | { kind: 'unexpected_failure'; requestId: string };
```

The public action shape must preserve this discriminant; do not collapse all
errors to `{ error: string }`. Validate UUIDs and action input at the server
boundary. Do not return SQL text, stack traces, tenant existence, or sensitive
source/canonical values. Log only a request correlation ID and safe SQLSTATE
classification.

Generate one random UUID per user intent before submission and persist it
client-side (for example, `sessionStorage` keyed by signed-in user,
candidate, and action) before the request. Reuse it for retries after network
timeout, browser retry, or `40P01`/`40001`. Clear it only after a definitive
result/conflict, then generate a fresh key for a new intent. If a timeout
occurs, show “outcome unknown; retry” and keep the key; never suggest the
decision failed or succeeded without a definitive response.

Entity confirmation returns a separate discriminated result and is idempotent
only if already confirmed by an allowed operation; its audit attribution and
authorization must be defined in its own RPC. Discrepancy resolution continues
to use its current path until a separately approved replacement is shipped;
it must not be represented as covered by the two match RPCs.

If server-only invocation is chosen instead, replace this actor contract with
an explicit gateway identity proof and include CSRF/session validation,
service-secret isolation, actor derivation, and replay tests. Passing an
arbitrary `_reviewer_id` to a service-role RPC is not an acceptable proof.

## 16. Testing and verification matrix

No test below is claimed as run. Tests that require a database must use an
approved disposable/local or staging project; production checks are read-only.

| Test | Classification | Required assertion |
|---|---|---|
| Owner acceptance and administrator acceptance | Local integration | Both authorize only current company membership; create one provenance decision, immutable source data, and one correlated audit event. |
| Ordinary member accept and reject | Local integration | Denied before candidate row lock; cannot read candidate/source/tenant-specific data. |
| Two-session unauthorized-member lock contention | Local integration | Member request never acquires candidate lock or blocks authorized reviewer; membership is checked from the locked row. |
| Cross-tenant candidate disclosure | Local integration | Same response shape for nonexistent and another-tenant candidate; no details or lock acquired. |
| Exact function grants and role attributes | Local integration | Catalog checks prove PUBLIC/anon/workers/scheduler denied; selected app caller only receives exact function; executor is NOLOGIN/NOBYPASSRLS and not inherited by client roles. |
| SECURITY DEFINER privilege escalation | Local integration | Malicious arguments, search-path objects, forged company/actor IDs, pre-set GUCs, and helper misuse cannot access another tenant or arbitrary table. |
| FORCE RLS under actual executor | Local integration | RLS remains forced; each per-command policy denies wrong tenant and unsupported command even when function executes as executor. |
| Lock privilege without source UPDATE | Local integration | Executor lacks source UPDATE; trusted helper locks expected rows and returns only approved fields. |
| Accept/accept and accept/reject same candidate | Staging concurrency | One committed outcome; other call returns exact replay or deterministic conflict; no duplicate link/decision/audit. |
| Different candidates share a source | Staging concurrency | One-source-one-entity invariant holds; second decision observes committed link and conflicts unless same target is explicitly allowed. |
| Different candidates share an entity | Staging concurrency | No deadlock; eligible entity remains same; no canonical overwrite. |
| Membership downgrade/removal during decision | Staging concurrency | Lock winner defines order; no stale role authorizes a request after revocation commits. |
| Same idempotency key in concurrent requests | Staging concurrency | Advisory lock plus unique constraint serializes; same binding replays; different binding fails. |
| Lost response/network timeout replay | Staging concurrency | Retrying same key yields `replayed` and no duplicate effects. |
| Deadlock / serialization failures | Staging concurrency | Inject `40P01` and `40001`; bounded retry uses same key and surfaces exhaustion without success-shaped response. |
| Audit-wrapper failure | Local integration | Inject permission/insert failure; all candidate/entity/link/decision writes roll back. |
| Concurrent matching-worker candidate insert | Staging concurrency | Pair normalization and index inference match; worker can insert without duplicate pending pairs or corrupting review locks. |
| Candidate-pair conflict inference | Local integration | Exact partial index predicate and ordered pair are inferable by current worker `ON CONFLICT`. |
| Entity status eligibility | Local integration | `candidate` and `confirmed` accepted; `merged`, `rejected`, soft-deleted, missing, and cross-tenant entities conflict; no redirect/restore. |
| Historical rows and FK compatibility | Local integration | Existing legacy decisions pass compatible checks; typed rows require keys; all composite FKs validate with no silent rewrite. |
| Generic audit forgery | Local integration | `authenticated` and `service_role` cannot create workflow-owned audit actions via generic wrapper; authoritative event requires typed decision correlation. |
| Company/entity deletion and reviewer erasure | Local integration in disposable schema | Trigger/FK graph behaves as approved; no unintended cascade, immutable-source delete failure, or lost historical attribution. |
| Worker and scheduler compatibility | Local integration | Existing restricted RPCs still work; direct DML and workflow RPC execution remain denied. |
| Concurrent-index failure recovery | Local integration / migration rehearsal | Simulate interruption, inspect invalid index and history, recover without blind full-migration replay or false applied status. |
| Soft-delete list/export behavior | Local integration | Deleted entities absent from ordinary lists/exports; historical views label them and preserve tenant authorization. |
| Production grants, policies, migration history, indexes | Production read-only verification | Read-only catalog checks only; no test writes, RPC decisions, or hosted changes during verification. |

Staging concurrency testing must use the exact deployment role and migration
runner version. Production verification cannot substitute for local/staging
write and race tests.

## 17. Migration 06 and hosted-project boundary

Prior Stage 1B evidence says the local migration history records
`20261101000006_enforce_import_finish_lease`, the repository lacks that
migration file, its SQL was recovered from local metadata, and the active
local function reportedly matches the recorded SQL. This does not establish
Git provenance, application method, or hosted state.

Before any reconciliation:

1. Identify the intended Supabase project using an owner-approved project
   reference (project ref/name and organization), not a guessed local name.
2. Have an authorized project owner confirm access and intended environment.
3. Use a least-privilege, read-only inspection method; never print or copy
   credentials, access tokens, API keys, or connection strings into reports.
4. Compare hosted migration history, function definition, grants, roles,
   indexes, constraints, RLS, and schema fingerprint with local and Git
   evidence. Record only non-secret identifiers and results.
5. Independently validate the recovered SQL against the metadata source and
   repository history. Preserve the distinction between recorded SQL,
   historical Git evidence, active function definition, and schema-based
   inference.
6. Obtain owner approval for the repository/history reconciliation mechanism
   before creating or marking any migration. Do not fabricate a migration
   file or execute recovered SQL as part of this design stage.

The project has not been identified or inspected for this amendment. Hosted
schema compatibility, migration-06 state, privileges, function ownership,
data validity, and concurrent-index recovery behavior remain unverified and
block Stage 2.

## 18. Deployment, rollback, and Stage 2 authorization

### 18.1 Deployment / rollback requirements

Deployment requires an approved maintenance window, verified backup/restore
path, preflight row/constraint inventory, and a tested forward-only recovery
plan. Deploy additive compatible schema first, then helpers/RPCs and
policies, then application cutover, then direct DML revocation. Run concurrent
index steps separately and verify validity/history after each. Do not combine
schema rollout with a destructive company/entity/account purge.

If a step fails, stop at the failing boundary, preserve migration/index
evidence, and return application traffic to a known safe path only if that
path does not bypass the intended review authorization. Do not drop validated
constraints, undo audit history, or restore broad direct DML as an automatic
rollback. A rollback must state whether forward-fix is safer and must preserve
source immutability and decisions.

### 18.2 Outstanding decisions and evidence

- Choose authenticated narrow-RPC access versus a server-only gateway and
  formally resolve the “deny client access to workflow RPCs” requirement.
- Approve active entity eligibility (`candidate`/`confirmed`) and
  soft-delete/export semantics.
- Approve company archive/hard-delete, source retention, reviewer erasure, and
  historical decision/audit retention policy.
- Complete repository and hosted caller inventory for generic audit and
  direct DML paths; confirm the exact discrepancy scope exception.
- Verify hosted project identity and migration 06 provenance/state.
- Verify migration-role ownership transfer and cleanup capabilities.
- Verify exact hosted grants, RLS, indexes, constraints, worker compatibility,
  and migration-runner handling for concurrent index statements.
- Run all local integration, staging concurrency, migration-recovery, and
  production read-only checks in §16.

### 18.3 Stage 2 authorization checklist

- [ ] Invocation architecture and actor identity proof are approved and
  consistent with the RPC grants.
- [ ] Candidate lookup is membership-gated and non-locking; current membership
  is locked and checked before any candidate lock.
- [ ] All lock helpers, owners, grants, RLS policies, tenant scoping, and return
  shapes are verified under actual roles.
- [ ] Entity eligibility and soft-delete behavior are approved.
- [ ] Audit forgery is blocked and audit insertion is atomic with decisions.
- [ ] New typed decisions require idempotency keys; legacy rows validate.
- [ ] Migration ordering, existing FK/delete actions, child indexes, pair
  normalization, and invalid-index recovery are rehearsed.
- [ ] Company deletion, source retention, reviewer erasure, and audit
  retention have written owner/legal approval.
- [ ] Every in-scope application write is cut over; deferred discrepancy and
  other writes are explicitly documented and retain only necessary access.
- [ ] Worker and scheduler RPCs pass compatibility and privilege tests.
- [ ] All local integration, staging concurrency, and migration failure tests
  pass; production verification is read-only.
- [ ] Intended hosted project and migration-06 state are independently
  identified and verified without exposing secrets.
- [ ] Backup, rollout, rollback/forward-fix, and monitoring plans are approved.

**Final recommendation: NO-GO. Stage 2 is not authorized.** Proceed only after
the invocation/identity contradiction is resolved, retention and entity rules
are approved, migration 06 and the intended hosted project are verified, and
the implementation and tests above are separately authorized.
