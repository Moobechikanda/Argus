# ZamBase Phase 2A.3.4 — Stage 1N Independent Design Review

> **Read-only design review.** This report assesses Stage 1M and current
> repository evidence. No application code, migration, database object, role,
> grant, policy, function, index, data, dependency, configuration, or secret
> was changed. No tests, SQL, database operations, local or hosted Supabase
> access, or migration-06 investigation were performed. Pre-existing worktree
> changes were preserved.

## 1. Executive verdict

**NO-GO for a separate disposable-local implementation-testing authorization
review at this time.**

Stage 1M makes a material improvement by replacing the unverified signed
assertion with an authenticated Supabase user session and a database-owned
authorization boundary. Its direct-PostgREST-call position is also sound in
principle: an authenticated user may invoke the same narrow RPC, so the
Server Action is not treated as the security boundary. These choices
substantially address the earlier gateway-identity problem.

However, the amendment still does not specify enough executable detail to
make the proposed security and data invariants determinate. In particular:

1. The executor/RLS design names `workflow_tenant()` and trusted helper
   behavior but omits exact signatures, bodies, ownership, grants, policies,
   and effective-role closure.
2. Audit provenance is described as authoritative, but the exact action
   allow/deny set, helper call boundary, correlation constraints, and
   “exactly one” enforcement mechanism are not specified.
3. The worker pause is procedural rather than enforced. A stale or separately
   invoked matching worker can still call the old granted RPC during
   migration; the pair-to-historical-candidate mapping and conflicting
   terminal-history resolution are also undefined.
4. The request ledger does not define canonical payload encoding or how a
   user recovers a committed terminal conflict after losing the request key.
5. The caller matrix is a useful writer inventory, but not a complete
   read/write, principal, function-owner, and effective-privilege closure.
6. Composite foreign keys, typed-decision constraints/index ordering, and
   retention relationships remain requirements rather than a complete
   migration/lifecycle contract.

These are not merely runtime questions. Disposable-local testing would
otherwise require inventing security-critical functions, policies,
historical-pair semantics, and migration behavior during implementation.
Another design amendment is justified. The chosen authenticated-RPC
architecture need not be abandoned, but the executor/audit contracts and
worker/data migration design must be made executable before a separate
authorization decision.

This verdict authorizes **no** implementation, tests, SQL, database
operations, migration activity, staging, hosted access, production changes,
or Stage 2.

## 2. Scope, evidence, and limitations

### 2.1 Reviewed material

Read the complete [Stage 1M amendment](./PHASE-2A-3-4-STAGE-1M-CORRECTED-DESIGN-AMENDMENT.md)
and compared it with [Stage 1L](./PHASE-2A-3-4-STAGE-1L-INDEPENDENT-REVIEW.md),
[Stage 1K](./PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md),
[Stage 1J](./PHASE-2A-3-4-STAGE-1J-INDEPENDENT-REVIEW.md),
[Stage 1I](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md),
[Stage 1H](./PHASE-2A-3-4-STAGE-1H-INDEPENDENT-REVIEW.md),
[Stage 1G](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md),
[Stage 1F](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md),
[Stage 1E](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md),
and earlier findings where relevant.

