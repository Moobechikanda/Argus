# ZamBase Phase 2A.3.4 — Stage 1M Corrected Design Amendment

> **Design only.** This document proposes a corrected specification responding
> to Stage 1L. It does not authorize implementation, tests, database access,
> migration creation or execution, hosted-project access, staging, or production
> changes. No tests or database operations were performed for this document.
> Existing worktree changes are to remain untouched.

## 1. Executive summary and verdict

**Recommendation: CONDITIONAL GO FOR ANOTHER INDEPENDENT DESIGN REVIEW ONLY.**

Stage 1L found that Stage 1K still depended on an unspecified signature
verifier, did not bind audit rows to a verified actor, allowed terminal pair
regeneration during worker expansion, left request recovery ambiguous, and had
not closed the caller, role, and ACL inventories. This amendment removes the
unnecessary signature assertion from the primary design: the existing
cookie-backed Supabase client calls a narrow authenticated-user RPC, and the
database derives the actor from the verified Supabase JWT (`auth.uid()`). The
RPC itself performs current-membership authorization and every state change.
It is callable over PostgREST, so it must be secure even when called outside a
Next.js Server Action.

The amendment also defines a request ledger keyed by actor and request key,
an audit relationship that is created atomically with the typed decision, a
worker pause-before-change sequence, a preservation-first candidate-pair
identity registry, a writer inventory, and recovery checkpoints. These are
proposals, not implemented or runtime-verified behavior.

Before a future disposable-local implementation-testing authorization
decision, owners must approve the decision and retention semantics; the exact
source and function/role inventory and the local migration-history discrepancy
must be accounted for; and the implementation plan must be reviewed
independently. **This recommendation is not authorization to begin that
implementation or testing.** Staging, hosted access, and production changes
remain unauthorized.

## 2. Evidence classification and review basis

Labels used below:

- **Repository-verified:** present in current-worktree source. Some files are
  untracked or modified; source presence does not prove Git provenance or
  deployment.
- **Prior local observation:** recorded in an earlier local-only report; not a
  fresh database query and not evidence of hosted state.
- **Proposed design:** desired future behavior or illustrative SQL; not
  implemented or tested.
- **Platform assumption:** must be confirmed for the selected local or hosted
  Supabase/PostgreSQL deployment before it is relied upon.
- **Owner decision:** requires product, security, privacy, or legal approval.
- **UNRESOLVED:** repository evidence or authoritative platform material does
  not establish the needed behavior.

### 2.1 Sources

