# ZamBase Phase 2A.3.4 — Stage 1J Independent Review

> **Read-only design review.** No application code, migrations, database
> objects, roles, grants, RLS policies, functions, indexes, dependencies, or
> configuration were changed. No local or hosted database was accessed. This
> report is the only file created for Stage 1J; all pre-existing worktree
> changes were preserved.

## 1. Executive summary and verdict

**NO-GO**

Stage 1I improves the design in meaningful ways: it proposes a global
source-link uniqueness rule, tenant-consistent foreign keys, permanent
normalized candidate-pair identity, membership-before-candidate locking, a
separate confirmation contract, and an atomic typed-decision/audit record.
These are design statements, not implementation evidence. Stage 1I itself
correctly says implementation is not authorized.

The design is not sufficiently closed to proceed to the full disposable local
implementation-testing milestone:

1. The server-only gateway is technically possible in Next.js, but the
   proposed service-role fallback does not provide a gateway-only principal.
   The repository has other service-role consumers, and the actual
   PostgREST role configuration and service credential isolation have not
   been demonstrated.
2. The RLS matrix is semantic rather than executable. It omits exact policy
   expressions and the complete setter/getter/validation protocol for the
   transaction-local tenant context. The security depends on those details.
3. Audit controls are not yet proven across every overload and caller. The
   decision-ID wrapper needs explicit tenant/actor/action validation in
   addition to restricted EXECUTE and uniqueness.
4. The worker currently emits directional pairs, and its database writer
   still uses pending-only conflict inference. The Stage 1I migration does
   not give a strict expand/contract ordering that prevents old writers from
   hitting the proposed ordered-pair constraint during rollout.
5. Browser `localStorage` is best-effort client persistence, not durable
   idempotency recovery. Clearing/loss of the key after a committed action
   can prevent replay of the original decision.
6. The application cutover matrix omits current direct-write paths for data
   sources, import jobs, reconciliation runs, and retry operations. Its
   deleted-entity requirement is not yet realized by the current list/export
   code.

No tests were run. No claim is made about local runtime behavior, actual
PostgREST roles, staging, or hosted state. The recommendation does not
authorize Stage 2 implementation, hosted changes, staging deployment, or
production activity.

## 2. Scope and evidence

