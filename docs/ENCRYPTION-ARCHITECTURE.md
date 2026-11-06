# ZamBase — Phase 2A.3.1: Encryption Architecture and Data Classification

> **Assessment and proposal only.** This document describes the repository as
> inspected and recommends a future design. It does not implement application
> encryption, add a KMS provider, change database migrations, or authorize
> production use.

## Executive summary

ZamBase has a multi-tenant Supabase/PostgreSQL foundation, a private import
bucket, and separate Python import and matching workers. RLS and claim-scoped
worker RPCs provide tenant and job/run boundaries. They do **not** encrypt
reconciliation values at the application layer.

The active path currently stores and reads `raw_data`, `normalized_data`,
`canonical_data`, and related values in plaintext. Upload objects are plaintext
in private Storage. The matching worker receives plaintext source data in a
Python process and a pandas DataFrame. Review and export code reads those values
through the authenticated Supabase client, then returns them to the browser or
an export. Database backups therefore contain plaintext.

An earlier migration introduced a prototype `pgsodium` `crypto_secretbox`
scheme and raw key bytes in `reconciliation_encryption_keys`. Later migrations
removed application-facing policies/grants and revoked every legacy
encrypt/decrypt overload. These are containment changes, **not** an active
encryption system or an external key-management design. Do not insert or use
legacy keys/functions.

The recommended direction is versioned envelope encryption with a production
KMS/HSM-protected KEK, short-lived DEKs, separate keyed HMAC tokens for exact
matching, purpose-specific decryption authorization, and additive migration
using sidecar ciphertext records. Keep existing plaintext untouched during
backfill and rollback. Do not retire plaintext until ciphertext, authorization,
rotation, and backup restoration have all passed explicit gates.

The Phase 2A.3.2 classification and cryptographic contract is documented in
[`ENCRYPTION-CONTRACT.md`](./ENCRYPTION-CONTRACT.md). It refines the proposal
into testable requirements but remains provisional and requires accountable
owner approval; it does not represent implemented controls.

## 1. Current architecture (observed)

### Application and database

- Next.js 15 / React 19 provides signup/login, company switching, members,
  audit-log, and reconciliation pages.
- Supabase Auth issues JWTs with memberships and active company claims through
  `custom_access_token_hook`. Core tenant relationships are N:N.
- PostgreSQL 15 holds the company, import, source-record, matching, entity,
  discrepancy, evidence, and reviewer-decision tables.
- Reconciliation tables have RLS enabled/forced. Most authenticated reads are
  tenant-wide for members; RLS is not field-level authorization.
- The database audit log is append-only for application roles after the
  revocation migration. Its metadata is JSONB and therefore must be treated as
  potentially sensitive.

### Workers and storage

- `worker-import` and `worker-match` use different PostgreSQL login roles and
  only their scoped RPCs. They do not receive `postgres` or a Supabase
  `service_role` key. Both can process work from all tenants over time, so each
  process remains a centralized cross-tenant trust boundary.
- Import files are uploaded from the browser to the private
  `reconciliation-imports` bucket. The import worker gets a short-lived,
  claim-bound signed URL from the `import-download-url` Edge Function and
  downloads to a private temporary file.
- Worker containers are non-root, read-only at the root filesystem, have
  dropped capabilities, and use a bounded tmpfs for temporary files.
- The import worker currently parses CSV, JSON arrays, or JSONL and sends the
  same parsed object as both `raw_data` and `normalized_data`. The separate
  `imports/loader.py` helper is not the active worker entrypoint.
- The matching RPC returns plaintext JSON. The worker flattens `raw_data` into
  a pandas DataFrame and calls Splink. Current accepted comparisons/blocking
  are exact equality on validated fields; `comparison_details` is currently
  written as `{}`. Splink/worker memory and possible DuckDB temporary state are
  not application encryption.

### Legacy encryption state

The migration `20261030000002_reconciliation_security_ops.sql` added
`raw_data_encrypted` and `normalized_data_encrypted` columns, a
`reconciliation_encryption_keys` table containing raw key bytes, and
`pgsodium.crypto_secretbox` functions. Current import, matching, review, and
export code does not use them. Migrations
`20261101000003_contain_encryption_keys_and_audit.sql` and
`20261101000007_revoke_all_legacy_crypto_overloads.sql` remove application
access to the key material and revoke the legacy functions. The current schema
does not provide an external KMS, key wrapping, ciphertext-only writes, or
controlled decryption.

## 2. Sensitive-data inventory

Classification is provisional until the product owner and data controllers
define the actual fields, jurisdictions, retention, and permitted purposes.
Every user-provided JSON object must be treated as sensitive until its schema
has been classified.