Repository sources checked include the
[reconciliation schema, policies, and audit helper](../supabase/migrations/20261029000001_reconciliation_module.sql),
[membership helpers and audit function](../supabase/migrations/20260514000007_helper_functions.sql),
[membership audit triggers](../supabase/migrations/20260514000009_triggers.sql),
[worker RPCs and grants](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
[lease recovery](../supabase/migrations/20261101000004_recover_missing_worker_leases.sql),
[cron and retention setup](../supabase/migrations/20261030000002_reconciliation_security_ops.sql),
[reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts),
[cookie-backed Supabase client](../examples/nextjs/lib/supabase/server.ts),
[dashboard summary](../examples/nextjs/app/dashboard/reconciliation/page.tsx),
[review page](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx),
[import detail page](<../examples/nextjs/app/dashboard/reconciliation/imports/[id]/page.tsx>),
[entity list](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx),
[import worker](../services/reconciliation/imports/worker.py),
[second import loader](../services/reconciliation/imports/loader.py),
[matching worker](../services/reconciliation/matching/splink_worker.py),
[invitation Edge Function](../supabase/functions/invitations/index.ts), and
[import-download Edge Function](../supabase/functions/import-download-url/index.ts).

### 2.2 Evidence classification

- **Repository evidence:** read from current-worktree source. Some files are
  untracked or modified; this does not establish commit provenance or
  deployment.
- **Prior local observation:** recorded in Stage 1A/1B only. No local database
  was queried for this review.
- **Platform documentation:** general documented Supabase/PostgreSQL behavior
  cited by earlier design reports; it does not prove target configuration.
- **Proposed design:** Stage 1M behavior, not implemented or tested.
- **Unresolved assumption:** depends on effective role, JWT, ACL, migration,
  data, or hosted state not established by this review.

**Repository-verified:** the Next.js server client uses the public anon key
with cookie-backed authentication; actions call `auth.getUser()`. The
reconciliation actions currently perform direct table writes and separate
audit calls. The import worker and loader both invoke the import insert RPC.
The matching worker sends directional candidate IDs. The migrations define
`SECURITY DEFINER` worker functions and a generic audit function granted to
`authenticated` and `service_role`.

**Prior local observation only:** Stage 1B recorded local migration-history
version `20261101000006` and an active local function associated with it,
while no corresponding migration file exists in the current repository.
This report neither rechecked nor inferred that state. It establishes nothing
about hosted Supabase.

**Not performed:** no tests, SQL, local/hosted database operations, migration
commands, secret inspection, or hosted access.

## 3. Historical finding disposition

“Resolved” below means that the proposed design addresses the underlying
problem on paper; it does not mean implemented or runtime verified.

### 3.1 Stage 1L findings L1–L7

| Finding | Classification | Independent assessment |
|---|---|---|
| **L1 — Signature verifier/key lifecycle** | **Resolved by a technically sound design change** | Stage 1M selects the authenticated-user JWT path instead of requiring a custom assertion verifier. The direct RPC must still reject non-user roles using the actual verified request role and derive actor from `auth.uid()`; local PostgREST behavior remains a test prerequisite. |
| **L2 — Audit actor binding** | **Partially resolved** | Deriving reviewer from `auth.uid()` and comparing it in the audit wrapper is directionally correct. Exact function ownership/EXECUTE closure, actor-context behavior in nested `SECURITY DEFINER` calls, and an enforceable exactly-one decision/audit relation remain unspecified. |
| **L3 — Unsafe worker expansion** | **Partially resolved** | Pause-before-change fixes the ordering defect in Stage 1K. It is not a database-enforced fence; old worker credentials/RPC grants can still write if a worker is not actually stopped. Historical conflicting terminal rows and candidate mapping remain underspecified. |
| **L4 — Ambiguous request recovery** | **Partially resolved** | The ordered decision-history list is better than an arbitrary latest-row lookup. It recovers decisions, not necessarily committed terminal conflicts with no decision row. Canonical payload digest and keyless recovery semantics are missing. |
| **L5 — Incomplete callers** | **Partially resolved** | Both import writers, worker RPC families, cron, Edge Functions, and several app paths are listed. Read paths, exact function-invoker versus definer-owner identity, effective inherited grants, and all deployment/manual callers are not closed. |
| **L6 — RLS/ACL/helper closure** | **Unresolved** | Section 7 remains a semantic matrix with an undefined `workflow_tenant()` and no exact helper signatures, SQL, ownership, grants, or complete per-command policies. |
| **L7 — Failpoints/retention recovery** | **Partially resolved** | Pair-migration checkpoints and general recovery rules are improved. There is no enforceable worker fence, exact migration object/constraint ordering, or concrete retention/FK behavior. |

### 3.2 Stage 1J findings J1–J6

| Finding | Classification | Independent assessment |
|---|---|---|
| **J1 — Gateway identity not isolated** | **Resolved for the selected primary design** | The shared service-role gateway is no longer the reviewer path; the authenticated JWT is the identity source. This depends on exact role grants and verified PostgREST claims, not Server Action secrecy. |
| **J2 — Executor/RLS not executable** | **Partially resolved** | Tenant context lifecycle is clearer, but still does not define executable helpers, complete policy SQL, role closure, or ACLs. |
| **J3 — Audit wrapper validation** | **Partially resolved** | Actor/tenant comparisons and link intent are stated; exact reserved-action set, helper boundary, exact FK/index/trigger design, and failure completeness are not. |
| **J4 — Worker pair migration** | **Partially resolved** | The pause precedes changes, but it is operational rather than fenced, and the historical identity map/conflict resolution is incomplete. |
| **J5 — Idempotency recovery** | **Partially resolved** | Same-key binding is specified at a high level. Payload canonicalization, keyless recovery for terminal conflicts, and retention/FK details remain open. |
| **J6 — Application writer inventory** | **Partially resolved** | The writer matrix is substantially broader but misses multiple read consumers and does not assign verified database invoker/definer/effective privilege identities. |

### 3.3 Stage 1I findings H1–H6

| Finding | Classification | Independent assessment |
|---|---|---|
| **H1 — One source record, one entity** | **Partially resolved** | Stage 1M states a unique source-link constraint and composite FKs, but does not define exact parent keys, FK column order/actions, validation sequence, or compatibility with existing constraints. |
| **H2 — Executor RLS and privileges** | **Partially resolved** | No broad policy is proposed and source UPDATE is correctly excluded for locking, but the executable contract is incomplete. |
| **H3 — Audit integrity** | **Partially resolved** | Generic reserved-action rejection and typed-decision derivation are proposed, but not all enum labels, overloads, or completeness constraints are fixed. |
| **H4 — Permanent candidate-pair identity** | **Partially resolved** | Pair normalization and all-status identity are proposed. A registry-to-candidate/history mapping and conflicting-terminal resolution are not specified sufficiently to preserve and interpret legacy decisions. |
| **H5 — Server-only gateway** | **Resolved by architecture change** | Stage 1M chooses the existing authenticated user session rather than a separate privileged gateway. It explicitly allows direct authenticated PostgREST invocation, protected by the same database checks. |
| **H6 — Confirmation/idempotency/UI** | **Partially resolved** | A distinct confirmation operation and result union are mentioned, but exact decision schema, UI treatment, and durable recovery for terminal conflict results remain incomplete. |

### 3.4 Stage 1H findings N1–N6

| Finding | Classification | Independent assessment |
|---|---|---|
| **N1 — Candidate lock before authorization** | **Partially resolved** | Stage 1M moves membership lock before target lock. The exact discovery helper, actor source, SQL lock clauses, and matching lock order for membership-changing functions remain unspecified. |
| **N2 — Entity status eligibility** | **Partially resolved** | Stage 1M excludes deleted/noncandidate confirmation targets, but does not state the full eligible status set and transition invariants for every target operation as an executable contract. |
| **N3 — Typed-decision child-index order** | **Unresolved** | Stage 1M does not give a migration sequence for typed-decision columns and dependent indexes/FKs. The earlier order defect cannot be assumed fixed by the general migration checkpoints. |
| **N4 — Generic audit event forgery** | **Partially resolved** | Generic helpers are to reject reserved actions, but the full action set, every overload/default signature, and trusted workflow-only insertion path are not concretely closed. |
| **N5 — Company cascade/source immutability** | **Partially resolved** | Stage 1M recognizes company `ON DELETE CASCADE` risk and calls for archive/owner policy, but does not define a concrete archive/purge FK and retention lifecycle. |
| **N6 — Typed decision idempotency key** | **Partially resolved** | A separate request ledger key is proposed, but the typed decision/ledger FK, nullability/uniqueness rules, and behavior after ledger expiry are not fully specified. |

### 3.5 Stage 1F findings F1–F11

| Finding | Classification | Independent assessment |
|---|---|---|
| **F1 — Executor RLS isolation** | **Partially resolved** | Exact executor policies and effective grants remain absent. |
| **F2 — Row-lock privileges** | **Partially resolved** | Source UPDATE is not granted, but trusted lock-helper signatures, owners, SQL, and ACLs are missing. |
| **F3 — Helper/audit grants** | **Partially resolved** | The design requires a privilege allowlist but does not enumerate effective grants signature by signature. |
| **F4 — Ownership transfer** | **Unresolved** | No executable ownership-transfer procedure or exact migration-owner capability contract is supplied. |
| **F5 — Idempotency** | **Partially resolved** | Unique actor/key binding is stated, but payload encoding, terminal-conflict recovery, and precise FK/retention semantics are not. |
| **F6 — Membership race** | **Partially resolved** | Lock ordering is improved; exact transaction/helper implementation and competing membership mutation paths are not specified. |
| **F7 — Typed-column migration order** | **Unresolved** | Column/check/index/FK order is not explicitly stated for the new typed schema. |
| **F8 — Child indexes and lifecycle** | **Partially resolved** | The design calls for supporting indexes and identifies cascade/erasure risks but lacks exact FK/index/lifecycle definitions. |
| **F9 — Application write paths** | **Partially resolved** | The broad writer paths are listed, but read consumers, runtime identities, and manual/operational closure remain incomplete. |
| **F10 — Application idempotency/result handling** | **Partially resolved** | The response union is illustrative; exact action/UI contract, storage behavior, and conflict recovery are open. |
| **F11 — Test completeness** | **Partially resolved** | The proposed tests are extensive, but cannot prove an unspecified ACL/policy/migration contract and do not cover every failure/recovery case identified below. No tests were run. |

## 4. New findings

### 1N-1 — High: executor context and RLS remain conceptual, not executable

**Stage 1M evidence:** §§7.1–7.3 refer to `workflow_tenant()` without a
signature or definition; call for “narrow trusted” discovery/lock helpers
without exact inputs, results, SQL, owners, or grants; and describe RLS
conditions in prose rather than complete policies. The design also defers
signature-by-signature ACL closure to future inventory.

**Repository evidence:** current table policies are defined in the
[reconciliation schema migration](../supabase/migrations/20261029000001_reconciliation_module.sql);
the source schema includes immutable source rows and existing company/entity
cascades. These do not implement Stage 1M's proposed executor.

**Failure scenario:** an implementer chooses a privileged `SECURITY DEFINER`
discovery helper that accepts arbitrary tenant/source IDs but omits a
company predicate, or grants an executor context helper more broadly than
intended. A caller then uses it to distinguish or lock another tenant's
records. A custom GUC can be caller-settable, so merely comparing it in an
RLS policy does not prove that the function set it after membership
authorization. A missing `WITH CHECK` could permit cross-tenant inserts even
when SELECT is tenant-scoped.

**Required correction:** specify each function signature and security mode;
owner and fixed `search_path`; exact parameter/return fields; membership,
tenant, and target predicates; lock clause; caller grants; and all
`USING`/`WITH CHECK` expressions. Enumerate `PUBLIC`, default, inherited,
schema `CREATE`, table/column/type/sequence, and function privileges for
every relevant role. Define the complete externally callable executor
function set and prove no other function/role can set workflow context or
assume executor.

**Blocks disposable-local implementation-testing authorization:** **Yes.**
The missing details are the security mechanism itself, not just test
configuration.

### 1N-2 — High: authoritative audit is not constrained to exactly one event

**Stage 1M evidence:** §§8.1–8.3 require reserved actions to be rejected by
generic paths and describe a trusted decision-ID writer, unique correlation,
and optional deferred constraint triggers. They do not enumerate a closed
reserved-action set, provide the wrapper/trigger SQL contract, or specify the
constraints that establish both “at most one” and “at least one.”

**Repository evidence:** the generic six-argument `log_audit` is
`SECURITY DEFINER` and granted to `authenticated` and `service_role` in
[audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql).
The five-argument `log_reconciliation_audit` accepts action, company,
target, and metadata in the
[reconciliation schema migration](../supabase/migrations/20261029000001_reconciliation_module.sql).
Workers, membership triggers, invitations, and cron/retention use these
paths in the [worker migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[membership triggers](../supabase/migrations/20260514000009_triggers.sql),
[invitation function](../supabase/functions/invitations/index.ts), and
[operations migration](../supabase/migrations/20261030000002_reconciliation_security_ops.sql).

**Failure scenario:** a new or legacy overload, default-argument call, or
privileged operational wrapper remains able to write `match.accepted` or
another reserved reviewer action. Alternatively, the decision RPC succeeds
without an audit link if no actual deferred constraint requires a link at
commit. A unique link index proves at most one, not at least one.

**Required correction:** inventory every overload, enum action, trigger,
wrapper, grant/default privilege, and call chain. Specify exact reserved
labels and rejection for every generic entry point. Define the trusted
writer's owner and caller path, the decision/audit composite FKs and unique
keys, and one concrete nonrecursive at-commit completeness mechanism (or a
schema shape that makes a missing audit link impossible). State exact
behavior for worker, membership, invitation, cron, and retention events.

**Blocks disposable-local implementation-testing authorization:** **Yes.**
Audit authenticity and atomicity are central invariants.

### 1N-3 — High: worker pause has no write fence and pair history has no mapping contract

**Stage 1M evidence:** §9.2 says to stop claims, drain workers, and verify no
transaction/lease remains before changing the writer. It does not revoke or
gate the old writer RPC during backfill. §9.1 proposes one pair identity and
says historical candidates map to it, but defines no mapping relation or
canonicalization rule for conflicting terminal histories.

**Repository evidence:** the matching worker calls the lease-checked writer
RPC with directional IDs in
[splink_worker.py](../services/reconciliation/matching/splink_worker.py);
the current database writer inserts candidates under a pending-only
conflict target in
[worker_and_audit_security.sql](../supabase/migrations/20261031000001_worker_and_audit_security.sql).
The worker's execution uses a dedicated URL, but the actual configured
database role is not established by source alone.

**Failure scenarios:**

- An old process, delayed job, or separately started worker calls the still
  executable RPC after the operator's “no lease” check but before/during
  backfill. A new accepted/rejected pair can receive a new pending candidate
  under the old writer.
- A pair has both accepted and rejected historical rows, multiple audit
  references, or terminal plus pending rows. A single registry row cannot
  preserve their individual histories without an explicit candidate-to-pair
  mapping. No rule identifies which candidate is reviewable or whether the
  pair is terminal.
- A reversed pair shares canonical identity, but existing candidate IDs and
  decision/audit references cannot be rewritten or discarded without
  preserving their original provenance.

**Required correction:** introduce an enforceable pause/fence before
backfill—e.g. a database maintenance state checked by the writer or a
carefully staged revoke/replace of its exact EXECUTE path—and prove that
existing transactions are drained. Define the pair registry, candidate
mapping, canonical review-row selection, duplicate visibility, and
deterministic treatment of every conflicting terminal class. Preserve
historical candidate/decision/audit IDs and specify whether ambiguity blocks
the migration. Define restart and interrupted-recovery states.

**Blocks disposable-local implementation-testing authorization:** **Yes.**

### 1N-4 — Medium: request ledger cannot recover every committed result

**Stage 1M evidence:** §§10.1–10.3 bind a unique `(actor_id, request_key)` to
tenant/operation/target/payload and propose terminal conflict results.
Keyless recovery in §10.2 is a decision-history query returning decisions,
not request-ledger outcomes. The digest is called “canonical” without a
canonical serialization or field-version contract.

**Failure scenario:** an operation commits a terminal conflict such as
`source_already_linked` or `already_decided`, the response is lost, and the
browser loses the key. There is no decision row for that conflict, so the
decision-history endpoint cannot recover the original response. Retrying
with a new key may produce a different conflict/result. Independently,
semantically identical JSON serialized with different key order or numeric
representation could hash differently unless canonicalization is fixed.

**Required correction:** define whether terminal conflicts are durable ledger
results and provide authorized keyless lookup of those rows, or explicitly
bound recovery guarantees to successful decision rows only. Specify
canonical payload encoding, included fields, versioning, digest algorithm,
and handling of transient failures versus committed expected conflicts.
Specify ledger-to-decision/entity/audit FKs and delete/expiry behavior.

**Blocks disposable-local implementation-testing authorization:** **Yes**
for the currently stated recovery guarantee; a narrower owner-approved
guarantee could reduce this to a nonblocking limitation.

### 1N-5 — Medium: caller matrix does not close reads or execution identities

**Stage 1M evidence:** §11 calls itself a complete writer/operational
inventory but does not provide an exact invoker/owner/effective-role mapping.
It leaves deployment definitions, catalogs, manual operations, and role
membership for later closure.

**Repository evidence:** beyond the listed writer actions, the
[reconciliation dashboard](../examples/nextjs/app/dashboard/reconciliation/page.tsx)
reads sources, jobs, source records, and entities; the
[review page](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx)
reads candidate/source joins; the
[import detail page](../examples/nextjs/app/dashboard/reconciliation/imports/%5Bid%5D/page.tsx)
reads job/source content; entity, run, discrepancy, and data-source pages
also query reconciliation relations. The
[import-download Edge Function](../supabase/functions/import-download-url/index.ts)
uses a service-role client. Worker RPCs are `SECURITY DEFINER` and have
owners distinct from their Python invokers.

**Failure scenario:** a DML/SELECT grant change preserves accept/reject but
breaks the dashboard or import detail page, or a worker's actual login role
inherits broader access than the matrix assumes. Conversely, treating
function invoker as its `SECURITY DEFINER` owner can lead to incorrect
revocation or audit attribution.

**Required correction:** inventory reads as well as writes and identify, for
each route/worker/Edge/cron/trigger/RPC, the HTTP/JWT role, database login or
PostgREST role, function invoker, function owner, inherited roles, required
columns, and secret holder. Mark deployment-dependent values explicitly
unverified; do not claim source inspection proves hosted completeness.

**Blocks disposable-local implementation-testing authorization:** **Yes**
for a cutover test plan that intends to change grants. A strictly isolated
prototype test could proceed only after an explicit scope excludes cutover
and preserves all current grants.

### 1N-6 — Medium: data constraints and lifecycle remain non-executable

**Stage 1M evidence:** §§7.3 and 12.1 state source uniqueness, composite
tenant FKs, typed decisions, audit links, pair identity, archive, and
retention requirements, but do not give exact parent/child key definitions,
FK actions, index ordering, typed-column check predicates, or an archive/purge
transition.

**Repository evidence:** the current identifier key is `(entity_id,
source_record_id)` and therefore permits one source to appear under multiple
entities in the
[reconciliation schema](../supabase/migrations/20261029000001_reconciliation_module.sql).
That schema also contains company cascades and an immutable source-record
trigger. The
[audit cleanup function](../supabase/migrations/20261031000001_worker_and_audit_security.sql)
deletes old audit rows based on configured retention.

**Failure scenario:** implementing composite FKs without matching unique
parent keys fails; applying a typed child index before its new column exists
fails; physical company deletion cascades into immutable source rows and
aborts; or cleanup deletes a row still required by a decision/audit
correlation.

**Required correction:** specify migration order from existing schema:
preflight, parent keys, child indexes after columns exist, constraints,
validation, concurrent-index interruption recovery, and FK delete actions.
Define an archive-only operation separately from any legally approved purge,
and state which decision/audit/ledger/source records are retained or
pseudonymized. Preserve migration `20261101000006` exactly as an unresolved
local-history fact; do not reconstruct it or infer hosted state.

**Blocks disposable-local implementation-testing authorization:** **Yes**
for schema/migration testing under the current broad scope. Owner-approved
tests explicitly excluding archive/purge could be scoped separately.

## 5. Supabase JWT and identity assessment

### 5.1 What is sound in the proposal

The primary design's core trust chain is more appropriate than Stage 1K's
service-role-plus-assertion proposal:

- The browser's actor argument is not trusted.
- The Server Action calls `auth.getUser()` and uses the same cookie-backed
  user client.
- The database RPC derives actor from `auth.uid()` and checks current
  membership/role from database state.
- The authenticated PostgREST role can call the RPC directly, but that path
  is intended to receive identical checks.
- `service_role`, `anon`, workers, and scheduler are explicitly denied the
  reviewer RPC in the design.

This is a defensible architecture if exact function grants and request claims
are confirmed. The repository already uses cookie-backed Supabase Auth and
RLS identity helpers. Supabase's documented role/JWT model and PostgreSQL
function security model support the general approach; they do not prove the
target request context or grants.

### 5.2 Remaining identity precision

Stage 1M says the RPC checks `auth.role() = 'authenticated'` and
`auth.uid() IS NOT NULL`, including inside a `SECURITY DEFINER` function.
That is a plausible Supabase request-context design, but the report labels
nested claim availability as an assumption and does not define:

- which exact workflow functions are `SECURITY DEFINER`, their owner, and
  whether `auth.uid()`/`auth.role()` read verified PostgREST JWT claims rather
  than mutable caller state for each invocation route;
- the complete ACL path preventing `service_role`, worker, scheduler, and
  inherited roles from executing the reviewer RPC or assuming executor;
- whether any direct SQL connection can set request claim GUCs and obtain
  execution as the `authenticated` role; and
- whether every public RPC/helper denies calls without an authenticated
  request, including calls nested under operational definer functions.

These are **platform/configuration and test prerequisites**, not evidence that
the primary design is inherently invalid. Never treat a non-NULL `auth.uid()`
alone as proof if the invoker is not constrained to the verified PostgREST
path. Direct PostgREST invocation does not bypass the database checks; it
does make every exposed RPC and helper part of the attack surface.

### 5.3 Browser protections

The Origin/Host and cookie controls in §4.2 are useful defense in depth.
They do not authorize a decision: the database RPC must still check JWT
identity, membership, target tenant/status, request binding, and constraints.
The current Server Action contract and future Origin allowlist are proposals,
not currently verified runtime controls.

## 6. Executor, RLS, helpers, and grants

Stage 1M correctly rejects `USING (true)`, recognizes custom GUCs are not
identity, excludes source UPDATE for locking, and says `FORCE RLS` does not
restrain a superuser or `BYPASSRLS` helper owner. Those are sound design
principles.

The remaining problem is implementation freedom at the security boundary.
“A trusted helper,” “workflow_tenant()”, “minimal return columns,” and
“explicit allowlist” do not determine exact SQL, roles, or grants. No policy
is defined for every table/action with its exact `USING` and `WITH CHECK`
expression. The design does not enumerate every executor-owned function,
function owner membership, object default privilege, schema `CREATE`, type
usage, sequence usage, or role inheritance. It also does not specify how
pre-existing `authenticated` policies compose with executor policies or how
the membership helper behaves when called by the executor.

The membership-before-target lock order is directionally correct, but the
discovery function must avoid leaking target tenant/status to unauthorized
callers and must not take target locks before the membership lock. A
privileged helper that bypasses RLS must have a fixed, minimal query and
non-oracular result behavior; the prose requirement alone is not proof.
PostgreSQL locking without source UPDATE is viable through a privileged
helper, but Stage 1M does not provide that helper's exact definition.

**Assessment:** J2, H2, N1, and F1–F4/F6 are not fully resolved. The test
matrix names relevant checks, but cannot supply a missing design contract.

## 7. Audit integrity

The JWT-derived reviewer is a better actor source than an unsigned argument,
and building an audit row from a typed decision is a sound direction.
However, `auth.uid()` comparison alone does not close the writer boundary:
the wrapper must be unreachable to untrusted callers and must not be callable
from an alternate privileged function with arbitrary decision creation.
`SECURITY DEFINER` ownership and ACLs do not provide a general “called only
from this function” stack restriction; the trust must come from private
EXECUTE grants plus a closed set of trusted owner functions and schema
privileges.

Stage 1M does not specify the final action enum reservation set. The phrase
“plus any additional labels found by final catalog/source inventory” leaves a
material implementation choice open. It also does not give a concrete
deferred trigger contract or alternative schema mechanism proving every new
decision has one and only one audit link. Unique indexes can enforce “at
most one”; mandatory wrapper invocation in a function body is not enough if
other trusted write paths or future functions can insert decisions.

Operational compatibility needs careful handling. Current worker, trigger,
invitation, cron, and retention callers use audit functions under different
invoker/function-owner contexts. Some worker `SECURITY DEFINER` functions
write directly to `audit_log`, while cron invokes the general reconciliation
wrapper. A generic reserved-action rejection is appropriate, but fixed
operational replacements and their exact grants must be enumerated so the
existing nonreserved events continue while workflow provenance cannot be
forged.

**Assessment:** L2, J3, H3, N4, and F3 remain partially resolved and block
authorization until the exact audit mechanism is specified.

## 8. Candidate-pair migration and historical preservation

The design correctly recognizes directional worker inputs and orders pause
before normalization/backfill. The unchanged RPC signature can preserve old
worker binary compatibility if the new database implementation normalizes
both IDs. A permanent unique pair identity is preferable to the existing
pending-only uniqueness for suppressing terminal regeneration.

But the design does not define the identity relation sufficiently:

- It has one unique pair key but no explicit candidate-to-pair history
  mapping.
- “Canonical candidate” is not defined when there are multiple pending,
  accepted, rejected, or mixed terminal rows.
- A pair with accepted and rejected rows has no deterministic terminal
  interpretation.
- A historical audit or typed decision referencing a noncanonical candidate
  must remain traceable without changing its original ID or implying a
  decision on another candidate.
- `ON CONFLICT ... DO NOTHING` on the registry alone prevents duplicate
  registry rows, but does not by itself guarantee there is exactly one
  pending candidate if legacy candidates are not atomically mapped before
  the RPC resumes.

The pause is an operational instruction, not a fencing mechanism. A worker
that retains its DB credentials and function grant can call the old RPC after
the pause check. A migration must close the race between the final drain
check and writer replacement/backfill. The current worker's run lease and
claim recovery functions make this especially important: a stale or restarted
process can reacquire work unless the database writer is gated.

**Required before authorization:** define a write-fence mechanism and a
candidate/pair mapping schema; give explicit preflight groups and owner
resolution rules for reversed, duplicate, self, cross-tenant, terminal plus
pending, and contradictory terminal rows. Preserve every candidate,
decision, and audit reference. If any history is ambiguous, block and leave
workers paused rather than choose silently.

## 9. Idempotency and recovery

The unique `(actor_id, request_key)` and immutable binding tuple are a good
base. A unique constraint can serialize same-key calls and prevent another
actor from replaying a row, provided the ledger's RLS/ACL and RPC checks are
implemented as specified. Current membership must be checked before replay,
as Stage 1M states.

Unresolved semantics:

1. **Canonical payload:** no canonical serialization, digest version, null
   handling, or exact field set is fixed.
2. **Terminal conflicts:** if a committed conflict is stored in the ledger
   without a decision, the proposed keyless decision-history lookup will not
   return it after browser key loss.
3. **Ledger result FK:** the document mentions foreign keys to decision/entity
   but not exact `ON DELETE` behavior, whether conflicts may have a null
   decision, or how decision/audit retention interacts with the ledger.
4. **Dynamic authorization:** `membership_denied` appears in the example
   result union, while replay must be denied after membership revocation.
   The design must distinguish a durable action outcome from a current
   authorization failure; the latter should not accidentally be persisted as
   an immutable successful/terminal request result.
5. **Account erasure/retention:** actor pseudonymization and request-key
   retention remain owner/legal decisions. Expiring a request row must not
   allow a terminal target to be re-decided.

Same-key concurrent calls and response loss are testable once these semantics
are fixed. The present proposal does not yet support the complete recovery
guarantee it describes.

## 10. Application and operational caller inventory

### 10.1 Repository evidence checked

The Stage 1M matrix correctly includes accept/reject, confirmation, links,
data-source writes, job/run create/retry, discrepancy resolution, both import
record writers, Splink candidate generation, import-download service-role
use, invitations, triggers, and cron/retention. Additional direct reads
include dashboard metrics, pending-review candidate/source joins, import
details and source-record contents, entity lists/exports, runs, discrepancies,
and data-source listings. Those reads may be affected by changing table
SELECT privileges or RLS, even when no write path changes.

### 10.2 Identity categories that must not be conflated

| Caller | Repository-visible mechanism | Still unverified |
|---|---|---|
| Next.js Server Action/page | Cookie-backed client uses anon key and user session; PostgREST is expected to act as the JWT-selected `authenticated` role. | Exact request role/claims, deployed function ACLs, and deployment secrets/config. |
| Import/matching Python workers | Dedicated DB URL variables and lease-checked RPC calls. | Actual database login role and all inherited privileges in any deployment. |
| Import-download Edge Function | Supabase client constructed with `SUPABASE_SERVICE_ROLE_KEY`. | Secret distribution, deployed grants, and every other holder of the credential. |
| SQL `SECURITY DEFINER` RPC | Function body executes with its function owner privileges; caller may be a worker, user, cron job, or other function. | Deployed owner, role attributes, function ACL, and nested call chain. |
| `pg_cron` job | SQL commands are scheduled from migration source; cleanup job later uses an explicit scheduler role in source. | Effective job username/role, scheduled job state, and target database configuration. |
| Trigger | Trigger function executes in its defined security context and may call audit helpers. | Actual trigger set, owner, grants, and behavior under each mutation path. |

Stage 1M does not provide a complete per-route/per-function matrix with
invoker role, function owner, effective role, read/write columns, and grant
requirements. Source inspection is not proof that the deployed caller set is
complete. No broad permission revocation is justified from this inventory.

## 11. Schema, retention, and migration lifecycle

The intent to preserve immutable source records, archive companies, retain
historical decisions, avoid false legacy audit provenance, and coordinate
ledger/audit retention is sound. Migration 06 and hosted-project uncertainty
are correctly kept separate.

The migration contract remains too abstract:

- one-source/one-entity uniqueness is stated, but exact composite parent
  unique keys and FK definitions are absent;
- candidate/source/entity tenant constraints and child indexes are not
  ordered against the typed decision columns;
- typed decision checks do not define every operation's required/forbidden
  field combination or legacy-row predicate;
- pair registry and historical mapping constraints are not defined;
- audit-link FKs and retention delete behavior are not defined;
- company archive versus physical purge is not translated into concrete FK
  actions, and the current source immutability trigger can reject cascaded
  deletes; and
- reviewer attribution erasure/pseudonymization remains open.

No retention duration should be invented. The next design should state which
records are immutable, which may be archived, which can be pseudonymized, and
which deletion operations are explicitly out of scope. It must not reconstruct
or mark migration `20261101000006` applied and must not infer the hosted
project.

## 12. Test readiness

The Stage 1M matrix is broad and correctly labels tests as proposed/not run.
It covers JWT identity, direct calls, CSRF, RLS, privilege boundaries,
membership races, pair normalization, audit spoofing, idempotency, response
loss, deleted entities, caller compatibility, migration recovery, and
retention.

It does not yet specify testable expected outcomes for:

- exact helper signatures, grants, role memberships, `PUBLIC`/default
  privileges, and all RLS expressions;
- identity claims through nested `SECURITY DEFINER` paths for authenticated,
  service-role, worker, scheduler, and direct SQL callers;
- the worker write fence between pause/drain and migration completion;
- pair mapping for contradictory terminal histories with multiple audit
  references;
- terminal conflict recovery after request-key loss;
- canonical payload digest equivalence and key reuse;
- exactly-one audit-link enforcement under direct privileged decision insert
  attempts and deferred-trigger failure; and
- every read page and operational caller under the post-cutover grants.

Tests cannot substitute for selecting the expected policy, migration, and
retention semantics. No tests were run during this review.

## 13. Owner decisions and platform prerequisites

Before a future separate authorization decision, owners/designers must:

1. Approve the authenticated JWT → RPC actor model and direct authenticated
   PostgREST invocation; document the rejected shared-service-role path.
2. Finalize exact executor/helper ownership, signatures, grants, policies,
   role membership closure, and transaction-local context.
3. Finalize the reserved audit action set, generic overload behavior,
   authoritative writer, and exactly-one correlation enforcement.
4. Approve historical pair conflict resolution and terminal-pair semantics;
   specify mapping that preserves every historical candidate/decision/audit.
5. Choose the recovery guarantee for terminal conflicts after key loss and
   approve request/decision/audit/source retention with privacy/legal review.
6. Complete read and write caller inventory, including actual worker DB
   logins, `SECURITY DEFINER` owners, cron identity, triggers, deployment
   functions, inherited roles, and all secret holders. Do not inspect secrets
   as part of this design review.
7. Specify exact migration ordering for typed columns, parent/child keys,
   indexes, FKs, validation, concurrent index recovery, and lifecycle actions.
8. Keep local migration-history version `20261101000006` as an unresolved
   prior observation until separately authorized; do not guess hosted
   identity or state.

## 14. Required next step and authorization boundary

**Recommendation: NO-GO.** Produce a further corrected design amendment
addressing findings 1N-1 through 1N-6, then request another independent
review. The authenticated-RPC architecture itself is not rejected; the
executor, audit, pair-migration, and request-recovery contracts need
substantive refinement.

No part of this report authorizes implementation, tests, SQL execution,
database connection, migration creation or execution, local or hosted
Supabase access, staging, production changes, or Stage 2.

### Completion record

- **Tests/SQL/database operations/hosted access:** none performed.
- **Files created by this task:** only this Stage 1N independent review
  document.
- **Worktree:** the pre-write status contained numerous existing modified
  and untracked files. They were preserved; only this new report is the
  intended task delta.
- **Validation:** 42 local Markdown links and anchors checked; code-fence and
  trailing-whitespace checks passed; `git diff --check` passed. Final status
  matched the recorded baseline plus this new report. The existing LF-to-CRLF
  warning for `examples/nextjs/app/auth/signup/page.tsx` is unrelated.