Reviewed [Stage 1L](./PHASE-2A-3-4-STAGE-1L-INDEPENDENT-REVIEW.md),
[Stage 1K](./PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md),
[Stage 1J](./PHASE-2A-3-4-STAGE-1J-INDEPENDENT-REVIEW.md), and the earlier
Stage reports where relevant. Repository evidence includes the
[reconciliation schema and policies](../supabase/migrations/20261029000001_reconciliation_module.sql),
[worker RPCs and grants](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
[lease recovery](../supabase/migrations/20261101000004_recover_missing_worker_leases.sql),
[cron and retention setup](../supabase/migrations/20261030000002_reconciliation_security_ops.sql),
[Next.js actions](../examples/nextjs/lib/actions/reconciliation.ts),
[cookie-backed Supabase client](../examples/nextjs/lib/supabase/server.ts),
[matching worker](../services/reconciliation/matching/splink_worker.py),
[import worker](../services/reconciliation/imports/worker.py),
[second import loader](../services/reconciliation/imports/loader.py),
[invitation Edge Function](../supabase/functions/invitations/index.ts), and
[import-download Edge Function](../supabase/functions/import-download-url/index.ts).

**Repository-verified:** the server client uses the public anon key with
cookie-backed authentication; actions call `auth.getUser()`. The Python
workers use dedicated database URLs and controlled RPCs. The matching worker
sends directional pair IDs. Current sources define `pgcrypto` installation in
the reconciliation operations migration, and the Stage 1B local report records
PostgreSQL 15.19. These facts do not prove that the extension or an approved
cryptographic design is present in any target database.

**Authoritative documentation consulted:** PostgreSQL 15 documents the
`pgcrypto` HMAC function and its OpenSSL dependency
([PostgreSQL `pgcrypto`](https://www.postgresql.org/docs/15/pgcrypto.html));
Supabase documents extension enablement
([Supabase extensions](https://supabase.com/docs/guides/database/extensions)),
its `service_role` RLS bypass
([Supabase Postgres roles](https://supabase.com/docs/guides/database/postgres/roles)),
and JWT identity
([Supabase JWTs](https://supabase.com/docs/guides/auth/jwts)). These sources
establish general capabilities, not the configuration or identity of a
particular hosted project.

**No runtime verification:** no tests, SQL, database command, migration
command, or hosted-project access was performed for Stage 1M.

## 3. Resolution of Stage 1L findings

| Stage 1L finding | Stage 1M design response | Remaining gate |
|---|---|---|
| **L1 — Verifier and key lifecycle not demonstrated** | Primary design no longer requires a custom signed assertion. A narrow RPC is called with the user's authenticated Supabase session and derives actor from `auth.uid()`; no service key or caller-supplied actor establishes identity. HMAC is described only as a conditional fallback. | Verify JWT claim behavior and effective PostgREST role in the disposable local environment. A service-role or HMAC fallback requires a separate security decision. |
| **L2 — Audit actor binding incomplete** | The decision RPC supplies `auth.uid()` as reviewer; the audit writer independently compares the typed decision reviewer and tenant to the JWT actor and transaction tenant. A unique decision/audit link and deferred consistency check enforce one-to-one correlation. | Implement and test using actual roles; inventory every audit overload, trigger, default grant, and operational caller. |
| **L3 — Worker normalization before pause** | Pause and drain matching writers before any writer-function change, normalization, or backfill. Build the permanent identity registry and resolve historical duplicates while stopped; resume only after the new RPC and indexes are verified. | Owner-approved duplicate resolution and disposable migration/restart rehearsal. |
| **L4 — Ambiguous ledger lookup and lock key** | Exact replay uses unique `(actor_id, request_key)` plus immutable tenant/operation/target binding. Lost-key recovery is an authorized decision-history query returning a list, never an ambiguous implicit replay. | Approve retention and account-removal behavior. |
| **L5 — Incomplete callers** | §10 inventories repository-observed actions, workers, Edge Functions, cron/retention, and trigger/audit paths; identifies inventory closure required before privilege cutover. | Complete code/config/catalog inventory in a separately authorized local test; current deployment principals remain unverified. |
| **L6 — RLS/ACL/helper closure incomplete** | §7 defines the proposed role boundary, context lifecycle, operation-specific RLS semantics, and privilege closure requirements. Caller-supplied GUCs and IDs are never authorization evidence. | Verify effective grants, inherited role memberships, function owners, FORCE RLS, and policy composition under actual roles. |
| **L7 — Failpoints and retention recovery incomplete** | §12 provides per-step interruption recovery and retention tests; migration 06 provenance remains separate from repository and hosted state. | Rehearse only after explicit disposable-local test authorization; retention is an owner decision. |

These are design responses only; none is a verified implementation result.

## 4. Proposed security architecture

### 4.1 Trust boundaries

1. **Browser:** supplies operation, target ID, a random request key, and
   operation-specific fields. It does not supply an authoritative actor,
   tenant, role, or decision result.
2. **Next.js Server Action:** obtains the cookie-backed client, calls
   `auth.getUser()`, performs input validation and same-origin checks, then
   invokes one narrowly scoped RPC using the user's session. It does not use a
   service-role client for reviewer decisions.
3. **PostgREST/Supabase Auth:** validates the JWT and maps the request to
   `authenticated`. The database derives actor from the verified JWT claim
   through `auth.uid()` and derives tenant from the target row.
4. **Workflow RPC:** is the sole reviewer mutation boundary. It rechecks
   membership from database state, locks and validates target/source/link
   rows, applies the state change, writes typed decision/ledger/audit rows in
   one transaction, and returns a closed result union.
5. **Workers and operational services:** retain separate worker or
   service-role paths for their specific functions. They do not receive
   reviewer-function `EXECUTE` or decision-table DML.

**Proposed invariant:** security does not depend on Server Action secrecy or
on the RPC being inaccessible to direct PostgREST callers. An authenticated
user may call the RPC directly; the database must apply exactly the same
identity, membership, input, target, idempotency, and audit checks.

### 4.2 Alternatives and recommendation

| Approach | Feasibility from repository/platform evidence | Trust and privileges | Decision |
|---|---|---|---|
| Dedicated database gateway principal | Supabase documents custom PostgreSQL roles, but no repository evidence establishes a dedicated PostgREST JWT role/credential, pooler route, or deployment process for one. A direct database login is possible in general PostgreSQL but would not itself prove the human reviewer. | Needs credential provisioning, actor authentication, tightly scoped grants, operational rotation, and assurance that unrelated functions cannot use it. | **Not selected.** Platform availability and actor-binding design are UNRESOLVED. |
| Shared `service_role` | Current Edge Function uses a service-role client for import download; Supabase documents that `service_role` bypasses RLS. | Any function holding the key can invoke whatever its grants allow; RLS cannot protect against it. Revoking table DML and all unnecessary function access could narrow it, but current app/worker/Edge callers and inherited ACLs are not yet closed. | **Rejected as the primary reviewer path.** Do not treat an unprefixed environment variable as isolated. |
| Cryptographically verified actor assertion | PostgreSQL 15 `pgcrypto` documents HMAC-SHA-256; repository migrations request `pgcrypto`, but target extension availability and key storage are not verified. The cited extension does not establish an asymmetric public-key verifier. | HMAC requires the gateway and database to share a secret. Database-side verification can be confined to a fixed-search-path function with protected key material, but the signer is trusted and any runtime holding the secret can impersonate actors. Key rotation/revocation and replay handling are additional obligations. | **Not selected for the primary design.** Use only if an owner requires a separate signer and a dedicated design/security review approves storage, isolation, rotation, and threat model. |
| Authenticated Supabase JWT → narrow RPC | Current architecture already uses a cookie-backed authenticated Supabase client and `auth.getUser()`; current policies/helpers use Supabase identity functions. Supabase documents JWT-based roles/claims. | `auth.uid()` is derived from the verified request JWT; all authorization and writes remain in the database RPC. No signing secret or service key is needed for reviewer decisions. | **Recommended.** This is the least novel design and matches current app architecture. Exact local PostgREST/JWT behavior is still a test prerequisite. |

**Gateway identity contract:** accept only a request whose PostgREST role is
`authenticated` and whose `auth.uid()` is non-NULL. Reject `anon`,
`service_role`, worker, and scheduler roles from reviewer RPCs. Ignore or
reject any actor/tenant/role values in RPC arguments. Do not copy identity
from mutable `app_metadata` or a custom GUC.

**CSRF/origin:** Server Actions must validate the exact configured Origin,
Host/forwarded-host relationship, method, and content type; use secure,
HTTP-only, SameSite cookies and no wildcard CORS for credentialed routes.
These controls protect the web entry point, but are not the database
authorization boundary. Direct PostgREST invocation still requires a valid
user JWT and passes the same RPC checks.

## 5. Gateway identity and request binding

### 5.1 Primary authenticated-RPC protocol

**Proposed sequence:**

1. Server Action obtains the cookie-backed client and calls `auth.getUser()`.
   Failure, absent user, invalid input, or stale session produces an explicit
   error; it never substitutes a supplied actor.
2. The action validates the operation's shape and request-key format, checks
   the request Origin against the configured canonical origin, then calls the
   operation-specific RPC using the same user client.
3. The RPC checks `auth.role() = 'authenticated'` and `auth.uid() IS NOT NULL`.
   It derives the actor exclusively from `auth.uid()`.
4. The RPC derives tenant from a locked candidate/entity row and checks current
   membership and required role in the database.
5. The RPC validates that the request key is bound to this actor, tenant,
   operation, target, and canonical payload digest.

**Assumptions to verify:** PostgREST authenticates and installs JWT claims
correctly for the local Auth setup; `auth.uid()` remains the verified user ID
inside the selected `SECURITY DEFINER` functions; role/claim functions cannot
be overridden via a request argument; cookie refresh/revocation behavior is
understood. No runtime claim is made here.

### 5.2 Conditional HMAC fallback (not selected)

If a separately isolated server gateway becomes an owner requirement, a
possible *design to evaluate* is a short-lived HMAC-SHA-256 assertion verified
inside PostgreSQL using `pgcrypto.hmac`. It must bind issuer, audience,
actor, exact operation, target, tenant derivation rule, request key, issued
time, expiry, and key version. The database must never return the HMAC secret;
only the verifier can read it. The signer must be isolated from workers,
schedulers, invitation handlers, and generic Edge Functions. Verification
must fail closed for unknown keys, expiry, invalid encoding, bad signature,
wrong audience, and binding mismatch. Replay must reach the idempotency
ledger, not reapply a decision.

**UNRESOLVED:** use of `pgcrypto` is in repository migration source, not a
current target catalog verification. Shared-key storage, secret distribution,
rotation, revocation, compromise recovery, and signer isolation are not
approved. No asymmetric verification or custom crypto implementation is
proposed. This fallback requires separate owner approval and an independent
review; it must not be silently substituted for the primary design.

## 6. Authorization, locking, and concurrency

**Proposed isolation:** `READ COMMITTED` with explicit row locks and
constraint-backed invariants. Each reviewer RPC is one transaction. Retry only
recognized transient SQLSTATEs (`40001`, `40P01`) with the *same* request key,
operation, target, and canonical payload; use a small bounded retry count.
Other errors remain failures.

**Required lock order:**

1. Authenticate `auth.uid()`; perform only non-locking, non-sensitive target
   discovery to derive tenant.
2. Lock the actor's exact membership row `FOR SHARE`; check current role and
   active membership. Membership downgrade/removal must lock/update that same
   row. If the downgrade commits first, the operation denies; if the
   reviewer locks first, downgrade waits until the decision commits.
3. Reserve/read the request ledger row for `(actor_id, request_key)`; enforce
   immutable binding.
4. Lock candidate or entity target `FOR UPDATE`; re-read status, tenant,
   deletion state, and links under lock.
5. Lock source records in ascending UUID order through a narrow trusted
   helper using `FOR KEY SHARE`/`FOR SHARE`, not UPDATE privilege. Re-read all
   links and entity rows in deterministic UUID order.
6. Apply only the permitted status/link changes; rely on unique constraints
   as final guards; insert typed decision, audit correlation, and terminal
   request result.

Every function that mutates membership or reviewer targets must use a
compatible lock order or be included in deadlock tests. Unique-constraint
violations on source links or entity state become a deterministic conflict,
not partial success. Deadlocks/serialization failures abort the whole
transaction and are retried only as described above.

**Soft deletion:** ordinary entity lists and exports filter `deleted_at IS
NULL`; the RPC refuses a deleted entity as a confirmation target or a linked
target. Candidate review must not silently revive a deleted entity. If a
source is already linked to a deleted entity, preserve that historical link
and return an explicit conflict; do not reassign it automatically.

## 7. Tenant context, RLS, and privileges

### 7.1 Roles, ownership, and identity

**Proposed roles:**

- `reconciliation_workflow_executor`: `NOLOGIN`, `NOINHERIT`,
  `NOBYPASSRLS`; not a member of any login role and not a table owner. Owns
  only the reviewer RPCs, context helpers, and trusted workflow audit wrapper.
- Existing migration owner/`postgres` may own narrow cross-tenant discovery
  and row-lock helpers only if that owner is confirmed as privileged in the
  target. Such helpers are security-critical, have fixed empty `search_path`,
  explicit target/tenant predicates, minimal return columns, and `EXECUTE`
  only for the executor.
- `authenticated` receives `EXECUTE` only on the operation-specific RPCs.
  It does not receive membership in executor, decision-table DML, or access
  to internal helpers.
- `anon`, `service_role`, workers, and scheduler receive no reviewer RPC
  execution or decision-table DML. Existing operational RPC privileges must
  be explicitly retained or replaced; no broad revocation is implied.

All function owners, `PUBLIC` privileges, default privileges, role
memberships, `SET ROLE` paths, schema `CREATE`, and inherited ACLs must be
catalog-inventoried before cutover. `SECURITY DEFINER` functions use
`SET search_path = ''` and fully qualified objects unless a helper has a
documented safe `pg_catalog` path. No untrusted role can alter their owner or
definition.

### 7.2 Context lifecycle

A custom setting is **not** identity evidence: callers may be able to set
custom GUC values. The workflow RPC clears its transaction-local company
context on entry, before protected reads; verifies JWT actor and membership;
then sets context from the database-derived target tenant using
`set_config(..., true)`. It clears/overwrites any caller value. A getter
returns NULL for missing, empty, malformed, or noncanonical UUID values.
Policies comparing `company_id` to NULL deny access. The getter and setter
are not granted to external roles and are not security capabilities.

Every externally callable RPC starts from a cleared context. Transaction
commit/rollback ends transaction-local context. No code path reuses a
session-level setting. Tenant context is set only after locked membership
authorization and revalidated target lookup.

### 7.3 Proposed RLS semantics by command

These are **proposed policy conditions, not SQL executed or installed**.
All rows below apply only to `reconciliation_workflow_executor`; existing
policies for other roles must be separately reviewed and removed only with
approved replacement behavior.

| Relation | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `reconciliation_match_candidates` | `USING (company_id = workflow_tenant())` | None | `USING` and `WITH CHECK` same tenant; RPC enforces allowed `pending → accepted/rejected`, reviewer and timestamp. Column grants only for the fields required by this transition. | None |
| `reconciliation_entities` | Tenant equality; exclude deleted rows for ordinary workflow reads | Tenant equality; require `deleted_at IS NULL`, allowed status, creator/reviewer derived from JWT | Same tenant in both clauses; only approved status/`updated_at` columns; forbid deleted target and canonical/survivorship changes | None |
| `reconciliation_identifiers` | Tenant equality | Tenant equality; source/entity tenant consistency and source uniqueness enforced by composite FKs/unique constraint | None | None |
| `reconciliation_reviewer_decisions` | Tenant equality | Tenant equality; all actor/tenant/operation/result fields derived or validated by RPC | None; immutable decision rows | None |
| `reconciliation_decision_audit_links` (proposed) | Tenant-scoped join through decision | Trusted wrapper only; both IDs and tenant must correspond | None | None |
| `reconciliation_workflow_requests` (proposed) | Actor and tenant equality; only own result | RPC only; actor/tenant derived and binding fields validated | RPC only; allow one pending-to-terminal update, no rebinding | None |
| `reconciliation_source_records` | No direct executor grant; narrow trusted lock/read helper only | None | **No UPDATE grant or policy** | None |
| `audit_log` | No general executor read; wrapper reads only required correlated rows | Trusted audit wrapper only; reserved event validated | None | None |

RLS is not a substitute for ACLs. Proposed schema/table/column/type/sequence
and function grants must be enumerated as an explicit allowlist. UUID defaults
and enum usage must not rely on accidental `PUBLIC` rights. No broad
`USING (true)` policy is allowed. No direct source-record UPDATE is allowed
for row-lock acquisition. Every function owner must be checked against
`BYPASSRLS`, superuser, table ownership, `FORCE ROW LEVEL SECURITY`, and role
membership behavior.

**Proposed tenant-consistency constraints:** add `(id, company_id)` unique
keys where needed; composite FKs from identifiers to both entity and source
record; a unique source-record identifier link so one source maps to at most
one entity. Index child FK columns and lock/query predicates. Preflight
historical duplicates or tenant mismatches; do not delete, reassign, or
rewrite source data automatically.

## 8. Authoritative audit contract

### 8.1 Audit entry points and reserved actions

**Repository-verified:** the repository defines six-argument
`log_audit(audit_action, uuid, uuid, text, text, jsonb)` with defaults and
five-argument `log_reconciliation_audit(audit_action, uuid, text, text,
jsonb)` with defaults. The hardening migration grants the generic helper to
`authenticated` and `service_role`, and revokes the reconciliation helper
from those roles. Worker finish/claim functions, invitation paths, Next.js
actions, triggers, cron, and retention call audit code. The actual target
overload set, defaults, ACLs, owners, triggers, and effective role inheritance
remain unverified.

**Proposed reserved workflow actions:** `match.accepted`,
`match.rejected`, `entity.confirmed`, and `reviewer.decision` (plus any
additional labels found by final catalog/source inventory). Every generic
overload and wrapper must reject these labels regardless of `auth.role()`,
`pg_trigger_depth()`, caller-supplied actor, or service-role status. Rejection
must be explicit and transactional. Generic helpers may continue to write
nonreserved operational events only under their existing, validated caller
rules. No trigger or worker may claim reviewer provenance.

`log_reconciliation_audit` must not remain a caller-controlled action/tenant/
target channel. Replace or constrain it to fixed operational action paths
with tenant and target derived from the operational row. Cron events without a
reviewer may use a separate fixed-action helper and a nonhuman actor identity.
Do not grant direct `INSERT`, `UPDATE`, or `DELETE` on `audit_log` to browser,
service-role, worker, scheduler, or generic application roles unless an
individually reviewed existing operation demonstrably requires it.

### 8.2 Decision/audit binding

**Proposed transaction:**

1. Reviewer RPC captures `v_actor := auth.uid()` and `v_company` from the
   locked target; neither is an input parameter.
2. RPC inserts one typed immutable decision with reviewer `v_actor`, tenant
   `v_company`, exact operation, candidate/entity target, and required
   before/after status fields.
3. Trusted `write_reconciliation_decision_audit(decision_id)` reads that
   decision and rejects unless its reviewer equals `auth.uid()`, its tenant
   equals the transaction workflow tenant, its action matches the typed
   operation, and its result entity/candidate and old/new states satisfy the
   operation's invariant.
4. The wrapper inserts the reserved audit row and a unique
   `reconciliation_decision_audit_links` row linking decision and audit ID.
   Both rows carry the same tenant; the audit row's action/target and metadata
   are generated from the decision, not caller arguments.
5. Unique constraints enforce one audit link per decision and one decision
   per audit row. Deferred constraint triggers, if needed to verify
   completeness at commit, must be nonrecursive and validate both directions.
   Any failure aborts decision, state change, ledger result, and audit.

The wrapper has fixed `search_path`, no public/application execute grant, and
is executable only from the trusted workflow owner path. It must not accept
caller-supplied actor, tenant, action, result, or metadata. A decision and
audit correlation is atomic; “at most one” uniqueness and “at least one”
deferred validation are separate requirements.

**Retention invariant:** workflow audit rows cannot be deleted while their
decision/link remains. Either exclude them from operational audit cleanup or
apply a separately approved coordinated retention procedure that preserves
referential and legal obligations.

### 8.3 Audit verification cases

Proposed tests deny every reserved action through every overload, including
five-argument default invocation, authenticated, service-role, worker,
scheduler, and trigger contexts. Tests attempt wrong actor, tenant, operation,
result, decision ID, duplicate audit, cross-tenant decision, direct insert,
and forged generic wrapper call. Inject failure after decision insert, audit
insert, and correlation insert; verify full rollback. Test nonreserved
invitation, worker, cron, and retention events still behave under their
intended principals.

## 9. Worker and candidate-pair rollout

### 9.1 Permanent identity model

**Proposed design:** introduce a permanent pair-identity relation keyed by
`(company_id, low_source_id, high_source_id)`, with checks that
`low_source_id < high_source_id`, both sources belong to `company_id`, and
the two IDs differ. It records the canonical candidate for new reviewer
work. The unique key applies across every pair status. Historical candidate
rows and their decisions remain preserved; duplicate legacy rows are mapped
to one pair identity and hidden from ordinary review lists only after an
owner-approved canonicalization record exists. Do not delete historical
candidate or decision rows as migration cleanup.

The unchanged worker RPC signature continues accepting directional IDs. In
the database, normalize with `LEAST(a,b)` / `GREATEST(a,b)` before inserting
pair identity or candidate. Self-pairs and cross-tenant pairs are rejected or
counted as invalid input, not silently inserted. The exact write conflict
target is the pair identity unique key:

```sql
ON CONFLICT (company_id, low_source_id, high_source_id) DO NOTHING
```

This is **illustrative proposed SQL only**. The worker RPC first inserts the
canonical pair identity; only a newly created pair may create a pending
candidate. An existing accepted/rejected/escalated or otherwise terminal
pair never generates another review candidate. Keep the existing pending-only
candidate index only as a transitional constraint; it is not the permanent
identity.

### 9.2 Ordered expand/contract with checkpoints

1. **Baseline checkpoint:** record exact migration files, migration history
   distinction, worker version, RPC definition, index validity, and row
   preflight in the authorized disposable database. Do not infer this state
   from repository files.
2. **Pause checkpoint:** disable every scheduler/worker mechanism that claims
   or writes matching candidates; stop new claims; allow in-flight runs to
   finish or explicitly fail/expire them; verify no old worker transaction or
   lease remains. The pause occurs *before* changing a writer function,
   normalizing rows, or backfilling pair identity.
3. **Preflight checkpoint:** report self-pairs, cross-company pairs,
   directional duplicates, same-direction duplicates, multiple terminal
   candidates, terminal-plus-pending pairs, and decision/audit references.
   Owner reviews each conflict class and records a preservation mapping.
   Any unresolved ambiguity blocks rollout; no automatic deletion or
   decision rewrite.
4. **Identity expansion:** create pair-identity relation, constraints and
   parent/child indexes; populate one canonical identity per normalized pair
   under the pause; map every historical candidate without changing its
   decision history. Mark noncanonical duplicates non-reviewable only through
   an explicit migration state/relationship that preserves their history.
5. **Index checkpoint:** create/validate all-status uniqueness on the pair
   registry. Any `CREATE INDEX CONCURRENTLY` must run outside a transaction
   in its own migration step. Check `pg_index.indisvalid`/`indisready`; if
   interrupted, keep workers paused, inspect state, drop only the known
   invalid index concurrently if required, and retry. Do not mark an
   incomplete migration applied.
6. **RPC switch checkpoint:** replace the existing RPC body while preserving
   its signature and worker grant. Normalize in SQL, write the registry with
   the exact unique conflict inference above, and insert a pending candidate
   only when the identity is newly created. Validate grants, function owner,
   fixed search path, lease checks, cross-tenant checks, and return count.
7. **Restart checkpoint:** run one controlled local worker against directional
   input in both orientations; confirm only one canonical identity and no
   second candidate. Then resume the worker fleet and monitor unique
   conflicts/lease failures. The old worker binary remains compatible only
   because the database function signature is unchanged; old SQL function
   bodies must not be restored.
8. **Contract checkpoint:** after a soak and verified no dependency, remove
   obsolete partial-index assumptions/paths in a later migration. Never drop
   the permanent identity or audit-history mapping as a rollback shortcut.

### 9.3 Rollback and interrupted recovery

Before the RPC switch, rollback may remove only newly created empty objects
after proving no writers touched them. After backfill or new writes, use
forward repair: preserve identity mappings, keep workers paused, repair invalid
indexes or mappings, rerun idempotent validation, then resume on the new RPC.
Do not restore the old directional writer after canonical writes begin.
Document per-step checksums, expected object state, and operator decisions in
the migration runbook before any authorized execution.

**Owner decision:** historical duplicate disposition and whether a superseded
candidate remains visible in audit/review history. **UNRESOLVED:** the target
data has not been queried; no repository result proves it is duplicate-free.

## 10. Idempotency and recovery

### 10.1 Durable key and binding

**Proposed ledger key:** `UNIQUE (actor_id, request_key)`, where request key
is a client-generated high-entropy UUID. Immutable binding columns are
`company_id`, operation, target type/ID, canonical payload digest, creation
time, and schema version. Store a terminal result code and typed decision/
entity IDs when the transaction succeeds or returns a defined terminal
conflict. Do not store raw source data or arbitrary caller metadata.

The database derives actor and tenant. A repeated same-key/same-binding call
returns the exact stored result and performs no additional write. Same key
with different tenant, operation, target, or canonical payload returns
`idempotency_key_reused`, without changing the original row. A foreign key
from the ledger result to decision/entity prevents dangling outcomes.
Concurrent identical calls serialize on the unique key: use insert-on-conflict
then lock/read the committed row; the unique constraint is authoritative.
No ambiguous ad hoc lock-string encoding is required.

Membership must be rechecked before returning replay data. Membership removal
denies result access; a replay cannot expose another tenant's result. The
result union is fixed, for example: `accepted`, `rejected`, `confirmed`,
`already_decided`, `source_already_linked`, `entity_unavailable`,
`membership_denied`, `idempotency_key_reused`. Unexpected SQL errors do not
become success-shaped results.

### 10.2 Lost key, reload, and account switching

The browser may persist an outstanding key in same-origin storage scoped by
authenticated actor and operation; it is a convenience, not source of truth.
On account switch, clear the local key cache. Server authorization remains
scoped to `auth.uid()` and tenant.

If browser storage is lost, the user calls an authorized decision-history
lookup filtered by current `auth.uid()`, current tenant membership, and
explicit target; it returns a bounded, ordered list of that user's decisions
and outcomes. It does **not** select an arbitrary latest request and replay
it. Multiple requests for one target are represented explicitly with decision
and request IDs. Cross-device recovery is the same history query. Revoked
members cannot retrieve historical tenant outcomes through this endpoint.

### 10.3 Retention

**Owner/legal decision required:** retention duration for request keys,
actor/target associations, decisions, and audit records; whether account
erasure should pseudonymize actor attribution; and how statutory retention
overrides deletion. Ledger expiry must not permit repeating a terminal
decision: durable decision/pair uniqueness and target terminal state remain
authoritative. Cleanup must not delete ledger rows referenced by retained
decisions or audit links. No retention period is invented here.

## 11. Complete application and operational writer inventory

The matrix reflects repository sources, not a claim that deployment/runtime
callers are fully known. Before revoking direct DML, search all code,
deployment definitions, cron jobs, role memberships, function ACLs, triggers,
default privileges, and manual operational procedures. **No broad DML
revocation may precede this closure.**

| Path / current caller | Observed reads/writes | Proposed handling and scope | Required compatibility tests |
|---|---|---|---|
| Accept match — `acceptMatch`, authenticated user | Candidate read/update; entity and identifier inserts; source/identifier reads; `log_audit`. | Replace decision-bearing sequence with one authenticated workflow RPC; in scope. | Concurrent accept/reject, links, source collision, audit failure, replay. |
| Reject match — `rejectMatch`, authenticated user | Candidate read/update and generic audit. | Separate operation branch/RPC; in scope. | Concurrent accept/reject, audit rollback, same-key replay. |
| Entity confirmation — `confirmEntity`, authenticated user | Entity read/update and generic audit. | Narrow confirmation RPC; reject soft-deleted/noncandidate target; in scope. | Entity state races, deleted target, audit rollback, response loss. |
| Identifier/link writes — accept action currently observed | Identifier read/insert; no other direct identifier writer found in reviewed action module. | Workflow RPC only for approved match-derived link writes; preserve uniqueness/FKs. Manual assignment remains deferred. | Concurrent same-source links, cross-tenant parent, rollback. |
| Data-source creation — `createDataSource`, authenticated user | Inserts tenant, name, description, type, config, creator. | Retain separate tenant/admin operation with DB authorization and narrow columns; outside decision cutover. | Nonmember/admin failure, validation, exact grants. |
| Data-source deletion — `deleteDataSource`, authenticated user | Soft-updates `deleted_at`. | Retain soft deletion; no hard-delete cascade; outside cutover. | Active import references and ordinary list exclusion. |
| Import-job creation — `createImportJob`, authenticated user | Reads active source; inserts job with tenant, source, status, file ref, creator. | Retain guarded operation; exact column grant or narrow RPC. | Wrong tenant/source, deleted source, file-ref validation. |
| Import-job retry — `retryImportJob`, authenticated user | Updates failed import job to pending. | Retain as narrow retry RPC/column permission; outside decision cutover. | Retry vs worker claim, stale lease, duplicate retry. |
| Import row ingestion — `worker.py` and `loader.py`, import worker DB role | Both call `reconciliation_import_insert_record`; function inserts immutable source row and refreshes lease. | Retain claim-bound RPC for both callers; never grant direct source DML. | Each caller, duplicate row, expired lease, wrong claim. |
| Import claim/heartbeat/finish — import worker | Claim, source insert, lease heartbeat, terminal job state; audit calls. | Retain exact worker RPC grants and fixed action audit; no reviewer audit authority. | Claim concurrency, lease expiry, audit failure, recovery. |
| Matching run create/retry — `startReconciliationRun` / `retryReconciliationRun`, authenticated user | Inserts queued run or requeues failed run with JSON config. | Retain separately, narrow admin authorization and transition fields. | Retry vs claim, JSON validation, tenant binding. |
| Matching source read/candidate generation — Splink worker | Lease RPC reads tenant source records; matching writer sends directional pair IDs; finish/heartbeat updates run. | Keep current worker-facing RPC signature and lease contract; replace candidate writer internals with canonical identity registry. | Directional/reversed pair, self-pair, lease, terminal replay, concurrent worker. |
| Discrepancy resolution — `resolveDiscrepancy`, authenticated user | Reads and updates resolution/reviewer/time; generic audit. | Do not revoke its current required path in this milestone. Defer to separately designed atomic decision/audit workflow; ensure it cannot modify match decision fields. | Direct test of existing resolution behavior before/after permission plan; tenant and role denial. |
| Entity list / export — reconciliation pages and `exportEntity`, authenticated user | Entity/identifier/source reads; export audit. Entity list currently needs a deleted filter. | Retain read/export path with explicit `deleted_at IS NULL`; export must reject deleted entity and enforce tenant access. | Deleted entity absent from list/export; nonmember export denied; audit failure behavior. |
| Entity management/manual operations | No separate manual merge/delete writer found in reviewed action module. | Treat as **UNRESOLVED** until repository-wide and operational inventory closes; no implied grant or revocation. | Search all routes, scripts, triggers, RPCs and manual operations. |
| Import download URL — Edge Function service-role client | Reads import job/lease and signs private Storage URL. | Retain separate service-role operation; never grant reviewer RPC or reviewer DML. | Claim token/lease, tenant path, expiration, unrelated job denial. |
| Invitations — Edge Function and authenticated callers | Creates/accepts/revokes memberships/invitations; generic audit; service-role membership upsert. | Outside workflow scope; preserve required audit paths and ensure service key not exposed to browser. | Invitation flows, membership lock race, reserved audit action rejection. |
| Audit triggers and helpers | Membership/operational triggers call generic audit; worker and cron call reconciliation helper. | Preserve only fixed, nonreserved operational actions; separately inventory every trigger/function owner and default grant. | Trigger behavior, generic spoof rejection, operational audit continues. |
| Scheduler / retention cleanup | `pg_cron` schedules audit entries; dedicated scheduler invokes cleanup. | Retain fixed-action, minimal scheduler privileges; workflow audit rows excluded from generic deletion. | Effective cron identity, `SET ROLE`, retention boundary, audit rollback. |

### 11.1 Cutover rule

First deploy replacement workflows and keep existing unrelated operational
permissions. Prove each row in the matrix under its actual caller. Only then
revoke the exact decision-table DML and generic workflow-audit paths, in
separate reviewable steps with rollback/forward-recovery plans. A source
search alone is not an ACL closure; inspect effective role membership,
`PUBLIC`/default grants, triggers, functions, Edge secrets, worker connection
roles, and scheduler commands in the authorized disposable environment.

## 12. Migration, compatibility, and data lifecycle

### 12.1 Data and schema constraints

- **Source-to-entity uniqueness:** one source record may be linked to no more
  than one entity. Add a unique source-link constraint after duplicate
  preflight.
- **Tenant consistency:** add composite unique keys and composite FKs for
  identifier `(entity_id, company_id)` and `(source_record_id, company_id)`;
  similarly validate candidate source and entity tenants. Index referencing
  child columns and common lock predicates.
- **Typed decisions:** new rows use operation-specific typed columns and
  `CHECK` constraints ensuring each operation has the required candidate or
  entity, old/new states, and result. Legacy rows remain unchanged; do not
  infer missing historical values or rewrite old audit history.
- **Audit correlation:** each new decision has exactly one authoritative
  audit link; historical decisions are not retroactively represented as if
  they had verified workflow provenance.
- **Candidate identity:** the permanent canonical pair registry is all-status
  and normalized; historical candidates and decisions remain preserved with
  an explicit canonical/superseded mapping.
- **Soft deletion:** company archive is preferred to physical deletion.
  Existing `ON DELETE CASCADE` references to companies/source records could
  physically erase immutable reconciliation records; changing this requires
  an owner-approved lifecycle migration and preflight, not a casual schema
  edit. Ordinary entity lists and exports exclude soft-deleted entities.
- **Reviewer deletion/erasure:** existing foreign keys using `ON DELETE SET
  NULL` can erase direct reviewer attribution. Decide retention and
  pseudonymization before altering reviewer references. Preserve immutable
  decision identity without retaining unnecessary personal data; legal review
  is required.
- **Retention:** align audit, decision, request-ledger, source, import, and
  export retention. No workflow audit deletion may orphan a decision or
  undermine idempotency. Configure no duration until owner/legal approval.

### 12.2 Migration `20261101000006` and hosted state

**Prior local observation:** Stage 1B records local migration-history version
`20261101000006`, a matching active local function, and no corresponding
repository migration file; repository files proceed from `20261101000005` to
`20261101000007`. This remains a recorded local observation, not a fresh
catalog check.

Do not reconstruct, edit, replay, or mark migration 06 applied. Do not infer
its author, source, or intended hosted project. Before any later migration
work, reconcile the local history and active function through an explicitly
authorized, read-only local investigation. Repository provenance and hosted
state are separate questions. **No hosted Supabase project has been
identified or accessed; its identity, migration history, schema, data, and
roles remain UNRESOLVED.**

### 12.3 Concurrent indexes and interruption

Any concurrent index operation runs outside a transaction and has an explicit
checkpoint. After interruption, inspect catalog validity and exact index
definition before retrying. Keep writers paused until validity, constraint
attachment/validation, and conflict inference are confirmed. Never assume a
migration runner safely retries a partially completed concurrent operation.
Use forward repair after data backfill; do not drop identity mappings or
decision history as rollback.

## 13. Proposed implementation test matrix

**All tests below are proposed and NOT EXECUTED.** The next authorization
decision must specify a disposable local environment and permitted setup.

| Invariant | Disposable-local test and expected result |
|---|---|
| Gateway identity | Call RPC with valid authenticated JWT; actor equals `auth.uid()`. Missing, expired, malformed JWT, anon and service-role calls fail. Altered actor argument is ignored/rejected. |
| Forged actor assertions | Primary design accepts no assertion. Attempt supplied actor/tenant/role fields and caller-set GUC; authorization still uses JWT actor, locked membership and database-derived tenant. |
| CSRF and Origin | Server Action rejects absent, foreign, malformed Origin and host/proxy mismatch; valid same-origin call succeeds. Direct PostgREST call still requires valid user JWT and full RPC authorization. |
| Forced RLS and helper owners | Under actual `authenticated`, executor, worker, scheduler, and helper-owner roles, verify `FORCE ROW LEVEL SECURITY`, table ACLs, role memberships, `BYPASSRLS`, function ownership/search path and exact policy outcomes. |
| Cross-tenant isolation | Actor from tenant A supplies IDs from B, mismatched source/entity/candidate IDs, stale target, and guessed UUID; no rows/results leak and no write occurs. |
| Helper privilege boundaries | Directly invoke setter/getter, discovery, lock, and audit helpers as every external role; calls fail. Verify executor cannot `SET ROLE` through any external path and source row lock needs no UPDATE grant. |
| Membership races | Concurrent downgrade/removal and decision. Expected result follows membership-row lock order; no operation commits using a role revoked before authorization linearization. Test lock timeout/deadlock retry. |
| Candidate/source-link concurrency | Concurrent accept/accept, accept/reject, and two candidates sharing one source; exactly one valid decision/link wins; loser receives a deterministic conflict; no partial audit/ledger rows. |
| Worker normalization | Submit `(a,b)`, `(b,a)`, self-pair and cross-tenant pair; exactly one canonical identity, self/cross tenant rejected. Existing terminal pair never creates pending candidate. |
| Audit spoofing and rollback | Try every reserved action through each generic overload/wrapper, including defaults and service role; deny. Fail at decision, audit, and link insert; entire transaction rolls back. Operational nonreserved audit callers still work. |
| Idempotency | Same actor/key/binding concurrent replay produces one decision and identical result. Same key with different actor, tenant, operation, target, or payload cannot retrieve or replace original result. |
| Response loss and browser recovery | Commit then simulate lost response/reload; same key returns stored result. Clear browser storage and recover via authorized decision history. Switch account and verify no old-actor result is visible. |
| Membership revocation / ledger expiry | Removed member cannot replay or look up tenant result. Expired ledger cannot permit duplicate terminal decision; retained decision/pair constraints still block reapplication. |
| Entity confirmation | Confirm only eligible, nondeleted entity; reject deleted, wrong-tenant, stale, and already-confirmed target. Verify atomic decision/audit and unchanged canonical data. |
| Writer compatibility | Exercise each §11 application/worker/Edge/cron caller with its actual local role before and after the planned grant boundary. Every retained path works; reviewer DML and reserved audit spoofing fail. |
| Deleted-entity exclusion | Soft-deleted entity absent from ordinary list and export; export direct ID and confirmation reject; source link history remains intact. |
| Migration recovery | Interrupt after each pair table/backfill/index/RPC checkpoint; verify paused safe state, invalid concurrent index recovery, idempotent rerun, forward repair, and no old writer resume. |
| Retention/lifecycle | Verify workflow audit/link/decision FK protections; source immutability; company archive vs physical-delete behavior; reviewer erasure/pseudonymization decision; no unauthorized cleanup. |

### 13.1 Staging and production boundaries

**Staging tests — not authorized here:** only after disposable-local tests
pass and a separate explicit staging authorization. Use synthetic data,
approved roles/secrets, nonproduction accounts, and an owner-approved
rollback/monitoring plan. Validate real JWT role mapping, cookie/origin
behavior, role membership, cron identity, storage, and worker rollout.

**Production read-only checks — not authorized here:** would require separate
authorization and verified project identity. Read-only preflight could check
migration history, schema/index validity, duplicate/tenant mismatch counts,
role/ACL/function ownership, worker activity, and retention configuration.
No production write, migration, role change, secret access, hosted access, or
deployment is approved by this design.

## 14. Outstanding owner decisions and platform prerequisites

1. Approve using the existing authenticated Supabase JWT as the sole reviewer
   identity and allowing direct authenticated PostgREST invocation of the
   same secure RPCs.
2. Confirm whether reviewer operations require any separately isolated server
   gateway. If yes, commission a separate design for gateway identity,
   credential isolation, and either a verified HMAC scheme or supported
   dedicated principal; do not silently use `service_role`.
3. Approve exact reviewer roles, allowed transitions, terminal-pair behavior,
   historical duplicate resolution, and how duplicate candidates remain
   represented to auditors.
4. Approve request-ledger, decision, audit, source, and actor-attribution
   retention and erasure policy with privacy/legal review.
5. Confirm local Supabase/PostgREST JWT behavior, extension installation
   capability if HMAC is ever considered, function owner capabilities, and
   role membership constraints in disposable local only.
6. Close the full application/operational caller inventory, including
   untracked source, deployment configuration, Edge Function secrets, manual
   operations, trigger functions, default privileges, and worker/scheduler
   connection roles.
7. Resolve Stage 1B's local migration-history discrepancy under a separate
   authorized read-only investigation. Hosted project identity and state
   remain unknown and must not be guessed.
8. Decide whether this amendment is sufficiently complete for another
   independent design review. This is the only next step recommended here.

## 15. Proposed implementation sequence

This is a future sequence only and is **not authorization to execute**:

1. Obtain owner decisions and a separate explicit disposable-local
   implementation-testing authorization.
2. Record pre-test worktree state and use a disposable database only; do not
   connect to hosted Supabase.
3. Inventory effective roles, grants, functions, policies, triggers, callers,
   data constraints, and migration history without changing them.
4. Test current behavior and preflight data; resolve all historical
   duplicates and lifecycle blockers with owners before schema changes.
5. Implement schema/constraints and pair identity under a matching-worker
   pause, following §9 checkpoints.
6. Implement authenticated workflow RPC, locked membership check, context/RLS,
   typed decision/ledger, and authoritative audit as one coherent change.
7. Migrate Server Actions to the RPC while preserving nonworkflow paths from
   §11; do not revoke broad DML yet.
8. Run the proposed local tests with explicit expected outcomes; close failures
   before privilege cutover.
9. Cut over exact ACLs only after caller tests pass; repeat role/negative tests.
10. Request another independent review before any staging authorization.

## 16. Final recommendation and limitations

**CONDITIONAL GO FOR ANOTHER INDEPENDENT DESIGN REVIEW ONLY.**

The primary design avoids an unverified custom signature verifier by using
the repository's existing authenticated Supabase session and making the
database RPC the complete authorization boundary. The worker sequence,
request recovery, audit binding, and test expectations are now substantially
more deterministic. However, the proposed mechanisms have not been
implemented or tested; target roles, RLS, caller completeness, legacy data,
retention decisions, and local migration-history recovery remain unverified
or owner-gated.

Permitted next step: an independent review of this amendment and closure of
the owner/platform prerequisites. This report does **not** authorize
implementation, database access, tests, staging, hosted access, production
changes, or Stage 2.

### Completion record

- **Tests/database operations:** none run; none authorized.
- **Files intended to be changed by this task:** only this new Stage 1M
  document.
- **Pre-existing worktree:** a baseline `git status --short
  --untracked-files=all` and `git diff --check` was recorded before writing.
  Existing modifications and untracked files were preserved; the new report
  is the only intended task delta.
- **Validation:** Markdown link/anchor, code-fence, trailing-whitespace, and
  final `git diff --check` validation must be completed before declaring this
  report finished.