| Table / column or structure | Sensitive data it may contain | Current storage format | Current writers | Current readers | Proposed protection |
|---|---|---|---|---|---|
| `reconciliation_source_records.raw_data` | Names, DOB, national IDs, passports, beneficiary IDs, phones, addresses, financial/payment identifiers, eligibility/benefit data, and arbitrary imported attributes | Plaintext JSONB; immutable source row | Import worker through `reconciliation_import_insert_record` | Matching worker RPC; tenant members through RLS; review and export Server Actions | Authenticated-encryption ciphertext in a sidecar payload; a bounded import-job row-payload DEK distinct from the uploaded-file DEK; allowlisted, purpose-scoped decryption |
| `reconciliation_source_records.normalized_data` | Same categories as `raw_data`; today the import worker stores an identical copy | Plaintext JSONB | Import worker RPC | Matching worker RPC; tenant members can query the table | Encrypt separately or include as a separately labeled field in a versioned encrypted payload; only persist normalized fields actually needed |
| `reconciliation_source_records.source_record_id` | Source-system keys may be account, beneficiary, or other identifying numbers | Plaintext `text` | Import worker RPC | Tenant members, matching RPC, UI, exports | Encrypt if it must be recovered; otherwise replace with tenant/purpose-specific keyed HMAC token plus opaque internal UUID |
| `reconciliation_source_records.row_hash` | Deterministic fingerprint of the full row; low-entropy values can be guessed and equality is exposed | Unkeyed deterministic SHA-256 hex | Import worker | Tenant members, import detail page, idempotency index | Replace new writes with keyed HMAC under a distinct purpose key or use opaque idempotency IDs; do not expose the digest |
| `reconciliation_entities.canonical_data` | Golden-record PII/financial/eligibility fields copied from source records | Plaintext JSONB | `acceptMatch` Server Action | Tenant members; entity UI; export action/page | Encrypted payload with an entity-scoped envelope; decrypt only for authorized review/export |
| `reconciliation_match_candidates.comparison_details` | May expose compared field names, values, match explanations, or inferred similarity | Plaintext JSONB; currently worker writes `{}` | Matching worker RPC | Tenant members; review page | Store minimized, value-free comparison outcomes; encrypt any necessary field values |
| `reconciliation_match_candidates` IDs and `match_score` | Linkability between source records and a probabilistic identity inference | Plaintext UUIDs and numeric score | Matching worker RPC; review actions | Tenant members; reviewers; exports may include linked IDs | Retain only required metadata; audit access; role/purpose checks; consider pseudonymous references |
| `reconciliation_discrepancies.field_name`, `competing_value` | Conflicting PII or financial values; field name may itself reveal identifier type | Plaintext text + JSONB | Table supports inserts; no automatic discrepancy writer was found | Tenant members; discrepancy page and action | Encrypt values and, if classification requires, field names; authorized reviewer-only decrypt |
| `reconciliation_evidence.evidence` | Arbitrary evidence, external-source data, identifier values, or reviewer notes | Plaintext JSONB | Table supports inserts; no current UI writer found | Tenant members under RLS | Strict evidence schema, data minimization, encrypted sensitive payload |
| `reconciliation_reviewer_decisions.rationale`, `previous_state`, `new_state` | Free text and snapshots can contain values or sensitive reasons | Plaintext text/JSONB | Table supports inserts; current review actions do not write rows here | Tenant members under RLS | Encrypt free-text/snapshots; never copy values into audit metadata; authorized reviewer decrypt |
| `reconciliation_data_sources.connection_config` | Database/API URLs, usernames, passwords, tokens, private hostnames, file paths | Plaintext arbitrary JSONB | `createDataSource` Server Action | Tenant members; data-source page renders the full JSON | Prefer external secret manager references and prohibit credentials in this column; encrypt any unavoidable sensitive config |
| `reconciliation_data_sources.name`, `description` | Business/source labels can identify programs, institutions, or individuals | Plaintext text | Authenticated data-source action | Tenant members | Classify; encrypt only if the business context requires it |
| `reconciliation_import_jobs.file_ref`, status/error metadata | Tenant/source UUID path; errors could become sensitive if raw parser errors are ever persisted | Plaintext text/status/error | UI and import-worker RPCs | Tenant members; import page | Keep opaque references and generic errors; never persist signed URLs, parser excerpts, or data values |
| `reconciliation_reconciliation_runs.blocking_rules`, `comparison_config` | Selected field names and matching strategy; may reveal which identifiers are used | Plaintext JSONB | Run-creation Server Action | Matching worker claim RPC; tenant members | Restrict configuration writers; keep values out; encrypt if classification requires |
| `audit_log.metadata`, `target_id` | Operational IDs, reviewer IDs, action details; future metadata could accidentally contain PII | Plaintext JSONB/text | Triggers, scoped RPCs, Server Actions through `log_audit` | Tenant admins | Allowlist metadata keys and audit schemas; never log field values, DEKs, tokens, or signed URLs |
| Original import objects in `reconciliation-imports` | Entire source file, including all imported PII | Plaintext object in a private bucket (provider-side storage encryption is not application-level encryption) | Browser upload | Claim-bound signed download to import worker | Encrypt before durable Storage write with a vetted streaming-AEAD implementation; retain only ciphertext at rest |
| `reconciliation-exports` object / inline CSV | Canonical and source-record contents | Plaintext CSV if upload succeeds; otherwise CSV returned inline to browser. The bucket is not provisioned by the tracked import-bucket migration | `exportEntity` Server Action | Requesting member through signed URL or inline response | Avoid inline fallback; export only allowlisted fields, encrypt or deliver through a controlled short-lived stream, clean up objects, audit access |
| Worker DB URLs, anon key, KMS credentials | Database passwords, API keys, future KMS identities | Environment/configuration, not application data columns | Operators/deployment platform | Respective container/runtime | Secret manager/workload identity; different role identities; rotate; never log or put in source, image, or browser variables |
| `profiles.full_name`, `profiles.email` and user auth data | Personal identifiers and account data | Plaintext in Supabase Auth/profile tables | Supabase Auth and profile triggers | User and same-company profile readers | Separate account identity from imported subject data; classify and protect per identity-data policy |

