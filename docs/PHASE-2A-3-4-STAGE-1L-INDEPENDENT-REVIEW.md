# ZamBase Phase 2A.3.4 — Stage 1L Independent Review

> **Read-only review.** No application code, migration, database object,
> role, grant, policy, function, index, data, dependency, or configuration was
> changed. No local or hosted database was accessed, and no tests were run.
> This review is the only file created for Stage 1L. Pre-existing worktree
> changes were preserved.

## 1. Executive verdict

**NO-GO for a future disposable-local implementation-testing authorization review.**

Stage 1K responds to the six Stage 1J findings and is more specific, but its
most important security mechanism is still a placeholder: it requires the
database to verify a signed actor assertion without choosing or demonstrating
a verifier, supported algorithm, safe key storage, or key rotation/revocation
mechanism. The report itself calls this an unresolved platform assumption.
Under the user's explicit rule, this is a blocker requiring another design
before a local implementation-testing authorization decision.

Other material gaps remain:

1. The authoritative audit wrapper is required to compare a decision's
   reviewer with the verified assertion actor, but the wrapper takes only a
   decision ID and no actor/assertion context is specified for that
   comparison.
2. The worker expansion phase normalizes new rows while retaining a
   pending-only unique index. A terminal pair does not conflict with that
   index, so a new pending row for an already accepted/rejected pair can be
   inserted before the later worker pause.
3. The request ledger does not define a deterministic target-based lookup
   result when multiple requests for the same actor/operation/target exist;
   the same actor/request key locking encoding also remains unspecified.
4. The application matrix misses a second import-worker path and operational
   scheduler/audit callers, and several “required permissions” are
   descriptions rather than an executable ACL/caller closure.
5. The RLS matrix and privilege list still leave exact helper signatures,
   decision-table column grants, effective role memberships, and some
   `WITH CHECK` invariants to implementation-time choices.

The recommendation is **not** to start implementation. The next permissible
work is a further design amendment that resolves the blockers and, if
necessary, a bounded platform-capability research/design step that uses no
database or hosted access. Any later disposable-local testing requires a
separate explicit authorization. This review does not authorize implementation,
database access, staging, hosted access, or production changes.

## 2. Scope, evidence, and baseline

Reviewed the [Stage 1K amendment](./PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md),
[Stage 1J review](./PHASE-2A-3-4-STAGE-1J-INDEPENDENT-REVIEW.md),
[Stage 1I amendment](./PHASE-2A-3-4-STAGE-1I-DESIGN-AMENDMENT.md),
and prior Stage 1A–1H reports where relevant. Inspected the current-worktree
[reconciliation schema/policies/audit helper](../supabase/migrations/20261029000001_reconciliation_module.sql),
[membership helpers](../supabase/migrations/20260514000007_helper_functions.sql),
[worker RPCs and grants](../supabase/migrations/20261031000001_worker_and_audit_security.sql),
[audit hardening](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql),
[lease recovery and finish functions](../supabase/migrations/20261101000004_recover_missing_worker_leases.sql),
[cron/retention operations](../supabase/migrations/20261030000002_reconciliation_security_ops.sql),
[Next.js reconciliation actions](../examples/nextjs/lib/actions/reconciliation.ts),
[cookie-backed Supabase client](../examples/nextjs/lib/supabase/server.ts),
[entity list](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx),
[entity export page](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx),
[Python matching worker](../services/reconciliation/matching/splink_worker.py),
[Python import worker](../services/reconciliation/imports/worker.py),
[Python import loader](../services/reconciliation/imports/loader.py),
[invitation Edge Function](../supabase/functions/invitations/index.ts), and
[import-download Edge Function](../supabase/functions/import-download-url/index.ts).

Evidence labels:

- **Repository-verified:** read in current-worktree source. Several sources
  are pre-existing untracked/modified files; this does not prove deployment
  or Git provenance.
- **Prior local observation:** recorded in Stage 1A/1B; not freshly queried
  for Stage 1L and not evidence of hosted state.
- **Proposed design:** Stage 1K proposal, not implemented SQL or runtime
  behavior.
- **Platform assumption:** needs explicit verification against the actual
  Supabase/PostgREST deployment.
- **Owner/legal decision:** requires product, security, or legal approval.
- **Not verified:** no execution or live catalog/config inspection occurred.

