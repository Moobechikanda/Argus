# ZamBase Phase 2A.3.4 — Stage 1I Design Amendment

> **Design only.** This amendment addresses findings H1–H6 in the
> [Stage 1H independent review](./PHASE-2A-3-4-STAGE-1H-INDEPENDENT-REVIEW.md).
> It does not authorize implementation, application changes, migration
> creation or execution, database access, hosted-project access, or changes to
> roles, grants, RLS policies, functions, indexes, or data. Prior reports
> remain unchanged.

## 1. Executive summary and readiness verdict

**Verdict: NO-GO for implementation.**

This amendment makes the remaining design choices explicit enough to plan
implementation, while preserving the unresolved owner decisions and runtime
verification gates. It proposes:

- a database-enforced one-source-record/one-entity link using a unique
  source-record key and tenant-consistent foreign keys;
- an exact executor role/table/command policy model with transaction-local
  tenant context set only inside trusted functions;
- a literal server-only workflow gateway to satisfy the requirement that
  browser clients cannot call workflow RPCs;
- generic audit rejection for workflow-owned actions, plus a decision-ID
  derived authoritative audit event;
- permanent normalized-pair identity across candidate terminal states, with
  explicit re-review deferred; and
- a complete separate entity-confirmation RPC contract and durable
  idempotency-key lifecycle.

These are proposed specifications, not demonstrated behavior. In particular,
the gateway and its service credential, exact executor/function ownership,
PostgREST role behavior, migration 06, existing data compatibility, legal
retention, and concurrent operation still require approval and testing.

**Stage 2 local implementation is not authorized by this document.** The
final disposition remains NO-GO until the independent review and authorization
checklist in §18 are complete.

## 2. Scope and evidence

This is a documentation amendment; no database or hosted project was
connected to, and no test was run. It relies on:

- current repository schema, worker, audit, and Next.js implementation;
- prior Stage 1A/1B local findings, explicitly not treated as hosted facts;
- PostgreSQL 15 semantics described in the cited Stage 1D/1F reports; and
- proposed behavior that remains unverified until implemented in a disposable
  local environment.

The current worktree contains pre-existing modified and untracked files.
Repository references identify current-worktree content, not necessarily
committed or deployed state.