### Classification rule

`raw_data`, normalized/canonical values, competing values, evidence, reviewer
snapshots, and source-system identifiers are **highly sensitive by default**.
National identifiers, health/eligibility/benefit data, payment identifiers, and
credentials may require a higher regulatory classification. `company_id`,
opaque internal UUIDs, timestamps, status, and scores are not automatically
anonymous; combinations can still reveal tenant activity or identity linkage.

## 3. Plaintext data-flow map

| Step | Current path and plaintext location | Process / identity with access | Lifetime / persistence |
|---|---|---|---|
| 1. File selection and upload | User selects a plaintext file in the browser; Supabase Storage receives the plaintext object over TLS | User browser; authenticated Supabase client; Storage service | Local file remains under user control; Storage object persists until explicitly removed. Private bucket controls access, not application-layer encryption |
| 2. Job creation | Browser sends `company/source/object` reference; `createImportJob` inserts job metadata | Browser and Next.js Server Action using the user JWT/RLS | Job metadata persists in PostgreSQL |
| 3. Download authorization | Edge Function checks job ID, claim token, status and live lease, then signs the fixed object for 60 seconds | Edge Function has its service-role key; worker receives only the short-lived path | Signed URL is short-lived; the file itself remains plaintext in Storage |
| 4. Worker download | Import worker streams the file to a mode-0600 path in the configured private tmpfs | Dedicated import DB login, public anon API key, import worker process | Temporary plaintext exists until `unlink` in `finally`; file deletion is not guaranteed secure erasure of memory/storage artifacts |
| 5. Parsing and import | Worker parses CSV/JSON/JSONL, computes an unkeyed row hash, and sends the row twice as raw and normalized JSON | Import worker process and Postgres RPC | Per-row plaintext transiently exists in worker memory and SQL request/DB memory; plaintext JSON is then persisted |
| 6. Database insertion | `reconciliation_import_insert_record` validates the claim/lease and inserts `raw_data`, `normalized_data`, `source_record_id`, and `row_hash` | `reconciliation_import_worker` can call the scoped `SECURITY DEFINER` RPC; database owner executes it | Plaintext persists in primary DB, replicas, logs/backups where applicable; source rows are immutable |
| 7. Matching retrieval | `reconciliation_matching_source_records` returns all source rows for the claimed tenant/run, including both JSON fields | Dedicated matching-worker login and database RPC | Plaintext response exists in DB/network/process buffers |
| 8. Splink processing | Python flattens `raw_data` into a pandas DataFrame and runs Splink/DuckDB | Matching worker process | Plaintext exists in DataFrame/DuckDB memory until references/process are released; no secure memory wipe is implemented |
| 9. Candidate persistence | Matching RPC inserts source UUIDs, score, and `comparison_details` (currently `{}`) | Matching worker under a valid run lease | Candidate metadata persists in DB; future field-level details could themselves contain PII |
| 10. Review page | Server-rendered page selects source `raw_data` and candidate `comparison_details`, then renders JSON in the browser | Any tenant member can read through RLS; UI actions are shown only to `admin`/`owner` | Plaintext exists in Next.js request/RSC output and browser memory, DOM, developer tools, and user-controlled copies |
| 11. Canonical entity | `acceptMatch` reads source `raw_data`, forms a simple first-value-wins object, and writes `canonical_data` | Next.js Server Action using the authenticated user's Supabase client/RLS | Plaintext entity persists in DB and is readable by tenant members |
| 12. Discrepancy handling | Page reads `competing_value`; resolver accepts a manual value but currently only changes resolution/reviewer metadata and writes an audit event | Tenant members can read the page via RLS; action checks owner/admin | Existing competing value persists in plaintext; the submitted manual value is transient and is not stored as a canonical result |
| 13. Export | `exportEntity` reads canonical and linked source values, builds CSV in server memory, uploads to `reconciliation-exports` if available, then returns a one-hour URL or inline CSV | Authenticated member Server Action and browser | CSV is plaintext in server memory; uploaded object has no tracked bucket lifecycle/cleanup; fallback delivers full CSV to browser |
| 14. Audit | Mutating workflow events record IDs, counts, scores, and decision metadata; current code has no read/decrypt audit events | DB triggers/RPCs and authorized action caller | Audit metadata persists in PostgreSQL. Current code avoids some raw values, but JSONB is not schema-constrained |

### Database functions and application actions that touch sensitive records

Current SQL paths:

- `reconciliation_import_insert_record`: writes plaintext source JSON under a
  valid import lease.
- `reconciliation_matching_source_records`: reads and returns plaintext source
  JSON under a valid matching lease.
