# ZamBase Phase 2A.3.4 — Stage 1K Corrected Design Amendment

> **Design only.** This document proposes a corrected implementation
> specification. It does not authorize implementation, migration creation or
> execution, database access, hosted-project access, or changes to application
> code, roles, grants, policies, functions, indexes, data, dependencies, or
> configuration. Earlier reports and pre-existing worktree changes remain
> untouched.

## 1. Executive summary and verdict

**Recommendation: CONDITIONAL GO FOR A FUTURE DISPOSABLE-LOCAL IMPLEMENTATION-TESTING AUTHORIZATION REVIEW.**

This amendment consolidates the unresolved J1–J6 findings and supplies a
testable proposal for:

- an isolated gateway that signs short-lived, request-bound actor assertions;
- an executor-only, transaction-local tenant context with explicit
  table/command RLS policies and column grants;
- workflow audit events derived from typed decisions and committed
  atomically;
- a paused-worker expand/contract sequence for permanent normalized
  candidate-pair identity;
- a server-side request ledger with authorized outcome lookup; and
- an application writer/permission matrix that preserves unrelated import,
  run, export, invitation, and worker paths.

**No behavior described here has been implemented or tested.** In
particular, the platform's ability to validate the proposed signed assertion,
the exact Supabase/PostgREST role path, role ownership/ACLs, historical data,
migration-runner behavior, and hosted state remain unverified. Conditional
readiness means only that this design is sufficiently concrete to take to a
separate authorization decision for disposable-local testing after owner
decisions and platform prerequisites are recorded. It does not authorize
implementation now, staging, hosted database access, production deployment,
or destructive activity.

### 1.1 Material invariants

- Accept/reject and entity confirmation are separate operations.
- No automatic merge, canonical-value overwrite, survivorship change, or
  source-record mutation/deletion occurs in these workflows.
- Existing source links are not silently reassigned, including links to
  soft-deleted entities.
- New decisions, request outcomes, state changes, and authoritative audit
  records commit or roll back together.
- Current membership and role are checked from a locked membership row.
- A caller-supplied tenant ID or GUC is never authorization evidence.
- Clients and workers cannot execute decision RPCs or directly mutate
  decision-bearing fields.
- Unknown database or audit errors remain errors; they are never converted
  into success-shaped outcomes.

## 2. Evidence classification

Every material claim in this report uses one of these labels:

- **Repository-verified:** read directly in current-worktree source. Some
  relevant files are untracked or modified; this does not establish commit or
  deployment provenance.
- **Prior local finding:** recorded by Stage 1A/1B from prior local inspection.
  It is not a fresh database query and says nothing conclusive about hosted
  state.
- **Proposed design:** desired future behavior or illustrative SQL. It is not
  implemented SQL.
- **Platform assumption:** requires verification against actual Supabase,
  PostgREST, PostgreSQL, deployment, or secret-management configuration.
- **Owner decision:** requires product/security/legal approval.
- **Not verified:** no runtime, catalog, migration, or concurrency proof was
  produced for this report.

### 2.1 Sources reviewed

Reviewed [Stage 1A preflight](./PHASE-2A-3-4-STAGE-1A-PREFLIGHT-REPORT.md),
[Stage 1B local readiness](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md),
[Stage 1C blueprint](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md),
[Stage 1D verification](./PHASE-2A-3-4-STAGE-1D-DESIGN-VERIFICATION.md),
[Stage 1E corrected blueprint](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md),
[Stage 1F review](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md),
[Stage 1G amendment](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md),
[Stage 1H review](./PHASE-2A-3-4-STAGE-1H-INDEPENDENT-REVIEW.md),
[Stage 1I amendment](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md), and
[Stage 1J review](./PHASE-2A-3-4-STAGE-1J-INDEPENDENT-REVIEW.md).

