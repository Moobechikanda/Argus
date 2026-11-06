# ZamBase — Phase 2A.3.3 Readiness Assessment

> **Read-only technical assessment.** This report describes the repository
> implementation inspected for this assessment and maps it to the proposed
> [Phase 2A.3.2 contract](./ENCRYPTION-CONTRACT.md) and
> [Phase 2A.3.1 architecture assessment](./ENCRYPTION-ARCHITECTURE.md).
> Encryption is not implemented. This is not a production-readiness,
> compliance, or security-certification statement.

## Executive summary

**Recommendation: NO-GO for production encryption rollout, sensitive
decryption, or plaintext retirement. Phase 2A.3.3 is not approved by this
assessment.** The current reconciliation path stores plaintext in PostgreSQL
and private Storage, transfers it to import/matching workers, and returns it
to tenant-member browser sessions. There is no application encryption
implementation, KMS adapter, crypto broker, ciphertext sidecar, or authorized
decryption endpoint.

Several useful boundaries exist and were verified in source: reconciliation
tables use forced RLS, import and matching workers have separate restricted
database roles and scoped RPCs, source rows are immutable, the import bucket
is private, and its download signer checks a live claim and lease. These
controls reduce some access paths; they do not encrypt data or provide
field-level authorization. In particular:

- Authenticated members can read source JSON, canonical JSON, comparison
  details, and discrepancy values through RLS; UI role checks only hide
  buttons, not these reads.
- The matching RPC validates the run lease but returns **all source rows for
  the tenant**, not a run-specific record/field allowlist. Splink currently
  compares exact values and returns a probabilistic score; comparison details
  are empty.
- Import files are uploaded from the browser directly to private Storage as
  plaintext. The importer downloads them to a private temporary file and
  writes plaintext JSON to the database.
- Review acceptance, discrepancy resolution, and export are multi-step
  application flows rather than atomic audited workflows. Reviewer-decision
  rows are not written; discrepancy manual values are not persisted; export
  can fall back to inline CSV.
- The database worker finish RPCs do not independently require an unexpired
  lease, although the import/matching read/write RPCs and worker loop include
  lease checks. A future decrypt endpoint must enforce lease validity
  independently.
- Production KMS configuration, provider identity, key material, crypto
  broker, and encryption/decryption code were not found. The legacy pgsodium
  prototype is contained and must remain unused.

The revised contract is a proposal, not an approved cryptographic profile.
Product-owner/security-owner approval and unresolved institutional/legal,
provider, access-role, upload-boundary, normalization, capacity, and recovery
decisions remain gates. No application, migration, configuration, dependency,
key, or data changes were made for this assessment.

## 1. Scope and evidence

Inspected the contract and architecture assessment; reconciliation schema,
RLS, triggers, worker RPCs, worker role grants, import Storage policies,
legacy-key containment and audit migrations; Python import and matching
workers/tests; Next.js reconciliation actions and pages; the import download
Edge Function; and Docker Compose worker restrictions.

The assessment distinguishes:

- **Current behavior:** directly observed in repository implementation.
- **Proposed integration:** target behavior from the contract, not implemented.
- **Status:** one of the six readiness classifications in section 5.

References below link to implementation files and symbols. SQL line citations
refer to the tracked migrations listed in each finding. A deployment's live
Supabase policies, grants, bucket configuration, Edge secrets, and worker
credentials were not queried; claims about effective production deployment
remain subject to environment verification.

## 2. Plaintext data-flow inventory