- `reconciliation_matching_write_candidates`: writes candidate links, scores,
  and caller-supplied `comparison_details`.
- `reconciliation_claim_import_jobs`, `reconciliation_claim_matching_runs`,
  heartbeat and finish RPCs: control job/run leases and audit operational
  status; they should not return decrypted data beyond their scoped claim
  metadata.
- `log_audit` and `log_reconciliation_audit`: write audit metadata. The
  reconciliation helper is not executable by application roles after
  containment changes.
- `reconciliation_encrypt_field` / `reconciliation_decrypt_field`: legacy
  prototype functions; application roles cannot execute them and current
  application paths do not call them.

Current Next.js paths:

- `createDataSource` writes `connection_config`; the data-source page selects
  and renders it.
- `createImportJob` creates plaintext-file job metadata.
- Review page reads candidate records and raw source JSON.
- `acceptMatch` reads source JSON, writes `canonical_data`, links identifiers,
  and audits the decision; `rejectMatch` changes candidate status and audits.
- `confirmEntity` changes status and audits.
- `resolveDiscrepancy` reads values but currently does not persist the submitted
  manual value or source winner into a canonical record.
- Entity and discrepancy pages select/render sensitive JSON.
- `exportEntity` reads canonical/source JSON, creates a CSV, attempts Storage
  upload, and may return inline CSV. There is no tracked migration that creates
  the referenced export bucket.

## 4. Recommended envelope-encryption architecture

### Cryptographic envelope

Use a vetted cryptographic library and KMS SDK; do not create a custom
cipher/format or make PostgreSQL a cryptographic service.

1. Generate a cryptographically random 256-bit DEK for a bounded data scope.
2. Encrypt sensitive payloads with an authenticated-encryption construction.
   AES-256-GCM is suitable when implemented by a maintained library, with a
   correct unique nonce for every encryption under the same DEK. For streamed
   files, use a vetted streaming-AEAD format/library rather than inventing a
   chunked GCM protocol.
3. Bind ciphertext to immutable context using AEAD associated data (AAD), for
   example: format version, tenant ID, object type, object ID, field/purpose,
   envelope ID, and scope. Define a canonical encoding and version it. A copied
   ciphertext must fail authentication when used for another tenant, record,
   field, or purpose.
4. Ask the configured external KMS/HSM to wrap the DEK under a KEK. Persist
   only the opaque wrapped DEK and explicit provider, KEK/key ID, key version,
   wrapping algorithm/format, and context version. Never persist plaintext
   production KEKs or DEKs in PostgreSQL, source, logs, images, or backups.
5. Keep an unwrapped DEK only in a short-lived process buffer while processing.
   Clear references and close the scope promptly; do not claim reliable
   zeroization from Python or JavaScript runtimes.
6. Fail closed on KMS, key metadata, authentication-tag, AAD, or key-version
   errors. Never fall back to plaintext or a local development key.

### DEK scope

The Phase 2A.3.2 contract refines this proposal into distinct scopes: one DEK
for each complete uploaded-file object (one whole-message encryption, within
the current 50 MiB boundary), and a separate DEK per bounded import-job
row-payload scope, subject to invocation and aggregate-byte ceilings. A
row-payload scope may need to be partitioned further; do not assume one DEK
covers a whole million-row job. Every separately encrypted payload under a
DEK requires a fresh nonce. Reserve budgets atomically across workers and
create a new DEK before any usage limit is crossed. These are provisional
recommendations pending approval and security analysis.

Do not use the same DEK for HMAC tokens or unrelated purposes. Canonical
entities can combine records from multiple imports, so give each entity (or a
small bounded entity partition) its own envelope rather than inheriting an
arbitrary source file's key. Give evidence and reviewer-snapshot payloads
separate purpose/object scopes where their retention or access rules differ.
This adds envelope metadata and KMS operations, but limits compromise and
rotation blast radius.

### AAD and explicit metadata

Every ciphertext needs an unambiguous algorithm/format version, nonce, tag
(either separately represented or in the library-defined ciphertext format),
AAD format version, envelope reference, and purpose. Envelope metadata needs
provider, key ID, key version, wrapping algorithm/version, wrapped DEK, tenant
and bounded scope, creation time, and lifecycle state. Do not rely on an
implicit "current key" lookup to decrypt historical values.

Do not put PII into KMS encryption context or AAD; use opaque IDs and
classification/purpose labels. Context protects against ciphertext swapping;
it is not a replacement for application authorization.

## 5. Provider-neutral KMS interface

Keep the provider adapter behind one server-only interface. The application
uses logical operations, never provider-specific SDK calls throughout feature
code.

| Operation | Contract |
|---|---|
| `wrap_dek(dek, context)` | Wrap a random DEK under the configured KEK and return opaque wrapped bytes plus provider, key ID/version, wrapping format, and non-sensitive metadata |
| `unwrap_dek(wrapped_dek, expected_context, expected_key)` | Authenticate expected tenant/purpose/scope and unwrap only for an authorized logical operation; return the DEK only to the trusted processing boundary |
| `get_key_metadata(key_id, version)` | Return provider, key/version state, algorithm, enabled/disabled status, and rotation metadata without exposing key material |
| `rotate_key(key_id)` | Initiate/coordinate a new KEK version according to provider capabilities; rotation state is explicit and observable |
| `rewrap_dek(wrapped_dek, old_version, new_version, context)` | Rewrap an existing DEK without changing its data ciphertext when only the KEK version changes |