Relevant repository evidence includes the
[identifier key and link schema](../supabase/migrations/20261029000001_reconciliation_module.sql#L245),
[pending-only candidate pair index](../supabase/migrations/20261029000001_reconciliation_module.sql#L291),
[forced-RLS policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L478),
[generic audit implementation and grant](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L50),
[worker candidate conflict target](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L196),
[accept/reject/confirm actions](../examples/nextjs/lib/actions/reconciliation.ts#L159),
[cookie-backed server client](../examples/nextjs/lib/supabase/server.ts#L11), and
[review UI result handling](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L32).

### 2.1 Invariants

- One source record has at most one entity link, including if that entity is
  soft-deleted.
- A candidate pair has one durable review identity. A prior accept/reject
  suppresses automatic regeneration; reopening/re-review is outside this
  milestone.
- Acceptance establishes provenance only. It never merges entities, changes
  canonical data, or modifies survivorship.
- New entities start with empty canonical data and a neutral manual-review
  survivorship rule.
- Rejection creates no entity, identifier, or source link.
- Source records are never updated or deleted by workflow RPCs.
- Decisions and their authoritative audit events commit or roll back together.
- Browser clients cannot execute workflow RPCs or directly perform decision
  DML. The server gateway is the only external entry point.
- Workers retain their existing narrow RPC boundaries; they receive no
  unrestricted table access or `BYPASSRLS`.
- Unknown SQL errors never become success-shaped responses.

## 3. Stage 1H findings H1–H6

| Finding | Stage 1I correction | Remaining gate |
|---|---|---|
| H1 — Identifier key does not enforce one entity per source | §6 adds an explicit unique source-record constraint and tenant-consistent parent/child FKs; defines duplicate preflight and conflict handling. | Existing duplicates and FK compatibility must be inspected; no cleanup is implicit. |
| H2 — Executor RLS is only a pattern | §7 defines role/table/command privileges, policies, context source and lifecycle, and states which rows are accessed only through trusted helpers. | Exact SQL and effective RLS must be validated under the final owners/roles. |
| H3 — Generic audit has no trusted caller discriminator | §10 reserves workflow action values from the generic wrapper for all external callers and derives authoritative audit fields from a typed decision ID. | Caller inventory, overload ACL inspection, and runtime negative tests remain mandatory. |
| H4 — Terminal pair may be regenerated as pending | §8 selects one permanent normalized pair row; no automatic re-review. Worker normalization and `ON CONFLICT` are specified. | Product approval and existing duplicate/reversed-pair preflight are required. |
| H5 — Invocation architecture unresolved | §5 selects a server-only gateway as the proposed design to preserve the explicit no-client-RPC requirement. | Owner approval, service credential/ACL feasibility, and gateway tests required; if infeasible, return to design review. |
| H6 — Confirmation/UI/key persistence incomplete | §§11–13 specify a separate confirmation contract, action result unions, and persistent key lifecycle. | Product scope decision and application/UI acceptance tests required. |

This status table does not mean any finding has been runtime verified.

## 4. Owner decisions and design limits

The amendment chooses a **proposed default** where a business/security choice
is unavoidable; it does not substitute for owner approval:

1. **Invocation:** server-only workflow gateway, no authenticated/PostgREST
   EXECUTE on workflow RPCs.
2. **Candidate pair lifecycle:** the normalized pair is reviewed once; an
   accepted or rejected pair is not regenerated automatically. A formal
   re-review feature would require a new versioned review generation and is
   out of scope.
3. **Entity target status:** only active `candidate` and `confirmed` entities
   are eligible. `merged`, `rejected`, deleted, missing, or unknown states
   conflict without redirection/restoration.
4. **Company/account retention:** archive rather than ordinary physical
   deletion; legal erasure/purge is a separately approved procedure.
5. **Discrepancy resolution:** remains deferred and must keep only the
   permissions it requires until a separate atomic replacement is approved.

If owners reject any of these defaults, stop and issue another design
amendment; do not silently implement an alternate behavior.

## 5. Invocation architecture: server-only gateway

### 5.1 Chosen proposed contract

The browser does not call `accept_reconciliation_match`,
`reject_reconciliation_match`, or `confirm_reconciliation_entity` through
PostgREST. A Next.js Server Action is the gateway. It:

1. obtains the cookie-backed Supabase session using the server client;
2. calls `auth.getUser()` and treats only the verified returned user ID as
   actor identity;
3. validates action, UUIDs, idempotency key, Origin/Host, and request shape;
4. invokes the RPC through a separate server-only Supabase client using a
   secret that is never named with `NEXT_PUBLIC_` and is never imported into
   client modules; and
5. never accepts an actor ID, company ID, role, or authorization assertion
   from the browser request.

PostgREST sees the service principal for the database RPC; `auth.uid()` is
not the reviewer identity in this call path and must not be used as if it
were. The RPC accepts a reviewer UUID only as a **gateway assertion** and is
executable solely by the trusted gateway role. The gateway derives that UUID
from the verified session on every request.

The service credential is a bearer secret and a high-impact trust boundary.
It must be stored in the deployment secret manager, excluded from logs and
bundles, rotated, and absent from browser source maps and client environment.
The gateway must enforce same-origin/CSRF protections, secure session
cookies, authorization through the database's current membership row, and
rate limits. A server action's existence alone is not CSRF protection.

### 5.2 Database grants and actor assertion

The target role name and deployment mechanism remain subject to catalog and
platform verification. The preferred role is a dedicated non-login
`reconciliation_workflow_gateway` with EXECUTE on the three exact external
RPC signatures and no direct table privileges. If the deployed PostgREST
configuration cannot issue or assume such a principal, the only proposed
fallback is `service_role` with:

- EXECUTE only on exact workflow RPCs needed by the gateway;
- no direct DML or unnecessary SELECT on workflow decision tables;
- no client exposure of the service credential; and
- catalog-verified absence of inherited table grants or alternate writable
  functions that defeat the restriction.

`BYPASSRLS` on service role does not itself confer table ACL privileges, but
it makes any remaining ACLs significant. Revoke and verify direct table
access where compatible with all other service-role callers. Do not assume
the role can be narrowed without caller inventory.

The RPC rejects a null reviewer assertion and any non-UUID input. The gateway
role is the only role authorized to assert it. The SQL function checks that
the asserted actor has a current owner/admin membership in the candidate's
tenant under the lock protocol in §9. The actor assertion is trusted only
because the gateway credential is secret and only verified server code may
use it. If that trust assumption is not acceptable, a custom signed assertion
protocol and its verification key lifecycle must be designed separately.

### 5.3 Rejected alternative: authenticated narrow RPC

Granting `authenticated` EXECUTE is technically compatible with `auth.uid()`
but means any holder of a valid user JWT can call the workflow RPC directly,
without using the UI or Server Action. That may be acceptable if the policy
prohibits only direct table DML, but it does not meet the stated requirement
that clients be denied workflow RPC access. It is not the selected design.
The owner may explicitly change that requirement, but such a change returns
the design to independent security review.

## 6. Source/entity uniqueness and exact relational constraints

### 6.1 Source-link uniqueness

The current key `(entity_id, source_record_id)` permits one source to be
attached to multiple entities. The target invariant is:

- each source UUID appears in zero or one row of
  `reconciliation_identifiers`;
- each link's `company_id` equals both the source row's company and entity
  row's company; and
- an existing link is immutable through this workflow: no UPDATE or DELETE
  reassigns it.

Proposed schema prerequisites:

1. Parent keys: `UNIQUE (company_id, id)` on
   `reconciliation_source_records` and `reconciliation_entities` if exact
   matching unique keys do not already exist.
2. Child unique invariant: `UNIQUE (source_record_id)` on
   `reconciliation_identifiers`. Source IDs are UUID primary keys and
   therefore globally unique; this prevents a source from linking to two
   entities regardless of tenant.
3. Tenant-supporting uniqueness: `UNIQUE (company_id, source_record_id)` on
   `reconciliation_identifiers` if needed for the exact composite FK/reference
   and query plan. It is redundant for uniqueness but may be retained only if
   useful and measured.
4. Composite FKs:
   - `(company_id, source_record_id)` references
     `reconciliation_source_records(company_id, id)`;
   - `(company_id, entity_id)` references
     `reconciliation_entities(company_id, id)`.
5. Keep the existing `(entity_id, source_record_id)` primary key only if
   required by consumers; otherwise any key transition must be explicitly
   planned, preserving its dependent FKs and indexes. A primary-key change is
   not implied by adding the unique source key.

Run read-only duplicate preflight before adding the unique source index.
Duplicates must block the migration and be reported with tenant/source/entity
IDs to an authorized operator; no automatic row deletion or entity choice is
permitted. Resolve duplicates only through an explicitly approved,
audited data-repair decision. Concurrent insertion is ultimately protected
by the unique index, not merely by application locks.

### 6.2 Candidate/result/decision relationship constraints

Typed decision rows must bind a single company, reviewer, candidate, action,
result entity (accept only), and idempotency key. Use tenant-consistent
composite foreign keys wherever the parent has a matching unique key. The
typed-row CHECK must explicitly distinguish:

- legacy row: typed candidate reference is NULL and key may be NULL, with
  legacy decision representation preserved; and
- new typed row: candidate/company/reviewer/action/key are non-null, action is
  `accept` or `reject`, accept has a result entity, reject has no result
  entity, and the decision's target identity cannot be contradicted by
  generic `decision_target_table/id`.

The final implementation must also decide how the current
`reviewer_id NOT NULL REFERENCES auth.users ON DELETE SET NULL` contradiction
is transitioned. Do not invent reviewer identity or erase historical
attribution.

## 7. Exact executor privilege and RLS contract

The SQL implementation must follow this role split:

- `reconciliation_workflow_executor`: owns only accept/reject/confirm
  `SECURITY DEFINER` functions; `NOLOGIN`, `NOBYPASSRLS`; not granted to
  gateway, `service_role`, workers, scheduler, `authenticated`, or `anon`.
- `reconciliation_workflow_gateway` (or approved service-role fallback):
  EXECUTE only on exact external workflow functions; no direct workflow table
  privileges.
- trusted helper owner: `postgres` only if verified as required and available;
  owns narrowly scoped lock/audit helpers; no client EXECUTE.
- clients and workers: no workflow function EXECUTE and no direct DML on
  decision/link fields.

All relevant tables retain ENABLE and FORCE RLS. A session GUC is **not**
accepted from the gateway as tenant authorization. The executor functions set
the tenant context only after current actor membership has been locked and
validated. The context is transaction-local, overwritten on each invocation,
and is never set from a request field.

Define a fixed-path helper, executable only within the definer chain, to
return the current validated tenant context from the transaction-local setting.
It returns NULL if absent or malformed. Executor policies must use this
helper, and all decision functions fail closed if context is absent. No other
executable function granted to the executor may set arbitrary context.
Gateway and client roles have no table grants that would let them benefit
from setting the GUC themselves. The exact helper owner/grants and inability
to call the context setter outside the trusted definer call must be verified
under actual PostgREST roles.

### 7.1 Executor table/command matrix

| Table | Executor SELECT | Executor INSERT | Executor UPDATE | Executor DELETE | RLS policy requirement |
|---|---|---|---|---|---|
| `reconciliation_match_candidates` | Own tenant rows only; decision function needs source IDs, pending status, and current result. | None. | Only `status`, `reviewer_id`, `reviewed_at`, and `entity_id` if required. Never update company/source IDs/score/details. | None. | `SELECT USING tenant_context = company_id`; `UPDATE USING` and `WITH CHECK` same tenant. Column ACL restricts updated fields. |
| `reconciliation_source_records` | None for executor; trusted lock helper returns only IDs, tenant, and existing link references. | None. | None. | None. | No executor policy/grant; helper uses explicit company predicates under trusted owner. |
| `reconciliation_entities` | Only fields necessary to check company/status/deleted state and canonical data is not selected. | New empty entity only; `WITH CHECK` tenant matches context and fixed neutral fields enforced by RPC/check. | None for match accept. | None. | `SELECT USING tenant_context = company_id`; `INSERT WITH CHECK tenant_context = company_id`. Entity row locks occur in helper. |
| `reconciliation_identifiers` | Only IDs/company/entity/source needed to detect existing link. | Insert provenance only with tenant context. | None. | None. | `SELECT USING` and `INSERT WITH CHECK` tenant match context; unique source constraint is authoritative. |
| `reconciliation_reviewer_decisions` | Scope to context; replay lookup only. | Typed decisions only, matching context. | None. | None. | Tenant-scoped SELECT/INSERT; CHECK and unique constraints enforce typed contract. |
| `memberships` | None. | None. | None. | None. | Membership discovery/lock only through trusted authorization helper with explicit `(company_id, actor_id)` predicate. |
| `audit_log` | None. | None. | None. | None. | Authoritative insert only through dedicated trusted audit helper; no executor table DML. |

Policies are `TO reconciliation_workflow_executor` and command-specific.
No `USING (true)`, no broad `PUBLIC` policy, and no direct source UPDATE
privilege. The final migration must state the exact actual policy expressions,
function signatures, and column grants; the matrix above defines the required
semantics, not executable SQL.

All helper and function EXECUTE grants are exact-signature grants. Revoke
`PUBLIC`, `anon`, `authenticated`, both workers, scheduler, and all unrelated
roles explicitly, then grant only the required internal/external roles.
Verify inherited membership, schema USAGE, enum USAGE, function defaults, and
actual table/column ACLs from catalogs.

## 8. Candidate-pair identity and worker write contract

### 8.1 Selected lifecycle

A normalized source pair has one durable candidate row for its lifetime.
Accept or reject is terminal. Matching workers do not create a fresh pending
candidate for a pair that has already been accepted or rejected. Re-review,
reopening, and versioned reconsideration are out of scope.

### 8.2 Pair normalization and index

Normalize each pair in the database worker RPC so:

- `record_a_id = LEAST(input_a, input_b)`;
- `record_b_id = GREATEST(input_a, input_b)`;
- self-pairs are rejected/omitted; and
- a CHECK enforces `record_a_id < record_b_id`.

Replace the pending-only uniqueness rule with uniqueness across all candidate
statuses on `(record_a_id, record_b_id)`. The worker insert uses the exact
non-partial `ON CONFLICT (record_a_id, record_b_id) DO NOTHING` inference
target. The normalized pair index is the authority; status changes do not
release pair identity.

Preflight all candidate pairs after canonical normalization. Reversed rows or
duplicates block rollout and require explicit, auditable disposition; do not
delete historical decisions or choose a survivor automatically. If the product
later needs re-review, add an explicit review generation and unique key
including that generation in a separate reviewed design.

## 9. Authorization, lock order, and transaction contract

### 9.1 Gateway identity and membership

`accept_reconciliation_match(candidate_id uuid, idempotency_key uuid,
reviewer_assertion uuid)`, `reject_reconciliation_match(...)`, and
`confirm_reconciliation_entity(entity_id uuid, idempotency_key uuid,
reviewer_assertion uuid)` are callable only by the gateway role.

The gateway derives `reviewer_assertion` from `auth.getUser()`'s verified
server-side result and never accepts it from browser input. The database
checks the gateway invocation role through its sole EXECUTE grant, then
validates the asserted actor's current membership and role itself. An actor
assertion mismatch cannot be validated through `auth.uid()` because the
database sees the service principal. Restrict the gateway API and credential
accordingly; leaked service credential compromises this assertion boundary.

### 9.2 Lock order

Within one database transaction, all human workflow functions follow:

1. Validate gateway invocation and input format; require non-null actor
   assertion and idempotency key for decisions.
2. Perform a membership-gated, non-locking candidate/entity tenant discovery.
   Return a uniform unauthorized/not-found result if the actor is not a
   member; do not expose tenant ID to the gateway response.
3. Lock the exact membership `(company_id, reviewer_id)` `FOR SHARE`; check
   the locked row's role is owner/admin. Keep lock until transaction end.
4. Acquire idempotency advisory lock and check for a committed replay; a
   replay still requires current owner/admin membership.
5. Lock candidate `FOR UPDATE`, rechecking company and pending status.
6. Lock all candidate source rows in ascending UUID order through a
   `postgres`-owned helper, rechecking tenant membership and source existence.
7. Lock all linked/target entity rows in ascending UUID order through a
   trusted helper; recheck tenant, deletion timestamp, and status.
8. Re-read all identifier links after source locks. If a link points to another
   entity, return a conflict without mutation. The unique link index remains
   the final concurrency guard.
9. Perform inserts/updates, typed decision insert, authoritative audit insert,
   then return a typed outcome. Any error rolls back the full transaction.

Entity confirmation uses the same membership-before-entity order, then locks
the entity and revalidates tenant, nondeleted state, and `candidate` status.
Entity restoration, merge, or rejection operations must use separate flows.

### 9.3 Membership and isolation semantics

Proposed isolation is READ COMMITTED. Membership lock is held for the whole
decision transaction. If a downgrade/removal commits first, the workflow
observes the current missing/non-admin tuple and denies. If the workflow locks
first, membership change waits until it commits. The lock order among all
human decision functions is consistent.

Worker candidate generation does not lock source rows in the opposite order;
it inserts a normalized pair under a unique index and validates the source
tenant in its lease-bound RPC. Any future manual link/entity operation must
follow the same source-then-entity lock order or use equivalent unique
constraints. PostgreSQL `40P01`/`40001` may still occur; retry only with the
same durable key and bounded backoff.

## 10. Audit integrity and correlation

### 10.1 Generic audit function

The generic `log_audit` function remains available only for non-workflow
actions required by inventoried callers. Its database implementation must
reject reserved workflow action values (including match accepted/rejected,
reviewer decision, and entity confirmation events) for both `authenticated`
and `service_role` callers. Restricting UI choices is insufficient.

Before changing grants or behavior, inventory every overload and caller,
including invitation Edge Functions, reconciliation actions, triggers,
workers, SQL jobs, and docs/examples. Migrate legitimate workflow writers to
their own trusted wrappers; preserve unrelated invitation actions. Revoke
generic EXECUTE from any role that does not need it. Inspect default
privileges so a later overload cannot reopen the path.

### 10.2 Authoritative wrapper

Add a dedicated trusted function with only the decision ID as input. It:

1. reads the typed decision row and derives company, reviewer, candidate,
   action, and result entity from that committed transaction's inserted row;
2. maps the typed decision action to one fixed audit enum action;
3. inserts exactly one audit row with a typed `reconciliation_decision_id`
   correlation reference;
4. accepts no caller-supplied actor, company, action, target, or metadata; and
5. raises on any failure.

The wrapper is owned by the verified trusted owner, fixed empty `search_path`,
fully qualified, and executable only by the executor function chain. Add a
nullable `reconciliation_decision_id` to `audit_log` for legacy compatibility,
with a FK to decisions and a unique partial index for non-null decision IDs.
The unique key makes one authoritative event per typed decision. If audit
retention or deletion rules cannot support that FK, stop and redesign instead
of omitting correlation.

The transaction writes decision then audit before commit. Audit insertion
failure aborts the transaction. Replays return the original decision and do
not create another audit row.

### 10.3 Legacy event interpretation

Existing workflow-labeled generic audit rows without typed decision
correlation are legacy/unverified. Do not backfill fabricated decision IDs.
Audit consumers must label these entries as unverified/legacy and treat only a
correlated decision/event pair as authoritative. Duplicate or contradictory
legacy events remain visible as historical evidence, not silently corrected.

## 11. Entity confirmation contract

Confirmation remains a separate operation; it is not added to accept/reject.

`confirm_reconciliation_entity(entity_id uuid, idempotency_key uuid,
reviewer_assertion uuid)`:

- is executable only by the server gateway;
- verifies current owner/admin membership under the same membership lock;
- locks entity after membership authorization;
- requires matching tenant, `deleted_at IS NULL`, and status `candidate`;
- transitions only `status` to `confirmed` and updates timestamp;
- does not modify canonical data, survivorship, identifier links, or counts;
- inserts a typed confirmation decision with non-null idempotency key and one
  authoritative correlated audit event atomically;
- returns `confirmed`, `replayed`, `conflict`, `unauthorized`,
  `not_found_or_unavailable`, or a surfaced retryable/unexpected failure;
- same key/actor/entity/action replays; different binding returns
  `idempotency_key_reused`; and
- a failed audit insert rolls back confirmation and decision.

An already confirmed entity is a replay only when a matching committed key
and typed confirmation decision exist. Otherwise return `already_confirmed`
conflict; never create a new audit event and success-shaped replay without
decision evidence.

## 12. Idempotency and application persistence

### 12.1 Database identity

Committed-decision-only semantics remain selected. Unique scope:
`(company_id, reviewer_id, idempotency_key)` for all typed accept/reject and
confirmation decisions. Key lookup is tenant/reviewer scoped and occurs after
current authorization. Same key/same candidate-or-entity/action replays;
same key with a different action or target conflicts. Failed/conflict
transactions do not reserve keys.

Use a single versioned deterministic advisory-lock encoding based on the
ordered bytes of company UUID, actor UUID, and request UUID. The encoding must
be specified with test vectors before implementation. Advisory collisions may
only serialize unrelated operations; the unique constraint defines identity.

### 12.2 Gateway key lifecycle

The browser generates a cryptographically random UUID per intent and submits
it as an opaque request token; it is not an authorization credential. Persist
it in same-origin `localStorage` (not only per-tab `sessionStorage`), keyed by
authenticated user ID, operation, and target ID. Reuse it after timeout,
connection reset, page reload, tab close/reopen, and bounded SQLSTATE retries.
Do not include tenant payload or sensitive data in the key record. On logout
or user switch, never reuse another user's pending key; retain or remove
records only according to a documented retention policy.

After an ambiguous result, show “outcome unknown; retry” and keep the key.
Clear a key only after a definitive accepted/rejected/confirmed/replayed or
definitive conflict result. A new user intent receives a new key. The server
does not convert a timeout into success.

### 12.3 Retry and errors

Retry only `40P01` and `40001` within a bounded jittered budget, reusing the
same operation, target, reviewer, and key. After exhaustion return
`retryable_failure` with a request correlation ID and retain the key. Map
only exact known constraint names to expected conflicts. Permission errors,
unexpected uniqueness failures, audit failures, malformed inputs, and unknown
SQL errors remain failures; never map them to `replayed` or success.

## 13. Application action and UI result contract

The server action performs verified session lookup and input validation, then
calls the private service client. It returns discriminated unions, never
generic `{ ok, error }` alone:

```ts
type DecisionResult =
  | { kind: 'accepted'; decisionId: string; entityId: string }
  | { kind: 'rejected'; decisionId: string }
  | { kind: 'confirmed'; decisionId: string; entityId: string }
  | { kind: 'replayed'; outcome: 'accepted' | 'rejected' | 'confirmed'; decisionId: string; entityId?: string }
  | { kind: 'conflict'; code: string }
  | { kind: 'unauthorized' }
  | { kind: 'not_found_or_unavailable' }
  | { kind: 'retryable_failure'; requestId: string }
  | { kind: 'unexpected_failure'; requestId: string };
```

Server actions must not accept `reviewer_assertion` or company ID from client
input. The review and entity UI must handle every union member explicitly:
refresh queue on accepted/rejected/replayed, display safe conflict messages,
retain keys after retryable failures, and never alert based solely on a
nonexistent `error` property. No SQL detail, cross-tenant existence, raw
source data, or stack trace is returned.

## 14. Complete write-path cutover boundary

| Path | Target contract | Cutover requirement |
|---|---|---|
| Accept/reject | Server gateway to atomic typed decision RPCs. | Remove direct candidate/link/entity/decision writes from actions; UI uses result union and persistent key. |
| Entity confirmation | Separate gateway RPC in §11. | Replace direct status UPDATE and separate audit before revoking status DML. |
| Identifier/link writes | Accept RPC only for match provenance. | Inventory other writers; provide separate authorized operation or explicitly defer and retain least privilege. |
| Candidate generation | Existing lease-bound matching worker RPC, normalized ordered pair and all-status unique pair key. | Update worker/RPC and exact `ON CONFLICT`; test terminal suppression and reversed inputs. |
| Source ingestion | Existing import worker RPC. | Preserve source immutability and worker-only boundary; no executor direct source UPDATE. |
| Export/list reads | Existing tenant-authorized reads with soft-deleted entity filtering. | Verify deleted target never exported as active; audit export through safe, non-workflow generic action. |
| Discrepancy resolution | Deferred; current direct UPDATE and separate audit remain. | Do not revoke its required permission until a separately approved atomic replacement is deployed. This remains a known direct-write exception. |
| Manual entity management, merge, restoration, deletion | Outside this milestone. | No match RPC expansion. Keep separately governed permissions and document residual risks. |
| Invitation and operational audit calls | Continue through generic audit only for nonreserved actions. | Caller inventory and service-role spoof test before generic wrapper change. |

No broad reconciliation DML revocation is permitted while a current writer
depends on it. Revocation is table/column/role-specific and follows verified
cutover of every in-scope writer.

## 15. Migration design and ordering

This is a proposed sequence, not executable SQL. Do not reconstruct or apply
missing migration 06.

1. **Read-only baseline:** inventory actual schema, duplicate identifiers,
   normalized candidate pairs, legacy decisions, all FKs/delete actions,
   triggers, RLS, privileges, overloads, and migration history.
2. **Resolve migration 06 evidence:** compare local recorded SQL, active
   function, Git evidence, and intended hosted state. Do not invent checksum
   or original-file provenance. Obtain approval for a separate reconciliation
   procedure.
3. **Parent keys:** add/build unique `(company_id, id)` keys on source records
   and entities if absent. Concurrent unique index creation must be a
   standalone operation outside explicit transaction; attach constraints in
   a separate transaction only after validity checks.
4. **Typed decision schema:** add nullable candidate, result entity, typed
   action, key, and audit correlation columns. Preserve legacy rows through an
   explicit legacy CHECK branch; validate historical data before tightening.
5. **Candidate pair normalization:** preflight canonicalized pairs for
   duplicate/reversed rows; resolve explicitly. Add ordered-pair CHECK and
   unique index across every status. Update worker normalization and
   non-partial conflict inference in a coordinated rollout.
6. **Identifier uniqueness:** preflight duplicate source links. Build
   unique `source_record_id` index concurrently if necessary, outside
   explicit transaction. Add matching parent unique keys and supporting
   indexes after relevant columns exist.
7. **Child indexes:** create decision, candidate, identifier, audit correlation
   and FK-support indexes after all columns exist; exact leading-column order
   follows each FK. Concurrent operations remain individually isolated.
8. **Composite foreign keys and checks:** add tenant-consistent FKs only after
   parent unique keys and child columns/indexes exist. Add `NOT VALID` where
   supported and warranted, then validate after explicit legacy/duplicate
   resolution. No silent cleanup.
9. **Retention/FK transition:** only after product/legal approval, update
   incompatible delete actions and reviewer attribution lifecycle. Rehearse
   complete FK/trigger graph on disposable data.
10. **Trusted role/functions:** create roles only after checking platform
    capabilities; create helpers, workflow RPCs, and audit wrapper with fixed
    empty `search_path`; perform ownership transfer only through verified
    temporary grants; then revoke temporary privileges.
11. **Policies and ACLs:** apply exact FORCE RLS policies, column grants, and
    gateway-only EXECUTE. Remove authenticated/workers/scheduler access to
    decision RPCs and helper overloads. Recheck function default privileges.
12. **Local security tests:** validate owner, forced RLS, grant closure,
    uniqueness, rollback, and worker compatibility before app cutover.
13. **Application gateway cutover:** deploy server actions and UI, verify
    server session derivation, CSRF/origin policy, secret isolation, durable
    idempotency handling, and no direct write callers.
14. **Scoped direct DML revocation:** revoke only in-scope direct decision
    writes after every in-scope writer has been replaced. Keep explicit
    discrepancies and manual operations out of this revocation.
15. **Post-cutover read-only verification:** confirm owner, function config,
    policies, ACLs, index validity, constraints, migration history, and
    intended project identity without exposing secrets.

### 15.1 Concurrent index recovery

`CREATE INDEX CONCURRENTLY` must not run inside a transaction. The prior
Stage 1B observation about Supabase CLI 2.119.0 is a local finding only. Before
deployment, verify the exact CLI/pipeline version and how standalone
statements interact with migration history. After a failure, inspect
`indisvalid`, `indisready`, definitions, duplicate data, and history. Recover
only the specific invalid index through an approved procedure; do not replay
an entire migration blindly or falsely mark it applied.

## 16. Retention and deletion

Default lifecycle is archive/soft-delete, not physical tenant deletion.

- **Company:** archive access and retain source/provenance/decisions. Physical
  purge requires written legal/product approval and a separately designed
  purge process compatible with the immutable-source trigger and all
  dependent cascades.
- **Entity:** soft delete only through a separate authorized operation;
  preserve identifiers and decisions. No workflow acceptance restores or
  redirects it.
- **Reviewer:** resolve the current non-null reviewer FK plus `ON DELETE SET
  NULL` contradiction. Preserve actor attribution through an approved
  retained/pseudonymous reference or legal purge policy; do not fabricate
  history.
- **Audit/decisions:** append-only for ordinary roles. Audit correlation FK and
  unique decision event must be compatible with approved retention.

Soft-deleted entities are excluded from normal lists, active review targets,
and exports. Historical views may show a deletion marker to authorized users.
No production destructive test is allowed.

## 17. Test and verification matrix

No test is claimed as run.

| Test | Local disposable integration | Staging | Production |
|---|---|---|---|
| Unique source link | Duplicate preflight; concurrent link inserts to different entities; exact unique conflict. | Repeat concurrent decision race with deployed roles. | Read-only duplicate and constraint inspection. |
| Pair identity | Reversed inputs normalize identically; terminal candidate suppresses regeneration; exact non-partial conflict target. | Concurrent worker/reviewer candidate insertion. | Read-only pair/index inspection. |
| Executor RLS and ACL | Every role/table/command, exact function overload, column grants, GUC pre-set attempts, owner and FORCE RLS behavior. | Verify managed-role/PostgREST configuration. | Catalog-only checks. |
| Gateway identity | Forged browser actor/company ignored; missing/invalid session denied; server-only secret not bundled; workflow RPC unavailable to authenticated role. | Real JWT, cookies, origin, CSRF, service-role/grant and gateway integration. | Read-only secret/config handling review; no workflow invocation. |
| Membership/locking | Downgrade/removal concurrent with decision; unauthorized lock contention; ordered shared-source/entity locks. | Repeat with actual pooler/PostgREST transaction behavior. | No role mutation or decision call. |
| Audit integrity | All generic overloads reject workflow actions for authenticated and service role; one correlated event; failed event rolls back all writes. | Repeat with deployed audit ACLs/callers. | Read-only decision/audit correlation sample. |
| Idempotency/UI | Same and mismatched keys; response loss; reload/tab close/account switch; retry budget; explicit union branches. | Network timeout and gateway restart behavior. | Read-only duplicates and correlation. |
| Confirmation | Candidate→confirmed, existing confirmed conflict/replay, unauthorized, audit failure rollback, immutable canonical values. | End-to-end UI/server gateway. | Read-only state checks. |
| Worker compatibility | Existing import/matching/scheduler RPCs; normalized pair index; no direct DML. | Real worker roles and exact CLI deployment. | Read-only privilege inspection. |
| Migration recovery | Interrupt concurrent build and history steps; recover invalid index without duplicate/false history. | Exact CLI and deployment pipeline rehearsal. | No migration; history/index inspection only. |
| Delete lifecycle | Disposable full-FK/trigger rehearsal only after policy approval. | Staging only if specifically authorized and with disposable data. | No destructive test. |

## 18. Outstanding evidence and Stage 2 checklist

### 18.1 Unresolved evidence / decisions

- Product/security owner approves the server-only gateway and trusted
  service-principal model.
- Platform confirms a least-privilege gateway role is possible, or approves
  service-role fallback after ACL and caller analysis.
- Product owner approves terminal candidate-pair identity and no automatic
  re-review.
- Product owner approves candidate/confirmed entity eligibility and deleted
  entity visibility.
- Legal/product owners approve company archive/erasure, source retention,
  reviewer erasure, and decision/audit retention.
- Existing source-link and normalized-pair duplicates are inspected; no
  hosted project is assumed or guessed.
- Migration 06's recorded local SQL, Git provenance, and hosted state remain
  separate facts until an owner identifies the target and authorizes safe
  read-only inspection.
- Exact helper/function ownership, grants, RLS, PostgREST role, and CLI
  behavior must be validated in the intended environment.

### 18.2 Stage 2 authorization checklist

- [ ] Independent reviewer confirms H1–H6 are addressed or explicitly
  accepted as gated owner decisions.
- [ ] Server-only gateway identity, CSRF/origin controls, secret handling,
  service-role/direct ACLs, and RPC grants are approved.
- [ ] Unique source-record link and normalized all-status candidate-pair
  constraints are preflighted and specified.
- [ ] Exact executor policies, context protocol, column privileges, helper
  owners, function overload ACLs, and role membership are specified.
- [ ] Generic audit spoofing is blocked for both authenticated and
  service-role calls; authoritative audit uses unique decision correlation.
- [ ] Confirmation RPC and UI contracts are complete, or confirmation is
  explicitly deferred with necessary permission retained.
- [ ] All direct write paths and deferred exceptions are enumerated.
- [ ] Historical data and FK/delete transitions have a no-silent-change plan.
- [ ] Local disposable tests pass for RLS, ACLs, uniqueness, concurrency,
  idempotency, audit rollback, and worker compatibility.
- [ ] Staging tests pass using actual JWT/PostgREST/pooler and migration
  runner; production verification is read-only.
- [ ] Migration 06 and intended hosted project are verified only after
  authorized identification; no provenance is inferred.
- [ ] Backup, recovery, monitoring, rollout, and rollback/forward-fix plans
  are separately approved.

**Final recommendation: NO-GO. Stage 2 implementation is not authorized.**
Proceed only after the blockers and owner decisions above are addressed and
the revised design receives independent review. This document does not
authorize hosted database changes, production deployment, or destructive
operations.