Reviewed Stage 1A through Stage 1I, with focus on the
[Stage 1I design amendment](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md),
the [Stage 1H independent review](./PHASE-2A-3-4-STAGE-1H-INDEPENDENT-REVIEW.md),
the [Stage 1B local readiness report](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md),
the [reconciliation schema and policies](../supabase/migrations/20261029000001_reconciliation_module.sql),
the [worker and audit security migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
the [generic audit hardening migration](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
the [Next.js reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts),
the [Next.js cookie-backed Supabase client](../examples/nextjs/lib/supabase/server.ts),
the [review UI](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx),
the [Splink worker](../services/reconciliation/matching/splink_worker.py),
the [invitation Edge Function](../supabase/functions/invitations/index.ts),
and the [import download Edge Function](../supabase/functions/import-download-url/index.ts).

Evidence categories:

- **Repository-verified:** facts read from current-worktree source. Several
  files are pre-existing untracked or modified files; their presence does not
  prove they are committed or deployed.
- **Prior local finding:** recorded in Stage 1A/1B. It is historical local
  evidence, not a fresh database query and not hosted evidence.
- **Design assessment:** evaluates the Stage 1I proposal; it is not proof of
  implementation.
- **Unverified:** actual PostgreSQL catalog state, effective ACLs, live
  PostgREST roles/JWT claims, role ownership, data compatibility, or hosted
  behavior.

The current Next.js server client uses the public anon key with cookie-backed
user authentication; it does not define the proposed private workflow
service client ([server client](../examples/nextjs/lib/supabase/server.ts#L11)).
The existing actions call `auth.getUser()` and use the user's RLS-bound
session ([reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts#L159)).

## 3. H1–H6 independent findings matrix

| Finding | Classification | Independent assessment and remaining proof |
|---|---|---|
| **H1 — One source record, one entity** | **Resolved in design; technically sound subject to compatibility** | `UNIQUE(source_record_id)` enforces the stated global uniqueness invariant because the source row identifier is a UUID primary key. The proposed composite tenant foreign keys are a reasonable additional consistency constraint, provided parent `(company_id, id)` keys exist and historical rows satisfy them. The existing identifier primary key can remain. Existing cascade relationships, duplicates, and consumers still require preflight and disposable migration tests. |
| **H2 — Executor RLS and context** | **Partially resolved** | Stage 1I supplies a role/table/command semantic matrix, denies unrestricted policies, and correctly avoids granting UPDATE on immutable source rows just to lock them. It explicitly defers exact SQL, helper ownership/grants, and effective RLS verification. The setting's provenance, validation, and all policy expressions remain critical implementation details; `FORCE RLS` alone does not establish them. |
| **H3 — Audit integrity** | **Partially resolved** | Reserving workflow actions from generic audit and deriving a correlated event from a typed decision are sound directions. The amendment does not provide executable checks across all deployed overloads/default privileges or prove the wrapper's decision is in the caller's validated tenant/actor context. Role ACLs restrict callers but are not a call-stack discriminator. |
| **H4 — Permanent candidate-pair identity** | **Resolved in design; runtime/migration compatibility unverified** | Ordered UUID pairs, a CHECK, all-status uniqueness, and non-partial `ON CONFLICT` address terminal-pair regeneration. The current worker still supplies directional IDs and calls a writer using pending-only conflict inference. The ordered constraint and rewritten writer must be deployed compatibly; all-status historical duplicates must be preflighted. |
| **H5 — Server-only gateway** | **Partially resolved** | The Next.js Server Action pattern can verify the cookie-backed user with `auth.getUser()` and call a separate server-only client. However, the proposed database identity is not yet gateway-specific. A shared `service_role` key is a bearer credential with broad trust, and there is no repository evidence of a dedicated PostgREST role/key that can assert the actor while remaining unavailable to other service-role callers. |
| **H6 — Confirmation and idempotency** | **Partially resolved** | The separate confirmation RPC, typed result union, same-key replay/conflict rules, and retry behavior are substantially specified. `localStorage` survives common reloads but can be cleared, unavailable, or lost with browser state; after a lost response and lost key, a new key cannot replay the committed outcome. The current UI does not yet handle the proposed union or persist keys. |

No finding is considered runtime verified by this review.

## 4. New findings

### J1 — High: the gateway identity is not isolated from other service-role callers

**Evidence:** Stage 1I §5 proposes a separate service client and permits a
`service_role` fallback, while noting that this principal may have `BYPASSRLS`
and that all callers must be inventoried
([Stage 1I §5](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L120)).
The existing Next.js client uses the anon key and does not implement such a
gateway client ([server client](../examples/nextjs/lib/supabase/server.ts#L11)).
Other repository functions already read `SUPABASE_SERVICE_ROLE_KEY`
([invitation function](../supabase/functions/invitations/index.ts#L76);
[download function](../supabase/functions/import-download-url/index.ts#L11)).

**Technical explanation and scenario:** a server-side `auth.getUser()` call
can establish a user identity for the gateway request, but the database sees
the gateway's service principal, not that user's JWT subject. The RPC
therefore trusts the supplied reviewer assertion. If the same service-role
credential is available to any other function or server component that can
call the RPC, that caller can assert another actor unless an independent
gateway-only credential or signed assertion is verified. Hiding a service key
from the browser does not distinguish trusted server functions from one
another. The Stage 1I alternative of a dedicated gateway principal is only
viable if the target Supabase/PostgREST deployment can issue/assume it and
the app can authenticate as it; no such configuration is present in the
reviewed sources.

**Required correction:** choose and prove one deployable principal model.
Prefer a dedicated, least-privilege gateway role/credential unavailable to
other service-role code. If platform constraints force a shared service
principal, explicitly accept the trust boundary and isolate/allowlist the only
gateway code that can use it; do not describe that model as gateway-only.
Document how the role reaches PostgREST and how the database validates actor
assertions. Add a negative test showing every non-gateway principal,
including service-role callers, cannot fabricate workflow decisions or
authoritative audit events.

**Blocks disposable local implementation testing:** Yes, until the identity
contract and local role simulation are fixed. A narrowly scoped platform
feasibility spike may be designed separately, but this report does not
authorize it.

### J2 — High: executor context and RLS are not yet an executable security boundary

**Evidence:** Stage 1I §7 says the executor sets a transaction-local tenant
context and proposes a fixed-path getter and table/command matrix, but
explicitly calls the matrix semantic rather than executable
([Stage 1I §7](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L252)).
The actual RLS policies in the existing schema are for `authenticated`, not
the proposed executor role ([schema policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L478)).

**Technical explanation and scenario:** policy correctness depends on the
exact policy target role, table privileges, context setter, getter, and
function execution chain. A policy trusting a malformed, stale, or
caller-influenced setting can expose or mutate another tenant's rows. The
proposal says the gateway cannot benefit from setting the context itself,
but does not state the exact call protocol that proves the value came from a
membership-locked function invocation, how it is cleared/overwritten, or
which roles can invoke any context helper. A `NOLOGIN` executor and
`FORCE ROW LEVEL SECURITY` do not compensate for an incorrect policy or
overprivileged owner.

**Required correction:** specify the complete SQL semantics before
implementation: executor ownership and attributes; exact per-table/per-command
`USING`/`WITH CHECK`; schema/type/table/column ACLs; helper owners and
signatures; context setter/getter ACLs; context format and fail-closed parsing;
and function `search_path`/transaction behavior. Ensure the executor does not
own the protected tables or have `BYPASSRLS`. Verify the context is overwritten
after the locked membership check in every entry point and is not accepted
from request state. Test with actual PostgREST roles and forced RLS, not only
SQL `SET ROLE`.

**Blocks disposable local implementation testing:** Yes; otherwise the local
test would be implementing unspecified security behavior rather than
verifying a settled design.

### J3 — High: the authoritative audit wrapper does not define enough validation

**Evidence:** the current generic `log_audit` accepts an arbitrary action and
grants EXECUTE to `authenticated` and `service_role`
([audit migration](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L50),
[grant](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L104)).
The original reconciliation audit helper also accepts caller-provided
action, company, target, and metadata
([schema helper](../supabase/migrations/20261029000001_reconciliation_module.sql#L551)).
Stage 1I proposes reserved workflow actions and a decision-ID wrapper
([Stage 1I §10](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L397)).

**Technical explanation and scenario:** the amendment's proposed generic
action rejection is the right control, but no implementation is supplied and
the report does not establish the exact deployed overload/ACL set. The
decision-ID wrapper's unique partial index prevents two correlated rows for
one decision; it does not by itself prove the referenced decision belongs to
the currently locked tenant/reviewer, or that its action/result match the
event being written. EXECUTE limited to the executor role is safe only if the
executor is not directly assumable and every executable function owned by it
is reviewed. A future executor-owned function that passes an arbitrary
decision ID could otherwise create a misleading event.

**Required correction:** make the wrapper verify decision ID, tenant context,
reviewer assertion, action, result entity, and typed-row invariants before
inserting. Restrict its inputs to the decision ID; use fixed mappings and
metadata; reject existing or mismatched correlation; raise on all audit
errors. Define exact generic-audit behavior for every overload and all
callers/default privileges, especially `service_role`. Add tests for direct
generic spoofing, direct wrapper execution by untrusted roles, cross-tenant
decision IDs, mismatched decision action/result, duplicates, and transactional
rollback.

**Blocks disposable local implementation testing:** Yes, pending the
executable audit contract and exact ACL proof.

### J4 — High: worker pair normalization and index deployment need an ordered compatibility plan

**Evidence:** the current matching database function inserts worker-provided
`a`/`b` in their original order and infers the pending-only partial unique
index ([worker RPC](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L199)).
The Splink worker emits `record_a_id` and `record_b_id` as directional
left/right values and forwards them to that RPC
([worker pair construction](../services/reconciliation/matching/splink_worker.py#L196),
[worker writer](../services/reconciliation/matching/splink_worker.py#L235)).
Stage 1I proposes a normalized check/index and a coordinated worker update
([Stage 1I §§8, 15](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L307)).

**Technical explanation and scenario:** adding `record_a_id < record_b_id`
before the database RPC normalizes inputs makes any old worker submission
with reversed IDs fail. Installing all-status uniqueness while the old
function or worker is active also leaves the intended conflict target and
error behavior dependent on rollout timing. The amendment says “coordinated
rollout” but does not state a safe expansion order or a worker pause/compatibility
gate. The existing pending-only target cannot be treated as proof that the
new all-status index is correctly inferred.

**Required correction:** specify a backward-compatible sequence: first
deploy/test an RPC that canonicalizes inputs while preserving the existing
index contract; preflight and explicitly resolve normalized historical
duplicates; then create/validate the new all-status unique index and CHECK;
then switch to the exact non-partial conflict inference; finally remove the
old partial index after all workers are upgraded or paused. If a sequence
cannot safely coexist, require a controlled worker drain. Include exact
index definitions and tests against the actual PostgreSQL version.

**Blocks disposable local implementation testing:** Yes, until the test
migration sequence and worker compatibility window are specified.

### J5 — Medium: browser-local idempotency keys cannot guarantee replay after key loss

**Evidence:** Stage 1I stores keys in user/operation/target-scoped
`localStorage` and expects reuse after timeouts and reloads
([Stage 1I §12](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L472)).
The design selects committed-decision-only semantics and does not reserve a
key for failed/conflict requests.

**Technical explanation and scenario:** `localStorage` is persistent for
ordinary same-origin browser use, but it can be cleared, unavailable, removed
by the user, or absent on another device/browser. If a decision committed but
its response was lost and the key is then lost, a newly generated key is not
the same request identity. The candidate/entity may now be terminal, so the
retry can return a conflict rather than the original decision. The server
cannot resolve this solely from the new key. This is a recovery limitation,
not an authorization token vulnerability.

**Required correction:** either document the bounded guarantee and provide a
safe authorized “lookup my decision for this target” recovery path, or persist
request identity server-side before/with the operation so the client can
recover the original key/outcome. Preserve same-actor/tenant authorization,
avoid leaking cross-tenant existence, and define account-switch behavior.
Test lost response after commit both with the key retained and after browser
storage is cleared.

**Blocks disposable local implementation testing:** No by itself, if the
owner explicitly accepts the limitation and the behavior is tested; otherwise
yes for an “exact replay after response loss” requirement.

### J6 — Medium: application cutover matrix omits existing direct writers and entity filtering

**Evidence:** Stage 1I §14 lists accept/reject, confirmation, identifiers,
worker paths, export/list reads, discrepancy resolution, and manual entity
operations ([Stage 1I §14](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L539)).
The actual Server Actions also directly insert data sources and import jobs,
soft-delete data sources, create runs, and retry failed jobs/runs
([actions](../examples/nextjs/lib/actions/reconciliation.ts#L12),
[data source writes](../examples/nextjs/lib/actions/reconciliation.ts#L47),
[run creation](../examples/nextjs/lib/actions/reconciliation.ts#L125),
[retry operations](../examples/nextjs/lib/actions/reconciliation.ts#L526)).
Stage 1I §16 requires deleted entities to be absent from normal lists and
exports ([Stage 1I §16](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md#L623)),
but the current entity/export action sources need explicit filters and
verification ([export action](../examples/nextjs/lib/actions/reconciliation.ts#L406)).

**Technical explanation and scenario:** if application access is revoked
broadly rather than per-table/column/role, these operational actions and the
worker lifecycle can break even though they are not part of match accept or
reject. Conversely, leaving broad DML to preserve them can retain bypasses on
decision-bearing columns. The design says not to broadly revoke DML, but it
does not inventory these paths or name the exact table/column privileges
they require. The current UI/action code also does not establish the Stage 1I
soft-deleted-entity exclusion.

**Required correction:** extend the cutover matrix with every current writer
and its principal, tables/columns, authorization, replacement, and
in-scope/deferred decision. Include source creation/import queue/run/retry,
discrepancy resolution, export auditing/storage, manual entity/link
operations, and worker RPCs. Specify table/column-scoped revocation that
preserves unrelated paths. Before cutover, add deleted-entity filters to
normal entity lists, confirmation/acceptance eligibility, and export, then
test all those views.

**Blocks disposable local implementation testing:** Yes for any ACL
revocation or integration test that assumes the current app remains usable;
not a blocker for isolated schema-only tests that make no permission changes.

## 5. Security and privilege feasibility assessment

### 5.1 Server gateway and identity propagation

The selected architecture is technically implementable in principle:

- A Server Action can obtain the cookie-backed Supabase client and call
  `auth.getUser()` to verify the current user.
- It can derive the actor UUID from that verified result and ignore actor or
  tenant fields supplied by browser input.
- A second server-only client can call a privileged RPC.

However, the repository currently has only the cookie-backed anon-key client,
not the dedicated private client. A production-ready implementation would
need a separately provisioned credential, environment isolation, logging and
bundle checks, rotation, and a defined deployment path. `auth.getUser()` does
not make the database RPC see the same user identity when the RPC is invoked
with a service credential. The RPC sees the server principal and trusts the
assertion. The owner must decide whether that assertion is acceptable and
which systems are trusted to make it.

The design appropriately calls out CSRF and same-origin checks. Those still
need concrete handling for every Server Action and deployment host/proxy
configuration; a server-only action is not by itself an authorization
control. Replay is handled at the database request key, but the localStorage
recovery limitation remains.

### 5.2 Role and forced-RLS feasibility

The `reconciliation_workflow_executor` role is a plausible least-privilege
design if it is `NOLOGIN`, `NOBYPASSRLS`, does not own protected tables, and
owns only the intended fixed-search-path functions. The `postgres`-owned
lock helpers are also plausible if their SQL is narrow and row-level
authorization is explicit. None of those role attributes, function owners,
membership paths, or grants has been verified for the target Supabase
deployment.

The Stage 1I matrix correctly avoids granting source-record UPDATE privilege
to obtain row locks. Lock helpers must return only the required identifiers
and existing link references, use explicit tenant predicates, and be
unexecutable by clients/workers. The final function and RLS policies must be
tested together under the actual definer and effective table owner roles.
Testing a policy under `authenticated` or a local superuser alone would not
prove executor behavior.

### 5.3 Audit trust

The repo has a generic `log_audit` definition in both the early helper
migration and the later hardening migration, with the later definition
granting `authenticated` and `service_role`. No new database state was read,
so deployed overloads, ACLs, default privileges, and grants remain unknown.
The existing `log_reconciliation_audit` accepts caller-selected event data
and must remain revoked from untrusted roles.

Reserving action values from the generic function is necessary but not
sufficient until the function checks every allowed caller path, the wrapper
validates typed decision fields, and all audit writes are atomic with the
decision. A generic audit event that merely shares an action label must never
be presented as a verified workflow decision.

## 6. Application and worker compatibility assessment

The current direct-write paths observed in the reconciliation Server Actions
are:

| Current path | Existing behavior | Stage 1I disposition / required boundary |
|---|---|---|
| Match acceptance | Updates candidate status; may insert entity/identifiers; updates candidate entity ID; calls generic audit. | Replace atomically with accept RPC; preserve no canonical overwrite and source immutability. |
| Match rejection | Updates candidate status and writes generic audit. | Replace atomically with reject RPC. |
| Entity confirmation | Updates entity status and separately writes generic audit. | Replace with separate confirmation RPC; no canonical changes. |
| Entity export | Reads entity/links/source records, uploads export object, and writes generic audit. | Keep export read authorization; preserve non-workflow audit action; explicitly exclude soft-deleted entities. |
| Discrepancy resolution | Reads then updates discrepancy and separately writes generic audit. | Explicitly deferred; retain only required scoped permission until replacement. |
| Data source creation/soft deletion | Inserts a data source; soft-deletes it by UPDATE. | Not enumerated in Stage 1I matrix; preserve only the specific operations and role permissions required. |
| Import-job creation | Inserts an import job after user/session and data-source checks. | Not enumerated in Stage 1I matrix; preserve separately from decision DML and test worker handoff. |
| Reconciliation-run creation | Inserts a queued run. | Not enumerated in Stage 1I matrix; preserve separately and test scheduler/worker lifecycle. |
| Import/run retry | Updates failed import jobs and reconciliation runs back to pending/queued. | Not enumerated in Stage 1I matrix; define exact ACL and validate worker transitions. |
| Candidate generation | Python worker calls lease-bound database RPC; current function preserves directional pairs and pending-only conflict inference. | Normalize in the database contract and coordinate worker/index rollout. |
| Source ingestion | Existing import worker uses a narrow worker RPC. | Retain worker-only boundary; no executor UPDATE/DELETE on immutable source rows. |
| Invitation/operational audit | Service-role Edge Function callers can write non-workflow audit events. | Inventory every caller before generic audit restrictions; explicitly block workflow action fabrication. |

The matrix in Stage 1I is directionally useful but does not fully cover the
listed data-source/import/run/retry writes. It must not be used to justify
revoking broad DML until the exact existing permissions and replacement
operations are mapped. A repository search is not proof of the complete
deployed caller inventory.

## 7. Migration feasibility and data compatibility

### 7.1 Source-link uniqueness and foreign keys

The existing identifier primary key is `(entity_id, source_record_id)`, so
the same source can currently occur under multiple entities. Adding global
`UNIQUE(source_record_id)` enforces the proposed rule. Composite foreign keys
on `(company_id, source_record_id)` and `(company_id, entity_id)` additionally
prevent tenant mismatch, provided unique parent keys `(company_id, id)` exist.
Child-side indexes must support both composite references.

Existing single-column foreign keys use `ON DELETE CASCADE`; the entity,
identifier, and source schema also has company cascades. The immutable-source
trigger and company cascade were previously identified as incompatible with
ordinary hard deletion. Stage 1I correctly gates physical purge and reviewer
erasure, but compatibility still requires a disposable full-FK/trigger
rehearsal. Soft-deleted entity links remain unique and must not silently be
reassigned.

### 7.2 Pair uniqueness and historical rows

The new normalized, all-status identity requires duplicate/reversed-pair
preflight and explicit disposition. Existing worker code uses the partial
pending index. The test must prove exact `ON CONFLICT` inference after the
new non-partial index exists and while the worker is upgraded. Do not silently
delete terminal candidates or their decisions.

### 7.3 Typed decisions, audit correlation, and deletion

Nullable typed columns plus an explicit legacy CHECK branch can preserve old
rows, but exact column types, enum creation order, constraint expressions,
uniqueness predicates, and historical validation queries remain to be
specified. Parent unique indexes must exist before composite FKs; child
indexes must follow column creation; foreign keys must be validated after
approved data cleanup. Concurrent index builds remain standalone, and invalid
index/history recovery must be exercised with the exact deployment runner.

The reviewer account FK contradiction (`NOT NULL` with `ON DELETE SET NULL`)
and the audit-decision FK retention policy remain owner decisions, not
technical details to guess. Historical audit rows remain unverified unless
correlated to typed decisions.

### 7.4 Migration 06 and hosted-project boundary

The prior Stage 1B report records a **local** migration-history entry
`20261101000006` with recoverable SQL and a matching active local function,
while the corresponding repository migration file is absent
([Stage 1B §2](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md#L65)).
That is not proof of Git provenance or proof that the repository originally
contained that SQL. Do not reconstruct or apply migration 06 during this
review. Hosted project identity, schema, function body, ACLs, and migration
history remain unverified; no hosted project was accessed or guessed.

## 8. Required disposable local tests

No tests were run for this review. A corrected design should name and pass at
least the following tests before any later environment is considered:

| Claim | Concrete disposable-local test |
|---|---|
| Gateway identity is genuine | Exercise the actual Next.js cookie-backed Server Action and Supabase `auth.getUser()`; submit forged actor/company fields and prove they are ignored. Attempt the workflow RPC as `anon`, `authenticated`, workers, scheduler, and every non-gateway service principal. |
| CSRF/origin enforcement is effective | Send valid-cookie requests from missing, hostile, and allowed origins through the actual route/proxy setup; verify rejection before privileged RPC invocation. Verify secure cookie/session behavior. |
| Service credential is isolated | Build the app and inspect client bundles/source maps and logs; prove no secret is exposed. Verify other service-role callers cannot invoke workflow RPCs or assert arbitrary actors. |
| Executor is forced through tenant RLS | Use actual PostgREST JWT claims/roles and the final function owner; test `ENABLE`/`FORCE RLS`, each table/command policy, absent/malformed/pre-set context, and cross-tenant reads/writes. Confirm executor is not table owner and has no `BYPASSRLS`. |
| Helpers are least privilege | Attempt source/entity/membership lock helper calls as every client/worker role; verify only authorized workflow functions can call them and returned fields reveal no extra tenant data. Confirm source locking succeeds without source UPDATE. |
| Membership authorization is atomic | Two-session races: membership downgrade/removal first; decision locks membership first; repeated under READ COMMITTED. Verify a downgrade/removal that commits first denies and a workflow that locks first completes before the membership change. Include owner-removal constraints/triggers. |
| Candidate decisions serialize | Concurrent accept/accept and accept/reject for one candidate; concurrent different candidates sharing a source; concurrent candidates sharing an entity. Verify one decision, no duplicate source link, deterministic conflicts, and no partial writes. |
| Worker pair contract works | Submit reversed pairs, self-pairs, repeated pairs, and terminal-pair inserts through the exact worker RPC. Verify normalization, ordered CHECK, all-status unique index, non-partial conflict inference, and old/new worker rollout behavior. |
| Audit is authoritative | Call every generic audit overload as authenticated and service role with reserved workflow actions; directly call the authoritative wrapper as each role; test cross-tenant/mismatched IDs, duplicate correlation, and event action/target tampering. Inject audit failure and prove decision/entity/link changes roll back. |
| Idempotency survives response loss | Commit the decision but drop the response; retry with the same key and verify exact replay/no second audit. Retry with same key/different action/target and verify conflict. Repeat after key loss/storage clearing and verify the explicitly accepted recovery outcome. Test user switching and bounded 40P01/40001 retries. |
| Confirmation is correct | Candidate→confirmed, already-confirmed without key, same-key replay, mismatched key, unauthorized actor, deleted/merged entity, audit failure rollback, and unchanged canonical data/survivorship. |
| App cutover preserves unrelated paths | Exercise data-source creation/deletion, import job creation/retry, run creation/retry, discrepancy resolution, export/audit, worker ingestion, and worker matching under the final table/column grants. Verify deferred paths remain explicitly scoped and operational. |
| Deleted entities stay excluded | Seed active and soft-deleted entities; verify entity lists, confirmation, match acceptance, and exports exclude or safely label deleted entities as specified. |
| Migration is recoverable | Start from historical rows and existing FKs; rehearse each migration stage, concurrent-index failure/interruption, invalid-index inspection/removal, migration history failure, and safe resume. Verify no silent duplicate deletion or fabricated provenance. |
| Retention lifecycle is compatible | In a disposable database only, rehearse entity/company deletion, immutable-source trigger behavior, cascades, reviewer deletion/erasure, and audit/decision retention under the approved policy. No production destructive test. |

**Staging-only verification** must then use the real project configuration,
PostgREST roles/JWT claims, pooler, service credentials, deployed Server
Action, concurrency, and migration runner. It requires separate explicit
authorization and correct project identification.

**Production verification** must remain read-only: inspect intended project
identity, migration history, role/function owners, ACLs/default privileges,
RLS/policies, index validity, constraints, and decision/audit correlations.
Do not invoke workflow functions, mutate roles/policies, or run destructive
tests in production.

## 9. Outstanding owner decisions

1. Is a shared `service_role` trust boundary acceptable for actor assertions,
   or is a dedicated gateway role/credential required?
2. Can the actual Supabase/PostgREST deployment provision and use the proposed
   dedicated gateway principal? What exact JWT role claim or connection
   mechanism is supported?
3. Is browser-local idempotency storage sufficient, or is recoverable
   server-side request identity required after storage loss?
4. Are accepted/rejected candidate pairs permanently terminal, with no
   automatic re-review?
5. Are `candidate` and `confirmed` entities valid acceptance targets, and what
   happens to identifiers attached to soft-deleted entities?
6. What retention/pseudonymization policy applies to reviewer erasure,
   decision attribution, audit correlation, company deletion, and immutable
   source records?
7. Which data-source, import, run, discrepancy, manual entity, export, and
   worker writes are in this milestone, and which remain deferred with
   narrowly scoped permissions?
8. Who approves the historical duplicate/pair remediation and the exact
   recovery plan for concurrent-index or migration-history interruption?
9. Which hosted Supabase project, if any, is the intended target? It remains
   unidentified and inaccessible in this review.

## 10. Final recommendation

**NO-GO**

Do not proceed to the Stage 2 implementation-testing milestone until J1–J4
and J6 are resolved in a revised design, J5's recovery limitation is
explicitly accepted or corrected, and the owner decisions above are recorded.
The new design should receive another independent review before implementation
authorization.

This verdict does not authorize staging or production deployment, hosted
database access, migration execution, destructive testing, or any database
changes. Migration 06 provenance and hosted project identity remain
unresolved.

### Validation and change record

- Created exactly: `docs/PHASE-2A-3-4-STAGE-1J-INDEPENDENT-REVIEW.md`.
- Compared with the pre-write worktree status, this task added only the
  Stage 1J report; pre-existing modified and untracked files were preserved.
- No database, hosted project, migration, test suite, or dependency was
  accessed or executed.
- Validation passed: 37 local Markdown link targets resolve and their line
  anchors are in range; code fences are balanced (none in this report); no
  trailing whitespace was found; `git diff --check` exited successfully.
- Git emitted an unrelated pre-existing LF-to-CRLF warning for
  `examples/nextjs/app/auth/signup/page.tsx`; that file was not changed by
  this task.
- No tests were run; implementation and runtime behavior remain unverified.