An encryption/decryption broker should own provider credentials. It should
accept logical requests such as "decrypt allowlisted fields for this live
matching run" or "decrypt these entity fields for this authenticated export,"
not arbitrary ciphertext/company-ID requests. It validates the caller, tenant,
object, field allowlist, purpose, operation, and active claim/lease before
calling the provider. For matching, it can release a short-lived DEK to the
trusted worker over an authenticated channel after that check; the worker must
not receive a general-purpose KMS credential. The matching worker remains a
trusted cross-tenant service, but a stolen worker DB credential alone should
not become an unrestricted decrypt API.

Required targets:

- **Local development:** explicit local-only provider and synthetic data; use
  ephemeral developer/test keys stored outside the repository. This mode is
  not production crypto assurance.
- **AWS KMS:** adapter uses workload identity and KMS key/version metadata.
- **Google Cloud KMS:** adapter uses workload identity and CryptoKey version
  metadata.
- **Azure Key Vault:** adapter uses managed identity and key version metadata.
- **OpenBao Transit:** adapter uses authenticated Transit operations and
  explicit key/version metadata.
- **Institution-managed HSM/KMS:** adapter implements the same contract with
  institution-defined identity, availability, and recovery controls.

Production/staging configuration must explicitly select an approved
non-development provider and key reference. Startup must fail if provider
configuration is absent, points at a development/test provider, lacks
workload identity, or cannot retrieve metadata for the active key. Never
silently fall back to local keys. Use different provider identities and keys
for development, test, staging, and production. Keep the provider allowlist
and production guard in deployment configuration and test it.

## 6. Secure entity matching

### Exact matching with keyed tokens

For exact-match identifier types, define and version a field-specific
normalization contract (including Unicode, case, punctuation, leading zeros,
country/issuer rules, and invalid-value behavior). Generate a
tenant-specific, purpose-specific HMAC token using a dedicated secret key
protected by KMS. Persist the token and its identifier type, normalization
version, HMAC algorithm, key ID/version, and tenant scope; do not persist
plaintext identifier values in the token table.

Keep source values encrypted when they are needed for authorized review or
recovery; HMAC tokens are not a reversible substitute for encrypted source
data. Use a separate key and domain/purpose for each token purpose. Never use
an unkeyed hash for low-entropy national IDs, phone numbers, or dates of birth.

HMAC tokens reveal equality: anyone who can read a tenant's tokens can see
which records have the same normalized identifier, frequency patterns, and
linkability within that tenant/purpose/version. They do not support fuzzy
matching. If an attacker obtains the HMAC key, low-entropy identifiers can be
tested with an offline dictionary. Tenant/purpose keys, restricted token
readers, rate controls, and key rotation reduce but do not eliminate these
risks.

Rotation requires parallel token versions: create the new version, backfill
tokens from authorized plaintext/decrypted values, query both versions during
transition, verify index coverage, then stop writing/removing old tokens only
after recovery and matching behavior is validated. Do not compare version 1
and version 2 tokens as if they were equivalent.

### Fuzzy matching

- Retrieve/decrypt only the fields required by the approved run configuration.
  The run-scoped database API should validate a field allowlist; never return
  every raw JSON field by default.
- Validate the current run claim and lease before retrieval, before/after
  decryption, before expensive matching, and immediately before every write.
- Isolate matching in a restricted worker with bounded memory/CPU, no debug
  dumps, no persistent local database, and a private ephemeral scratch area.
  Configure Splink/DuckDB so spills cannot land on a persistent unprotected
  filesystem. Stop and discard output on lease loss. If the synchronous match
  cannot be interrupted, terminate its isolated process/container within a
  bounded time and do not write candidates.
- Keep plaintext only for the matching operation. Python/NumPy/DuckDB memory
  cannot be reliably zeroized; minimize copies and process lifetime.
- Do not log source rows, comparison values, decrypted fields, wrapped or
  unwrapped keys, signed URLs, or exception text that may contain input.
  Candidate details should contain minimized, value-free comparison outcomes.
- Do not apply fuzzy comparison to HMAC tokens; fuzzy algorithms require
  plaintext values or a separately reviewed privacy-preserving matching
  construction.

## 7. Proposed database changes (additive)

Do not overwrite or drop current plaintext columns, mutate immutable source
rows, or run a production migration as part of this assessment.

Prefer sidecar tables over updating `reconciliation_source_records`: its
immutability trigger rejects every UPDATE, including a naive backfill of
ciphertext columns.

1. `reconciliation_encryption_envelopes`: envelope ID, tenant, bounded scope
   type/ID, purpose, provider, key ID/version, wrapping format/version,
   wrapped DEK, AAD/format version, lifecycle state, timestamps, and optional
   retiring/replaced envelope reference. It contains no plaintext KEK or DEK.