**Baseline worktree:** before writing this report, `git status
--short --untracked-files=all` showed numerous pre-existing modified and
untracked files. The status was captured in the tool output; no baseline file
was created or altered. After writing, the only expected status delta is this
new Stage 1L report. The pre-existing LF-to-CRLF warning for
`examples/nextjs/app/auth/signup/page.tsx` is unrelated.

## 3. J1–J6 comparison

| Stage 1J finding | Stage 1K correction | Independent classification |
|---|---|---|
| **J1 — Gateway identity not isolated** | §5 compares dedicated principal, shared `service_role`, and signed assertion; recommends signed assertion with isolated signer. | **Partially addressed.** The trust model is clearer, but the cryptographic verifier and key lifecycle are not selected or shown feasible. Under the required standard, this remains a blocking design gap, not an implementation detail. |
| **J2 — Context/RLS not executable** | §6 gives role attributes, context helpers, policy matrix, and minimum grants. | **Partially addressed.** The proposal is substantially more concrete, but still does not specify complete helper signatures/SQL, full typed-decision column privileges, all restrictive/effective policy interactions, or the actor context needed by audit. RLS proof remains absent. |
| **J3 — Audit wrapper validation incomplete** | §7 reserves actions, specifies decision-ID wrapper, typed-field checks, correlation index/FK, and deferred constraint trigger. | **Partially addressed.** Wrapper's reviewer-versus-assertion check has no specified assertion context; exact reserved enum labels and full overload/caller behavior are not closed. Deferred trigger is proposed but its design/retention interaction is not validated. |
| **J4 — Worker expand/contract incomplete** | §8 normalizes in database, pauses worker for all-status unique index and function switch. | **Incorrectly addressed in the proposed sequence.** The new normalized RPC is installed before the pause while the pending-only index remains; it can insert a pending row for a pair that has only a terminal row. The intended permanent-terminal invariant is therefore violated during expansion. |
| **J5 — Key loss prevents replay** | §9 selects server-side ledger plus actor-authorized target lookup. | **Partially addressed.** Actor/request uniqueness prevents cross-actor key collision if actually constrained, but target lookup is ambiguous for multiple requests for the same target and lock encoding remains unspecified. Retention and membership-revocation behavior are owner-gated. |
| **J6 — App writer inventory incomplete** | §10 lists app and worker paths with scope and tests. | **Partially addressed.** Most major actions appear, but `services/reconciliation/imports/loader.py` also writes through the import RPC, and cron/operational audit calls are not fully assigned to concrete principals. Exact operational ACLs and all readers/writers are not closed. |

These are assessments of design text only. No finding is runtime verified.

## 4. New findings

### L1 — High: signed-assertion verification remains an unresolved prerequisite