| Path | Current implementation and sensitive data | Current authorization boundary | Plaintext location and lifetime |
|---|---|---|---|
| Data-source configuration | `createDataSource` writes arbitrary `connection_config` JSON. The data-source page selects and renders the entire JSON object. The schema comment explicitly allows credentials. See [`reconciliation.ts`](../examples/nextjs/lib/actions/reconciliation.ts#L47), [`data-sources/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/data-sources/page.tsx#L23), and `reconciliation_data_sources` in [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L142). | RLS SELECT is for any tenant member; inserts are also available at the `member` role threshold, despite the UI form being hidden from non-admin/owner roles. | Persistent plaintext JSON in PostgreSQL; server and browser response/DOM. If credentials are put there, they are exposed to each tenant member allowed to view the page. |
| Browser upload | `ImportUploadForm.submit` accepts CSV/JSON/JSONL up to 50 MiB, generates a tenant/source object reference, and uploads the original `File` directly to `reconciliation-imports`. See [`upload-form.tsx`](../examples/nextjs/app/dashboard/reconciliation/imports/upload-form.tsx#L10). | Private bucket; tracked policy grants authenticated INSERT only when path tenant/source match and caller has admin role. No tracked SELECT/UPDATE/DELETE bucket policy. See [`20261101000001_private_import_storage.sql`](../supabase/migrations/20261101000001_private_import_storage.sql#L1). | Plaintext exists in the browser, in transit protected by transport, and persists as a private Storage object. Bucket privacy is not application-layer encryption. Failed job creation may leave an orphaned uploaded object. |
| Import job creation | `createImportJob` validates active tenant, membership role, object path and source, then inserts job metadata and `file_ref`. See [`createImportJob`](../examples/nextjs/lib/actions/reconciliation.ts#L12). | Authenticated user JWT/RLS plus Server Action owner/admin check; the table's INSERT RLS policy allows the `member` role threshold. | Job metadata and a plaintext Storage object reference persist in PostgreSQL; no key/envelope metadata. |
| Import download authorization | `import-download-url` uses a service-role client to load the job, validates the random bearer claim, running status, unexpired lease, fixed tenant/source/object path, then returns a 60-second signed path. See [`index.ts`](../supabase/functions/import-download-url/index.ts#L1). | Edge Function has a service-role secret; endpoint JWT verification is disabled in config, so its live claim-token check is the authorization capability. This is a meaningful narrow boundary, but issuance is not a data-decryption audit event. | Signed URL exists briefly in worker/network memory; source object remains plaintext in Storage. |
| Import worker download and parsing | `process_claim` obtains the signed download, `download_from_storage` validates tenant/source/object path and streams to a mode-0600 file, enforces 50 MiB, parses CSV/JSON/JSONL, caps at 1,000,000 rows, computes SHA-256, and passes each row as both raw and normalized JSON. See [`worker.py`](../services/reconciliation/imports/worker.py#L90) and [`process_claim`](../services/reconciliation/imports/worker.py#L149). | Dedicated `reconciliation_import_worker` DB login plus claim/lease RPCs; worker also requires the anon API key, rejects a service-role key, and has no KMS integration. Docker gives it a 64 MiB tmpfs, read-only root filesystem, dropped capabilities, and non-root UID. | Plaintext exists in worker memory and on tmpfs until `finally` unlinks the file. Unlink is not a secure-erasure guarantee; crash-abandoned files and non-Compose `TMPDIR` behavior require operational validation. |
| Source-record insertion | `reconciliation_import_insert_record` checks active job claim and unexpired lease, derives `company_id` from the job, then inserts plaintext `raw_data`, `normalized_data`, `source_record_id`, and `row_hash`; duplicate conflict returns false. See [`20261031000001_worker_and_audit_security.sql`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L100). | Worker can execute only its RPC, but the public table also has an authenticated INSERT RLS policy at member threshold. Source rows have tenant-member SELECT RLS and an immutability trigger. | Row values persist in primary PostgreSQL, replicas and applicable backups/logging layers; worker request and database buffers temporarily contain plaintext. |
| Source ID and duplicate fingerprint | Active worker chooses `source_record_id`, else `id`, else one-based row number, truncates to 512 characters, and calculates SHA-256 over sorted-key compact JSON UTF-8. Unique scope is `(import_job_id, source_record_id, row_hash)`. See [`worker.py`](../services/reconciliation/imports/worker.py#L161) and [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L192). | Same DB read policy as source records; import details render ID and hash prefix. | Plaintext source ID and deterministic unkeyed hash persist and can reveal equality/guessable values. Same ID+content duplicates are suppressed only within one job; changed content with the same ID and identical data across different jobs have different semantics. |
| Direct source-table reads | `reconciliation_source_records` SELECT RLS permits tenant members to read the entire row, including raw/normalized JSON, source ID and row hash. `review`, `imports/[id]`, and `acceptMatch` issue direct selects. | RLS is forced and tenant-scoped, but is not field- or purpose-level authorization. An authenticated member can query the Supabase API directly without using the UI's admin/owner action gates. | Plaintext returns to the server action/page process; selected fields may be serialized into server-rendered output or directly rendered. |
| Matching retrieval | `reconciliation_matching_source_records(run_id, claim_token)` checks a live run lease, derives company from the run, then selects every source row for that company, returning `id`, `source_record_id`, raw and normalized JSON. See [`20261031000001_worker_and_audit_security.sql`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L179). | Matching worker role can call only the matching claim/read/heartbeat/write/finish RPCs. Read is run-claim scoped but not record-set or field scoped. | Full tenant dataset exists in Postgres/network buffers and worker process memory. |
| Matching computation | `load_source_records_df` builds a pandas DataFrame, flattens `raw_data`, and drops unsafe source column names. Splink creates exact-equality comparison levels and exact-only blocking rules; when no blocking rule exists, it uses `1 = 1`. It computes a probability threshold of 0.85 and writes an empty `{}` comparison detail. See [`splink_worker.py`](../services/reconciliation/matching/splink_worker.py#L63) and [`run_splink_matching`](../services/reconciliation/matching/splink_worker.py#L96). | Matching worker login and run lease/heartbeat. Docker restrictions apply; no encryption or KMS boundary is present. | Plaintext fields are in Python/pandas and Splink/DuckDB runtime memory for the run. No verified memory wipe or validated maximum run size exists. Exact comparisons are not fuzzy edit-distance comparisons; the scoring/model is probabilistic. |
| Candidate persistence | `reconciliation_matching_write_candidates` validates live run lease and verifies each source row belongs to the derived tenant, then writes score and details to `reconciliation_match_candidates`. See [`20261031000001_worker_and_audit_security.sql`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L199). | Matching worker RPC enforces lease and tenant membership for joined source rows. Table RLS SELECT is tenant-member; authenticated INSERT/UPDATE policies are also broader than the UI reviewer action. | Candidate IDs, scores, status and comparison JSON persist; current worker sends `{}` for details. Candidate metadata can still reveal identity linkage and match inference. |
| Review display | Review page selects candidate rows joined to source IDs/raw JSON and comparison details, then renders those values in a server-rendered page. See [`review/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/review/page.tsx#L12). | `getUser` and active-company lookup protect the route. `canReview` gates action buttons only. Direct table SELECT RLS allows tenant members to read records; `viewer` and `member` can still see the values. | Values are fetched server-side and rendered into browser response, DOM and browser memory. |
| Match acceptance / rejection | `acceptMatch` checks owner/admin in application code, reads candidate/source rows, updates candidate status, creates/updates entity and identifier links, sets entity ID, then calls `log_audit`. `rejectMatch` updates status then audits. See [`acceptMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L159) and [`rejectMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L299). | User JWT/RLS plus Server Action role check; candidate UPDATE policy itself allows the member role threshold. Calls are separate requests, and several write/audit results are not checked. | Source values read into Next.js memory; canonical values persisted plaintext. No reviewer-decision row is written. Failures can leave partially applied updates and missing audit. |
| Canonical entity viewing/confirmation | `entities/page.tsx` selects and renders `canonical_data` for all visible tenant entities. `confirmEntity` updates status then separately calls `log_audit`. See [`entities/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/entities/page.tsx#L12) and [`confirmEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L354). | Tenant-member SELECT RLS exposes canonical values; owner/admin check gates confirmation only. | Canonical values persist plaintext in JSONB and are returned to browser. |
| Discrepancy creation and display | Schema stores plaintext `field_name`, `competing_value`, and source reference. The page reads and displays unresolved discrepancies and related canonical values. No active discrepancy creation writer was found. See [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L315) and [`discrepancies/page.tsx`](../examples/nextjs/app/dashboard/reconciliation/discrepancies/page.tsx#L12). | RLS SELECT is tenant-member; action buttons are gated to admin/owner. | Existing conflicting values persist in DB and are fetched/rendered for tenant members. |
| Discrepancy resolution | `resolveDiscrepancy` loads unresolved discrepancy, accepts a winner source ID or manual value, updates only resolution/reviewer/time, then calls audit. The submitted manual value is not saved to canonical state, and winner source ID is not verified/persisted as the selected value. See [`resolveDiscrepancy`](../examples/nextjs/lib/actions/reconciliation.ts#L592). | User JWT/RLS plus app owner/admin check. Update and audit are separate requests; errors from the audit RPC are ignored. | Manual value exists transiently in browser request and Server Action memory; competing values remain plaintext. UI can report success without a canonical correction. |
| Export | `exportEntity` allows owner/admin/member, reads canonical JSON and linked raw source JSON, constructs a CSV in server memory, uploads to `reconciliation-exports` and tries a one-hour signed URL; errors fall back to inline CSV. See [`exportEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L406). | Server Action user JWT/RLS and member-role check; no field allowlist, row/size bound, export-specific audit-before-release, or verified bucket lifecycle. No tracked migration creates the export bucket. | Full source and canonical values in server memory, Storage if configured, signed URL or browser inline data URL. Export can be copied beyond app control. |
| Audit and operational logs | Import/matching claims and finishes write operational audit rows; Server Actions log IDs, score, reviewer, counts and delivery metadata. No read/decrypt audit events exist. Workers log run IDs/counts/error classes; import path stores exception class, not exception text. The separate loader helper can place source IDs and exception text in returned `row_errors`, but is not the active worker entry point. | `audit_log` RLS permits admin reads; later migration revokes application INSERT/UPDATE/DELETE table privileges. `log_audit` permits authenticated writes for the caller's own tenant. The database audit helper is not field-schema constrained. | Audit JSONB persists. No plaintext values are intentionally present in current action audit payloads inspected, but arbitrary metadata is accepted; audit events can be fabricated by members for their own tenant and are not immutable proof of an action. |

### Current source identity and re-import semantics

The active worker's canonical row encoding is
`json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))`
before SHA-256. With an explicit source ID, repeated identical content in the
same job conflicts on the unique index; changed content with that same ID may
insert as a second immutable row. With no source ID, the fallback is the row
number, so repeated identical rows in different positions do not deduplicate.
The uniqueness key includes `import_job_id`, so cross-job repeat imports are
not deduplicated by this index. The inactive [`loader.py`](../services/reconciliation/imports/loader.py#L22)
uses a different JSON serialization call and fallback source-ID behavior; it
must not be treated as equivalent to the active worker.

The contract's proposed HMAC fingerprint must therefore be an additive,
versioned sidecar transition. Replacing the SHA hash or source ID in place
would break the immutable-row model and re-import semantics. Retain historical
row UUIDs and hashes; validate canonicalization and dual-version lookup before
switching active writers.

## 3. Proposed encryption integration map

The following is a target architecture mapped to the contract, not existing
functionality. The precise ingress/broker deployment is still unresolved.

| Operation | Encryption/decryption placement and DEK holder | KMS and authorization | Audit requirement and outage behavior |
|---|---|---|---|
| File upload and durable Storage | Per contract §3.2, a trusted server-side ingress encrypts the complete file before Storage receives it. Browser never gets a DEK. The crypto broker/ingress creates and wraps a dedicated file DEK; Storage stores ciphertext only. The present browser-direct upload must be replaced. | KMS Generate/wrap operation (provider-specific mapping remains to select); authenticate user, derive tenant/source from membership, enforce one-time object path, file type and 50 MiB bound. | Record a sanitized file-encryption/upload outcome. Fail closed if KMS or required audit commit fails; do not write plaintext to Storage or fall back to local keys. |
| File retrieval for import | Broker performs authenticated file decryption, verifies the full GCM tag before exposing bytes to parser. Importer may receive plaintext file/records but should not receive DEK or KMS credentials. Temporary plaintext remains private and bounded and is deleted on error/cleanup. | KMS unwrap only after verifying claimed job, tenant, file object, `import_file` purpose and live lease. Exact placement and transport from broker to parser must be settled. | Commit authorized attempt audit before KMS; record success before plaintext is made available under contract §3.6. KMS/audit/tag failure stops import, deletes partial files and returns a generic failure. |
| Row parse and source payload writes | Import worker necessarily sees parsed plaintext unless parsing is moved into broker. Preferred design: broker performs payload AEAD and wrapping; worker passes only authorized row fields to broker and receives ciphertext/envelope metadata. DEK remains inside broker. Sidecar writes are additive; immutable plaintext columns are retained only for approved transition and later retired separately. | KMS Generate/Wrap per bounded row-payload scope; import identity, tenant/source/job derived from live claim; approved field schema; nonce/budget reservation shared atomically across retries/workers. HMAC row fingerprint, if approved, uses a separate key/purpose. | Audit sensitive-write outcome with opaque IDs/counts only. If KMS, budget reservation, or required audit fails, abort row/job and do not write success-shaped plaintext fallback. Existing insert RPC writes plaintext and is not suitable post-cutover. |
| Controlled backfill | Dedicated backfill service reads only enumerated immutable source IDs/fields, encrypts into sidecars, and never updates source rows. DEK remains in broker; backfill process sees values only within approved operation. | KMS Generate/Wrap and verification Unwrap; locked migration task/tenant, field allowlist, batch lease, actor and purpose `backfill`. | Audit attempt/result with counts and opaque scope IDs. Fail closed and leave scope incomplete on KMS/audit/auth failure; no source mutation or cutover. |
| Exact matching | Normalize only approved identifiers; broker/token service computes tenant/purpose HMAC tokens with distinct key and profile versions. Avoid decrypting those fields when token equality suffices. | KMS/token-key access only through broker; tenant, identifier type, profile, purpose, exact run set and live lease. No token oracle or browser token access. | Audit token generation/use without token or identifier. KMS failure stops matching; no unkeyed-hash fallback. |
| Fuzzy/probabilistic matching | Where value similarity is needed, broker decrypts only explicitly allowlisted fields for the run. Prefer broker-performed AEAD; if matching worker-side decryption is indispensable, the current contract permits only a short-lived claim-bound handoff for a DEK whose entire ciphertext scope is no broader than the run. Worker sees plaintext and the scope DEK, a documented residual exposure. | KMS unwrap only after active run claim/lease, derived tenant, record set, field allowlist and fixed purpose `matching`; recheck lease before each batch and candidate write. Workers never get general KMS credentials or arbitrary decrypt capability. | Attempt audit before KMS and successful read audit before plaintext use/release. Lease loss stops new decryptions and writes, discards outputs; KMS/audit failure aborts run. Current RPC's all-tenant fetch must be narrowed. |
| Candidate explanation | Store only value-free comparison codes/levels/scores required for review. Encrypt any value-bearing evidence separately; do not serialize raw values into `comparison_details`. | Matching identity/run scope may write through fixed RPC after validating both source records and lease. Review readers need separate role/purpose authorization. | Audit candidate writes with counts/opaque IDs, not compared values. Do not expose details before schema/redaction tests. |
| Review and entity viewing | Broker decrypts only requested projection for one candidate/entity and selected review purpose. It performs AEAD; no DEK is returned to browser or ordinary Server Action. | Verify user identity, tenant membership plus approved reviewer role, exact candidate/entity/source relationship, field allowlist, object status and purpose. Member/viewer deny sensitive plaintext by default. | `decrypt_attempt_authorized` before KMS; distinct successful sensitive-read event after authenticated decryption and reauthorization but before returning plaintext. Audit failure withholds plaintext. KMS/tag/AAD failures produce generic error and no plaintext. |
| Accept/reject match | Broker returns only fields needed for adjudication. The workflow service then commits candidate status, entity creation/linkage, reviewer-decision record, and audit as one database transaction/RPC. | Authenticated reviewer and tenant; pending candidate; both source rows tenant-consistent; role and field/purpose allowlists; audit required. Avoid stale status races. | Required audit/decision commit failure rolls back the workflow and no success is reported. KMS unavailable means no review plaintext and no acceptance that depends on it. |
| Discrepancy resolution | Broker decrypts only the competing value and, if selected, authorized source value. Correction is written to canonical encrypted state; immutable source remains unchanged. | Reviewer, tenant/entity/discrepancy/source relationship, exact field, typed value schema, unresolved status, and one atomic resolution operation. | Audit attempt/release before value presentation; correction/decision/audit commit atomically. KMS or audit unavailable means no correction and no success. |
| Export | Broker performs the decryption and emits only approved fields in a bounded export. Prefer controlled private export artifact plus expiration/cleanup and authenticated signed retrieval; prohibit unrestricted inline fallback. | Actor and tenant, explicit field allowlist and role, entity relationship, export purpose, max size/rows, destination policy and expiry. | Audit before plaintext release and record export outcome/delivery. KMS/audit/storage failure fails closed; no inline plaintext fallback. |
| Operational secrets | `connection_config` should contain only approved non-secret references; credentials belong in an external secret manager. If unavoidable sensitive config is retained, encrypt and authorize it separately. | Secret-manager identity or purpose-specific envelope; data-source tenant/admin scope. | Audit access without secret values. Secret service outage prevents connection use; do not reveal config to tenant members. |
| Audit and logs | Audit metadata remains value-free and schema-allowlisted. Treat worker, browser, exception, crash, tracing, backup and temporary-file channels as possible plaintext sinks. | Audit actor/service, tenant, opaque object ID, field codes, purpose, operation, key version, request/run and result; never take tenant from user-supplied ID alone. | If required audit cannot commit, no plaintext release. Denials, KMS failures and authenticated decrypt/release are distinct outcomes; expose only generic errors/correlation IDs. |

See contract §§3.2, 3.5–3.6, 5.3, 6–8 for proposed format, limits,
authorization, audit, migration and test requirements. None of these
integrations currently exists.

## 4. Reconciliation workflow gaps

| Area | Current behavior | Required behavior before sensitive feature enablement | Status |
|---|---|---|---|
| Reviewer-decision persistence | `reconciliation_reviewer_decisions` exists with RLS and append-only client policy, but `acceptMatch`, `rejectMatch`, and `resolveDiscrepancy` do not insert decisions. | Persist actor, target, action, time and value-free decision metadata in the same transaction as workflow state and audit. | **Not implemented.** |
| Discrepancy correction | UI offers source winner/manual value. Resolver only updates discrepancy resolution/reviewer/time; manual value is not persisted to canonical entity and source winner is not applied. | Validate field and source relationship; update encrypted canonical state, decision row and audit atomically; preserve source immutability. | **Partially implemented.** |
| Discrepancy creation | Table and UI exist, but no active writer/automatic generation path was found. | Define discrepancy generation, field schema, value minimization, encrypted persistence and ownership of source/canonical references. | **Not implemented / requires further investigation** for any external writer. |
| Comparison details | Matching emits `{}`; comparison metadata schema/table can store JSON. | Define and test complete, value-free comparison evidence with field codes, labels and scores; encrypt any necessary value-bearing evidence. | **Partially implemented.** |
| Match acceptance atomicity | Candidate update, source reads, entity insert, identifier inserts, candidate entity update and audit are separate Supabase requests. Some insert/update errors are ignored; audit result is not checked. | Single trusted transaction/RPC with row locking or equivalent stale-state protection; all entity/link/decision/audit writes succeed or roll back. | **Not implemented.** |
| Export Storage | Action references `reconciliation-exports`; no tracked migration creates the bucket or its tenant policy. Upload exceptions are swallowed; signed URL is optional; full CSV falls back inline. Deployment bucket state was not queried. | Tracked private bucket, fixed tenant/object policy, authorization, expiry, cleanup, size/field bounds, audit-before-release, no inline fallback. Verify live project config. | **Not implemented** in tracked schema; live configuration **requires further investigation**. |
| Export authorization | Owner/admin/member can export all canonical and source JSON; no per-field allowlist or export role decision. | Approved role/field/purpose matrix and secure delivery; reject unauthorized fields even if actor can view metadata. | **Partially implemented** (tenant membership/role check only). |
| Audit completeness | Mutations write generic audit rows, but results are not checked in actions; no sensitive-read/decrypt events; audit metadata is arbitrary JSON. Reviewer-decision table not populated. | Enforce transaction-coupled audit for state changes and pre-release audit protocol for sensitive reads; value-free schemas and differentiated attempt/failure/success events. | **Partially implemented.** |
| End-to-end flow | Imports, matching, review, discrepancies, entities and export pages exist; tests focus on worker boundaries/unit cases; no import-to-review-to-export E2E suite was found. | Synthetic end-to-end coverage across tenant isolation, encryption, retry, lease loss, review, discrepancies, export, logs and cleanup. | **Not implemented / not verified.** |

## 5. Security boundary assessment

### Database RLS, tenant integrity and RPCs

- The reconciliation tables inspected have `ENABLE ROW LEVEL SECURITY` and
  `FORCE ROW LEVEL SECURITY`. Source SELECT is tenant-member scoped; UPDATE
  and DELETE policies are omitted, and `source_records_immutable` rejects
  updates/deletes. Evidence:
  [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L383)
  and its source trigger at line 600.
- Tenant filtering is not field-level authorization: member SELECT permits
  plaintext data retrieval from the client API. `reconciliation_match_candidates`
  UPDATE also uses the member threshold at lines 484–489, broader than
  owner/admin UI decision controls.
- Table foreign keys point to individual IDs and separately to `company_id`;
  there are no composite tenant-consistency constraints tying a candidate,
  entity, identifier, discrepancy, import job, and source row to the same
  company. Worker matching RPC joins candidate rows to the run tenant, but
  direct authenticated writes use table policies that mainly check the
  supplied `company_id`. Use composite FKs or narrow trusted RPC checks before
  treating a row's `company_id` as proof that all referenced objects belong to
  that tenant.
- Worker RPCs use `SECURITY DEFINER`, empty `search_path`, fixed owner and
  explicit grants. Separate login roles are `NOSUPERUSER`, `NOBYPASSRLS`,
  `NOINHERIT`; direct public-schema/table access is revoked. This is a
  meaningful least-privilege boundary, not a KMS or plaintext boundary.
- `reconciliation_matching_source_records` checks a live run claim but
  returns the entire tenant's source rows. Candidate write validates its
  run lease and both source rows' `company_id`; this does not scope retrieval
  to a selected import or record set.
- `reconciliation_finish_import` and `reconciliation_finish_matching_run`
  update based on running status and matching claim token but do not require
  `lease_until > now()` in their update predicates. The claim and most
  read/write/heartbeat RPCs do check lease expiry. Treat terminal RPC expiry
  validation as a defect to resolve before relying on it for decryption
  fencing; do not assume lease behavior from the RPC name.

### Workers and credentials

- Import and matching workers have distinct database logins and narrow
  EXECUTE grants. The worker code rejects a Supabase service-role API key in
  import configuration; Compose passes the anon API key and separate worker
  DB URLs. Matching has only its dedicated DB URL. Compose also sets read-only
  root filesystems, unprivileged user in the image, dropped capabilities,
  no-new-privileges and bounded 64 MiB tmpfs. These controls are **implemented
  and source-verified**.
- Import lease checks occur before insert and during periodic heartbeat;
  signer validates active claim and expiry. Matching worker fails closed on
  heartbeat DB failure, checks `lease_lost` before/after matching and around
  writes; candidate write RPC also checks live lease. Existing unit tests
  cover lost lease and error redaction. These are not sufficient for future
  decryption: decrypt itself must check lease and narrow field/record scope.
- No AWS/GCP/Azure/OpenBao/HSM credentials, KMS adapter, broker, crypto
  library, or current encryption call was found in active application,
  worker, or Edge Function code. Edge signer does use a Supabase service-role
  secret, but only to validate a claimed job and create the short-lived
  Storage URL. This is separate from the workers and does not provide key
  management.

### Storage, browser and exports

- Import Storage is private and the only tracked object policy is tenant/source
  validated authenticated INSERT for admins. Reads are via the claim-bound
  Edge signer; no tracked select/update/delete policy exists. The file remains
  plaintext in Storage. No tracked export bucket/policy was found.
- Browser-facing review, import details, entities, discrepancies and export
  pages retrieve/display sensitive JSON for tenant members. Hiding decision
  buttons from non-admins does not protect the data.
- The export Server Action permits members and returns a one-hour signed URL
  where possible, otherwise inline CSV. The action does not check whether the
  audit RPC succeeded before releasing the file. Storage authorization is
  unverified without a tracked bucket policy and live-project inspection.

### Audit and sensitive channels

- `audit_log` is RLS protected; direct application INSERT/UPDATE/DELETE
  privileges are revoked by
  [`20261101000005_revoke_audit_mutation_grants.sql`](../supabase/migrations/20261101000005_revoke_audit_mutation_grants.sql#L1).
  `log_audit` checks authenticated membership in the supplied tenant, but
  accepts caller-selected action/target/metadata, so a member can add a
  fabricated event for their own tenant. This is append-only at the table
  privilege layer, not a tamper-proof attestation of each application action.
- Sensitive reads are not audited. Several mutation actions await `log_audit`
  but ignore its returned error object. Current audit payloads inspected avoid
  values but may include IDs and scores; JSONB has no strict metadata allowlist.
- Active worker log statements avoid row values and database/parser exception
  text; import failure status records only exception class. `loader.py` is not
  the active importer and has a `row_errors` return structure containing
  source ID and exception text; reassess before reactivating it.
- Temporary-file unlink, private tmpfs, or short signed-URL expiry reduces
  exposure but is not proof of secure erasure or absence from crash dumps,
  memory, traces, snapshots, backups or browser copies.

### Legacy encryption prototype

Migration [`20261030000002_reconciliation_security_ops.sql`](../supabase/migrations/20261030000002_reconciliation_security_ops.sql#L25)
created database-held raw key bytes and pgsodium functions. Later migration
[`20261101000003_contain_encryption_keys_and_audit.sql`](../supabase/migrations/20261101000003_contain_encryption_keys_and_audit.sql#L1)
revokes application access, and
[`20261101000007_revoke_all_legacy_crypto_overloads.sql`](../supabase/migrations/20261101000007_revoke_all_legacy_crypto_overloads.sql)
revokes named overloads. The legacy
[`test_encryption.sql`](../services/reconciliation/tests/test_encryption.sql)
is explicitly marked retired. Do not enable, call, or rely on these objects.

## 6. Readiness matrix

“Implemented and verified” means verified in tracked source, and where
indicated by a relevant test, not independently certified in a deployed
environment. “Implemented but not verified” means source is present but no
adequate execution/deployment evidence was inspected.

| Finding | Status | Evidence and readiness implication |
|---|---|---|
| Source rows retain plaintext JSON and immutable trigger | **Implemented and verified** | Table columns, RLS and trigger in [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L192); source mutation is rejected by trigger at line 600. Blocks direct in-place backfill. |
| Active import parsing, hash and plaintext RPC write | **Implemented and verified** | [`worker.py`](../services/reconciliation/imports/worker.py#L149) and [`reconciliation_import_insert_record`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L100). |
| Import worker path validation, 50 MiB limit, temp file handling | **Implemented and verified** in code; deployment behavior **not verified** | [`test_import_file_security.py`](../services/reconciliation/tests/test_import_file_security.py) contains path, signer and container checks; `worker.py` uses mode-0600 temp file and unlink. No live Storage run was performed for this assessment. |
| Private import bucket and claim-bound signed download | **Implemented and verified** in tracked migrations/code | [`20261101000001_private_import_storage.sql`](../supabase/migrations/20261101000001_private_import_storage.sql#L1), [`import-download-url/index.ts`](../supabase/functions/import-download-url/index.ts#L1). |
| Worker DB role separation and direct-table revocation | **Implemented and verified** in tracked migration | [`20261031000001_worker_and_audit_security.sql`](../supabase/migrations/20261031000001_worker_and_audit_security.sql#L8) and lines 241–260. Live secrets/role state remain **not verified**. |
| Worker claim/lease controls | **Partially implemented** | Import/matching claim, read/write/heartbeat RPCs validate lease. Finish RPCs omit `lease_until` predicate; matching data retrieval is tenant-wide. Existing lease tests do not test every database predicate or live DB path. |
| Forced tenant RLS | **Implemented and verified** in tracked migration | Reconciliation tables have ENABLE/FORCE RLS and tenant policies; for example source rows at [`20261029000001_reconciliation_module.sql`](../supabase/migrations/20261029000001_reconciliation_module.sql#L421). Does not prevent same-tenant member plaintext reads or ensure related FK company consistency. |
| Reviewer role boundary for plaintext read | **Partially implemented** | UI gates actions to admin/owner; RLS permits member SELECT on raw data. Direct client queries bypass UI visibility checks. |
| Worker-side exact/probabilistic matching | **Implemented and verified** in code | [`splink_worker.py`](../services/reconciliation/matching/splink_worker.py#L63) uses DataFrame and exact comparison levels, probabilistic score; no field-token architecture or fuzzy edit comparators. |
| Comparison evidence | **Partially implemented** | Candidate schema supports JSON details; active matcher writes `{}` at [`splink_worker.py`](../services/reconciliation/matching/splink_worker.py#L202). |
| Reviewer decision history | **Not implemented** | Table/policy exists at migration lines 361 and 521; active review actions do not insert rows. |
| Atomic match acceptance and complete audit | **Not implemented** | Sequential Supabase requests in [`acceptMatch`](../examples/nextjs/lib/actions/reconciliation.ts#L159); partial writes and ignored results possible. |
| Discrepancy generation and canonical correction | **Not implemented / requires further investigation** | Schema/page/action exist; no active creator found, and resolver only changes discrepancy status/metadata at [`resolveDiscrepancy`](../examples/nextjs/lib/actions/reconciliation.ts#L592). |
| Export bucket and access policy | **Not implemented** in tracked migrations; live configuration **requires further investigation** | Action references bucket at [`exportEntity`](../examples/nextjs/lib/actions/reconciliation.ts#L406); repository search found only import bucket creation/policies. |
| Export authorization and no-plaintext-fallback behavior | **Partially implemented** | Tenant/member check exists; no field allowlist/size limit; inline CSV fallback remains; audit result is ignored. |
| Audit table append-only grants | **Implemented and verified** at migration level | Direct mutations revoked in [`20261101000005_revoke_audit_mutation_grants.sql`](../supabase/migrations/20261101000005_revoke_audit_mutation_grants.sql#L1). |
| Trustworthiness and completeness of application audit | **Partially implemented** | Authenticated `log_audit` is tenant-bound, but arbitrary action/metadata allowed; no read/decrypt audit, some call errors ignored. |
| Application AEAD, wrapped DEKs, KMS/HSM, crypto broker | **Not implemented** | No matching crypto/KMS code found in active services, Next.js or Edge Functions; dependencies absent per contract §1. |
| Local development key adapter and production fail-closed guard | **Not implemented** | Contract requirement only; no provider-mode configuration or adapter in code. |
| Ciphertext sidecar, HMAC token tables, migration state/backfill | **Not implemented** | No associated migration/schema present. |
| Cryptographic, recovery and backup-restore acceptance suite | **Not implemented** | Contract C01–C34 are requirements; no current crypto implementation. `test_encryption.sql` is retired. |
| Full import-to-review-to-export E2E | **Not implemented / not verified** | Existing tests cover focused worker/storage/security behaviors; no end-to-end app test suite was found. |
| Production bucket, IAM, role, backup and key recovery state | **Requires further investigation** | Repository artifacts cannot prove deployed provider config, Storage policy state, backup recoverability or credentials. |
| Product/institutional approval | **Blocked by an external decision** | Contract §§11–12 list outstanding data classification, field-role matrix, KMS/region, upload, retention, recovery and named sign-off gates. |

## 7. Test and recovery requirements

The existing tests provide useful narrow checks:

- `test_import_file_security.py` checks object-reference validation, no
  service-role key in the worker, private bucket policy expectations, and
  worker container restrictions.
- `test_matching_worker_lease.py` checks that matching output is not written
  after a simulated lease loss, heartbeat DB failure closes the run, and
  exception values are not copied into a failure message.
- Supabase pgTAP files test RLS/worker/storage/legacy-key containment at the
  migration level. These do not exercise AEAD, KMS, decryption authorization,
  audit-before-release, or integrated review/export behavior.
- `services/reconciliation/tests/test_encryption.sql` is explicitly retired
  and refers to the unsafe raw-key prototype; it is not an encryption
  validation test.

No tests were run for this read-only assessment. Do not infer the test results
from their presence. Before their corresponding features are enabled, execute
the staged tests in contract §8:

1. **Primitive/interoperability:** official AES-GCM and HMAC vectors; exact
   AAD/serialization bytes; Python/Node round trips; tag/AAD/cross-tenant
   rejection; nonce and aggregate limit reservation, including failed
   inserts, concurrent retries and restarts.
2. **Database/authorization:** direct RLS and ACL checks; tenant-consistent
   relationships; field/purpose/record allowlists; actor/role denial; live,
   expired and reassigned lease; no worker KMS credential; audit failure
   prevents plaintext release.
3. **Migration/recovery:** immutable-source preservation; idempotent additive
   backfill; legacy and new fingerprint compatibility; dual-read safeguards;
   KEK rewrap, DEK/HMAC rotation; isolated backup restore with all historical
   provider versions and authorization policy.
4. **End-to-end:** browser upload -> encrypted Storage -> authorized import
   -> encrypted sidecar -> matching -> reviewer decision -> discrepancy
   correction -> controlled export; include retries, lease loss, partial
   failures, audit outage, synthetic canary scans and cleanup.
5. **Capacity/recovery:** measure import and crypto throughput, Splink runtime,
   peak RSS/temp space, concurrent jobs, KMS latency/throttling, and maximum
   supported records/run using synthetic datasets. Exercise provider outage,
   missing/disabled key, restore, expired lease during processing and
   operational alerts. No supported encrypted capacity or RPO/RTO is
   established yet.

Restore must be tested before plaintext retirement: restore database
ciphertext, sidecar/envelope metadata, token versions and migration state into
an isolated environment; recover external KMS versions and workload policies;
authenticate/decrypt sampled and boundary payloads; verify counts and tenant
links; keep service closed until the complete check passes. A database backup
without recoverable external keys is a potential unrecoverable data-loss
event.

## 8. External decisions and blockers

The following remain unresolved in the contract and cannot safely be inferred
from source:

1. Actual legal/institutional field classification, legal basis, permitted
   purposes, residency, retention, deletion and subject-rights requirements.
2. Accountable data, security and institutional owners and their written
   approval of the contract.
3. Human role/field matrix: owner/admin/member or a dedicated reviewer role;
   entity viewing and which fields can be exported.
4. Production KMS/HSM provider, operating region, key ownership, workload
   identity, provider context binding, recovery/availability objectives and
   old key-version retention.
5. Crypto-broker deployment/identity and exact separation between encryption,
   decryption, audit and import/matching services.
6. File-ingress redesign: trusted server-side upload encryption, who may
   decrypt for parsing, plaintext temporary-file boundaries, storage retry
   semantics and file cleanup.
7. HMAC normalization profiles and migration of current source IDs/row hashes
   without breaking existing same-job duplicate behavior or immutable
   historical rows.
8. Approved invocation, aggregate-byte, message-size, file-size, concurrency,
   Splink capacity and lease budgets, backed by GCM analysis and measurements.
9. Atomic review/discrepancy workflows, comparison evidence schema, export
   bucket/authorization/retention, and synthetic E2E environment.
10. Backup RPO/RTO, key recovery/escrow authority, restore frequency and
    sign-off before retaining ciphertext or retiring plaintext.

## 9. Prioritized remediation plan

This is a sequence of prerequisites, not authorization to begin Phase 2A.3.3:

1. **Approve the contract profile:** product/security owners resolve the
   tenant/field/purpose/role matrix, KMS/provider/region, broker placement,
   file-ingress design, normalization and operational limits. Record
   institutional/legal decisions or their responsible approver. Reconcile
   the worker DEK-handoff residual access with its actual ciphertext scope.
2. **Close current authorization and integrity gaps:** verify effective RLS
   and grants in the target environment; add same-tenant relational integrity
   enforcement to future write APIs; narrow matching records/fields to an
   authorized run; enforce lease expiry in all terminal RPCs; prevent direct
   authenticated plaintext reads before decryption is introduced.
3. **Resolve workflow prerequisites:** implement transactionally persisted
   reviewer decisions and match acceptance, discrepancy creation/resolution,
   value-free comparison evidence, and tracked export bucket/authorization.
   Gate every plaintext release on role/field policy and required audit.
4. **Build synthetic fixtures and performance/recovery harness:** freeze
   standards vectors and normalization fixtures, then measure capacity and
   test KMS outage/restore behavior. Do not use production values/keys.
5. **Only after approval, implement additive KMS/broker/schema:** local-only
   synthetic adapter; production guard; selected provider workload identity;
   private ciphertext/envelope/token sidecars; least-privilege RPCs and audit.
   Never enable the legacy pgsodium prototype.
6. **Implement staged file and row encryption/backfill:** encrypt before
   Storage persistence, preserve immutable source rows, use stable idempotent
   sidecars, verify counts/AAD and recoverability, and gate legacy fallback.
7. **Integrate matching, review, discrepancy and export individually:** HMAC
   exact matching where approved; broker-only authorized decrypt; temporary
   worker handoff only if its DEK scope and exposure are accepted; test each
   feature before enabling it.
8. **Run full E2E, restore, rotation and rollback evidence:** synthetic
   canaries across logs/browser/export; isolated backup restore; measured
   limits; no silent plaintext fallback.
9. **Ciphertext-only transition and retirement:** only in separately approved
   releases after complete coverage, retention approval, restore test,
   rollback-window expiry and named written authorization. Source immutability
   means backfill cannot update source rows.

## 10. Go/no-go recommendation

**NO-GO** for:

- claiming encryption or KMS protection currently exists;
- processing production sensitive records on the assumption that private
  Storage, RLS, the legacy pgsodium columns or worker leases provide
  application encryption;
- enabling sensitive decryption, field-level review, or export;
- starting Phase 2A.3.3 implementation before the contract's applicable
  product/security/institutional gates are approved;
- enabling or restoring legacy pgsodium functions;
- retiring or overwriting existing plaintext rows.

**Limited technical preparation is acceptable:** synthetic test vectors,
performance harness design, architecture review, environment inventory, and
owner decision gathering. The revised contract is a reviewable proposal; this
assessment neither approves it nor marks Phase 2A.3.3 ready/complete.