2. `reconciliation_encrypted_payloads`: tenant, logical object type/ID,
   field/purpose, envelope ID, ciphertext, nonce, AEAD format/version, AAD
   version, and creation metadata. Unique constraints prevent ambiguous active
   ciphertext for an object/field/version.
3. `reconciliation_identifier_tokens`: tenant, source-record reference,
   identifier type, normalization version, HMAC key ID/version, algorithm,
   token bytes, and purpose. Index only the exact tenant/type/version/token
   lookup required by the product.
4. `reconciliation_encryption_migrations`: object/scope, migration version,
   state (`plaintext`, `backfill_pending`, `dual`, `verified`,
   `ciphertext_only`, `failed`), counts, timestamps, and generic failure code.
   Do not store plaintext samples, raw exceptions, or unkeyed content hashes.

Keep encrypted payload reads and writes unavailable to direct client table
access. Add narrowly scoped RPCs/authorization wrappers for operations, not a
generic `decrypt(ciphertext, company_id)` function. Workers retain only
job/run-scoped RPC access. The authenticated application must not gain access
to wrapped DEKs or general KMS operations just because it has RLS access to a
tenant.

Existing `raw_data_encrypted` and `normalized_data_encrypted` columns may
remain unused for compatibility; the legacy key table/functions should remain
unavailable until separately reviewed and safely retired. Add constraints and
indexes only after write/read behavior is tested. Do not weaken existing RLS or
the source immutability trigger.

## 8. Authorization and auditing for decryption

KMS authentication alone does not authorize a user to see data. Each logical
decryption must be bound to:

- A verified authenticated user JWT or a named trusted service identity.
- The authoritative tenant derived from membership or a validated job/run,
  never a caller-selected tenant ID.
- The exact record/object and field allowlist.
- A fixed purpose and operation (for example `matching`, `review`, or
  `export`), not a free-form caller string.
- An unexpired claim/lease when the caller is a worker.
- An explicit role/consent/policy check in the database/application layer.

Use different workflows:

- **Matching/import:** worker claims a run/job; scoped RPC derives tenant and
  records; the decryption broker validates the live claim and approved fields;
  the worker gets only the needed plaintext/short-lived DEK. Lease loss stops
  new reads and all writes.
- **Review:** request uses the authenticated user's server-side session.
  Recheck tenant membership, reviewer role, record relation, purpose, and
  fields in a narrow server-side path. Do not expose a generic ciphertext
  endpoint or rely only on a hidden UI button.
- **Export:** explicitly authorize export permission and selected fields,
  decrypt only those fields, generate a bounded export, write an audit event,
  and deliver with a short-lived download capability. Avoid returning large
  sensitive CSVs inline or keeping exports indefinitely in a shared bucket.

Emit an audit event for each sensitive read/decryption operation (or a
bounded, attributable operation event covering a well-defined set of records)
with actor/service, tenant, record/scope reference, purpose, operation,
allowlisted field names, key ID/version, request/run ID, outcome, and time.
Do not log plaintext, ciphertext, DEKs/KEKs, HMAC tokens, signed URLs, or
exception messages containing source input. Fail closed if policy requires an
audit record but the audit write cannot be durably committed. Existing audit
events record many mutations but do not currently record reads or decryptions.

## 9. Migration, verification, and rollback plan

1. **Classify fields and purposes.** Approve data owners, legal basis,
   retention, field allowlists, permitted roles, tenant boundaries, and source
   data contracts. Treat unclassified JSON as sensitive.
2. **Freeze the format contract.** Select the AEAD/streaming library, envelope
   format, AAD canonical encoding, nonce strategy, HMAC normalization/version
   rules, maximum DEK usage, and error semantics. Create test vectors before
   writing production code.
3. **Provision external keys.** Select the production KMS/HSM, workload
   identity, key ownership, region, version/rotation policy, access logging,
   disabled/deleted-key recovery window, and break-glass process. Keep all
   production KEKs external.
4. **Add schema without changing old data.** Add envelope, payload, token, and
   migration-state tables/constraints with deny-by-default RLS and no direct
   client access. Keep old plaintext columns and source immutability intact.
5. **Build controlled backfill.** Use an authenticated, resumable worker that
   reads one bounded tenant/scope, encrypts in memory, and inserts sidecar
   ciphertext transactionally/idempotently. Record progress by IDs/counts and
   generic failures only. Do not update/delete original plaintext rows.
6. **Verify ciphertext.** In an isolated validation process, decrypt under the
   same expected AAD and compare to source using a keyed verification digest
   kept only in the trusted process. Validate row/field counts and
   authentication. No plaintext samples or unkeyed hashes in telemetry.
7. **Dual-read transition.** Deploy readers that understand both validated
   ciphertext and legacy plaintext. Prefer ciphertext only after verification;
   decrypt only through the authorized service. Keep compatibility behind a
   versioned feature flag. Audit fallback-to-plaintext counts and investigate
   every fallback.
8. **Dual-write, then ciphertext-only writes.** During a limited validation
   window, write both formats only if the operational need and access policy
   approve the extra plaintext exposure. Then make all new writes ciphertext
   only, store non-sensitive placeholders in legacy NOT NULL columns if
   necessary, and verify no new plaintext is written.