**Evidence:** Stage 1K §5.2 says the exact signature algorithm, PostgreSQL
verifier/extension, key storage, rotation, and revocation are unverified and
requires stopping if no supported verifier is proved
([Stage 1K §5.2](./PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L212)).
The repository server client uses the anon key and has no signer or
service-only workflow client
([server client](../examples/nextjs/lib/supabase/server.ts#L11)).
No current repository source defines the proposed verifier or assertion
protocol.

**Technical impact:** the selected gateway relies on the database to
authenticate the human actor despite PostgREST seeing a service principal.
Without an actual verifier and key lifecycle, the database can only trust an
unsigned actor argument or a shared service credential. That reintroduces
J1: another service-role holder, worker, scheduler, or Edge Function could
assert a different reviewer. Merely specifying claim names and rejecting
algorithm confusion does not implement signature verification.

**Required correction:** before any implementation-test authorization,
select a verifier supported by the exact target PostgreSQL/Supabase
environment, supported algorithm and encoding, key location, key rotation
and revocation protocol, `kid` semantics, and failure behavior. Demonstrate
feasibility from authoritative platform documentation or a separately
authorized disposable capability test. If support is not demonstrated,
require a different architecture; do not use unsigned assertions or assume
a custom PostgREST role/JWT arrangement.

**Blocks next authorization review:** Yes.

### L2 — High: audit wrapper cannot currently prove reviewer equals verified actor

**Evidence:** Stage 1K says
`write_reconciliation_decision_audit(_decision_id uuid)` accepts only a
decision ID, then must verify that the decision reviewer equals the actor
from the verified assertion held by the workflow transaction
([Stage 1K §7.2](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L486)).
The proposed tenant-context protocol defines only a company GUC, not a
verified actor context
([Stage 1K §6.2](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L288)).

**Technical impact:** the wrapper has no specified source for the “verified
assertion actor.” Comparing only the typed decision reviewer to a field
written by the same executor function proves internal consistency, not an
independent binding to the validated token. A future executor function could
insert a decision with an arbitrary reviewer and call the wrapper unless the
whole executor function set is trusted and audited as the sole assertion
verifier. The specification simultaneously requires wrapper-level actor
validation and omits the mechanism to perform it.

**Required correction:** define a transaction-local, non-client-controlled
verified actor context set only after signature verification, or pass a
verified assertion to a trusted verifier inside the audit wrapper. Specify
exact setter/getter signatures, owner, ACL, clearing, and binding to target,
operation, and request key. The wrapper must compare that verified actor to
the decision reviewer and reject mismatches. Do not rely on a caller-settable
GUC as identity evidence.

**Blocks next authorization review:** Yes.

### L3 — High: normalized-worker expansion can regenerate terminal pairs

**Evidence:** Stage 1K §8 step 2 installs DB-side normalization while
retaining the existing partial `WHERE status = 'pending'` uniqueness; worker
pause is step 5
([Stage 1K §8.2](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L568)).
The repository's current unique index is pending-only
([schema](../supabase/migrations/20261029000001_reconciliation_module.sql#L305)),
and the worker RPC uses the matching partial conflict target
([worker RPC](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L199)).

**Failure scenario:** after step 2 but before step 5, an old-directional
worker submits a pair whose existing candidate is accepted or rejected.
The new function normalizes it, inserts a new pending row, and the partial
index does not conflict with the terminal row. A concurrent worker can do
the same. The subsequent duplicate preflight in step 4 is not an enforcement
mechanism and can race with continued writes. This violates permanent pair
identity before the documented pause.

**Required correction:** either pause/drain before installing any
normalization/function change that can create canonical pending rows, then
normalize/backfill, resolve duplicates, add/validate all-status uniqueness,
switch conflict inference, and resume; or add and test a concurrency-safe
intermediate write guard that suppresses inserts when any canonical terminal
row exists. A non-atomic “SELECT terminal then INSERT” is insufficient without
serialization/constraint protection. State how interrupted deployment
resumes without enabling the old behavior.

**Blocks next authorization review:** Yes.

### L4 — Medium: request lookup is not uniquely defined after multiple same-target requests

**Evidence:** Stage 1K §9 specifies unique `(actor_id, request_id)` and
lookup by actor plus operation/target after browser-key loss, but does not
define a unique target-operation outcome key or deterministic selection among
multiple requests
([Stage 1K §9.2](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L647)).
It also describes a versioned actor/request advisory lock but provides no
exact encoding/test vectors.

**Failure scenario:** one actor may submit distinct UUID request IDs for the
same target and operation (for example after a second click or a lost local
cache). The ledger can contain multiple outcomes, including an earlier
expected conflict and a later terminal decision. A target-only lookup can
return an arbitrary/stale row unless ordering, cardinality, and result
selection are specified. The client cannot reliably recover the exact
original outcome cross-device.

**Required correction:** define the lookup identity and deterministic
behavior. Options include a unique one-decision-per-actor/tenant/target/
operation invariant where product semantics permit, or return an ordered,
bounded list with an explicit “authoritative terminal decision” selection
rule. Define tie-breaking and what happens after re-review generation.
Specify advisory-lock serialization bytes/algorithm and test vectors, or
remove the advisory lock and rely on a proven database uniqueness/row-lock
protocol. Document what happens after ledger expiry while terminal decisions
remain.

**Blocks next authorization review:** Yes for the promised exact recovery
guarantee; otherwise an owner may explicitly narrow that guarantee.

### L5 — Medium: application/operational caller inventory is not yet complete

**Evidence:** Stage 1K §10 calls the matrix complete
([Stage 1K §10](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L707)).
The repository has both [import worker](../services/reconciliation/imports/worker.py#L66)
and [import loader](../services/reconciliation/imports/loader.py#L115)
calling `reconciliation_import_insert_record`. Database sources also include
cron-scheduled `log_reconciliation_audit` calls
([operations migration](../supabase/migrations/20261030000002_reconciliation_security_ops.sql#L170)),
and worker/lease finish functions that write operational audit events
([worker migration](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L232),
[lease recovery](../supabase/migrations/20261101000004_recover_missing_worker_leases.sql#L59)).
Invitation Edge Functions call generic `log_audit`
([invitation function](../supabase/functions/invitations/index.ts#L207)).

**Technical impact:** if generic wrapper EXECUTE is tightened or worker
privileges are changed without mapping every SQL/cron and Python caller,
imports, run finalization, scheduled audit events, or operational recovery
can fail. Conversely, preserving service-role access too broadly may leave
decision-table bypasses. Stage 1K says exact principal assignments and full
deployed caller inventory remain a gate but does not identify all current
repository paths in its matrix.

**Required correction:** amend the matrix to include both import-worker
implementations, scheduler/cron job identity and function ownership,
lease-recovery SQL, worker audit wrappers, all direct audit callers and
trigger paths. Distinguish database function owner from invoker role for
SECURITY DEFINER calls. Produce an exact table/column/function ACL diff for
each role before any future cutover; keep broad revocation prohibited until
every caller is accounted for.

**Blocks next authorization review:** Yes for ACL changes and audit-wrapper
changes.

### L6 — Medium: RLS and executor privilege closure still rely on unspecified details

**Evidence:** Stage 1K §6.4 provides a table matrix and sample candidate
policies, but some policy cells remain `context` placeholders and the
remaining policies are described as literal interpretations rather than
specified SQL
([Stage 1K §6.4](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L380)).
§6.5 leaves the final typed decision SELECT/INSERT columns to be determined
later ([Stage 1K §6.5](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L416)).
The current source schema has client policies on these tables
([RLS policies](../supabase/migrations/20261029000001_reconciliation_module.sql#L478)).

**Technical impact:** the design does not yet fix exact effective privileges
for every command and function. It also names trusted discovery/lock helpers
without exact signatures, arguments, result shapes, lock clauses, or
authorization predicates. A privileged helper owner explicitly bypasses RLS;
an omitted tenant predicate or an unreviewed SECURITY DEFINER wrapper would
therefore cross the tenant boundary. The executor policy equality is only
safe if context cannot be set by any externally reachable executor function
before authorization.

**Required correction:** give exact helper signatures and SQL invariants for
discovery, membership lock, source/entity lock, and audit; enumerate every
executor-owned SECURITY DEFINER function and prove no external role can
assume executor. Replace `context` placeholders with exact expressions for
each table/command; enumerate complete typed decision column ACLs; specify
existing policy removal/interaction and exact function/default grants. Include
the invariant that row-lock helpers return no cross-tenant facts and lock only
after membership. Keep source UPDATE ungranted.

**Blocks next authorization review:** Yes.

### L7 — Low: tests do not completely specify migration interruption and retention recovery

**Evidence:** Stage 1K §12 includes migration interruption and retention
tests, but does not state expected ledger recovery after retention expiry,
the exact resume state at each worker migration checkpoint, or cron owner
expectations ([Stage 1K §12](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L832)).
Prior local Stage 1B explicitly separates local migration history from Git
provenance and says no hosted project was selected
([Stage 1B §1](./PHASE-2A-3-4-STAGE-1B-READINESS-REPORT.md#L10)).

**Required correction:** enumerate failpoints after each standalone
concurrent-index command, function switch, old-index removal, and worker
resume; specify the safe state and operator decision at each. Test ledger
retention/cleanup against immutable decisions and audit FKs. Record cron
execution identity and verify required nonreserved audit operations still
work. Migration 06 and hosted-project boundary are correctly preserved and
must remain unchanged.

**Blocks next authorization review:** No by itself; fold into the next test
plan.

## 5. Gateway identity and signed assertion assessment

### 5.1 What is technically coherent

**Repository-verified:** a Next.js Server Action can obtain the cookie-backed
client, call `auth.getUser()`, and use the returned verified user UUID as
application input. The current action architecture uses the anon key and
user session; no server-role gateway is implemented.

**Proposed design:** an isolated gateway revalidates the access token, signs
an assertion restricted to issuer, audience, key ID, actor, exact operation,
target, request key, issued-at, and expiry. The database derives tenant from
the target and checks current membership rather than trusting a tenant claim.
This is a defensible trust pattern only when signature verification and key
isolation actually exist.

### 5.2 Blocking unknowns and impersonation paths

**Platform assumptions not demonstrated:** no specific PostgreSQL extension,
built-in verifier, trusted extension schema, supported algorithm, claim
canonicalization, key table ACL, rotation/revocation protocol, or Supabase
hosted support is identified. No dedicated PostgREST role/JWT mechanism is
verified. The repository has shared service-role Edge Function callers, so
service-role itself cannot identify the intended gateway.

Until a verifier is selected, any call path accepting `reviewer_assertion`
as plain input can be abused by any holder of the RPC transport credential.
A stolen service key is an additional risk; with mandatory signature
verification it still cannot mint a new actor assertion unless the signer key
is also compromised, but it can replay a valid assertion until expiry. The
ledger must make such replay idempotent and reject a changed binding.

**Exact blocker:** Stage 1K's own §5.2 stop condition is unmet. Require a
documented supported verifier or a different identity architecture before
authorization. No actual cryptographic implementation can be inferred from
the repository.

## 6. Tenant context, RLS, and function security

### 6.1 Context setter/getter

Stage 1K correctly recognizes custom GUC values can be caller-forged and
proposes clearing context at every external RPC, then setting it only after
assertion and membership validation
([Stage 1K §6.2](../docs/PHASE-2A-3-4-STAGE-1K-CORRECTED-DESIGN-AMENDMENT.md#L288)).
The illustrative setter's `current_user` check is consistent with being
called inside a SECURITY DEFINER function owned by executor; as a direct
gateway invocation it should see the gateway role and fail. This is a
**proposed PostgreSQL behavior**, not a runtime test.

Residual issue: only company context is defined. The audit wrapper also needs
verified actor context (L2). Stale values supplied by the gateway must be
cleared before helper queries, not just overwritten later. Every function
owned by executor, including future overloads and helper wrappers, must be
reviewed for arbitrary setter use. Role membership closure must prove no
authenticated, service-role, worker, scheduler, or unrelated function can
`SET ROLE` to executor.

### 6.2 Forced RLS and privileged helpers

**Proposed:** executor is not table owner and has no `BYPASSRLS`, so FORCE
RLS should apply. Trusted `postgres`/privileged lock helpers bypass RLS by
design and must enforce explicit actor/company predicates themselves. That
can be safe only if helper bodies are narrow, fixed-search-path, and
non-callable except through executor.

**Unverified:** actual owner role attributes, ownership-transfer capability,
RLS-effective role, role memberships, `public` schema CREATE grants, and
platform policy behavior. Stage 1K has not supplied complete helper
definitions nor all concrete policy SQL.

### 6.3 Privilege closure

Stage 1K is right to distinguish RLS from table ACLs and to deny source
UPDATE for row locking. However, the candidate/decision table ACL is not yet
finalized: §6.5 expressly defers typed decision SELECT/INSERT columns.
Foreign-key checks, UUID defaults, enum USAGE, schema USAGE, helper EXECUTE,
existing policy removal, public defaults, and inherited grants all need
catalog-backed verification in a disposable environment. No privileges were
changed or inspected during this review.

## 7. Audit integrity assessment

### 7.1 Overloads, wrappers, triggers, and operational callers

**Repository-verified:** migrations define/redefine six-argument
`log_audit(audit_action, uuid, uuid, text, text, jsonb)` with defaults and a
five-argument `log_reconciliation_audit` wrapper with defaults. The hardening
migration grants the former to authenticated and service role and revokes
the latter from application/worker roles. Current source includes:

- invitation Edge Function generic audit calls;
- Next.js reconciliation action generic audit calls for accept/reject,
  confirmation, export, and discrepancy;
- membership audit trigger calls to `log_audit`;
- worker finish/claim functions calling `log_reconciliation_audit`;
- cron-scheduled nonreserved audit events and retention cleanup.

The actual deployed overload set, ACLs/default privileges, cron session
identity, and function owner are **unverified**. The report's audit plan
should test callers by actual effective role, not just role name.

### 7.2 Reserved action rejection

The requirement to reject workflow events for all callers including triggers
is sound, but Stage 1K does not name exact enum labels or give exact behavior
for every installed overload. Generic `log_reconciliation_audit` currently
accepts caller-supplied action/company/target/metadata, while the
SECURITY DEFINER worker functions call it internally. Tightening it without
an internal operation path can break worker/cron auditing; retaining it
without reserved-action enforcement allows spoofing.

**Required correction:** enumerate exact signatures, labels, ACLs, caller
identities and function-owner call chains from repository and target catalogs.
Use separate internal fixed-action audit helpers for operational events if
needed. Reject reserved workflow labels in every externally callable generic
path, regardless of `auth.role()` or trigger depth. Ensure triggers cannot
fabricate reserved workflow labels through direct insert or wrapper calls.

### 7.3 Authoritative event and rollback

The decision-ID-only wrapper plus correlation unique index is a reasonable
shape. However, L2's actor-binding gap is unresolved. The deferred constraint
trigger proposal is possible in principle for a deferred AFTER ROW constraint
trigger, but it is not shown as SQL and must be designed to:

- validate the exact typed-decision row and one correlated audit row at
  transaction end;
- avoid recursive audit/decision writes;
- use a safe fixed owner/search path and not leak decision existence;
- remain compatible with FK delete/retention rules; and
- preserve rollback on trigger error.

Unique correlation proves “at most one”; the deferred check is intended to
prove “at least one.” It does not substitute for authorization/actor
verification. Test failures at each write stage and transaction rollback.

## 8. Worker pair migration assessment

**Stage 1K sequence is unsafe as written.** Its step 2 normalizes database
inputs before its step 5 pause. With the old partial unique index, terminal
rows do not conflict with a newly inserted pending candidate. Normalization
can also convert previously distinct opposite-direction pending keys into
one canonical key; the pending partial index will handle a duplicate pending
pair, but not a terminal-plus-pending pair. Step 4's repeat preflight cannot
close the race while writers continue.

The safer specification is to pause/drain before the first canonicalizing
writer change, then deploy/verify the canonical writer while paused, perform
historical conflict resolution, create/validate ordered CHECK and all-status
unique index, switch exact nonpartial conflict inference, remove old partial
index, and resume. If maintaining availability is required, the design must
specify a concurrency-safe transitional uniqueness/serialization mechanism
and prove it prevents terminal regeneration. No such mechanism is specified.

Interrupted `CREATE INDEX CONCURRENTLY` recovery and no-replay migration
history principles are appropriate, but the plan needs a precise checkpoint
table stating, at each failure, whether workers remain paused, which function
is installed, which index is valid, and whether a forward fix or rollback is
allowed.

## 9. Idempotency and request ledger

### 9.1 Strengths

Stage 1K improves on browser-only storage by making a server-side ledger the
source of truth, binding a request ID to actor/operation/target, serializing
same-key work, requiring current membership for replay, and keeping
unexpected/transient errors out of success-shaped results.

### 9.2 Remaining correctness conditions

- **Target lookup ambiguity:** no uniqueness or selection rule for multiple
  request IDs on the same actor/operation/target.
- **Lock encoding:** “ordered actor UUID and request UUID bytes with a
  versioned encoding” is not a complete deterministic algorithm or test
  vector. Unique constraints must remain authoritative; advisory locks alone
  do not prove identity.
- **Target discovery/replay order:** Stage 1K says membership check and
  current target resolution occur before/around ledger lookup; a retry after
  target deletion or membership removal may not recover the stored outcome.
  That may be an intentional privacy policy, but it must be explicit and
  consistent with the decision lookup endpoint.
- **Retention:** after ledger expiry, target state and typed decision history
  must still let the lookup find the same authoritative outcome or return a
  defined expired/unavailable result; a new request must never reapply a
  terminal operation.
- **Cross-tenant safety:** actor-scoped unique `(actor_id, request_id)` is a
  good direction, but every lookup must check actor and current membership
  before returning any tenant-bound fields. No live verification was done.

Expected conflicts stored as terminal ledger results require a clear list of
which conflict codes are durable. Transient errors and unexpected SQL/audit
errors must roll back ledger insertion and workflow state. Response-loss tests
must cover committed success, committed expected conflict, and rollback
before commit.

## 10. Application writer inventory assessment

### 10.1 Current callers missed or under-specified

The Stage 1K matrix accurately lists major Next.js Server Actions, but the
repository search found additional details:

| Repository path | Observed operation | Review impact |
|---|---|---|
| `services/reconciliation/imports/worker.py` | Calls lease-bound import insert and finish RPCs. | Listed generally as source ingestion. |
| `services/reconciliation/imports/loader.py` | Also calls `reconciliation_import_insert_record`. | Separate worker/loader caller must be mapped to actual connection role and retained grants. |
| `supabase/migrations/20261030000002_reconciliation_security_ops.sql` | Schedules cron calls to `log_reconciliation_audit` and defines retention cleanup. | Scheduler/cron identity and owner/invoker call chain are not explicit in the Stage 1K matrix. |
| `supabase/migrations/20261031000001_worker_and_audit_security.sql` | Defines lease claim, finish, and candidate RPCs that write audit events. | Must distinguish worker invoker, SECURITY DEFINER owner, and wrapper EXECUTE needed internally. |
| `supabase/migrations/20261101000004_recover_missing_worker_leases.sql` | Defines claim/finish recovery functions and logs operational events. | Recovery caller and its grants need explicit inventory. |
| `supabase/functions/invitations/index.ts` | Uses user and service clients and writes non-workflow audit events. | Preserve nonreserved behavior while blocking reserved workflow actions. |
| `supabase/functions/import-download-url/index.ts` | Uses service key to read job metadata and generate signed Storage URL. | Preserve exact read/storage capabilities while removing any inappropriate decision DML. |

The search also found UI pages that read source/job/run/candidate/entity/
discrepancy tables. They are not writers, but broad table revocation can break
them; page/read compatibility must be tested separately. The current entity
list and export page do not filter `deleted_at` in their query
([entity list](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx#L30),
[export page](../examples/nextjs/app/dashboard/reconciliation/entities/[id]/export/page.tsx#L28)).
Stage 1K correctly requires both filters, but this is not implemented.

### 10.2 Direct write coverage

Current direct action writes include:

- `acceptMatch`: candidate updates, entity/identifier inserts, generic audit;
- `rejectMatch`: candidate update and generic audit;
- `confirmEntity`: entity status update and generic audit;
- `createDataSource`/`deleteDataSource`: source metadata insert/soft-delete;
- `createImportJob`/`retryImportJob`: import-job insert/retry update;
- `startReconciliationRun`/`retryReconciliationRun`: run insert/retry update;
- `resolveDiscrepancy`: discrepancy update and generic audit;
- `exportEntity`: entity/link/source reads, Storage upload/signing, audit.

Do not treat the §10 list as a complete deployed caller inventory until it
includes the separate loader, scheduler/cron, migration-owned functions,
triggers, and any operational scripts or untracked deployment callers.
Table/column ACLs and exact app roles are not verified here. No permission was
changed.

## 11. Schema, migration, retention, and test-readiness

### 11.1 Schema and lifecycle

The proposed `UNIQUE(source_record_id)` plus composite tenant FKs is
technically coherent if source UUIDs are globally unique and parent
`(company_id,id)` unique keys exist. The current identifier PK
`(entity_id,source_record_id)` alone does not enforce one entity per source
([schema](../supabase/migrations/20261029000001_reconciliation_module.sql#L245)).
Historical duplicate and tenant mismatch preflight and approved remediation
remain required.

Typed decision legacy preservation, nonnull new request keys, candidate pair
uniqueness, audit correlation, and child-side indexes are directionally
specified but exact constraint expressions, all decision column grants, and
data compatibility remain unresolved. Company cascades conflict with
immutable source DELETE trigger behavior; archive is the safe default.
Reviewer erasure and `NOT NULL` with `ON DELETE SET NULL` remain a product/
legal/schema transition decision. Request ledger, decisions, and audit
retention must be coordinated; a correlated audit FK cannot silently cascade.

### 11.2 Migration 06 and hosted state

The prior Stage 1B report records local migration version
`20261101000006` and recovered SQL; it does not prove Git provenance or the
original migration file. Stage 1K correctly prohibits reconstruction or
silent history edits. No migration 06 operation was performed in Stage 1L.
Hosted project identity and state remain unverified; no hosted Supabase
access occurred.

### 11.3 Test-readiness

Stage 1K §12 is broad and properly separates future local, staging, and
production checks. It is not yet sufficient to prove the design because:

- assertion tests cannot pass meaningfully until verifier/key architecture is
  selected;
- no test validates that the audit wrapper compares the decision actor with
  an independently verified actor context;
- worker tests miss the step-2-to-step-5 terminal-pair regeneration window;
- target lookup needs multiple same-target request IDs, retention expiry,
  membership removal, and deterministic response expectations;
- forced-RLS tests need exact helpers/policies/decision column grants first;
- audit tests must exercise cron/scheduler and SECURITY DEFINER owner paths,
  not only role names;
- migration interruption tests need a defined safe checkpoint after every
  function/index/pause/resume transition; and
- app compatibility must include the import loader and every operational
  cron/worker/audit caller.

**Tests executed:** none. **Runtime behavior verified:** none.

## 12. Outstanding decisions and platform prerequisites

1. Select and demonstrate a database-supported signature verifier,
   algorithm, canonical encoding, public-key storage, key rotation/revocation,
   and failure policy; otherwise redesign gateway identity.
2. Decide whether a dedicated PostgREST role is available. If not, explicitly
   accept service-role as a transport principal while keeping signed actor
   verification mandatory and decision-table DML revoked.
3. Approve the signing gateway's isolation, service-to-service auth, CSRF/
   origin policy, key custody, and incident/rotation process.
4. Define the transaction-local verified actor context required by the audit
   wrapper.
5. Approve terminal candidate-pair identity and a worker pause/drain window
   before any canonicalizing write change.
6. Define deterministic target lookup and request key lock algorithm, ledger
   retention, account-switch behavior, membership-removal behavior, and
   request expiry.
7. Approve entity eligibility and soft-delete policy; company archive/purge,
   immutable source retention, reviewer erasure, and audit/decision/ledger
   retention.
8. Verify actual role ownership, schema CREATE, role membership, function
   ownership transfer, PostgREST roles, cron identity, and migration-runner
   behavior in a separately authorized disposable environment.
9. Complete repository and deployment caller inventory before ACL revocation.
10. Resolve migration 06 provenance and intended hosted project only under
    separate owner approval; do not infer either from this review.

## 13. What may proceed next

**Permitted next work:** a further documentation-only amendment resolving
L1–L6 and producing exact gateway-verifier, audit actor-context, worker
pause/rollout, request-lookup, helper, policy, and caller/ACL contracts.
Platform documentation research may identify candidate supported
cryptographic mechanisms, but must not access a hosted project or imply
support until source evidence is cited.

**Not permitted by this review:** implementation, SQL/migration creation or
execution, database access, local or hosted Supabase access, staging,
production changes, destructive testing, role/grant/policy changes, or
dependency/configuration changes. Any disposable-local implementation test
requires a separate explicit authorization after a revised design is
independently reviewed.

## 14. Final recommendation

**NO-GO for a future disposable-local implementation-testing authorization review.**

Stage 1K is directionally useful but not yet sufficiently precise or
internally safe to authorize even disposable implementation testing. The
signed-assertion verifier is not demonstrated; the audit actor binding is
underspecified; the worker expansion has a terminal-pair race; and ledger
lookup/caller/ACL contracts need correction. A new design amendment and
independent review are required before any implementation authorization is
considered.

This conclusion does not authorize Stage 2, database access, staging, hosted
Supabase access, production changes, or destructive operations.

### Validation and change record

- Created exactly `docs/PHASE-2A-3-4-STAGE-1L-INDEPENDENT-REVIEW.md`.
- The baseline contained numerous pre-existing modified and untracked files.
  They were not edited, removed, reset, stashed, or overwritten.
- No tests, SQL, database commands, hosted access, dependency operations, or
  configuration changes were performed.
- Validation passed: 42 local Markdown links and anchors resolve; there are
  no code fences to balance; no trailing whitespace was found; and
  `git diff --check` exited successfully.
- Final `git status --short --untracked-files=all` matches the recorded
  baseline plus this one new Stage 1L document. Git emitted the same
  pre-existing LF-to-CRLF warning for
  `examples/nextjs/app/auth/signup/page.tsx`; that file was not changed.
