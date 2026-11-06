# ZamBase Phase 2A.3.4 — Stage 1H Independent Review

> **Read-only design review.** No application code, migration, database object,
> role, grant, policy, function, index, data, or configuration was changed.
> No database or hosted Supabase project was accessed. This report is the only
> file created for Stage 1H.

## 1. Executive verdict

**GO FOR ANOTHER DESIGN AMENDMENT.**

Stage 1G is directionally stronger than Stage 1E: it moves current membership
authorization ahead of the candidate lock, selects explicit active entity
statuses, corrects the typed-column/index ordering, and recognizes that the
audit and gateway boundaries remain unresolved. It is not yet a technically
complete, implementable security specification.

The most important blockers are:

1. The schema's current primary key on
   `reconciliation_identifiers(entity_id, source_record_id)` permits one source
   record to be linked to multiple entities. Stage 1G asserts a one-source,
   one-entity invariant but does not state the exact global/source-unique
   constraint needed to enforce it.
2. The proposed executor RLS is a policy pattern, not the exact per-table,
   per-command policy contract promised by the earlier requirements. Its
   transaction-local tenant context, who may set it, and how policies validate
   it are not concretely specified.
3. Audit authenticity remains incomplete. The current generic wrapper is
   executable by both `authenticated` and `service_role`; it accepts an
   arbitrary action and does not reject workflow-owned action values.
   Stage 1G states the desired restriction but leaves the trusted-caller
   discriminator and service-role boundary undefined.
4. The invocation decision is a real product/security conflict: the current
   Next.js server client uses the user's JWT and anon key, while granting
   `authenticated` EXECUTE also makes the RPC callable directly over PostgREST
   by any holder of a valid user JWT. A service-only gateway is feasible in
   principle, but would trust a server-verified actor assertion and must
   isolate its service credential and restrict service-role operations.
5. Candidate-pair uniqueness is only partial on `status = 'pending'`. Once a
   candidate is accepted or rejected, the matching worker can later insert a
   new pending candidate for the same pair. Stage 1G does not choose whether
   historical decisions suppress regeneration.
6. Several “exact” contracts remain incomplete: the entity confirmation RPC,
   authorization/RLS expressions, audit event correlation, and the complete
   constraints/indexes are described at a high level rather than specified
   sufficiently for safe implementation.

Stage 2 is not authorized by this verdict. No test is claimed to have passed.

## 2. Review scope and evidence sources

Reviewed the required
[Stage 1C blueprint](./PHASE-2A-3-4-STAGE-1C-IMPLEMENTATION-BLUEPRINT.md),
[Stage 1D verification](./PHASE-2A-3-4-STAGE-1D-DESIGN-VERIFICATION.md),
[Stage 1E corrected blueprint](./PHASE-2A-3-4-STAGE-1E-CORRECTED-IMPLEMENTATION-BLUEPRINT.md),
[Stage 1F review](./PHASE-2A-3-4-STAGE-1F-FINAL-DESIGN-REVIEW.md), and
[Stage 1G amendment](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md).