9. **Backfill and reconcile every retained scope.** Handle deleted/soft-deleted
   tenants, retries, partial files, entities spanning imports, failed runs, and
   orphaned records. Prove every active record is readable through the
   authorized path.
10. **Prove rollback and recovery before retirement.** Restore a full backup
    into an isolated environment, recover all external key versions, decrypt
    representative and boundary-case data, verify counts/integrity and app
    behavior, and test a KMS outage/disabled-key scenario. Keep a compatible
    dual-read release available. Because source rows are immutable, rollback
    must not depend on updating their JSON columns; use versioned readers and
    sidecar state.
11. **Retire plaintext in a later approved release.** Only after documented
    sign-off, restore tests, retention checks, and rollback window completion
    may a separate migration remove or irreversibly clear plaintext. This
    assessment does not authorize that step.

Rollback is an application/configuration rollback, not a destructive database
rollback. Preserve encrypted payloads, envelopes, key versions, migration
state, and existing plaintext during rollout. Do not deploy pre-encryption
code that cannot read ciphertext-only records after the cutover; keep a
compatible release or a tested, separately authorized recovery process.

## 10. Key rotation and disaster recovery

- Separate KEK rotation from DEK rotation. A KMS-managed new KEK version can
  rewrap DEKs without re-encrypting data, but do not assume automatic KMS
  rotation rewraps existing envelopes or removes availability of old versions.
- Track the exact KEK ID/version on every envelope. Rewrap in bounded batches,
  verify the new wrapped DEK can be unwrapped, atomically activate the new
  envelope/version, and retain old key versions through backups and the
  recovery retention period.
- DEK rotation requires decrypting and re-encrypting each bounded payload with
  a new DEK and fresh nonces, then verifying before switching the active
  payload pointer. For a suspected DEK compromise, re-encrypt affected
  ciphertext; rewrapping a compromised DEK is not sufficient.
- HMAC-token key rotation is separate from encryption-key rotation and must
  use the dual-version lookup/backfill plan in section 6.
- Backups must include encrypted payloads, wrapped DEKs, key/provider IDs,
  schema/format versions, and migration state. External KMS/HSM versions,
  authorization, and recovery procedures must remain available for the full
  backup-retention period.
- A database backup without recoverable external keys is a potential
  unrecoverable data-loss event. Conversely, a key backup without the matching
  database metadata/ciphertext is insufficient.
- Define and rehearse KMS outage, key disablement, accidental deletion,
  provider account loss, compromised key, tenant deletion, and region
  recovery. A key-recovery process must not silently bypass tenant/purpose
  authorization.

## 11. Required security tests

### Cryptographic and KMS

- Approved-library test vectors for encryption/decryption; reject modified
  ciphertext, tag, nonce, AAD, format, key ID, and version.
- Verify ciphertext cannot be transplanted between tenants, records, fields,
  scopes, or purposes.
- Test nonce uniqueness under the selected lifecycle/volume limits and all
  retries; no nonce reuse after worker restart.
- Test local provider only in local/test; production and staging startup fail
  closed if it is selected or configuration is missing.
- Test each adapter's wrap/unwrap, key metadata, disabled key, unavailable
  provider, version rotation, rewrap, and old-version recovery. No plaintext
  fallback on any failure.
- Inspect DB rows, logs, crash reports, Docker layers, and backups to ensure
  plaintext KEKs/DEKs never appear.

### Authorization, RLS, and audit

- Cross-tenant, non-member, viewer/member/admin/owner, wrong-purpose,
  wrong-field, wrong-operation, wrong-record, expired-lease, stale-claim,
  replay, and arbitrary-ciphertext negative tests.
- Authenticated review/export decrypts only explicitly allowed records/fields;
  a caller cannot change company ID, object ID, ciphertext, purpose, or key
  reference to broaden access.
- Worker can decrypt only fields and records in its live job/run; after lease
  loss, no new decrypt, candidate write, or finish operation succeeds.
- RLS denies direct access to ciphertext/envelope/token tables unless a
  specific, reviewed workflow requires it.
- Audit success and failure events include identity/scope/purpose/key version
  without values; sensitive read fails closed when required audit cannot be
  recorded.

### Matching, data handling, and migration

- HMAC normalization vectors, tenant/purpose separation, equal-value
  equality-leak documentation, key compromise response, version overlap,
  backfill, and old-token retirement.
- No PII in application, SQL, Splink, DuckDB, container, or KMS logs; no
  persistent DuckDB spill; bounded memory/disk; temporary input cleanup.
- Simulate lease loss before load, during decrypt, during matching, and before
  write; output is discarded and no candidates persist.
- Backfill is idempotent and resumable after process failure; count mismatch,
  duplicate row, corrupt ciphertext, missing key, and partial migration all
  fail visibly without altering the source row.
- Verify the existing immutable-source trigger remains effective and that
  sidecar insertion cannot change tenant/object ownership.
- Test dual-read fallback telemetry, ciphertext-only writes, rollback with
  ciphertext-only rows, and full backup restore with external key recovery.
- Verify export field allowlists, access logging, signed-link expiry, object
  cleanup, CSV formula/content handling, and no inline sensitive fallback.