Repository sources include the
[reconciliation schema, policies, and helper functions](../supabase/migrations/20261029000001_reconciliation_module.sql),
[membership helpers](../supabase/migrations/20260514000007_helper_functions.sql),
[worker RPCs and grants](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
[reconciliation Server Actions](../examples/nextjs/lib/actions/reconciliation.ts),
[cookie-backed Supabase client](../examples/nextjs/lib/supabase/server.ts),
[entity list](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx),
[entity export page](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx),
[matching worker](../services/reconciliation/matching/splink_worker.py),
[import worker](../services/reconciliation/imports/worker.py),
[invitation Edge Function](../supabase/functions/invitations/index.ts), and
[import-download Edge Function](../supabase/functions/import-download-url/index.ts).

**Repository-verified:** the Next.js server client uses the public anon key
with cookie-backed user authentication and calls `auth.getUser()` in current
actions. The matching writer calls a lease-bound database RPC with directional
`a`/`b` values. Current actions directly write review, confirmation,
discrepancy, source, import-job, and run state as detailed in §10.

**Prior local finding:** Stage 1B recorded PostgreSQL 15.19, local migration
version `20261101000006`, a local active import-finalization function matching
the SQL recorded in that local history, and no corresponding repository file.
It also recorded that no hosted project was identified or queried.

**Not verified:** this amendment did not connect to any database, inspect
current catalogs, run tests, inspect credentials, or access a hosted project.

## 3. Resolution of J1–J6

| Stage 1J finding | Stage 1K proposed resolution | Remaining gate |
|---|---|---|
| **J1 — Gateway identity not isolated** | §5 compares three principal models and recommends an isolated assertion-signing gateway. Database authorization uses a verified signature bound to actor, action, target, key, audience, issuer, and expiry; tenant is derived and membership-checked in the database. | Verify a supported database signature-verification implementation, isolate the signing key and service credential, and approve the trust model. |
| **J2 — Context/RLS not executable** | §6 specifies executor attributes, function owners, context helper signatures and lifecycle, policies for each table/command, and minimum column/schema/type/function grants. | Exact ACLs, ownership transfer, role availability, and forced-RLS behavior must be tested under actual roles. Illustrative SQL is proposed only. |
| **J3 — Audit wrapper validation incomplete** | §7 defines reserved actions, behavior for every generic overload, a decision-ID-only wrapper, typed-field validation, correlation uniqueness/FK, and rollback semantics. | Catalog inventory, default-privilege review, and direct-spoof tests must prove coverage. |
| **J4 — Worker expand/contract incomplete** | §8 requires database normalization first, duplicate preflight, a controlled worker drain during all-status index installation and writer replacement, and forward-recovery rules. | Product approval of terminal pair identity and successful disposable migration rehearsal. |
| **J5 — Key loss prevents replay** | §9 selects a server-side request ledger plus an actor-authorized outcome lookup. Browser persistence is only a convenience, not the recovery source. | Owner approves ledger retention/privacy; transaction and lookup tests prove no cross-tenant disclosure. |
| **J6 — App writer inventory incomplete** | §10 inventories the current app, worker, export, and audit writers and states the proposed permissions and scope for each. | Deployed caller inventory and exact ACL cutover remain required before any DML revocation. |

These are **proposed design corrections**, not verified resolutions.

## 4. Complete proposed security architecture

### 4.1 Principals and ownership

**Proposed design:**

1. `reconciliation_workflow_executor`: `NOLOGIN`, `NOSUPERUSER`,
   `NOCREATEDB`, `NOCREATEROLE`, `NOINHERIT`, `NOBYPASSRLS`; no membership
   grants to gateway, authenticated users, anon, service-role callers,
   workers, or scheduler. It owns only the external accept/reject/confirm
   `SECURITY DEFINER` functions and the narrow context setter. It does not own
   protected tables.
2. `reconciliation_workflow_gateway` (if the platform can provision it):
   no direct workflow table DML; exact EXECUTE only on external workflow RPCs.
   The role must not be granted to a client, worker, or general service role.
3. `postgres` or a separately verified privileged helper owner: owns only
   narrow membership/source-lock, signed-assertion verification configuration,
   and authoritative-audit helpers. It must not be assumed available or safe
   merely by name; the actual managed-platform owner role is unverified.
4. Existing import/matching workers and scheduler retain only their existing
   bounded RPC privileges. No worker receives workflow decision EXECUTE or
   direct decision/link DML.
5. `authenticated` and `anon` receive no workflow RPC EXECUTE and no direct
   decision-bearing DML.

**Proposed ownership rules:** all `SECURITY DEFINER` functions use
`SET search_path = ''` and fully qualified object references; small
non-definer helpers may use `pg_catalog` explicitly. No untrusted role may
create objects in a function's search path. Ownership transfer requires
verified schema `CREATE` privileges and owner-role membership as required by
PostgreSQL; temporary grants are removed after the transfer. No hosted
migration-user capability is assumed.

### 4.2 External RPC boundary

**Proposed design:** browser code calls only the Next.js Server Action. It
does not call workflow RPCs through PostgREST. The action verifies the
cookie-backed Supabase user with `auth.getUser()`, validates request shape and
same-origin protections, and sends the verified user access token plus the
action/target/key to an isolated gateway. The isolated gateway independently
validates the user token with Supabase Auth and signs a short-lived actor
assertion. It invokes only the database RPC.

The database sees the gateway/PostgREST service principal, not the user's
`auth.uid()`. It therefore does not treat `auth.uid()` or a client-supplied
UUID as reviewer identity. It validates the assertion signature and request
binding, derives the actor UUID from the verified claims, then validates and
locks the actor's current membership in the target tenant.

**Platform assumption:** the current repository has no such gateway service,
assertion signer, or private Supabase client. A separate service/process is
proposed to keep the signing private key and service-role credential out of
other server-side functions. If deployment cannot isolate these secrets,
return to design review; do not silently share them among functions.

### 4.3 Privilege closure

Before any permission cutover, inspect effective (including inherited)
privileges for `PUBLIC`, `anon`, `authenticated`, `service_role`, gateway,
executor, all workers, scheduler, and function owners. Revoke broad table and
column grants only after every current caller is inventoried and compatible
replacement paths are tested.

**Proposed invariants:**

- `service_role` may call a signed-assertion workflow RPC only if the
  signature verifies; it has no direct INSERT/UPDATE/DELETE on workflow
  decision, candidate decision fields, entity decision fields, or link rows.
- Existing service-role SELECT needed for operational tools is preserved
  only by exact column/table grants.
- `BYPASSRLS` never substitutes for table privileges or application
  authorization. Because service-role ACL breadth is unverified, failure to
  isolate its direct writes is a stop condition.
- Default privileges for future functions/tables do not reopen `PUBLIC` or
  service-role write access.

## 5. Gateway identity model

### 5.1 Option comparison

| Approach | Supabase/PostgREST feasibility | Credentials/privileges | Actor verification and impersonation resistance | Consequences |
|---|---|---|---|---|
| **1. Dedicated gateway database principal** | A role claim can be used by PostgREST when backed by a valid JWT and appropriate role grants. Whether this project can issue a distinct gateway JWT/role or safely configure a custom JWT path is **unverified**. Do not assume a custom role can be provisioned by hosted Supabase. | A dedicated credential/JWT-signing mechanism, exact RPC EXECUTE, schema USAGE, and no direct table DML. The principal must not be assumable by app users, workers, scheduler, or service role. | Database can authenticate the database principal, but the principal alone does not identify the human. The gateway must still derive actor from verified `auth.getUser()` and provide an assertion; protect its credential from every other server function. | Best ACL separation if genuinely supported; provisioning, JWT role claims, token rotation, connection path, and ownership are platform gates. Without those verified, this is not the selected assumption. |
| **2. Shared `service_role` with accepted trust** | The repository already uses `SUPABASE_SERVICE_ROLE_KEY` in Edge Functions; the current Next.js reconciliation client does not. Service-role PostgREST use is therefore architecturally plausible, but exact role grants and deployment isolation are unverified. | Shared service key, with exact RPC EXECUTE and direct workflow-table DML revoked where compatible. `BYPASSRLS` makes remaining table ACLs decisive. | The database does not know which server function supplied a reviewer UUID. Any service-role holder capable of calling the RPC could impersonate a reviewer unless another assertion is added. Accepting this means explicitly trusting every service-key holder. | Lowest engineering cost, largest blast radius. Not recommended as a standalone identity model. It is not gateway-only if the same key is available to other Edge Functions or server functions. |
| **3. Cryptographically verified short-lived actor assertion** | Can be transported as an RPC argument over PostgREST regardless of custom role provisioning, provided the database can verify the signature. The required PostgreSQL/Supabase crypto verifier and key storage are **unverified** and must be proved locally. | Isolated gateway holds a signing private key; database stores/uses only a pinned public key and key ID. The RPC caller also needs a database principal with exact RPC EXECUTE. Prefer dedicated gateway role if proven; otherwise use `service_role` only with direct workflow-table DML revoked and signature mandatory. | Database verifies signature and exact claims: issuer, audience, actor UUID, action, target UUID, request key, issued-at, expiry, and key ID. Tenant is derived from target and locked membership, never trusted from the assertion. Other functions cannot impersonate unless they can access the private signer or the verifier accepts an unbound token. | Strongest available actor binding without assuming a dedicated PostgREST role. Requires isolated signer, key rotation/revocation, canonical claim encoding, expiration policy, database verification support, replay control, and careful logging. |

### 5.2 Recommendation and exact assertion contract

**Proposed recommendation:** approach 3, with an isolated gateway service
signing short-lived assertions. Use approach 1 as the preferred database
transport principal only after the actual PostgREST/JWT capability is
demonstrated. Otherwise use service role solely as a transport principal,
never as human identity, and require valid signed assertions on every workflow
RPC. Do not accept approach 2 without an explicit written owner decision that
all service-role holders are trusted to assert human identity.

**Proposed assertion claims:** `iss`, `aud`, `kid`, `sub` (verified actor
UUID), `op` (one exact RPC operation), `target` (candidate/entity UUID),
`request_id` (ledger key UUID), `iat`, and `exp`. Do not include an
authoritative `company_id`; the database discovers tenant from the target and
validates locked membership. Signature verification must use a pinned
algorithm/key ID and canonical serialization; reject unknown algorithms,
unknown keys, duplicate/ambiguous claims, invalid UUIDs, future-issued or
expired tokens, audience/operation/target/key mismatch, and missing claims.
An assertion is short-lived and one-request-bound; the request ledger makes
replay return the same bound result rather than reapply the action.

**Platform assumption/stop condition:** the specific signature algorithm,
PostgreSQL verifier (including extension availability and algorithm support),
secure public-key storage, and rotation/revocation mechanism are not verified.
No custom crypto code or SQL verifier is authorized here. If no supported
verifier can be proven, stop and return to design review; do not downgrade to
unsigned service-role assertions.

### 5.3 Server-side protections

**Proposed design:** the Server Action verifies the session using
`auth.getUser()`, ignores browser-supplied actor/company/role, validates
Origin against a configured allowlist, validates Host/proxy behavior, and
uses secure HTTP-only SameSite cookies. It forwards the bearer token to the
isolated gateway over authenticated TLS. The gateway validates the token
again with Supabase Auth, limits accepted operations, signs only the verified
actor/action/target/key tuple, and does not expose a generic “sign arbitrary
claims” endpoint.

Origin/CORS checks alone are not authorization. The private key and
service-role credential are not placed in the browser bundle, source maps,
logs, or shared runtime. Rate limiting and audit-safe request IDs are
required. CSRF, session revocation, key rotation, and service-to-service
authentication are staging/platform-specific gates.

## 6. Exact tenant-context and RLS contract

### 6.1 Transaction and lock sequence

**Proposed design, `READ COMMITTED`:**

1. Validate gateway database principal and signed assertion. Check issuer,
   audience, operation, target, request key, expiry, and signature.
2. Clear any pre-existing transaction-local context before any executor
   policy-protected query.
3. Use a narrow trusted discovery/authorization helper to find the target
   candidate/entity tenant without locking the candidate/entity row. The
   helper returns no tenant information for an actor without a current
   owner/admin membership.
4. Lock the exact membership `(company_id, actor_id)` `FOR SHARE` and check
   the locked role. This is the authorization linearization point.
5. Acquire the request-ledger key lock; look up the actor-bound prior request.
   A replay still requires current membership.
6. Set tenant context from the verified target row's company, after membership
   validation.
7. Lock candidate or entity row; lock source records in ascending UUID order
   via a trusted helper; lock linked/target entities in ascending UUID order.
   Re-read links under lock and rely on unique constraints as final guards.
8. Apply allowed changes, insert the typed decision, request outcome, and
   authoritative audit record. Any unexpected error aborts the transaction.

If membership downgrade/removal commits first, the workflow observes missing
or insufficient membership and denies. If the workflow locks first, the
membership update/delete waits until the transaction ends. The same lock order
must be used by every workflow operation.

### 6.2 Context setter/getter

**Proposed SQL illustration only; not executed:**

```sql
CREATE FUNCTION public._set_reconciliation_workflow_tenant(_company_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
BEGIN
    IF current_user <> 'reconciliation_workflow_executor' THEN
        RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_catalog.set_config(
        'zambase.workflow_company_id',
        COALESCE(_company_id::text, ''),
        true
    );
END
$$;

CREATE FUNCTION public._reconciliation_workflow_tenant()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
    SELECT CASE
        WHEN pg_catalog.current_setting(
            'zambase.workflow_company_id', true
        ) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN pg_catalog.current_setting(
            'zambase.workflow_company_id', true
        )::uuid
        ELSE NULL
    END
$$;
```

The setter/getter are **not** an unforgeable credential. PostgreSQL custom
settings can be supplied by a caller. The security invariant is that no
external role has executor membership or protected-table ACLs, every
externally callable executor-owned RPC clears context first, and it sets the
context only after signature and locked-membership checks. The gateway's
pre-set value is overwritten/cleared before use. Missing, empty, malformed,
noncanonical, or stale values return NULL; policy equality with NULL denies.
The setter is owned by executor, has EXECUTE only to executor, and accepts a
NULL only to clear. The getter is invoker-security, callable only by executor
for RLS evaluation. Revoke EXECUTE from `PUBLIC`, `anon`, `authenticated`,
`service_role`, workers, and scheduler. Audit all executor-owned functions
because each could invoke the setter.

Transaction-local `set_config(..., true)` lasts only for the current
transaction. The gateway must invoke one RPC per transaction; pooled
connections must not retain context after commit/rollback. Every external RPC
clears context on entry; error rollback clears transaction-local state.

### 6.3 Function ownership and RLS behavior

**Proposed design:**

- Accept, reject, and confirmation functions: owner
  `reconciliation_workflow_executor`, `SECURITY DEFINER`,
  `SET search_path = ''`; exact function `EXECUTE` to gateway transport
  principal only. No `PUBLIC` execution.
- Context setter: owner executor, invoker-security, `search_path = pg_catalog`,
  EXECUTE only to executor.
- Context getter: invoker-security, `search_path = pg_catalog`, EXECUTE only
  to executor.
- Membership/source lock and discovery helpers: owner a verified privileged
  database role (prefer `postgres` only if its actual capability is confirmed),
  `SECURITY DEFINER`, empty search path, fully qualified names, exact input
  predicates, return only IDs/company/status/link facts. EXECUTE only to
  executor. Helpers must lock membership before candidate/entity and use
  explicit actor/company filters.
- Audit wrapper: trusted owner, fixed empty search path, EXECUTE only to
  executor.
- No executor function owner is a protected table owner, superuser, or
  `BYPASSRLS` role. Membership or role grants must not allow external
  `SET ROLE` to executor.

`ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` apply to the
executor because it is neither table owner nor `BYPASSRLS`. A verified
superuser/`BYPASSRLS` lock-helper owner is an intentional exception: PostgreSQL
does not constrain that helper with table RLS, so each helper must enforce
explicit tenant and actor predicates internally. If the hosted platform
cannot provision/transfer to these owners, stop; do not substitute a broad
policy.

### 6.4 Exact executor RLS policy set

**Proposed SQL semantics:** one permissive policy per allowed command, all
`TO reconciliation_workflow_executor`; no `PUBLIC` policies and no
`USING (true)`. The context getter returns NULL unless context is valid.

| Table | SELECT `USING` | INSERT `WITH CHECK` | UPDATE `USING` / `WITH CHECK` | DELETE |
|---|---|---|---|---|
| `reconciliation_match_candidates` | `company_id = public._reconciliation_workflow_tenant()` | None | Both expressions: same company equality. RPC validates pending→accepted/rejected, reviewer and timestamp. Column ACL restricts update to `status, reviewer_id, reviewed_at, entity_id`. | No grant or policy. |
| `reconciliation_source_records` | No executor grant/policy. Trusted lock helper only. | None | None; **no UPDATE grant**. | None. |
| `reconciliation_entities` | `company_id = context` | `company_id = context` | Both expressions: `company_id = context AND deleted_at IS NULL`; RPC validates candidate→confirmed only. Only `status, updated_at` update columns. | No grant or policy. |
| `reconciliation_identifiers` | `company_id = context` | `company_id = context` | None | None. |
| `reconciliation_reviewer_decisions` | `company_id = context` | `company_id = context` | None; append only | None. |
| `memberships` | No executor grant/policy. Trusted membership helper only. | None | None | None. |
| `audit_log` | No executor grant/policy. Trusted audit helper only. | None | None | None. |

Illustrative SQL for policy expressions only:

```sql
CREATE POLICY workflow_candidate_select
ON public.reconciliation_match_candidates
FOR SELECT TO reconciliation_workflow_executor
USING (company_id = public._reconciliation_workflow_tenant());

CREATE POLICY workflow_candidate_update
ON public.reconciliation_match_candidates
FOR UPDATE TO reconciliation_workflow_executor
USING (company_id = public._reconciliation_workflow_tenant())
WITH CHECK (company_id = public._reconciliation_workflow_tenant());
```

The remaining allowed policies use the table/command expressions in the
matrix literally. Existing client policies that permit direct decision writes
must be removed or rendered ineffective by revoked table/column grants. RLS
policies do not grant SQL privileges.

### 6.5 Required SQL privileges

**Proposed minimum executor privileges; exact catalog closure is unverified:**

- `USAGE` on `public` and `extensions` schemas; `USAGE` on the specific
  reconciliation enum types used in INSERT/UPDATE/constraints; `EXECUTE` on
  the exact UUID default generator if a table default calls it.
- No sequence privileges are expected for UUID defaults. If implementation
  introduces serial/identity sequences, grant only the exact sequence
  privileges required and include them in review.
- Candidate: `SELECT(id, company_id, record_a_id, record_b_id, entity_id,
  status)`; `UPDATE(status, reviewer_id, reviewed_at, entity_id)`.
- Source records: no executor table privileges.
- Entities: `SELECT(id, company_id, status, deleted_at)`;
  `INSERT(company_id, canonical_data, survivorship_rule, record_count,
  status, created_by)`; `UPDATE(status, updated_at)` for confirmation only.
  Server-generated `id` uses the verified UUID default.
- Identifiers: `SELECT(company_id, entity_id, source_record_id)`;
  `INSERT(company_id, entity_id, source_record_id, confidence)`.
- Reviewer decisions: `SELECT` only required typed decision/key/tenant/actor/
  target/result fields; `INSERT` only the explicit typed fields plus legacy
  compatibility columns required by existing NOT NULL constraints. Exact list
  follows the finalized typed schema.
- No executor table privilege on `memberships` or `audit_log`; only helper
  EXECUTE.
- Exact helper EXECUTE grants to executor, exact external RPC EXECUTE to
  gateway, no grants to `PUBLIC`, `anon`, `authenticated`, workers, or
  scheduler.

The executor column list must be narrowed further after the final SQL function
bodies are reviewed; no `GRANT ALL` shortcut. Function defaults and inherited
role membership are checked from catalogs. `USAGE` on `auth` is not granted
to executor as an identity source; verified assertion claims and trusted
membership helpers supply actor identity.

## 7. Audit integrity contract

### 7.1 Generic audit overload behavior

**Repository-verified:** the migration history in the worktree defines a
six-argument `public.log_audit(audit_action, uuid, uuid, text, text, jsonb)`
with defaults, and a five-argument `log_reconciliation_audit` with defaults.
Earlier helper migration and later hardening migration define/redefine the
same named audit helper. Actual deployed overloads/default ACLs are
**unverified**.

**Proposed contract for every overload and wrapper that accepts an action:**

1. Reject reserved reconciliation workflow action enum values before writing,
   for every caller class, including `authenticated`, `service_role`,
   workers, scheduler, and trigger callers. Triggers must not be an
   exception for these reserved workflow decisions.
2. Reserved events include match accepted, match rejected, reviewer decision
   for those operations, and entity confirmed (the exact enum labels are
   taken from the finalized `audit_action` enum; no new label is assumed
   without schema preflight).
3. Nonreserved generic actions retain only documented caller use. Authenticated
   callers must have current tenant membership; service-role calls must be
   explicitly inventoried and may not write reserved actions. Caller-supplied
   actor metadata is not authoritative.
4. Revoke generic EXECUTE from callers that do not need it. Keep trigger and
   worker operation possible through the intended owner/definer chain, not by
   broadening the public wrapper.
5. Set default privileges so newly created action-accepting overloads are
   not executable by `PUBLIC` or roles that have no approved use. Catalog
   checks enumerate overload identity arguments and effective grants before
   and after deployment.
6. `log_reconciliation_audit` must reject the same reserved actions. Generic
   functions cannot be an alternate path to create authoritative events.

### 7.2 Authoritative wrapper and correlation

**Proposed signature:**

```text
public.write_reconciliation_decision_audit(_decision_id uuid) RETURNS void
```

Only the executor function chain may EXECUTE it. It accepts no actor, tenant,
action, target, result, or metadata from the caller. It loads the typed
decision row and validates:

- typed row is nonlegacy and has non-null company, actor, action, target,
  idempotency/request key, and creation time;
- decision company equals the executor transaction tenant context;
- decision reviewer equals the actor from the verified assertion held by the
  workflow transaction;
- decision target type/ID corresponds to the locked candidate/entity;
- accept has the selected entity result and reject has no entity result;
- confirmation references the exact entity and permitted status transition;
- legacy target-table/target-ID/enum fields cannot contradict typed fields;
- the requested action maps to exactly one fixed audit enum action;
- the decision has no existing authoritative audit row.

The database inserts one audit row using only derived values, with
`reconciliation_decision_id = decision.id`, actor and company derived from the
typed row, fixed target/action mapping, and only approved non-sensitive
metadata. It raises on any mismatch or insertion failure.

**Proposed relational constraints:**

- nullable `audit_log.reconciliation_decision_id` FK to the typed decision
  primary key, with deletion default RESTRICT; no cascade that silently
  erases audit evidence;
- unique partial index on non-null `reconciliation_decision_id`;
- tenant-consistent composite FKs for decision/company/actor/target/result
  where matching parent unique keys exist;
- a typed-row CHECK with a separate legacy branch, exact action/result
  consistency, and non-null key for every new typed request;
- no UPDATE/DELETE of typed decisions or correlated audit rows by ordinary,
  authenticated, worker, service-role, or executor SQL callers.

The unique partial index proves at most one correlated event. The workflow
transaction must insert the decision and audit row together and abort if the
wrapper fails. To enforce at least one event even if another executor-owned
function is accidentally added, the implementation should add a deferred
constraint trigger on typed decision INSERT that verifies a matching
authoritative audit row at transaction end. Whether that trigger is
compatible with the final schema/retention model is a disposable-test gate.
The wrapper plus trigger yields one event or no committed decision.

Historical uncorrelated workflow-labelled audit rows remain visible but are
marked legacy/unverified. Never backfill fabricated decision IDs.

### 7.3 Required audit tests

Test every overload by exact signature; authenticated and service-role
reserved-action spoof attempts; worker/scheduler reserved-action attempts;
generic nonreserved caller compatibility; function default ACLs; wrapper
direct calls by each untrusted role; cross-tenant decision ID; actor/action/
target/result mismatch; duplicate event; audit insert failure rollback; and
deferred trigger behavior. No test is run in Stage 1K.

## 8. Worker and candidate-pair rollout

### 8.1 Target contract

**Proposed business rule, owner approval required:** one permanent candidate
per unordered source-record pair across every status. Accept/reject is
terminal; re-review requires a separately designed generation/version key.

**Repository-verified:** current Splink worker emits directional `id_l` and
`id_r` as `record_a_id`/`record_b_id`; current worker RPC inserts them as
received and uses:

```sql
ON CONFLICT (record_a_id, record_b_id) WHERE status = 'pending' DO NOTHING
```

The pending-only index therefore does not prevent reversed or terminal
duplicates.

### 8.2 Ordered expand/contract sequence

1. **Read-only preflight:** group all historical candidates by
   `(LEAST(record_a_id, record_b_id), GREATEST(...))`; report self-pairs,
   duplicate canonical pairs, opposite-direction rows, and terminal rows.
   No automatic deletion/survivor selection. Product owner approves an
   audited disposition for every conflict.
2. **Worker-safe database expansion:** replace the existing RPC body while
   preserving its signature and current partial conflict target. Normalize
   inside the database:
   `a = LEAST(input_a,input_b)`, `b = GREATEST(input_a,input_b)`.
   Omit/reject self-pairs and validate both source records belong to the
   lease-derived company. Do not yet add an ordered-pair CHECK that can break
   preexisting unnormalized rows. Old Python workers remain compatible
   because their directional payload is accepted and normalized in the RPC.
3. **Optional application defense:** after step 2 is verified, deploy Python
   worker normalization too. Retain database-side normalization as the
   authoritative boundary; direct RPC callers may still submit reversed
   values.
4. **Canonical duplicate remediation:** after all writes pass through the
   normalized RPC, repeat read-only canonical duplicate preflight and resolve
   approved legacy collisions. This is necessary because two historical
   opposite-direction rows do not collide under the old ordered partial
   index.
5. **Controlled worker pause/drain:** stop scheduling new matching runs,
   wait for active matching leases to finish/expire under the approved lease
   recovery procedure, and verify no writer can insert candidates. This pause
   begins before the all-status index operation and remains through the
   function switch. The exact scheduler/worker control is environment
   specific and unverified.
6. **Build all-status uniqueness:** create a nonpartial unique index on
   `(record_a_id, record_b_id)` with the appropriate canonical pair CHECK
   validated only after all stored rows satisfy it. `CREATE INDEX
   CONCURRENTLY` is a standalone operation outside an explicit transaction.
   Check `indisvalid`, `indisready`, definition, and migration history.
7. **Switch conflict inference while paused:** replace the RPC target with
   the exact nonpartial inference clause:

   ```sql
   ON CONFLICT (record_a_id, record_b_id) DO NOTHING
   ```

   Keep database normalization and lease/tenant checks. Confirm the
   nonpartial unique index is valid before resuming.
8. **Remove old partial index:** after the new function is active and exact
   conflict inference is tested, drop the pending-only partial index in a
   separately planned, lock-aware step. Do not run this before the new index
   and function are verified.
9. **Resume worker:** start one worker, verify lease-bound writes and terminal
   pair suppression, then resume normal scheduling. Keep monitoring and a
   pause switch.

### 8.3 Rollback and interruption

Before the nonpartial index is installed, reverting the database function to
the old behavior is possible only if no ordered constraint/data transition
has made old directionality unsafe. After all-status uniqueness is installed,
do not resume an old function using only the partial conflict target: a
terminal-pair conflict could become an unhandled unique violation. Prefer a
forward fix while the worker remains paused. If rollback is explicitly
approved, drop the new index concurrently only after proving no new invariant
depends on it, then restore the partial target and old semantics. Never
blindly replay a migration or mark it applied to hide failure.

If concurrent index creation fails, inspect validity/readiness, duplicate
rows, and migration history; remove only the specific invalid index through
an approved procedure, resolve data, retry standalone creation, and keep the
worker paused. No migration 06 action is part of this sequence.

## 9. Idempotency recovery architecture

### 9.1 Alternatives

| Option | Benefits | Limits and risks |
|---|---|---|
| Browser-local persistence | Simple; same browser can reuse UUID after reload/tab close. | Browser storage may be cleared/unavailable; no cross-device recovery; does not reserve failures; after key loss a new request key cannot identify an old outcome. Treat only as a cache. |
| Server-side request ledger | Durable actor/request binding and stored terminal response; same-key retries work after browser loss or device change if the request key can be recovered. | Requires schema, retention, privacy review, transaction/concurrency design, and authorization on lookup. A key lost by the client still needs target-based recovery. |
| Authorized decision lookup | Can find an actor's prior decision for a target without the original key; useful after storage loss and across devices. | Must avoid cross-tenant existence leaks; decision history may include sensitive identifiers; ambiguity if an actor has multiple decisions/operations for a target or re-review generations. |

### 9.2 Recommendation: ledger plus restricted lookup

**Proposed design:** server-side request ledger is authoritative; browser
storage is optional; a narrow lookup operation recovers a terminal request by
authenticated actor and target after key loss.

Suggested ledger fields (final names/types subject to schema review):

- `request_id uuid`, unique globally or scoped as specified below;
- `company_id uuid`, nullable only for a valid request whose target cannot
  be resolved;
- `actor_id uuid`;
- operation enum (`accept`, `reject`, `confirm`);
- target type and UUID;
- result code;
- nullable typed decision ID and result entity ID;
- created/completed timestamps and schema/version marker;
- no raw source data, request body, or caller-provided metadata.

**Proposed key uniqueness:** unique `(actor_id, request_id)`; company,
operation, target type, and target UUID are immutable binding fields. A key
reused with any different binding returns `idempotency_key_reused`, never
replays another target. The request lock is based on the ordered actor UUID
and request UUID bytes with a versioned encoding; the unique constraint is
authoritative. Tenant is derived from the target and current membership, not
from the browser.

For a syntactically valid, authenticated request whose target resolves, the
database serializes same-key calls, checks current locked membership, and
stores a deterministic terminal result, including expected conflicts. A
same-key/same-binding request returns the stored result. Same-key/different
binding returns a key-reuse conflict without altering the first row.
Transient SQL errors (`40P01`, `40001`) and unexpected errors abort the
transaction and do not create a success-shaped ledger result; bounded retries
reuse the exact key and binding. Input validation failures before a valid
request is formed are not ledger entries.

The lookup endpoint accepts only operation/target identifiers from the
request, derives actor from a freshly verified user session, discovers tenant
internally, rechecks current membership, and returns only the caller's own
matching result. A missing/nonmember/cross-tenant target has one uniform
unavailable response. For multiple generations, lookup must include the
generation/decision identity; re-review remains out of scope.

### 9.3 Browser, account, cross-device, and retention behavior

The browser may cache request IDs in same-origin storage keyed by actor,
operation, and target, but it does not determine truth. On account switch, the
new actor cannot read or replay the old actor's request. The original actor
can recover on another device via authorized target lookup, subject to current
membership. If membership has been removed, deny lookup and replay; never
reveal the old tenant outcome.

**Owner decision:** approve a retention period for request outcomes and their
actor/target references, coordinated with decision/audit retention and legal
erasure. Expired request rows must not permit accidental reapplication of
already terminal actions; decision uniqueness and target terminal state
remain authoritative. Ledger deletion/pseudonymization needs a separately
approved retention procedure.

## 10. Complete application write-path matrix

**Principal classification:** current Next.js actions use a cookie-backed
Supabase client with the anon key and the user's JWT; PostgREST therefore
uses the authenticated user role for allowed operations. This is
repository-verified architecture, not a catalog privilege statement.
Worker role names below are repository-intended from migration definitions;
actual deployment connection roles are not verified. `service_role` callers
are shown where code uses that key. The deployed caller inventory remains a
gate.

| Path and current caller | Tables/columns accessed or written | Required permissions and proposed replacement | Scope and tests |
|---|---|---|---|
| **Accept match** — `acceptMatch`, authenticated user | Reads candidate fields, identifiers, source raw data; updates candidate status/reviewer/time/entity; inserts entity and identifiers; calls `log_audit`. | Replace with signed gateway RPC + locked membership, executor-limited candidate/entity/link/decision writes, ledger and audit atomically. No direct client DML on candidate decision columns, entities, links, or decisions. | In scope. Concurrent accept/accept, accept/reject, shared-source/entity, audit failure rollback, cross-tenant denial. |
| **Reject match** — `rejectMatch`, authenticated user | Reads/updates candidate status/reviewer/time; generic audit write. | Replace with separate reject RPC; no entity/link insert. | In scope. Concurrent reject/accept; same-key replay and mismatch. |
| **Entity confirmation** — `confirmEntity`, authenticated user | Reads entity status/count; updates status/updated_at; generic audit. | Separate confirmation gateway RPC; only candidate→confirmed; no canonical/survivorship/count/link updates. | In scope. Eligibility, deleted entity, audit rollback, response-loss retry. |
| **Identifier/link writes** — acceptance currently; no other direct identifier writer found in reviewed app actions | Accept reads `company_id, entity_id, source_record_id`; inserts links with confidence. | Accept RPC only for match provenance. Preserve unique `source_record_id` and composite tenant FKs. Any additional deployed/manual writer requires separate inventory and operation; no broad client INSERT. | Accept path in scope; manual assignment deferred. Duplicate link and concurrent source tests. |
| **Data-source creation** — `createDataSource`, authenticated user | Inserts company/name/description/source type/config/creator. | Retain as separate tenant-authorized operation; narrow INSERT columns and enforce membership/role at database, not only app metadata. Does not use workflow executor. | Retained operational path, not decision milestone. Membership/tenant and validation tests. |
| **Data-source deletion** — `deleteDataSource`, authenticated user | Updates `deleted_at`. | Retain soft-delete only, scoped by tenant and role; no physical delete/cascade. Narrow UPDATE column. | Retained. Verify existing imports/runs behavior with archived source. |
| **Import-job creation** — `createImportJob`, authenticated user | Reads active data source; inserts company/source/status/file_ref/creator. | Retain as a separate guarded operation. Exact table/column grant and tenant/active-source check; not granted workflow decision fields. | Retained. Bad reference, wrong tenant, deleted source, worker handoff. |
| **Import-job retry** — `retryImportJob`, authenticated user | Updates failed job status/timestamps/errors to pending. | Retain only authorized retry fields; preferably a narrow retry RPC if current table grant is broader than needed. Do not revoke until cutover. | Retained. Concurrent retry/claim and worker lease tests. |
| **Reconciliation-run creation** — `startReconciliationRun`, authenticated user | Inserts company/status/blocking rules/comparison config/creator. | Retain separate tenant/admin operation with validated JSON and exact columns; scheduler derives tenant from run row. | Retained. Tenant/config validation and worker claim compatibility. |
| **Reconciliation-run retry** — `retryReconciliationRun`, authenticated user | Updates failed run status/timestamps/error to queued. | Retain narrow retry permission or replace with guarded RPC; worker lease/state transition must remain consistent. | Retained. Concurrent retry/claim and stale lease tests. |
| **Discrepancy resolution** — `resolveDiscrepancy`, authenticated user | Reads discrepancy; updates resolution/reviewer/time; writes generic audit. | Deferred from accept/reject milestone. Keep only the exact current permission it needs until a separate atomic decision/audit design ships; no broad revocation that silently disables it. | Deferred. Explicitly test that deferral cannot mutate match decision fields. |
| **Entity list/management** — entity page uses authenticated read; confirmation is above | Lists entity fields; current query does not filter `deleted_at`; no distinct manual merge/delete action found in reviewed action module. | Ordinary list filter `deleted_at IS NULL`; entity delete/merge/restore remain separate and deferred. No match RPC expansion. | List filtering required before cutover. Test deleted, merged, rejected, candidate, confirmed. |
| **Entity export and audit** — export page/action, authenticated user | Reads entity, links, source raw data; uploads CSV to Storage and signs URL; calls generic `entity.exported` audit. | Keep export read path and safe nonreserved audit. Require `deleted_at IS NULL` both in page and action; enforce tenant membership and storage path policy. | Retained. Deleted entity denial, cross-tenant, audit failure/error behavior, signed URL scope. |
| **Source ingestion** — Python import worker through `reconciliation_import_insert_record` | Inserts immutable source record from lease-derived company; updates job lease internally; logs operational audit. | Keep worker-only lease RPC; no client or executor source UPDATE/DELETE. The worker RPC/function owner and operational action audit remain separate from decision audit. | Retained. Lease ownership, source immutability, tenant derivation, retry/idempotency. |
| **Candidate generation** — Python matching worker via `reconciliation_matching_write_candidates` | Reads source records under run lease; inserts candidates from JSON pair inputs; updates run lease; operational audit. | Keep lease-bound RPC; database canonicalizes pairs; pause/drain during all-status index/function contract. No direct worker table DML. | In scope for pair identity. Reversed inputs, self-pair, terminal suppression, old/new worker compatibility. |
| **Export audit and other generic audit** — Server Actions and invitation/operational functions | `log_audit` from user actions; invitation Edge Function uses user/service clients; worker `log_reconciliation_audit` calls appear in migrations/tests. | Preserve inventoried nonreserved calls; reject reserved workflow actions for every generic overload. Migration-owned worker audit may use internal call chain. | In scope for audit restriction. Per-caller regression and spoof tests. |
| **Import download URL** — Edge Function using service key | Reads import-job claim/file metadata and creates signed Storage URL. | Preserve exact SELECT/storage operations. Must not receive workflow signing key; service-role direct DML on decision tables is separately revoked if compatible. | Retained. Claim token, file path, no-store, and service-role ACL test. |
| **Manual entity create/merge/restore/delete** — no such writer identified in reviewed current action module | Not established by repository scan; may exist elsewhere/deployed. | Deferred; separately authorize and inventory before changing entity grants. | Deferred. Catalog/caller inventory before ACL cutover. |

No broad reconciliation DML revocation is permitted until this matrix is
expanded with the complete deployed caller list and every required permission
is either retained narrowly or replaced and tested.

### 10.1 Deleted-entity behavior

**Proposed rule:** `deleted_at IS NOT NULL` entities are excluded from normal
entity lists and exports. Acceptance and confirmation reject them as
unavailable/conflict without revealing cross-tenant existence. Existing
identifier links to deleted entities remain and are not reassigned
automatically. Export page and export action both enforce the predicate; the
page check alone is not authoritative. No workflow updates `deleted_at`.

## 11. Migration and retention contract

### 11.1 Relational schema

**Proposed design; historical compatibility not verified:**

1. Source/entity parent unique keys `(company_id,id)` must exist before
   composite foreign keys.
2. Add global unique `reconciliation_identifiers(source_record_id)` to
   enforce one source link across all entities. Preserve the existing
   `(entity_id,source_record_id)` primary key unless dependency inventory
   justifies a separately planned key transition.
3. Add composite FKs
   `(company_id,source_record_id)` → source `(company_id,id)` and
   `(company_id,entity_id)` → entity `(company_id,id)`. Add child-side indexes
   matching leading FK columns. Preflight tenant mismatches and duplicate
   source links; no silent repair.
4. Add nullable typed decision columns first, preserving legacy rows under
   an explicit legacy CHECK branch. New rows must have tenant, actor,
   operation, target, idempotency/request key, and valid result fields.
   Accept requires result entity; reject has none; confirmation targets an
   entity. Keep legacy enum/target columns consistent with typed fields.
5. Build unique ledger key and target/actor lookup indexes only after
   columns and checks exist. Add audit correlation FK/unique partial index
   only after decision schema exists.
6. Add constraints `NOT VALID` where useful, resolve approved historical
   incompatibilities, then validate. Do not fabricate decision, actor, or
   audit data to satisfy constraints.
7. Candidate-pair migration follows §8. Parent and child indexes, checks,
   FKs, helper/function ownership, grants, RLS policies, app cutover, and
   scoped DML revocation are ordered so dependencies exist before use.

### 11.2 Deletion, retention, and erasure

- **Company:** archive/tombstone is the default. Existing company FKs include
  cascades. Physical deletion must not be attempted while the immutable-source
  delete trigger makes cascading source deletion fail or while audit/decision
  retention is unresolved. A separate legal/product-approved purge design
  must inventory all cascades/triggers, explicitly address source immutability,
  preserve required history or document lawful purge, and be rehearsed only
  in disposable data.
- **Source records:** immutable and retained by default. No workflow update or
  delete. Re-imports create new provenance according to existing import
  identity rules; no deletion just to make a unique index build.
- **Entity:** soft delete only through a separately authorized operation.
  Links and history remain; uniqueness still blocks reassignment.
- **Reviewer:** current schema has a reviewer `NOT NULL` FK with
  `ON DELETE SET NULL`, a contradictory lifecycle. Do not delete the auth
  user until a reviewed schema transition preserves attribution, e.g.
  retained/pseudonymous immutable actor reference separate from the live auth
  FK, under legal approval. Never fabricate or silently null historical
  actors.
- **Decisions/requests/audit:** append-only for ordinary roles. Retention
  duration and erasure must be approved together. Correlation FK defaults to
  RESTRICT, not cascade. Any purge is a separately authorized transaction
  that preserves referential truth or removes the linked records together
  according to the approved legal policy.
- **Soft-deleted export/list behavior:** enforce as specified in §10.1 and
  prove with seeded active/deleted rows.

### 11.3 Concurrent indexes and migration 06

Every `CREATE INDEX CONCURRENTLY` is an isolated operation outside an
explicit transaction. Inspect `indisvalid`, `indisready`, exact definition,
duplicate data, and migration history before resume. The prior local Stage 1B
report described Supabase CLI 2.119.0 migration behavior; that is a prior
local finding, not current hosted pipeline proof. Test the actual runner and
pipeline in disposable/staging environments before using concurrent builds.

**Migration 06 boundary:** Stage 1B records local database metadata for
`20261101000006` and recovered SQL, while the repository lacks the matching
file. Recorded local SQL is not proof of Git provenance or original migration
file. Do not reconstruct, rename, replay, or silently mark migration 06
applied. Any history reconciliation is a separate, owner-approved procedure.

**Hosted identity boundary:** no hosted project was identified or accessed
for Stage 1K. Do not infer the target from local names, credentials, or
previous reports. Hosted state remains unverified until separately authorized
project identification and read-only inspection.

## 12. Disposable-local test plan

**No tests are authorized or executed in Stage 1K.** The following are
requirements for a later, separately authorized disposable-local phase.

| Claim | Concrete disposable-local test |
|---|---|
| Gateway identity | Run the isolated gateway with test user sessions. Verify `auth.getUser()` identity and database-verified signed assertion; forge actor/company/role browser fields and prove they are ignored. |
| Forged assertions | Missing, invalid signature, modified actor, target, operation, key, issuer, audience, expiry, future `iat`, unknown `kid`, and algorithm-confusion inputs all fail before mutation. Verify signer private key unavailable to unrelated app/Edge Functions. |
| CSRF/origin | Valid session with hostile/missing Origin/Host is rejected; allowed same-origin succeeds. Exercise real proxy and Server Action path. CORS-only tests do not count. |
| Actual roles and forced RLS | Invoke through real PostgREST JWT roles and final function owners. Verify RLS enabled/forced, executor nonowner/non-bypass, exact ACLs/default privileges, and per-table command policy. |
| Cross-tenant isolation | Use two tenants, actor/member/nonmember/admin roles; probe candidates, entities, links, decisions, ledger, source locks, and lookup. Confirm uniform unavailable responses and no cross-tenant result. |
| Context lifecycle | Pre-set valid and malformed GUCs as gateway; call each RPC; verify entry clear, locked membership-derived context, fail-closed missing/malformed context, and transaction-pool cleanup after commit/rollback. |
| Helper boundaries | Attempt every membership/source/entity lock helper and setter as authenticated, service role without assertion, workers, and scheduler. Verify exact return columns, explicit tenant filters, and source row locking without source UPDATE. |
| Membership races | Two-session READ COMMITTED tests for downgrade/removal committing first and workflow acquiring `FOR SHARE` first. Include owner-removal constraints and verify the chosen linearization behavior. |
| Candidate/link concurrency | Concurrent accept/accept and accept/reject; distinct candidates sharing source; concurrent links to different entities. Verify one decision, one source link, correct conflict, and no partial writes. |
| Worker normalization/rollout | Old directional payload through new DB RPC; reversed/self/repeated pairs; duplicate preflight; worker drain; nonpartial inference; terminal suppression; interrupted index creation and resume. Verify exact index definitions and valid state. |
| Audit spoofing | Every generic audit overload and `log_reconciliation_audit` rejects reserved events for authenticated/service/workers. Wrapper rejects direct untrusted calls, cross-tenant or mismatched decision fields, duplicates; audit failure/deferred constraint failure rolls back decision and state. |
| Ledger/idempotency | Same key/same binding replays; different action/target conflicts; simultaneous same-key calls serialize; expected conflicts persist; 40P01/40001 bounded retry uses same key; unknown/audit errors do not yield success-shaped result. |
| Response loss/key loss | Commit then drop response; recover with same key; clear browser storage and recover via authorized actor/target lookup; test cross-device, account switch, current-member removal, and uniform cross-tenant denial. |
| Confirmation | Candidate confirms once; replay returns same decision; confirmed-without-ledger conflicts; deleted/merged/rejected target denies; canonical data/survivorship/links/count remain unchanged. |
| App-path compatibility | Run every retained operation in §10 under final grants: source create/delete, import create/retry, run create/retry, discrepancy deferred path, export/audit, worker ingestion/matching, invitation audit, import download. Verify exact permission closure and no client workflow RPC. |
| Deleted entities | Verify normal list and both export layers exclude deleted entities; acceptance and confirmation return safe unavailable/conflict; existing links are retained, never redirected. |
| Migration/data lifecycle | Historical duplicate source links, tenant mismatches, candidate direction duplicates, legacy typed rows, existing FKs/triggers, invalid concurrent index and migration-history interruption. No silent cleanup. |
| Retention/deletion | Disposable-only full graph tests for company archive/purge proposal, immutable-source trigger, entity soft delete, reviewer erasure, request-ledger retention, audit/decision retention. Requires owner/legal policy first. |

## 13. Staging and production verification boundaries

### 13.1 Staging (requires separate explicit authorization)

Use the identified intended project and actual deployment configuration to
verify:

- real Supabase JWTs, `auth.getUser()`, PostgREST role claims, CSRF/origin,
  gateway credential isolation, signer service identity, and key rotation;
- signature verifier extension/algorithm/key behavior and database role
  assumptions;
- actual table/function owners, schema CREATE/role membership requirements,
  `BYPASSRLS`, FORCE RLS, ACL inheritance, default privileges, and exact
  overloaded function grants;
- transaction pooler semantics and concurrent membership/candidate/source/
  entity/request-key lock behavior;
- worker pause/drain, migration runner, concurrent-index failure recovery,
  import/matching compatibility, and UI result/lookup behavior.

No staging access or mutation is authorized by Stage 1K.

### 13.2 Production (read-only only, separately authorized)

After explicit project identification and authorization, verify catalogs and
read-only evidence only: project identity; migration history; role/function
owners/attributes; memberships; effective grants/default privileges; RLS and
policy definitions; index validity/definitions; constraints/FK delete
actions; typed-decision, request-ledger, and audit correlation counts; worker
function signatures and conflict targets. Do not invoke workflow RPCs, alter
roles/policies, create/drop indexes, modify migration history, or perform
destructive tests.

## 14. Owner decisions and unresolved assumptions

1. **Owner decision:** approve terminal candidate-pair identity and no
   automatic re-review.
2. **Owner decision:** approve an isolated assertion-signing gateway and
   explicit trust in its deployment/security boundary.
3. **Platform assumption:** prove a supported database-side signature
   verifier, pinned algorithm/key storage, rotation, and revocation. If not
   available, require another design; no unsigned fallback.
4. **Platform assumption:** determine whether a dedicated PostgREST gateway
   role/JWT can be provisioned. Do not assume it; service-role fallback still
   requires signed assertions and direct DML restriction.
5. **Owner decision:** approve server-side request-ledger fields, retention,
   actor-target lookup, privacy minimization, and behavior after membership
   revocation/account deletion.
6. **Owner decision:** approve entity acceptance eligibility (`candidate` or
   `confirmed`), soft-deleted entity visibility, and no redirect/reassignment.
7. **Owner/legal decision:** approve company archive versus physical purge,
   immutable source retention, reviewer erasure/pseudonymization, and
   decision/audit/ledger retention.
8. **Platform assumption:** verify role creation/attributes, schema CREATE,
   ownership transfer, role membership, and exact Supabase migration-user
   capability in disposable environment.
9. **Repository/deployment gate:** enumerate every deployed `service_role`,
   worker, scheduler, application, trigger, and operational audit caller.
   Current source search is not proof of complete runtime usage.
10. **Prior local finding only:** migration 06 has local recorded SQL/history;
    Git provenance and intended hosted project remain unresolved.

## 15. Proposed implementation sequence

This is a future sequence, not authorization to execute it:

1. Obtain product/security/legal decisions and identify the intended
   disposable environment; settle gateway isolation, assertion verification,
   ledger retention, terminal pairs, and lifecycle policy.
2. In disposable local setup, verify platform role/ownership/signature
   prerequisites; if any fail, stop and amend the design.
3. Inventory all current and deployed callers; snapshot read-only schema,
   constraints, duplicates, roles, ACLs, overloads, and migration state.
   Keep migration 06 provenance separate.
4. Test assertion verifier, isolated gateway, exact role grants, ownership
   transfer, forced RLS, helper boundaries, and context lifecycle before
   allowing any data mutation in the workflow.
5. Create typed decision/request-ledger/audit design prerequisites in
   dependency order; preserve legacy rows, preflight duplicate and FK
   compatibility, add parent indexes before composite FKs and child indexes.
6. Deploy/test database pair normalization with the old partial index and
   directional worker payloads; remediate canonical duplicate pairs only by
   approved auditable disposition.
7. Pause/drain matching workers; build and validate nonpartial all-status
   pair index; switch exact conflict inference; validate CHECK; remove old
   partial index only after function verification; resume and monitor.
8. Create helpers/functions with fixed search paths and correct owners; apply
   exact policies, column grants, schema/type/function privileges, audit
   restrictions, and default ACLs. Verify effective grants, not just GRANT
   statements.
9. Implement gateway/Server Action and UI result/lookup behavior; cut over
   accept, reject, confirmation, and export soft-delete filtering.
10. Preserve separately scoped source/import/run/retry/discrepancy/invitation/
    worker paths. Revoke only exact obsolete workflow DML after end-to-end
    callers pass tests.
11. Run the full disposable-local matrix. Any failed invariant blocks
    staging authorization; unexpected SQL errors remain visible.
12. Request a separate independent review of test evidence and only then
    decide whether to authorize staging. Production remains a distinct,
    separately authorized process with read-only verification first.

## 16. Final recommendation

**CONDITIONAL GO FOR A FUTURE DISPOSABLE-LOCAL IMPLEMENTATION-TESTING AUTHORIZATION REVIEW.**

The Stage 1K design is concrete enough to be considered for a future,
disposable-local implementation-test authorization only after the owner
decisions and platform prerequisites in §14 are resolved. It does not grant
that authorization itself. In particular, do not begin implementation until
the signing verifier, isolated gateway, executor ownership/RLS, generic audit
closure, worker pause plan, and request-ledger retention model have been
accepted and independently reviewed.

There is **no authorization** for staging, hosted Supabase access, production
changes, migration execution, destructive testing, or production workflow
calls. No tests were run. Migration 06 provenance and hosted project identity
remain unresolved.

### Validation and change record

- Created exactly `docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md`.
- The baseline worktree contained numerous pre-existing modified and
  untracked files. They were not edited, removed, reset, stashed, or
  overwritten by this documentation task.
- No tests, SQL, database commands, hosted access, dependency operations, or
  configuration changes were performed.
- Validation passed: 22 local document links resolve; no line anchors were
  used; all five code fences are balanced; no trailing whitespace was found;
  and `git diff --check` exited successfully.
- Final `git status --short --untracked-files=all` matches the pre-write
  status plus this one new Stage 1K document. Git emitted the same unrelated
  pre-existing LF-to-CRLF warning for
  `examples/nextjs/app/auth/signup/page.tsx`; it was not changed.