Repository sources inspected include the
[reconciliation schema, policies, and audit helpers](../supabase/migrations/20261029000001_reconciliation_module.sql),
[membership helpers](../supabase/migrations/20260514000007_helper_functions.sql),
[generic audit wrapper hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
[worker and audit security](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[Next.js reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts),
[Next.js Supabase server client](../examples/nextjs/lib/supabase/server.ts),
[review page](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx),
[RLS tests](../supabase/tests/rls.test.sql), and
[worker security tests](../supabase/tests/worker_security.test.sql).

Evidence categories:

- **Repository evidence:** current-worktree source and migrations; several
  relevant files are untracked or modified in the pre-existing worktree, so
  this does not assert they are committed or deployed.
- **Prior local finding:** as recorded in Stage 1A/1B; not freshly queried for
  this review and not evidence of hosted state.
- **PostgreSQL/Supabase architecture assessment:** reasoned from the documented
  privilege/RLS/function model and the repository's Supabase client pattern.
  No live role, JWT, PostgREST, or database execution was performed.
- **Unverified:** anything depending on actual local/hosted catalog state,
  SQL execution, migration runner behavior, or staging concurrency.

## 3. N1–N6 reassessment

| Finding | Classification | Independent assessment and remaining verification |
|---|---|---|
| N1 — Candidate lock precedes authorization | **Partially resolved** | Stage 1G's order is directionally correct: membership-gated tenant discovery, membership row `FOR SHARE`, role check, then candidate lock. However, the proposed SECURITY DEFINER authorization helper's exact SQL and caller identity check are not supplied. It must prove that candidate discovery returns no tenant information to a nonmember, that `actor_id` is exactly the signed JWT subject (or a trusted gateway assertion), and that the membership lock and later candidate lock occur in the same transaction. Run a two-session real-role test, not just a synthetic `SET ROLE` test. |
| N2 — Entity status eligibility undefined | **Requires product/legal owner decision** | `candidate` and `confirmed` are now eligible; `merged`, `rejected`, deleted, missing, and unknown statuses conflict. This is internally clear, but is a proposed business rule. The owner must approve whether a candidate entity is a valid provenance target and whether two sources already linked to the same entity constitute a successful accept. Test every state under row locks. |
| N3 — Typed child-index order | **Resolved in design and technically sound** | §11 adds nullable typed columns and compatible checks before indexes and FKs that use them. The sequence is now logically ordered. Historical data, exact index definitions, concurrent-build recovery, existing constraints, and migration-runner behavior remain unverified. |
| N4 — Generic audit event forgery | **Partially resolved** | §9 selects rejection of workflow-owned actions from generic calls and a dedicated authoritative wrapper, which is the right direction. It does not specify how the wrapper distinguishes a trusted workflow invocation from service-role or authenticated calls, nor how the generic function enforces that check across its exact signature/defaults. Existing `service_role` EXECUTE remains a fabrication path until a concrete guard or revocation is designed. |
| N5 — Company cascade conflicts with source immutability | **Requires product/legal owner decision** | §12 rejects ordinary hard delete and proposes archive/retention. That avoids treating a company cascade as an acceptable default, but the schema still has company cascades and an immutable-source DELETE trigger. Archive/tombstone semantics, required retention, legal purge, and transition of existing FKs remain undecided and require disposable-schema rehearsal. |
| N6 — Typed decision idempotency key nullable | **Resolved in design and technically sound** | New typed accept/reject rows require a non-null key while legacy untyped rows may remain nullable. The exact CHECK predicate, unique-index predicate, and validation strategy must still be written and tested against historical rows. |

## 4. F1–F11 reassessment

| Finding | Classification | Independent assessment and remaining verification |
|---|---|---|
| F1 — Executor RLS isolation | **Partially resolved** | Stage 1G prohibits unrestricted policies and requires tenant context, but supplies no exact `USING`/`WITH CHECK` expression per table and command. The GUC/context mechanism is not defined as unforgeable or bound to the current transaction/JWT. Effective forced-RLS behavior remains untested. |
| F2 — Row-lock privileges | **Partially resolved** | Trusted `postgres`-owned source/membership lock helpers avoid granting UPDATE on immutable source rows, consistent with PostgreSQL's row-lock privilege requirement. The SQL, exact grants, table-owner/BYPASSRLS behavior, and hosted ability to own/call the helpers are unverified. The helpers must be the sole, narrowly scoped path and must not expose arbitrary IDs or payloads. |
| F3 — Helper/audit grants | **Partially resolved** | Stage 1G lists needed schemas, types, and helper EXECUTE grants, but not a complete signature-by-signature ACL plan or effective privilege closure. Audit wrapper trust and auth role differ across invocation designs. Verify defaults, overloads, grants inherited through membership, and `PUBLIC`. |
| F4 — Ownership transfer | **Partially resolved** | The transfer procedure includes the schema CREATE and role membership gate and says to stop if unavailable. It is not yet proven the actual Supabase migration principal can grant membership, transfer ownership to the intended role, or revoke temporary privileges. Test the exact deployment principal in a disposable target. |
| F5 — Idempotency | **Partially resolved** | Scope, replay and mismatch behavior are described. The advisory-lock encoding remains an example rather than a fixed interoperable algorithm, and the exact unique-index/check predicates are not specified. A collision only serializes unrelated intents if uniqueness is enforced independently; race behavior and lost-response handling still need tests. |
| F6 — Membership race | **Partially resolved** | Lock-before-candidate plus `FOR SHARE` gives a reasonable linearization rule under `READ COMMITTED`. It depends on transaction scope, helper execution, membership RLS, and role updates actually taking conflicting locks. Verify delete, role update, owner-removal trigger, and two-session timing using real JWT/PostgREST roles. |
| F7 — Typed-column migration order | **Resolved in design and technically sound** | The principal ordering defect is corrected. Verify exact composite parent keys exist, the typed schema is added before dependent indexes, and legacy rows satisfy the compatibility branch. |
| F8 — Child indexes and lifecycle | **Partially resolved** | Child-side indexes and lifecycle review are called out, but no complete table/FK/index inventory or precise source-link uniqueness is listed. In particular, the current identifier PK does not enforce one entity per source. Deletion policy remains owner/legal gated. |
| F9 — Other app write paths | **Partially resolved** | The matrix distinguishes confirmation and deferred discrepancy resolution, but confirmation has no complete RPC contract or dedicated test. The deferred discrepancy path retains direct UPDATE and separate audit; therefore broad DML revocation cannot occur without breaking it or leaving that bypass open. Manual link/entity writers and operational callers still need repository-wide and deployed caller inventory. |
| F10 — App idempotency and UX | **Partially resolved** | Typed outcomes and key reuse are specified, but the current review UI still checks only `result.error`. `sessionStorage` may be lost when a tab/session is closed, and no UI test verifies pending outcome, replay, conflict, or retry behavior. |
| F11 — Test gaps | **Partially resolved** | The matrix is broad, but it does not prescribe exercising real Supabase JWT claims/PostgREST roles, exact gateway trust, generic-audit service-role forgery, identifier uniqueness, duplicate pair regeneration after a terminal decision, or the exact confirm RPC. No test was executed. |

## 5. New findings

### H1 — High: source-to-entity uniqueness is not enforced by the existing key or the migration sequence

**Exact evidence:** the current
[`reconciliation_identifiers` table](../supabase/migrations/20261029000001_reconciliation_module.sql#L245)
has `PRIMARY KEY (entity_id, source_record_id)` at line 251. Stage 1G
requires a unique source-record link in
[§6.1](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L195) and asserts a
one-source-one-entity rule, but [§11](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L496)
does not name a unique constraint/index on `source_record_id` or
`(company_id, source_record_id)`.

**Technical explanation / failure scenario:** the composite primary key only
prevents the same source from being linked twice to the same entity. It allows
the same source UUID to appear under two different entity IDs. Two accepted
decisions, a manual identifier writer, or a concurrent writer can therefore
violate the central provenance invariant while satisfying all currently
declared keys. Locking source rows serializes compliant RPCs but does not
protect against an omitted direct writer or enforce correctness at the schema
boundary.

**Required correction:** choose an explicit tenant-consistent unique key that
enforces exactly one entity link per source (`UNIQUE(source_record_id)` if
source UUIDs are globally unique, otherwise `UNIQUE(company_id,
source_record_id)` plus a matching parent key/FK). Preflight duplicates,
define conflict/recovery for existing data, make every writer handle that
constraint, and test the exact concurrent conflict. Add the supporting child
index/FK ordering to §11.

**Blocks Stage 2:** Yes.

### H2 — High: executor RLS is still a pattern, not an implementable policy set

**Exact evidence:** Stage 1G
[§6.1](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L195) says policies
predicate on “verified company context” and gives a transaction-local company
ID as an example. It does not define the exact context source, the per-table
and per-command `USING`/`WITH CHECK` clauses, or a complete policy for every
executor read/write. Existing policies are explicitly `TO authenticated`, for
example
[candidate UPDATE](../supabase/migrations/20261029000001_reconciliation_module.sql#L488)
and
[reviewer-decision policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L525).

**Technical explanation / failure scenario:** without a concrete policy and
context protocol, the executor may see zero rows, may be granted a broad
policy to make the function work, or may trust a transaction/session setting
that is not set by the approved function path. `NOLOGIN` and `NOBYPASSRLS` do
not make an under-specified SECURITY DEFINER boundary safe. `FORCE RLS` does
not define the policy predicates.

**Required correction:** provide a role/table/command matrix with exact
policies, tenant source, context-setting point, reset/transaction scope,
defense against client-pre-set context, and exact SELECT/INSERT/UPDATE column
privileges. Include the candidate, source, entity, link, decision,
membership, and audit objects, and demonstrate effective privileges under the
actual function owner. If a trusted helper bypasses RLS, explicitly scope its
SQL and return values instead of implying a policy covers it.

**Blocks Stage 2:** Yes.

### H3 — High: the generic audit restriction has no defined trusted-caller discriminator

**Exact evidence:** the current
[`log_audit` implementation](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L50)
accepts `_action`, and grants EXECUTE to both `authenticated` and
`service_role` at
[lines 104–105](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L104).
Its body checks tenant membership for authenticated callers but does not
reserve workflow action values. The existing
[`log_reconciliation_audit`](../supabase/migrations/20261029000001_reconciliation_module.sql#L551)
also takes arbitrary action, company, target, and metadata parameters; the
later security migration revokes its application/service grants, so any new
grant must be designed explicitly. Stage 1G §9 requires the generic wrapper to
reject workflow actions but does not specify how a trusted workflow caller is
identified.

**Technical explanation / exploit scenario:** authenticated tenant members can
call the generic function with a workflow action and fabricate an audit row.
The current service-role branch is broader still: service role may submit
arbitrary actions and the function records `auth.uid()` (which may be null for
the service JWT). A wrapper that merely checks `auth.role()` cannot distinguish
a legitimate nested workflow call from a service-role caller if both use the
same JWT role. A SECURITY DEFINER wrapper also changes `current_user`, so
trusting that value without defining the call chain is insufficient.

**Required correction:** reserve workflow action values in the generic helper
for all external callers, including service role; inventory and preserve
legitimate service audit callers. Use a separate narrowly executable
authoritative wrapper whose action, actor, company, target, and decision
correlation are derived or bound by the trusted workflow call, not arbitrary
inputs. State exactly how that wrapper can only be reached by the executor or
approved gateway, and how audit consumers distinguish authoritative rows.
Enumerate overloads and default EXECUTE privileges. Test authenticated and
service-role spoof attempts and wrapper failure rollback.

**Blocks Stage 2:** Yes.

### H4 — Medium: a terminally decided pair can be reintroduced as pending

**Exact evidence:** the current candidate unique index is partial on
`status = 'pending'` in the
[reconciliation schema](../supabase/migrations/20261029000001_reconciliation_module.sql#L291).
The matching RPC uses
`ON CONFLICT (record_a_id, record_b_id) WHERE status = 'pending' DO NOTHING`
in
[worker migration line 213](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L213).
Stage 1G [§11 steps 7–8](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L530)
requires normalized pairs and an active-pair invariant, but does not say
whether a prior accepted/rejected decision suppresses a new pending row.

**Technical explanation / operational scenario:** when a candidate changes
from pending to accepted/rejected, it no longer participates in the partial
unique index. A later matching run can therefore insert the same ordered pair
as a fresh pending candidate. Source-link conflicts may prevent a second
acceptance, but the review queue can present an already-decided match again
and produce confusing or contradictory audit history.

**Required correction:** decide whether terminal decisions are final per
normalized pair. If final, enforce pair uniqueness across all statuses or add
a separate durable pair/decision key. If re-review is intended, model an
explicit review generation/version and link each decision to it. Align worker
conflict inference and candidate lifecycle tests with the selected policy.

**Blocks Stage 2:** Yes, until the product rule and unique-key design are
specified.

### H5 — Medium: authenticated and gateway invocation designs are not yet a single deployable contract

**Exact evidence:** Stage 1G [§5.2](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L128)
offers both authenticated EXECUTE and a server-only gateway. The current
[Next.js server client](../examples/nextjs/lib/supabase/server.ts#L11)
uses the public anon key with cookie-backed user auth; reconciliation actions
call `auth.getUser()` via that client at
[reconciliation.ts line 159](../examples/nextjs/lib/actions/reconciliation.ts#L159).
The action module explicitly says service role is not used in
[its header](../examples/nextjs/lib/actions/reconciliation.ts#L1).

**Technical explanation / failure scenario:** authenticated EXECUTE is
compatible with `auth.uid()` and the existing server client, but means any
holder of a valid user JWT can call the RPC endpoint directly, bypassing UI
controls (database authorization still must reject unauthorized decisions).
A Next.js Server Action is not a private API merely because it runs on the
server; its inputs are caller-controlled and it must derive identity from the
verified session. A service-role gateway can be implemented with a
server-only credential, but PostgREST then sees `service_role`, not the user's
JWT subject. `auth.uid()` may be null, so the server must assert an actor ID
after `auth.getUser()` verification. That is a valid trust model only if the
service credential is never exposed, the gateway ignores actor IDs from the
request, and direct service-role table access is constrained. Stage 1G
simultaneously says no client RPC access and that a server gateway must not
trust a caller-supplied actor; it does not define whether a server-verified
assertion is acceptable.

**Required correction:** the product/security owner must decide exactly:
“May a signed-in user invoke the narrow RPC directly using their authenticated
JWT, with database-side authorization, or must the RPC be callable only by a
trusted server principal?” If server-only, specify the trusted principal,
verified-session-to-actor assertion, service-role/table privileges, secret
handling, CSRF/origin protection, and gateway replay limits. Do not equate
authenticated RPC exposure with direct table DML.

**Blocks Stage 2:** Yes.

### H6 — Medium: confirmation, user-facing retry behavior, and audit consumers are not acceptance-tested

**Exact evidence:** Stage 1G
[§14–16](./PHASE-2A-3-4-STAGE-1G-DESIGN-AMENDMENT.md#L672) proposes a
separate entity-confirmation RPC and discriminated results, but gives no
complete confirmation input/authorization/locking/idempotency contract and no
dedicated confirmation test. The current
[review UI](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L32)
only checks `result.error`, while §15 requires a different typed union. The
current accept implementation writes the candidate, identifiers, and entity
separately at
[reconciliation.ts lines 159–280](../examples/nextjs/lib/actions/reconciliation.ts#L159).

**Technical explanation / failure scenario:** if DML is revoked before the
confirmation replacement is fully specified/deployed, a legitimate workflow
will fail. If the UI retains its `{error}` assumptions, it may ignore
`conflict`, `replayed`, or `retryable_failure`, and a timeout can leave the
reviewer unsure whether to retry. `sessionStorage` is per-tab and can be lost
when the tab closes; it does not guarantee retry-key retention across a
browser restart.

**Required correction:** specify the confirmation RPC contract separately,
including current database-side owner/admin authorization, state transition,
audit atomicity, replay semantics, and exact result type. Update the action and
UI contract together. Define the persistence lifetime for an idempotency key
when a user closes/reopens a tab, signs out, or changes account, and test
unknown-outcome UX and replay. Do not revoke confirmation DML until cutover
passes.

**Blocks Stage 2:** Yes for an implementation that includes confirmation;
otherwise explicitly defer it and retain only the necessary permission.

## 6. Invocation architecture assessment

### Authenticated narrow RPC

This design is technically compatible with the repository's present
Next.js/Supabase SSR path: the server client uses the anon key and cookies,
and actions call `auth.getUser()`. With a valid user access token, PostgREST
sets the database role from the signed JWT role claim (normally
`authenticated`), and Supabase `auth.uid()` reads the signed subject claim.
A SECURITY DEFINER function runs SQL with its owner privileges, while the
request JWT claims remain available to `auth.uid()`/`auth.role()`; those claims
must still be checked in the function and must not be confused with
`current_user`.

The design is acceptable only if the requirement means: **no direct decision
table writes; a narrow RPC is an allowed authenticated endpoint, and the
database itself verifies tenant membership/role and state.** An authorized
client can call that RPC without using the UI, so UI role checks are not a
security boundary. An ordinary member may invoke the endpoint but must receive
no decision, no tenant disclosure, and no candidate-lock contention.

### Server-only trusted gateway

This is also technically implementable in principle in the current Next.js
architecture, but not with the existing user-JWT Supabase client alone. A
server action can verify its cookie session with `auth.getUser()`, derive the
actor from that verified result, and call a separate server-only Supabase
client using a service credential. The RPC then sees `service_role`, not the
user's identity; the SQL function must take the actor assertion from the
gateway and enforce that actor's current tenant membership/role. The database
trusts the gateway because only it has the credential. The request must not be
allowed to choose `actor_id`.

This alternative needs strict credential isolation, no service key in
`NEXT_PUBLIC_*` or browser bundles, strict server-action origin/CSRF handling,
server-side session verification on every call, input validation, rate and
replay controls, and a least-privilege service-role ACL review. Service-role
RLS bypass does not itself grant SQL table privileges, but any retained table
ACLs or inherited grants may still permit direct access; revoke/check them.
Using a user JWT inside the gateway does **not** make the RPC server-only if
`authenticated` has EXECUTE.

### Exact unresolved requirement

The owner must resolve whether the prohibition is against:

1. direct table DML only, with authenticated callers permitted to invoke a
   database-authorized RPC; or
2. any direct client invocation of that RPC, requiring a trusted server
   principal and a defined, verified actor assertion.

The current requirement to prohibit client RPC access cannot be silently
weakened to fit the existing user-JWT action. Conversely, selecting a
service-role gateway cannot be treated as safe without its trust/ACL contract.

## 7. Authorization, locking, and RLS assessment

### What is sound in principle

- Candidate tenant discovery can be non-locking and membership-gated.
- Locking the current membership tuple `FOR SHARE` before the candidate row
  gives a clear serialization point for a concurrent role update/delete.
- Under `READ COMMITTED`, a locking read that waits on an update must inspect
  the surviving/current tuple and then check the locked role; if the row was
  removed, authorization fails. The decision transaction must keep that lock
  through commit.
- The proposed consistent order (membership, candidate, ordered source rows,
  ordered entity rows) avoids common cycles among the human decision RPCs if
  every writer follows it.
- PostgreSQL row-locking SELECT privilege requirements make a trusted helper a
  reasonable way to lock immutable source rows without granting the executor
  UPDATE on source data.

These are design-level conclusions, not runtime verification.

The relevant PostgreSQL 15 contracts are documented in the
[locking clause of `SELECT`](https://www.postgresql.org/docs/15/sql-select.html)
and [row security policies](https://www.postgresql.org/docs/15/ddl-rowsecurity.html).
They do not establish the target database's actual owner, RLS, or JWT behavior.

### Remaining gaps

1. **Tenant discovery:** the helper is described to accept `candidate_id` and
   `actor_id`, but exact SQL must prove `actor_id = auth.uid()` for the
   authenticated design. If using the gateway design, it must prove only the
   trusted service principal can call it and that actor is not request input.
   The helper must use a stable membership lookup, return a generic
   unauthorized/not-found result, and not return company ID before membership
   succeeds.
2. **Membership locking:** confirm the membership key is unique, RLS is
   bypassed only within a trusted helper, and `FOR SHARE` is held for the
   whole RPC. Test last-owner protection triggers and concurrent role changes.
3. **Helper ownership:** “owned by postgres” is not a complete safety model.
   A superuser/BYPASSRLS owner can ignore RLS; every helper must have exact
   tenant predicates, fixed search path, fully qualified references, bounded
   arrays, and a small return shape. Verify ownership transfer rights and
   effective grants on the intended platform.
4. **RLS context:** Stage 1G mentions a transaction-local company context but
   not the exact mechanism or policy SQL. A caller-set context must never
   grant access. The easiest safe proof may be to avoid a GUC and use exact
   function predicates/role-specific policies, or set a transaction-local
   context only after identity/membership lock and deny all caller-controlled
   setters. Decide and specify it.
5. **Lock ordering:** candidate then source then entity is coherent among
   decisions. Confirm no entity restoration/deletion, confirmation, manual
   link, discrepancy, or worker path takes the same locks in a reverse order.
   The current source generator reads source rows without locking and candidate
   insertion uses a unique index; it still can regenerate terminal pairs as
   described in H4.
6. **Read-committed races:** same-candidate requests serialize at candidate
   lock; different candidates sharing a source serialize at ordered source
   locks, provided all links are re-read after lock acquisition and the
   database unique source-link constraint is present. The latter is currently
   absent, so uniqueness is not guaranteed by the schema.
7. **Error handling:** helper failures must propagate; lock helpers must not
   return empty rows on permission or SQL errors. Retry only deadlock and
   serialization failures with the same idempotency identity.

## 8. Audit integrity assessment

The existing audit schema is append-only by RLS policy, but that does not make
events authentic. `log_audit` is SECURITY DEFINER and its latest checked-in
definition authorizes authenticated callers by tenant membership while
accepting the caller-supplied action; service role is allowed without the
member check. The
[audit log table](../supabase/migrations/20260514000006_audit_log.sql#L10)
also stores nullable actor and company references, so service-role calls can
create unattributed entries.

Stage 1G is correct to require an atomic workflow-owned wrapper, but these
properties are still necessary:

- **Authenticated fabrication:** not prevented until `log_audit` rejects
  reserved workflow actions for all authenticated callers.
- **Service-role fabrication:** not prevented until generic calls from
  service role are also denied for reserved actions or generic EXECUTE is
  revoked/replaced after caller inventory. RLS bypass is not the only issue;
  the SECURITY DEFINER wrapper itself inserts the row.
- **Authoritative attribution:** a dedicated function whose action is fixed
  per decision (or whose allowed action is not caller-controlled) must link
  actor, company, candidate, decision ID, and outcome to the typed decision.
  Merely correlating target strings in an audit consumer is not enough unless
  exact correlation and duplicate behavior are defined.
- **Duplicate/contradictory records:** require a unique decision per candidate
  outcome/idempotency scope and an audit correlation key/constraint or a
  consumer rule that handles legacy rows, retries, and duplicates. Stage 1G
  says replay writes no second event but does not define the schema-level
  audit-to-decision relationship.
- **Atomic failure:** a wrapper error inside the same RPC transaction will
  roll back prior writes if it is allowed to propagate. The contract says so,
  but it has not been executed. Existing application `await log_audit` calls
  do not check the RPC result and are not atomic with preceding DML.
- **History:** historical generic `match.accepted`/`match.rejected` rows
  cannot be retroactively certified. Analytics and audit UI must label them
  as legacy/unverified unless a typed decision correlation exists.
- **Overloads/defaults:** enumerate every overload and default EXECUTE ACL.
  Revoking one exact signature does not protect another overload, and
  default privileges may regrant functions created later.

Repository caller search found reconciliation action calls plus invitation
Edge Function calls. Those legitimate callers need action-specific migration
planning before changing generic audit grants.

## 9. Schema and migration assessment

### Reviewer decisions and idempotency

Stage 1G's legacy/typed split is feasible in principle: old rows can remain
untyped while new rows require a candidate/action/key. The final design must
spell out all columns and exact predicates, including:

- whether `reviewer_id` remains nullable for legacy data despite the current
  `NOT NULL` plus `ON DELETE SET NULL` contradiction;
- how accepted decisions reference result entity versus rejected decisions
  with no result entity;
- how candidate/company/reviewer relationships are tenant-consistent;
- exact unique scope `(company_id, reviewer_id, idempotency_key)` and partial
  predicate;
- behavior when a committed key is replayed after candidate status or entity
  status changed; and
- whether audit correlation references a typed decision ID.

An advisory lock is only a serialization optimization. The unique constraint
must establish correctness. The fixed key encoding should be chosen and
versioned, but advisory hash collisions are safe if they only cause extra
serialization and the unique key is authoritative.

### Composite foreign keys and indexes

PostgreSQL 15 supports composite unique constraints/FKs and partial unique
indexes, subject to a matching unique referenced key. Stage 1G orders the
dependent operations better than Stage 1E. However, its migration blueprint
still says “such as” parent keys and “cover every FK” without enumerating the
exact columns/actions. The migration author needs a table-by-table FK and
index matrix from the live schema.

The identifiers table is the notable hard invariant gap (H1). Its existing
primary key does not establish one source to one entity. A candidate pair
normalization check and uniqueness predicate must also match the worker's
actual `ON CONFLICT` target exactly. The worker currently accepts directional
`a` and `b` UUIDs, excludes self-pairs, and inserts them unchanged; no
normalization is present in that RPC. Migration/application rollout must
change the worker payload/RPC together with the index.

### Existing deletes and immutability

The base schema declares company cascades for reconciliation rows, source
records, and identifiers. The source trigger raises on DELETE. Stage 1G
appropriately blocks ordinary company deletion pending a retention policy,
but a future archive procedure must not accidentally invoke those cascades.
The existing identifiers' FKs also cascade on entity/source delete, and
reviewer decisions have a `NOT NULL reviewer_id` referencing auth users with
`ON DELETE SET NULL`. Those actions require a deliberate transition plan.
Do not treat soft deletion as equivalent to physical retention compliance.

### Concurrent indexes and migration history

`CREATE INDEX CONCURRENTLY` must execute outside a transaction. Stage 1G
properly warns against assuming an ordinary transactional migration can
contain it and includes invalid-index recovery checks. The exact Supabase CLI
behavior cited is only a prior Stage 1B local finding; inspect the actual
version/pipeline used for deployment. Test failure after index creation but
before migration-history recording, and the inverse partial state, in a
disposable migration rehearsal.

Migration 06 remains a hard boundary: do not reconstruct, apply, mark applied,
or infer Git provenance from its locally recorded SQL. Stage 1G's mention of
“checksum evidence” should be conditional on such evidence actually existing;
the prior Stage 1B report establishes recovered statements, not necessarily a
stored checksum or original source file.

## 10. Application integration assessment

| Path | Repository behavior | Stage 1G coverage | Independent conclusion |
|---|---|---|---|
| Accept | [`acceptMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L159) directly reads/updates candidate, inserts/updates links and creates an entity from source payload, then calls generic audit separately. | Replaces with accept RPC and key. | Correct scope; must also remove canonical data merge, honor the DB unique source-link constraint, and update the review UI. |
| Reject | [`rejectMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L299) directly updates candidate then separately audits. | Replaces with reject RPC and key. | Correct in principle; ensure reject never creates links/entities and typed outcome is displayed. |
| Confirmation | [`confirmEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L354) directly updates entity status and separately audits. | Separate RPC, but contract deferred to future definition. | Not implementation-ready; either complete a precise contract/test or explicitly defer and retain that write capability. |
| Link insertion | Accept directly inserts into `reconciliation_identifiers`; other manual paths remain possible. | Match RPC owns links; unrelated writers require separate operation. | Must inventory all writers and enforce global one-source uniqueness in DB. |
| Candidate generation | Worker RPC inserts pair in received order with pending-only `ON CONFLICT`. | Preserve worker boundary and normalize. | Must decide terminal pair behavior (H4) and coordinate the exact normalized index predicate. |
| Entity export | Reads entity and identifier/source data and separately logs export. | Filter deleted entities. | Verify deleted status before both entity and source queries; ensure read/audit behavior stays tenant scoped. |
| Discrepancy resolution | [`resolveDiscrepancy`](../examples/nextjs/lib/actions/reconciliation.ts#L592) reads, directly updates, then calls generic audit. | Explicitly deferred. | Direct UPDATE/audit bypass remains after match-only DML revocation. Keep least required permission or cut over in a separate approved scope; do not claim all human decisions are protected. |
| Generic audit | Actions and invitation Edge Functions call `log_audit`. | Restrict workflow-owned actions after caller inventory. | Must update all callers and reject workflow actions for both authenticated and service-role generic calls. |
| Result/UI handling | Current review UI expects `{ error }` and alerts only errors. | New discriminated union proposed. | Code and UI are not yet compatible; test every outcome and stale/unknown result. |
| Key persistence/retry | No current key passed by the actions. | UUID per intent; session storage suggested. | Retention across tab/browser closure and account switch is not defined. Always reuse the same key after ambiguous transport failure. |

Direct writes that must be removed or deliberately retained before any DML
revocation include candidate status updates, entity status updates, identifier
inserts, discrepancy resolution, and other administrative/entity management
paths. A narrow match RPC does not cover them all.

## 11. Test coverage assessment

Stage 1G §16 is a strong inventory, not evidence. The following additions and
refinements are necessary:

| Area | Local/disposable integration | Staging | Production |
|---|---|---|---|
| Real identity and PostgREST role | Issue real test JWTs for owner/admin/member/nonmember and verify the actual JWT `sub`/`role` reaches the RPC; test `auth.uid()` under both invocation designs. Do not rely solely on test `set_config` or `SET ROLE`. | Repeat with deployment auth/PostgREST configuration and exact function ACLs. | Read-only inspect role/function ACL and auth configuration; do not invoke decision writes. |
| `SECURITY DEFINER` / FORCE RLS | Execute functions under their final owners; test owner role attributes, function `proconfig`, forced RLS, wrong tenant, malicious IDs, pre-set GUCs, and search-path shadow objects. | Verify same with managed roles and actual grants. | Read-only catalog verification. |
| Function overloads/ACLs | Enumerate overloads, `PUBLIC`/default grants, role membership, and exact EXECUTE access; assert denied direct helper and RPC calls for anon/workers/scheduler. | Recheck exact deployed ACLs. | Catalog-only checks. |
| Unauthorized lock contention | Two sessions: member starts request and pauses; owner/admin must not be blocked by a candidate lock held by unauthorized member. | Repeat with real JWTs and pooler. | Not a production write test. |
| Concurrent decision correctness | Accept/accept, accept/reject, two candidates sharing source, two candidates sharing entity; assert one-source uniqueness and exact audit/decision count. | Repeat under real Supabase concurrency and transaction/pooler behavior. | Read-only inspect resulting constraints only. |
| Membership revocation | Update role/delete membership concurrently with decision; prove lock-winner rule and that stale role does not authorize after revocation commit. Include last-owner trigger. | Repeat against actual schema. | No destructive role mutation. |
| Idempotency | Same key same binding, same key different action/candidate, concurrent reuse, response loss, process restart, and duplicate unique conflict. | Exercise actual HTTP timeout/retry and gateway if selected. | No decision invocation. |
| Audit spoofing | Authenticated and service-role attempts to submit workflow actions through every generic overload; verify fixed wrapper cannot be invoked by them; inject audit failure and confirm full rollback. | Repeat with actual role claims and grants. | Inspect representative correlation only, read-only. |
| Identifier uniqueness | Seed existing duplicate source links; verify preflight stops rollout; race two insertions to different entities and ensure DB constraint rejects one. | Repeat contention with actual RPCs. | Read-only duplicate and constraint query. |
| Candidate regeneration | Accept/reject a pair, run matching candidate insert again (including reversed input), and verify chosen terminal-pair policy. | Test concurrent worker/reviewer candidate insertion. | No worker writes. |
| Confirmation / discrepancy | Test confirmation transition, audit rollback and retries if in scope. Separately test that deferred discrepancy DML remains as intended and is not mistaken for secured. | Cutover integration. | Read-only grants/path audit. |
| Migration interruption | In disposable DB, fail before/during/after concurrent index creation and before history recording; validate invalid index cleanup and safe rerun. | Rehearse exact CLI/pipeline and history behavior. | No migration; inspect history/index validity only. |
| Retention/deletion | Disposable schema only: company delete/archive, entity delete, source trigger, reviewer account deletion and FK graph. | Staging only after written policy approval. | No destructive test; read-only policy verification. |
| Worker compatibility | Execute import/matching/scheduler RPCs as their actual restricted roles after grants/policies/index changes. | Run worker lease and conflict tests against deployment-equivalent setup. | Read-only privilege check only. |

The classifications in Stage 1G should be adjusted: deterministic PostgreSQL
lock/constraint tests can and should run locally; staging is additionally
required for Supabase JWT/PostgREST/pooler and hosted-role behavior. Production
is limited to read-only catalog and migration-history inspection.

No tests were run for this review.

## 12. Migration 06 and hosted-project boundary

No hosted project was identified, connected to, or inspected for this review.
The Stage 1B report's local finding that migration version
`20261101000006_enforce_import_finish_lease` is recorded and its SQL can be
recovered does not prove:

- that Git ever contained the corresponding migration file;
- which operator or mechanism applied the SQL;
- that the recovered statements are the original source file;
- that the hosted database has the version or same function definition; or
- that any stored checksum exists.

Before any migration reconciliation, an authorized owner must identify the
exact Supabase project ref, organization, and environment out of band and
authorize read-only inspection. Compare hosted migration history, active
function body/owner/config/ACL, schema constraints/indexes/RLS, and role
attributes to local and Git evidence. Do not print credentials, tokens, API
keys, or connection strings. Do not reconstruct or apply migration 06 during
this stage.

## 13. Corrective actions, ordered by priority

1. **Resolve invocation requirement:** choose direct authenticated RPC with
   database authorization, or server-only gateway with a service-principal
   trust contract. Specify whether the client prohibition covers RPC endpoints
   or only direct table DML.
2. **Enforce source-link uniqueness:** specify and preflight a unique key on
   source-record link identity; define duplicate repair and writer behavior.
3. **Specify exact RLS/ACLs:** replace the policy pattern with a precise
   per-role, per-table, per-command policy and column grant matrix, including
   the tenant context protocol and actual role-membership closure.
4. **Close audit forgery:** restrict every generic audit overload for both
   authenticated and service role; define the fixed authoritative wrapper,
   decision correlation, duplicate semantics, and consumer treatment of old
   events.
5. **Choose terminal candidate-pair lifecycle:** decide whether accepted or
   rejected pairs may be regenerated, then align worker normalization,
   conflict inference, uniqueness, and typed decision references.
6. **Complete confirmation and cutover contracts:** specify confirmation RPC
   and tests or explicitly defer it; inventory every link/entity/discrepancy
   and operational writer before grants change.
7. **Fix application key/result UX:** implement typed responses in action and
   UI, establish key retention across ambiguous responses/account changes,
   and exercise actual network retries.
8. **Complete the migration plan:** enumerate exact parent/child keys, indexes,
   FK actions, compatibility predicates, concurrent-index isolation, invalid
   index recovery, and migration-06 reconciliation without fabricating its
   provenance.
9. **Approve lifecycle policies:** obtain written product/legal approval for
   company archive/erasure, source retention, entity soft deletion, reviewer
   erasure, and historical decision/audit retention.
10. **Run staged verification:** execute local disposable role/RLS/constraint
    and concurrency tests, then staging JWT/PostgREST/pooler/migration tests.
    Production remains read-only for verification.

## 14. Final recommendation

**GO FOR ANOTHER DESIGN AMENDMENT.**

Stage 1G materially improves the prior design but does not yet establish a
schema-enforced one-source-one-entity invariant, an executable executor RLS
contract, or an audit trust boundary that excludes service-role forgery. The
RPC invocation decision, terminal candidate-pair behavior, and full app
cutover also remain unresolved or unimplemented. These are design defects or
owner decisions, not merely missing confidence.

Create a new amendment that addresses H1–H6 and updates the N1–N6/F1–F11
status matrix. Only after that amendment is independently reviewed and the
explicitly local implementation phase is separately authorized may local
implementation begin. This verdict does not authorize hosted database
changes, production deployment, or destructive operations.