## 12. Outstanding decisions and risks

1. Which actual columns and source schemas contain national IDs, passport
   numbers, financial/payment IDs, eligibility/benefit data, DOB, phone,
   address, or other regulated data?
2. Which users may review raw source fields? Current tenant-member RLS reads are
   broader than the UI's admin/owner action gates.
3. Which production provider is required, in what region, and who controls
   account recovery, key disablement, rotation approval, and audit retention?
4. Is a per-tenant KEK required, or is an environment-level KEK plus
   tenant/purpose AAD acceptable to the relevant institutions and threat
   model?
5. Where will the encryption authorization broker run, and how will it
   validate short-lived worker claims without giving workers general KMS
   credentials?
6. Should browser uploads be encrypted in a dedicated ingress service before
   Storage, or should a trusted ingress stream through a vetted streaming-AEAD
   library? Either approach must ensure the persisted source object is
   ciphertext and must not expose a KEK to the browser.
7. Which imported values must be exactly recoverable for human review, and
   which can be replaced by keyed tokens or discarded after matching?
8. How long do source files, exports, reviewer rationale, audit events, and
   retired key versions need to remain recoverable?
9. What is the approved data limit and memory budget for Splink? The current
   million-row limit can exceed a small worker's safe in-memory capacity.
10. The review/discrepancy/export workflow is incomplete: reviewer decision
    rows are not written by current actions, manual resolution values are not
    persisted, comparison details are empty, and the export bucket is not
    created by tracked migrations.
11. No local end-to-end import-to-review run was verified in this assessment.
    Local SQL tests do not establish production deployment, provider, privacy,
    or compliance readiness.

## 13. Verification performed for this assessment

On the current local working tree:

- `supabase test db`: **passed**, 4 SQL files / 99 pgTAP assertions.
- `python -m unittest discover -s services/reconciliation/tests -v`:
  **failed at import** of `test_blocking.py`, which imports
  `splink.internals.blocking_rule_creator`; that module is unavailable in the
  declared/installed Splink 3.7.0. The remaining explicit Python unit tests
  passed (19 tests); the local Storage integration class was skipped because
  its environment values were not supplied.
- `npx tsc --noEmit` in `examples/nextjs`: **passed**.
- `npm run build`: **passed**; Next.js compiled and generated 19 routes.
- `npm run lint`: **not runnable non-interactively**; `next lint` prompts to
  create an ESLint configuration and exits without one.

These are local code checks only. They are not cryptographic, KMS, full E2E,
production, legal, or compliance validation.

## 14. Exact Phase 2A implementation order

### Phase 2A.3.2 — Classification and cryptographic contract

The draft contract and acceptance checklist are in
[`ENCRYPTION-CONTRACT.md`](./ENCRYPTION-CONTRACT.md). It specifies proposed
field handling, AES-GCM/AAD serialization, KMS operations, HMAC tokenization,
authorization, migration/recovery rules, and 34 testable criteria. These are
not approved decisions: legal/institutional classification, provider and
region, human access roles, upload boundary, normalization profiles, recovery
policy, and other listed gates remain unresolved. Phase 2A.3.2 is not approved
complete, and Phase 2A.3.3 is not ready to begin implementation.

### Phase 2A.3.3 — KMS boundary and additive schema

Implement the provider-neutral interface and authorization broker, beginning
with local-only test behavior plus the production provider selected by the
owner. Add production fail-closed configuration and workload identity. Add
envelope, encrypted-payload, HMAC-token, and migration-state schema
additively; preserve all plaintext and existing source immutability. Complete
provider, schema/RLS, and recovery-path tests.

### Phase 2A.3.4 — Encrypted ingest and controlled backfill

Encrypt uploaded files at a trusted server-side ingress before durable Storage
persistence; use a distinct wrapped DEK for each file and bounded row-payload
scope; add resumable sidecar backfill for existing rows. Keep legacy plaintext
in place, verify decryption/AAD and record counts, test replay and partial
failure, and deploy dual-read/dual-write only behind explicit operational
gates.

### Phase 2A.3.5 — Authorized matching, review, and export

Add separate HMAC exact-match tokens and migration/rotation coverage. Change
matching retrieval to an allowlisted encrypted-field workflow under a valid
run lease; keep fuzzy plaintext isolated and transient. Add role/field/purpose
authorization and audited decryption for review, discrepancy resolution, and
export. Complete reviewer-decision persistence, actual discrepancy-value
handling, export bucket lifecycle, and E2E acceptance tests.

### Phase 2A.3.6 — Ciphertext-only cutover, rotation, and recovery

Stop plaintext writes after dual-read verification; prove every active scope
has recoverable ciphertext and key versions; rehearse KMS/backup restoration,
rollback, KEK rewrap, DEK rotation, and HMAC rotation. Monitor for plaintext
fallbacks and reject cutover on any count mismatch. Only after owner approval,
legal/retention review, restore success, and expiration of the rollback window
should a separate later migration retire existing plaintext columns/data.

**Recommended order:** 2A.3.2 -> 2A.3.3 -> 2A.3.4 -> 2A.3.5 -> 2A.3.6.
Wait for architecture review before beginning implementation.
